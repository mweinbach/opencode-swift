import Foundation
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import Synchronization

/// Confined JavaScript-subset value model, built-ins, async/Promise runtime, host bridge,
/// snapshot codec, and real AST evaluator for `OpenCodeCore`.
/// Ports `packages/codemode/src/language/*` (Part 2).
extension CodemodeLanguage {
    // MARK: - Core Value & Property Model (src/language/runtime/objects.ts)

    // parity: psychoscript/src/runtime/objects.ts#Value [status=implemented hash=fc0847f6d98c]
    public enum Value: Sendable {
        case undefined
        case null
        case bool(Bool)
        case number(Double)
        case string(JSString)
        case symbol(RuntimeSymbol)
        case object(Obj)
        case hostNamespace(HostNamespace)

        public var isUndefined: Bool {
            if case .undefined = self { return true }
            return false
        }

        public var isNullish: Bool {
            switch self {
            case .undefined, .null: return true
            default: return false
            }
        }

        public var isTruthy: Bool {
            switch self {
            case .undefined, .null: return false
            case .bool(let b): return b
            case .number(let n): return n != 0 && !n.isNaN
            case .string(let s): return !s.isEmpty
            case .symbol, .object, .hostNamespace: return true
            }
        }
    }

    public enum PropertyKey: Equatable, Hashable, Sendable {
        case string(JSString)
        case symbol(RuntimeSymbol)

        public var jsStringKey: JSString? {
            if case .string(let s) = self { return s }
            return nil
        }

        public var stringKey: String? {
            if case .string(let s) = self { return s.toWellFormedString() }
            return nil
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Attributes [status=implemented hash=caacb5e439be]
    public struct Attributes: Equatable, Sendable {
        public let writable: Bool
        public let enumerable: Bool
        public let configurable: Bool

        public init(writable: Bool, enumerable: Bool, configurable: Bool) {
            self.writable = writable
            self.enumerable = enumerable
            self.configurable = configurable
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Getter [status=implemented hash=3173ce79844e]
    public typealias Getter = @Sendable (Value) throws -> Value

    // parity: psychoscript/src/runtime/objects.ts#Setter [status=implemented hash=ba2bab310ffd]
    public typealias Setter = @Sendable (Value, Value) throws -> Void

    /// A getter half of an accessor: a native closure (with the program function that stands for it, when made with
    /// the intrinsics), or a program function, which only program code can call.
    public enum GetterHalf: Sendable {
        case native(Getter, companion: Native?)
        case program(Callable)
    }

    /// A setter half of an accessor; see `GetterHalf`.
    public enum SetterHalf: Sendable {
        case native(Setter, companion: Native?)
        case program(Callable)
    }

    /// The native half a companion function stands for (see `accessorHalf`).
    public enum CompanionHalf: Sendable {
        case getter(Getter)
        case setter(Setter)
    }

    // parity: psychoscript/src/runtime/objects.ts#Slot [status=implemented hash=19ff9a8daf94]
    public enum Slot: Sendable {
        case data(value: Value, writable: Bool, enumerable: Bool, configurable: Bool)
        case accessor(get: GetterHalf?, set: SetterHalf?, enumerable: Bool, configurable: Bool)

        public var enumerable: Bool {
            switch self {
            case .data(_, _, let e, _), .accessor(_, _, let e, _): return e
            }
        }

        public var configurable: Bool {
            switch self {
            case .data(_, _, _, let c), .accessor(_, _, _, let c): return c
            }
        }

        /// The accessor view of this slot, when it is one.
        public var accessorSlot: AccessorSlot? {
            if case .accessor(let g, let s, let e, let c) = self {
                return AccessorSlot(get: g, set: s, enumerable: e, configurable: c)
            }
            return nil
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#AccessorSlot [status=implemented hash=66e5a141210c]
    public struct AccessorSlot: Sendable {
        public var get: GetterHalf?
        public var set: SetterHalf?
        public var enumerable: Bool
        public var configurable: Bool

        public init(get: GetterHalf?, set: SetterHalf?, enumerable: Bool, configurable: Bool) {
            self.get = get
            self.set = set
            self.enumerable = enumerable
            self.configurable = configurable
        }

        public var slot: Slot { .accessor(get: get, set: set, enumerable: enumerable, configurable: configurable) }
    }

    // parity: psychoscript/src/runtime/objects.ts#isProgramHalf [status=implemented hash=6566682f6d4b]
    public static func isProgramHalf(_ half: GetterHalf?) -> Bool {
        if case .program = half { return true }
        return false
    }

    public static func isProgramHalf(_ half: SetterHalf?) -> Bool {
        if case .program = half { return true }
        return false
    }

    // parity: psychoscript/src/runtime/objects.ts#isProgramAccessor [status=implemented hash=cc3498734660]
    public static func isProgramAccessor(_ slot: Slot) -> Bool {
        guard case .accessor(let g, let s, _, _) = slot else { return false }
        return isProgramHalf(g) || isProgramHalf(s)
    }

    /// Whether a slot is an accessor with no getter, which reads as undefined and never crosses to the host.
    static func isSetterOnly(_ slot: Slot) -> Bool {
        if case .accessor(nil, _, _, _) = slot { return true }
        return false
    }

    // parity: psychoscript/src/runtime/objects.ts#accessorFunction [status=implemented hash=8bf2747322e4]
    public static func accessorFunction(_ half: GetterHalf?) -> Callable? {
        switch half {
        case .none: return nil
        case .program(let fn): return fn
        case .native(_, let companion): return companion
        }
    }

    public static func accessorFunction(_ half: SetterHalf?) -> Callable? {
        switch half {
        case .none: return nil
        case .program(let fn): return fn
        case .native(_, let companion): return companion
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#accessorHalf [status=implemented hash=d1c0ff09ea59]
    public static func accessorHalf(getter fn: Callable?) -> GetterHalf? {
        guard let fn else { return nil }
        if let native = fn as? Native, case .getter(let half)? = native.companionHalf {
            return .native(half, companion: native)
        }
        return .program(fn)
    }

    public static func accessorHalf(setter fn: Callable?) -> SetterHalf? {
        guard let fn else { return nil }
        if let native = fn as? Native, case .setter(let half)? = native.companionHalf {
            return .native(half, companion: native)
        }
        return .program(fn)
    }

    /// Whether two getter halves are the same function, as `===` compares them upstream.
    static func sameHalf(_ a: GetterHalf?, _ b: GetterHalf?) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.program(let x), .program(let y)): return x === y
        case (.native(_, let x?), .native(_, let y?)): return x === y
        default: return false
        }
    }

    static func sameHalf(_ a: SetterHalf?, _ b: SetterHalf?) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.program(let x), .program(let y)): return x === y
        case (.native(_, let x?), .native(_, let y?)): return x === y
        default: return false
        }
    }

    private struct MakingState: Sendable {
        var made: [Obj]? = nil
    }

    private static let intrinsicCollector = Mutex<MakingState>(MakingState())

    /// The intrinsics being made by the running task.
    public enum Making {
        /// The `Function.prototype` of the intrinsics being made, for the companions of native accessors.
        @TaskLocal public static var functions: Obj?
    }

    // parity: psychoscript/src/runtime/objects.ts#makingIntrinsics [status=implemented hash=63033f7e6aa5]
    public static func makingIntrinsics<A>(_ first: [Obj], functions: Obj, _ make: () -> A) -> (A, [Obj]) {
        intrinsicCollector.withLock { $0 = MakingState(made: first) }
        let result = Making.$functions.withValue(functions) { make() }
        let collected = intrinsicCollector.withLock { current -> [Obj] in
            let out = current.made ?? first
            current = MakingState()
            return out
        }
        return (result, collected)
    }

    // parity: psychoscript/src/runtime/objects.ts#Protector [status=implemented hash=5b6a25fa5985]
    public final class Protector: Sendable {
        private let state = Mutex(true)

        public init() {}

        /// True while no program has changed `Array.prototype[Symbol.iterator]` or the built-in iterators' `next`.
        public var intact: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    /// The key whose change on a guarded object clears its protector.
    public struct ProtectorGuard: Sendable {
        public let key: PropertyKey
        public let protector: Protector

        public init(key: PropertyKey, protector: Protector) {
            self.key = key
            self.protector = protector
        }
    }

    /// Clears a guarded object's protector when `name` is the key it guards.
    static func guardKey(_ target: Obj, _ name: PropertyKey) {
        if let guarded = target.guardInfo, guarded.key == name {
            guarded.protector.intact = false
        }
    }

    /// Whether arrays may still be iterated directly; see `Protector`.
    static func arrayIterationIntact(_ builtins: Builtins) -> Bool {
        builtins.Array.guardInfo?.protector.intact ?? true
    }

    // parity: psychoscript/src/runtime/objects.ts#changed [status=implemented hash=0c0d55a24986]
    public static func changed(_ target: Obj) {
        if target.intrinsic > 0 {
            target.intrinsic = -target.intrinsic
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#data [status=implemented hash=99de336c7f94]
    public static let data = Attributes(writable: true, enumerable: true, configurable: true)

    // parity: psychoscript/src/runtime/objects.ts#hidden [status=implemented hash=f631adda681d]
    public static let hidden = Attributes(writable: true, enumerable: false, configurable: true)

    // parity: psychoscript/src/runtime/objects.ts#readonly [status=implemented hash=4370648b0586]
    public static let readonly = Attributes(writable: false, enumerable: false, configurable: true)

    // parity: psychoscript/src/runtime/objects.ts#frozen [status=implemented hash=1582b2ffa533]
    public static let frozen = Attributes(writable: false, enumerable: false, configurable: false)

    public struct OmittedSentinel: Equatable, Hashable, Sendable {
        public init() {}
    }

    // parity: psychoscript/src/runtime/objects.ts#OMITTED [status=implemented hash=8cc1d26ad2d7]
    public static let OMITTED = OmittedSentinel()

    // parity: psychoscript/src/runtime/objects.ts#Obj [status=implemented hash=67cc9613ba1d]
    public class Obj: @unchecked Sendable {
        private struct Storage: Sendable {
            var order: [PropertyKey] = []
            var props: [PropertyKey: Slot] = [:]
            var proto: Obj?
            var extensible: Bool = true
            var intrinsic: Int = 0
            var hasProgramAccessors: Bool = false
            var guardInfo: ProtectorGuard? = nil
        }

        private let storage: Mutex<Storage>

        public init(proto: Obj? = nil) {
            self.storage = Mutex(Storage(proto: proto))
            CodemodeLanguage.intrinsicCollector.withLock { state in
                state.made?.append(self)
            }
        }

        /// Whether a program accessor was ever defined here: the bulk readers' cue to take their slow paths.
        public var hasProgramAccessors: Bool {
            get { storage.withLock { $0.hasProgramAccessors } }
            set { storage.withLock { $0.hasProgramAccessors = newValue } }
        }

        /// Only on `Array.prototype` and the built-in iterators' prototype: the key whose change clears the protector.
        public var guardInfo: ProtectorGuard? {
            get { storage.withLock { $0.guardInfo } }
            set { storage.withLock { $0.guardInfo = newValue } }
        }

        public var proto: Obj? {
            get { storage.withLock { $0.proto } }
            set {
                CodemodeLanguage.changed(self)
                storage.withLock { $0.proto = newValue }
            }
        }

        public var extensible: Bool {
            get { storage.withLock { $0.extensible } }
            set {
                CodemodeLanguage.changed(self)
                storage.withLock { $0.extensible = newValue }
            }
        }

        public var intrinsic: Int {
            get { storage.withLock { $0.intrinsic } }
            set { storage.withLock { $0.intrinsic = newValue } }
        }

        open var tag: String { "Object" }

        // parity: psychoscript/src/runtime/objects.ts#Obj.describe [status=implemented hash=02913a46c828]
        open var describe: String {
            if tag == "Object" { return "a data object" }
            let startsVowel = tag.first.map { "AEIO".contains($0) } ?? false
            return "\(startsVowel ? "an" : "a") \(tag)"
        }

        // parity: psychoscript/src/runtime/objects.ts#Obj.toString [status=implemented hash=41f85da0afbd]
        open func jsToString() -> JSString {
            JSString("[object \(tag)]")
        }

        // parity: psychoscript/src/runtime/objects.ts#Obj.toPrimitive [status=implemented hash=f658a26f7c38]
        open func toPrimitive(hint: Hint) -> Value {
            _ = hint
            return .string(jsToString())
        }

        // parity: psychoscript/src/runtime/objects.ts#Obj.toNumber [status=implemented hash=f6c09a6922dc]
        open func toNumber() -> Double {
            coerceToNumber(toPrimitive(hint: .number))
        }

        // parity: psychoscript/src/runtime/objects.ts#Obj.inspect [status=implemented hash=0f78eabb5106]
        open func inspect(_ item: (Value) -> String) -> String {
            let shown = inspectBody(item)
            guard let name = CodemodeLanguage.instanceClassName(self) else { return shown }
            return "\(name) \(shown)"
        }

        private func inspectBody(_ item: (Value) -> String) -> String {
            if !hasProgramAccessors {
                let pairs = CodemodeLanguage.entries(self).map { k, v in
                    "\(CodemodeLanguage.jsonQuote(k)):\(item(v))"
                }
                return "{\(pairs.joined(separator: ","))}"
            }
            // Showing a value never runs program code, so a program accessor shows what it is, as Node does.
            let pairs = CodemodeLanguage.keys(self).map { key -> String in
                let shown: String
                if let slot = CodemodeLanguage.own(self, .string(key)), let accessor = slot.accessorSlot,
                   CodemodeLanguage.isProgramAccessor(slot) {
                    shown = CodemodeLanguage.accessorLabel(accessor)
                } else {
                    shown = item(CodemodeLanguage.getOwn(self, key))
                }
                return "\(CodemodeLanguage.jsonQuote(key)):\(shown)"
            }
            return "{\(pairs.joined(separator: ","))}"
        }

        // parity: psychoscript/src/runtime/objects.ts#Obj.toHost [status=implemented hash=663d9f4bef2f]
        open func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            var dict: [String: JSONValue] = [:]
            if !hasProgramAccessors {
                for (key, value) in CodemodeLanguage.entries(self) where key != "__proto__" {
                    // A setter-only native accessor reads as undefined; it is left out like a program one.
                    if value.isUndefined, let slot = CodemodeLanguage.own(self, .string(key)), CodemodeLanguage.isSetterOnly(slot) {
                        continue
                    }
                    if let copied = item(value) {
                        dict[key.toHostString()] = copied
                    }
                }
                return .object(dict)
            }
            // A getter's value crosses as data (read ahead by the call; see `withReads`), and a setter-only property is left out.
            for key in CodemodeLanguage.keys(self) where key != "__proto__" {
                guard let slot = CodemodeLanguage.own(self, .string(key)), !CodemodeLanguage.isSetterOnly(slot) else { continue }
                if let copied = item(CodemodeLanguage.getOwn(self, key)) {
                    dict[key.toHostString()] = copied
                }
            }
            return .object(dict)
        }

        // parity: psychoscript/src/runtime/objects.ts#Obj.iterator [status=implemented hash=85108493c525]
        open func iterator(_ builtins: Builtins) -> Cursor? {
            _ = builtins
            return nil
        }

        internal func getSlot(_ key: PropertyKey) -> Slot? {
            storage.withLock { $0.props[key] }
        }

        internal func setSlot(_ key: PropertyKey, _ slot: Slot) {
            CodemodeLanguage.changed(self)
            CodemodeLanguage.guardKey(self, key)
            if key == .string("stack"), let error = self as? ErrorObj {
                error.stackSlot?.fix()
            }
            storage.withLock { s in
                if s.props[key] == nil {
                    s.order.append(key)
                }
                s.props[key] = slot
            }
        }

        @discardableResult
        internal func deleteSlot(_ key: PropertyKey) -> Bool {
            CodemodeLanguage.changed(self)
            let removed = storage.withLock { s -> Bool? in
                guard let existing = s.props[key] else { return nil }
                guard existing.configurable else { return false }
                s.props.removeValue(forKey: key)
                s.order.removeAll { $0 == key }
                return true
            }
            guard let removed else { return true }
            if removed {
                CodemodeLanguage.guardKey(self, key)
                if key == .string("stack"), let error = self as? ErrorObj {
                    error.stackSlot?.fix()
                }
            }
            return removed
        }

        internal func orderedKeys() -> [PropertyKey] {
            storage.withLock { $0.order }
        }

        internal func allSlotsSnapshot() -> [(PropertyKey, Slot)] {
            storage.withLock { s in
                s.order.compactMap { k in s.props[k].map { (k, $0) } }
            }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Arr [status=implemented hash=ee5c9661cb82]
    public final class Arr: Obj, @unchecked Sendable {
        private let itemsStorage: Mutex<[Value]>
        /// Indices with no element (holes: elisions, `new Array(n)`, `delete a[i]`, growth past the end). The slot
        /// reads as undefined, but the index is not an own property, and the callback methods skip it. Replacing
        /// the items wholesale fills every hole.
        private let holeStorage = Mutex<Set<Int>>([])

        public init(proto: Obj? = nil, items: [Value] = [], holes: Set<Int> = []) {
            self.itemsStorage = Mutex(items)
            super.init(proto: proto)
            if !holes.isEmpty { holeStorage.withLock { $0 = holes } }
        }

        public var holes: Set<Int> { holeStorage.withLock { $0 } }

        public func isHole(_ index: Int) -> Bool { holeStorage.withLock { $0.contains(index) } }

        /// `delete a[i]`: the element is gone, leaving a hole.
        public func removeItem(at index: Int) {
            CodemodeLanguage.changed(self)
            let size = count
            itemsStorage.withLock { list in
                if index < list.count { list[index] = .undefined }
            }
            holeStorage.withLock { h in
                if index < size { h.insert(index) }
            }
        }

        /// Sets the length: truncating drops elements and holes past it; growing adds holes.
        public func setLength(_ newLen: Int) {
            CodemodeLanguage.changed(self)
            let old = count
            itemsStorage.withLock { list in
                if newLen < list.count {
                    list.removeSubrange(newLen..<list.count)
                } else if newLen > list.count {
                    list.append(contentsOf: repeatElement(Value.undefined, count: newLen - list.count))
                }
            }
            holeStorage.withLock { h in
                h = h.filter { $0 < newLen }
                if newLen > old { for i in old..<newLen { h.insert(i) } }
            }
        }

        public override var tag: String { "Array" }

        // parity: psychoscript/src/runtime/objects.ts#Arr.describe [status=implemented hash=0a95ea6aedd4]
        public override var describe: String { "an array" }

        // parity: psychoscript/src/runtime/objects.ts#Arr.toString [status=implemented hash=63d245ffcfbe]
        public override func jsToString() -> JSString {
            items.map { item -> JSString in
                item.isNullish ? "" : CodemodeLanguage.coerceToString(item)
            }.joinedJS(separator: ",")
        }

        public var items: [Value] {
            get { itemsStorage.withLock { $0 } }
            set {
                CodemodeLanguage.changed(self)
                itemsStorage.withLock { $0 = newValue }
                holeStorage.withLock { if !$0.isEmpty { $0.removeAll() } }
            }
        }

        public var count: Int {
            itemsStorage.withLock { $0.count }
        }

        public func item(at index: Int) -> Value {
            itemsStorage.withLock { list in
                index >= 0 && index < list.count ? list[index] : .undefined
            }
        }

        public func setItem(at index: Int, value: Value) throws {
            try CodemodeLanguage.checkArrayLength(index + 1)
            CodemodeLanguage.changed(self)
            let oldCount = count
            itemsStorage.withLock { list in
                if index >= list.count {
                    list.append(contentsOf: repeatElement(Value.undefined, count: index - list.count + 1))
                }
                list[index] = value
            }
            holeStorage.withLock { h in
                if index > oldCount { for i in oldCount..<index { h.insert(i) } }
                h.remove(index)
            }
        }

        public func append(_ value: Value) throws {
            let next = count + 1
            try CodemodeLanguage.checkArrayLength(next)
            CodemodeLanguage.changed(self)
            itemsStorage.withLock { $0.append(value) }
        }

        // parity: psychoscript/src/runtime/objects.ts#Arr.inspect [status=implemented hash=a2ab8698b068]
        public override func inspect(_ item: (Value) -> String) -> String {
            "[\(items.map(item).joined(separator: ","))]"
        }

        // parity: psychoscript/src/runtime/objects.ts#Arr.toHost [status=implemented hash=df5eea12e013]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            .array(items.map { item($0) ?? .null })
        }

        // parity: psychoscript/src/runtime/objects.ts#Arr.iterator [status=implemented hash=f47f7234d2aa]
        public override func iterator(_ builtins: Builtins) -> Cursor? {
            // Iterated directly only while nothing could make the iterator protocol answer differently.
            if !CodemodeLanguage.arrayIterationIntact(builtins) || proto !== builtins.Array
                || getSlot(.symbol(CodemodeLanguage.IteratorSymbol)) != nil {
                return nil
            }
            let pos = Position(source: .array(self), kind: .values, arrays: builtins.Array)
            return Cursor { pos.step() }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#ErrorObj [status=implemented hash=fac92b3f63ee]
    public final class ErrorObj: Obj, @unchecked Sendable {
        private let failureBox = Mutex<PendingThrow?>(nil)
        private let stackBox = Mutex<StackSlot?>(nil)

        public var failure: PendingThrow? {
            get { failureBox.withLock { $0 } }
            set { failureBox.withLock { $0 = newValue } }
        }

        /// The lazily formatted own `stack` property, while it is the one the error was made with.
        public var stackSlot: StackSlot? {
            get { stackBox.withLock { $0 } }
            set { stackBox.withLock { $0 = newValue } }
        }

        public override var tag: String { "Error" }

        // parity: psychoscript/src/runtime/objects.ts#ErrorObj.toString [status=implemented hash=03085e3a4fc2]
        public override func jsToString() -> JSString {
            let n = CodemodeLanguage.peek(self, .string("name"))
            let m = CodemodeLanguage.peek(self, .string("message"))
            let shownName: JSString = if case .string(let s) = n { s } else { "Error" }
            let shownMessage: JSString = if case .string(let s) = m { s } else { "" }
            if shownMessage.isEmpty { return shownName }
            if shownName.isEmpty { return shownMessage }
            return "\(shownName): \(shownMessage)"
        }

        // parity: psychoscript/src/runtime/objects.ts#ErrorObj.inspect [status=implemented hash=9c76db74334d]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return jsToString().toHostString()
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#errorToString [status=implemented hash=b33867dd972b]
    public static func errorToString(_ selfObj: Obj, read: (Obj, JSString) -> Value = { CodemodeLanguage.peek($0, .string($1)) }) -> JSString {
        let n = read(selfObj, "name")
        let m = read(selfObj, "message")
        let shownName: JSString = n.isUndefined ? "Error" : coerceToString(n)
        let shownMessage: JSString = m.isUndefined ? "" : coerceToString(m)
        if shownMessage.isEmpty { return shownName }
        if shownName.isEmpty { return shownMessage }
        return "\(shownName): \(shownMessage)"
    }

    /// An error's own `stack` slot, a data property to every reader. Its `    at` lines are fixed when the error is
    /// made, and its `name: message` header when it is first read, as V8 formats on first access: a subclass
    /// constructor that sets `this.name` is in the header. The header reads `name` and `message` as display does, so a
    /// program getter there runs no code and reads as undefined.
    // parity: psychoscript/src/runtime/objects.ts#StackSlot [status=implemented hash=4932be8533c3]
    public final class StackSlot: Sendable {
        private enum State: Sendable {
            case pending(String)
            case formatted(Value)
            case detached
        }

        private let state: Mutex<State>

        public init(trace: String) {
            self.state = Mutex(.pending(trace))
        }

        // parity: psychoscript/src/runtime/objects.ts#StackSlot.trace [status=implemented hash=755edaff9050]
        /// The `    at` lines while the header is not formatted yet; `nil` once the value is fixed.
        public var trace: String? {
            state.withLock { s in
                if case .pending(let trace) = s { return trace }
                return nil
            }
        }

        /// The slot's value for `error`, formatting the header on first read; `nil` once a program wrote the property.
        func resolve(_ error: ErrorObj) -> Value? {
            if let trace {
                let text = Value.string(CodemodeLanguage.errorToString(error) + JSString(trace))
                return state.withLock { s -> Value? in
                    switch s {
                    case .pending:
                        s = .formatted(text)
                        return text
                    case .formatted(let v): return v
                    case .detached: return nil
                    }
                }
            }
            return state.withLock { s -> Value? in
                if case .formatted(let v) = s { return v }
                return nil
            }
        }

        /// A write or delete replaced the property: the stored slot is the one every reader sees from now on.
        func fix() {
            state.withLock { $0 = .detached }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Opaque [status=implemented hash=676e74b92f53]
    public class Opaque: Obj, @unchecked Sendable {
        // parity: psychoscript/src/runtime/objects.ts#Opaque.inspect [status=implemented hash=b1ddee5704f2]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return "[opaque reference]"
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Callable [status=implemented hash=43cda50e3d0e]
    public class Callable: Opaque, @unchecked Sendable {
        public override var tag: String { "Function" }

        // parity: psychoscript/src/runtime/objects.ts#Callable.describe [status=implemented hash=ade8adab0d14]
        public override var describe: String { "a function" }

        public override func jsToString() -> JSString {
            let n = CodemodeLanguage.get(self, "name")
            let name: JSString = if case .string(let s) = n { s } else { "" }
            return "function \(name)() { [native code] }"
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Fn [status=implemented hash=95040f747e1c]
    public final class Fn: Callable, @unchecked Sendable {
        public let payload: FunctionPayload
        public let closure: LexEnv
        public let code: Code?
        private let classBox = Mutex<(home: Obj?, klass: ClassInfo?)>((nil, nil))

        public init(proto: Obj?, payload: FunctionPayload, closure: LexEnv, code: Code? = nil) {
            self.payload = payload
            self.closure = closure
            self.code = code
            super.init(proto: proto)
            CodemodeLanguage.define(self, "name", .string(JSString(payload.name ?? "")), CodemodeLanguage.readonly)
            CodemodeLanguage.define(self, "length", .number(Double(payload.expectedArgumentCount)), CodemodeLanguage.readonly)
        }

        /// [[HomeObject]]: the prototype or constructor a class method was defined on.
        public var home: Obj? {
            get { classBox.withLock { $0.home } }
            set { classBox.withLock { $0.home = newValue } }
        }

        /// Set on class constructors only.
        public var klass: ClassInfo? {
            get { classBox.withLock { $0.klass } }
            set { classBox.withLock { $0.klass = newValue } }
        }

        // parity: psychoscript/src/runtime/objects.ts#Fn.generator [status=implemented hash=d29565b01b5b]
        public var generator: Bool {
            if let code {
                return (code.flags & CodeFlags.GENERATOR) != 0
            }
            return payload.isGenerator
        }

        // parity: psychoscript/src/runtime/objects.ts#Fn.inspect [status=implemented hash=259daf040775]
        public override func inspect(_ item: (Value) -> String) -> String {
            guard let klass else { return super.inspect(item) }
            let ownName = CodemodeLanguage.ownName(self)
            let name = ownName.isEmpty ? "(anonymous)" : ownName
            let parent: String = if klass.derived, let p = proto as? Callable { CodemodeLanguage.ownName(p) } else { "" }
            return parent.isEmpty ? "[class \(name)]" : "[class \(name) extends \(parent)]"
        }
    }

    /// A function's own string `name`, read without running program code.
    static func ownName(_ target: Obj) -> String {
        if case .data(.string(let s), _, _, _)? = own(target, .string("name")) { return s.toWellFormedString() }
        return ""
    }

    /// The class an instance was made by, read from its prototype's own `constructor` without running program code.
    static func instanceClassName(_ target: Obj) -> String? {
        guard let proto = target.proto,
              case .data(.object(let ctor as Fn), _, _, _)? = own(proto, .string("constructor")),
              ctor.klass != nil else { return nil }
        let name = ownName(ctor)
        return name.isEmpty ? nil : name
    }

    // parity: psychoscript/src/runtime/objects.ts#ClassInfo [status=implemented hash=948840d21b9e]
    /// What a class constructor knows about its class.
    public final class ClassInfo: @unchecked Sendable {
        public let derived: Bool
        private let fieldsBox: Mutex<Fn?>
        public let errorBase: Callable?

        public init(derived: Bool, fields: Fn? = nil, errorBase: Callable? = nil) {
            self.derived = derived
            self.fieldsBox = Mutex(fields)
            self.errorBase = errorBase
        }

        public var fields: Fn? {
            get { fieldsBox.withLock { $0 } }
            set { fieldsBox.withLock { $0 = newValue } }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Arguments [status=implemented hash=9d399d8fca8e]
    public final class Arguments: Obj, @unchecked Sendable {
        public let values: [Value]

        public init(proto: Obj?, values: [Value]) {
            self.values = values
            super.init(proto: proto)
            for (idx, v) in values.enumerated() {
                CodemodeLanguage.define(self, JSString(String(idx)), v, CodemodeLanguage.data)
            }
            CodemodeLanguage.define(self, "length", .number(Double(values.count)), CodemodeLanguage.hidden)
        }

        public override var tag: String { "Arguments" }

        // parity: psychoscript/src/runtime/objects.ts#Arguments.iterator [status=implemented hash=be0f48ac0f23]
        public override func iterator(_ builtins: Builtins) -> Cursor? {
            // With program accessors, its own elements are read in program code through the iterator protocol.
            if hasProgramAccessors || !CodemodeLanguage.arrayIterationIntact(builtins) { return nil }
            let snapshot = Arr(
                proto: builtins.Array,
                items: CodemodeLanguage.keys(self).map { CodemodeLanguage.get(self, $0) }
            )
            let pos = Position(source: .array(snapshot), kind: .values, arrays: builtins.Array)
            return Cursor { pos.step() }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#NativeResult [status=adapted hash=470362e40834]
    /// A native body's result. Upstream's VM signals (`Push`, `Resume`, `Invoke`, `Convert`, `Prefetch`) are carried
    /// out by the async natives themselves here, through the `Evaluator` they receive (see `withReads`).
    public typealias NativeResult = Value

    // parity: psychoscript/src/runtime/objects.ts#NativeCall [status=implemented hash=ef5160b0a31b]
    public typealias NativeCall = @Sendable (Value, [Value], AstNode?, Evaluator) async throws -> Value

    // parity: psychoscript/src/runtime/objects.ts#NativeConstruct [status=implemented hash=e31fbec4eefd]
    public typealias NativeConstruct = @Sendable ([Value], Callable, Evaluator) async throws -> Value

    // parity: psychoscript/src/runtime/objects.ts#NativeOptions [status=implemented hash=0818412d8971]
    public struct NativeOptions: Sendable {
        public let name: String
        public let length: Int
        public let call: NativeCall
        public let construct: NativeConstruct?
        public let callback: Bool

        public init(
            name: String,
            length: Int = 0,
            call: @escaping NativeCall,
            construct: NativeConstruct? = nil,
            callback: Bool = true
        ) {
            self.name = name
            self.length = length
            self.call = call
            self.construct = construct
            self.callback = callback
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#RuntimeNative [status=implemented hash=904d0daf81a5]
    public typealias RuntimeNative = Native

    // parity: psychoscript/src/runtime/objects.ts#nativeRule [status=implemented hash=4401dc343cdb]
    public static func nativeRule(_ fn: Native) -> Bool {
        fn.supportsCallback
    }

    // parity: psychoscript/src/runtime/objects.ts#Builtin [status=implemented hash=299d59de4dd8]
    public class Builtin: Callable, @unchecked Sendable {
        public let callFn: NativeCall
        public let constructFn: NativeConstruct?
        public let supportsCallback: Bool
        /// Set on the companion function of a native accessor half (see `accessorHalf`).
        public let companionHalf: CompanionHalf?

        public init(proto: Obj?, options: NativeOptions, companion: CompanionHalf? = nil) {
            self.callFn = CodemodeLanguage.trappingAccessors(options.call)
            self.constructFn = options.construct.map(CodemodeLanguage.trappingAccessors)
            self.supportsCallback = options.callback
            self.companionHalf = companion
            super.init(proto: proto)
            CodemodeLanguage.define(self, "name", .string(JSString(options.name)), CodemodeLanguage.readonly)
            CodemodeLanguage.define(self, "length", .number(Double(options.length)), CodemodeLanguage.readonly)
        }

        // parity: psychoscript/src/runtime/objects.ts#Builtin.invoke [status=implemented hash=f42def51ed94]
        open func invoke(thisValue: Value, args: [Value], site: AstNode?, evaluator: Evaluator) async throws -> NativeResult {
            try await callFn(thisValue, args, site, evaluator)
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Native [status=implemented hash=d30439a4a8a9]
    public final class Native: Builtin, @unchecked Sendable {
        // parity: psychoscript/src/runtime/objects.ts#Native.invoke [status=implemented hash=18e5e0e7fb16]
        public override func invoke(thisValue: Value, args: [Value], site: AstNode?, evaluator: Evaluator) async throws -> NativeResult {
            try await callFn(thisValue, args, site, evaluator)
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#BoundFn [status=implemented hash=400012faf124]
    public final class BoundFn: Callable, @unchecked Sendable {
        public let target: Callable
        public let boundThis: Value
        public let boundArgs: [Value]

        /// `name` and `length` are the target's, as `Function.prototype.bind` read them.
        public init(proto: Obj?, target: Callable, boundThis: Value, boundArgs: [Value], name: JSString, length: Int) {
            self.target = target
            self.boundThis = boundThis
            self.boundArgs = boundArgs
            super.init(proto: proto)
            CodemodeLanguage.define(self, "length", .number(Double(length)), CodemodeLanguage.readonly)
            CodemodeLanguage.define(self, "name", .string("bound \(name)"), CodemodeLanguage.readonly)
        }

        // parity: psychoscript/src/runtime/objects.ts#BoundFn.invoke [status=implemented hash=7347864c0626]
        public func invoke(thisValue _: Value, args: [Value], site: AstNode?, evaluator: Evaluator) async throws -> NativeResult {
            try await evaluator.callCallable(.object(target), thisValue: boundThis, args: boundArgs + args, site: site)
        }
    }

    /// The "already resolved" record a `resolve`/`reject` pair shares: only the first call of either settles.
    public final class ResolvingFlag: Sendable {
        private let done = Mutex(false)
        public init() {}
        /// Marks the pair used; false when it already was.
        public func claim() -> Bool {
            done.withLock { d -> Bool in
                if d { return false }
                d = true
                return true
            }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Resolver [status=implemented hash=bac9ce16190b]
    public final class Resolver: Callable, @unchecked Sendable {
        public let promise: PromiseObj
        public let isReject: Bool
        public let flag: ResolvingFlag

        public init(proto: Obj?, promise: PromiseObj, isReject: Bool, flag: ResolvingFlag = ResolvingFlag()) {
            self.promise = promise
            self.isReject = isReject
            self.flag = flag
            super.init(proto: proto)
            CodemodeLanguage.define(self, "length", .number(1), CodemodeLanguage.readonly)
            CodemodeLanguage.define(self, "name", .string(""), CodemodeLanguage.readonly)
        }

        // parity: psychoscript/src/runtime/objects.ts#Resolver.invoke [status=implemented hash=3adb149c1f68]
        public func invoke(thisValue _: Value, args: [Value]) -> NativeResult {
            guard flag.claim() else { return .undefined }
            let arg = args.first ?? .undefined
            if isReject {
                promise.reject(arg)
            } else {
                promise.fulfill(arg)
            }
            return .undefined
        }
    }

    public enum PromiseStatus: Sendable {
        case pending
        case fulfilled(Value)
        case rejected(Value)
    }

    /// A promise reaction: runs as a job once the promise settles (upstream `VmScheduler.then`).
    public typealias PromiseReaction = @Sendable (PromiseOutcome) async -> Void

    // parity: psychoscript/src/runtime/objects.ts#PromiseObj [status=adapted hash=bfc6c5015f28]
    public final class PromiseObj: Opaque, @unchecked Sendable {
        private struct State: Sendable {
            var status: PromiseStatus = .pending
            var observed: Bool = false
            var hasAttachedHostWork: Bool = false
            var hostCallKey: String? = nil
            var rawRejection: (any Error)? = nil
            var task: Task<PromiseOutcome, Never>? = nil
            var abortController: AbortController? = nil
            var reactions: [PromiseReaction] = []
            var settlementObservers: [@Sendable () -> Void] = []
            var nextWaiterId: Int = 1
            var waiters: [Int: CheckedContinuation<PromiseOutcome, Never>] = [:]
        }

        private let pState: Mutex<State>
        /// The run this promise belongs to: its reactions run as that run's jobs, in order.
        public let scheduler: ProgramScheduler?
        /// Creation order, which orders unhandled-rejection warnings.
        public let id: Int

        public init(
            proto: Obj?,
            status: PromiseStatus = .pending,
            task: Task<PromiseOutcome, Never>? = nil,
            hostCallKey: String? = nil,
            rawRejection: (any Error)? = nil
        ) {
            let scheduler = ProgramScheduler.current
            self.scheduler = scheduler
            self.id = scheduler?.newPromiseId() ?? 0
            self.pState = Mutex(State(status: status, observed: false, hostCallKey: hostCallKey, rawRejection: rawRejection))
            super.init(proto: proto)
            if case .rejected(let reason) = status, !(rawRejection is Interruption) {
                scheduler?.noteUnhandled(self, reason)
            }
            if let task {
                attachTask(task)
            }
        }

        public override var tag: String { "Promise" }

        // parity: psychoscript/src/runtime/objects.ts#PromiseObj.describe [status=implemented hash=c8e4293af100]
        public override var describe: String { "an un-awaited Promise" }

        // parity: psychoscript/src/runtime/objects.ts#PromiseObj.inspect [status=implemented hash=26311df63d08]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return "[Promise (await it to get its value)]"
        }

        public var status: PromiseStatus {
            pState.withLock { $0.status }
        }

        public var rawRejection: (any Error)? {
            pState.withLock { $0.rawRejection }
        }

        public var isPending: Bool {
            if case .pending = status { return true }
            return false
        }

        public var isObserved: Bool {
            get { pState.withLock { $0.observed } }
            set {
                pState.withLock { $0.observed = newValue }
                if newValue { scheduler?.noteHandled(self) }
            }
        }

        public var hostCallKey: String? {
            pState.withLock { $0.hostCallKey }
        }

        public var hasAttachedHostWork: Bool {
            pState.withLock { $0.hasAttachedHostWork }
        }

        public func attachAbortController(_ controller: AbortController) {
            pState.withLock { $0.abortController = controller }
        }

        /// Registers an internal settlement observer without marking the promise observed by program code.
        public func addSettlementObserver(_ observer: @escaping @Sendable () -> Void) {
            let alreadySettled = pState.withLock { s -> Bool in
                if case .pending = s.status {
                    s.settlementObservers.append(observer)
                    return false
                }
                return true
            }
            if alreadySettled { observer() }
        }

        /// Marks this pending host promise as active host work in `scheduler` if it is not already attached to a task.
        public func registerExternalHostWorkIfNeeded(in scheduler: ProgramScheduler) {
            let needsRegistration = pState.withLock { s -> Bool in
                guard case .pending = s.status, !s.hasAttachedHostWork else { return false }
                s.hasAttachedHostWork = true
                return true
            }
            guard needsRegistration else { return }
            let seq = scheduler.beginHostWork()
            addSettlementObserver { [weak scheduler] in
                scheduler?.deliver(seq: seq) {}
            }
        }

        /// Settles with the outcome of host work running outside the job loop: the outcome is delivered through the
        /// run's inbox, so it lands between jobs like upstream host completions.
        public func attachTask(_ task: Task<PromiseOutcome, Never>) {
            pState.withLock { s in
                s.task = task
                s.hasAttachedHostWork = true
            }
            guard let scheduler else {
                Task { [weak self] in
                    let outcome = await task.value
                    self?.settle(outcome)
                }
                return
            }
            let seq = scheduler.beginHostWork()
            Task { [weak self] in
                let outcome = await task.value
                let promise = self
                scheduler.deliver(seq: seq) { promise?.settle(outcome) }
            }
        }

        /// Settles with a host call whose rejection may carry an unmaterialized `HostFailure`, `PendingThrow`, or `Interruption`.
        public func attachHostTask(_ task: Task<(outcome: PromiseOutcome, rawError: (any Error)?), Never>) {
            let bridged = Task<PromiseOutcome, Never> {
                let pair = await task.value
                if let raw = pair.rawError {
                    self.pState.withLock { s in
                        if case .pending = s.status { s.rawRejection = raw }
                    }
                }
                return pair.outcome
            }
            attachTask(bridged)
        }

        /// Adds a reaction (upstream `VmScheduler.then`): queued now if settled, else when it settles. Marks the
        /// promise handled.
        public func addReaction(_ reaction: @escaping PromiseReaction) {
            let settled = pState.withLock { s -> PromiseOutcome? in
                s.observed = true
                switch s.status {
                case .pending:
                    s.reactions.append(reaction)
                    return nil
                case .fulfilled(let v): return .fulfilled(v)
                case .rejected(let r): return .rejected(r)
                }
            }
            guard let settled else { return }
            if case .rejected = settled { scheduler?.noteHandled(self) }
            schedule(reaction, settled)
        }

        private func schedule(_ reaction: @escaping PromiseReaction, _ outcome: PromiseOutcome) {
            if let scheduler {
                scheduler.enqueue { await reaction(outcome) }
            } else {
                Task { await reaction(outcome) }
            }
        }

        public func settle(_ outcome: PromiseOutcome, rawError: (any Error)? = nil) {
            let taken = pState.withLock { s -> (reactions: [PromiseReaction], waiters: [CheckedContinuation<PromiseOutcome, Never>], observers: [@Sendable () -> Void], handled: Bool, suppressUnhandled: Bool)? in
                guard case .pending = s.status else { return nil }
                if let rawError { s.rawRejection = rawError }
                switch outcome {
                case .fulfilled(let v): s.status = .fulfilled(v)
                case .rejected(let r): s.status = .rejected(r)
                }
                let reactions = s.reactions
                s.reactions = []
                let list = Array(s.waiters.values)
                s.waiters.removeAll()
                let observers = s.settlementObservers
                s.settlementObservers.removeAll()
                s.task = nil
                return (reactions, list, observers, s.observed, s.rawRejection is Interruption)
            }
            Contract.promiseControllers.remove(self)
            guard let taken else { return }
            if case .rejected(let reason) = outcome, !taken.handled, !taken.suppressUnhandled {
                scheduler?.noteUnhandled(self, reason)
            }
            for obs in taken.observers {
                obs()
            }
            for cont in taken.waiters {
                cont.resume(returning: outcome)
            }
            for reaction in taken.reactions {
                schedule(reaction, outcome)
            }
        }

        public func fulfill(_ value: Value) {
            settle(.fulfilled(value))
        }

        public func reject(_ reason: Value, rawError: (any Error)? = nil) {
            settle(.rejected(reason), rawError: rawError)
        }

        public func cancelTask() {
            let (toResume, task, controller) = pState.withLock { s -> ([CheckedContinuation<PromiseOutcome, Never>], Task<PromiseOutcome, Never>?, AbortController?) in
                let list = Array(s.waiters.values)
                s.waiters.removeAll()
                let t = s.task
                s.task = nil
                let c = s.abortController
                s.abortController = nil
                return (list, t, c)
            }
            controller?.abort()
            if let synced = Contract.promiseControllers.get(self)?() {
                synced.abort()
            }
            Contract.promiseControllers.remove(self)
            task?.cancel()
            for cont in toResume {
                cont.resume(returning: .rejected(.string("Cancelled")))
            }
        }

        /// Waits for the outcome from outside the run's job loop (host code). Program code awaits with
        /// `Evaluator.awaitValue`, which parks its fiber instead.
        public func awaitOutcome() async -> PromiseOutcome {
            let fast = pState.withLock { s -> PromiseOutcome? in
                s.observed = true
                switch s.status {
                case .fulfilled(let v): return .fulfilled(v)
                case .rejected(let r): return .rejected(r)
                case .pending: return nil
                }
            }
            if let fast {
                if case .rejected = fast { scheduler?.noteHandled(self) }
                return fast
            }
            scheduler?.noteHandled(self)

            let waiterId = pState.withLock { s -> Int in
                let id = s.nextWaiterId
                s.nextWaiterId += 1
                return id
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let immediate = pState.withLock { s -> PromiseOutcome? in
                        switch s.status {
                        case .fulfilled(let v): return .fulfilled(v)
                        case .rejected(let r): return .rejected(r)
                        case .pending:
                            if Task.isCancelled { return .rejected(.string("Cancelled")) }
                            s.waiters[waiterId] = continuation
                            return nil
                        }
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                    }
                }
            } onCancel: {
                let cancelledCont = pState.withLock { s in
                    s.waiters.removeValue(forKey: waiterId)
                }
                cancelledCont?.resume(returning: .rejected(.string("Cancelled")))
            }
        }
    }

    public enum PromiseOutcome: Sendable {
        case fulfilled(Value)
        case rejected(Value)
    }

    // parity: psychoscript/src/runtime/objects.ts#GeneratorState [status=implemented hash=9cd19fe30442]
    public enum GeneratorState: String, Equatable, Hashable, Sendable, Codable {
        case suspendedStart
        case suspendedYield
        case executing
        case completed
    }

    // parity: psychoscript/src/runtime/objects.ts#GeneratorObj [status=adapted hash=fa9a9b25f698]
    public final class GeneratorObj: Opaque, @unchecked Sendable {
        /// A request an async generator has not answered yet (upstream AsyncGeneratorRequest).
        struct AsyncRequest: Sendable {
            let kind: GeneratorRequestKind
            let value: Value
            let promise: PromiseObj
        }

        private struct State: Sendable {
            var genState: GeneratorState
            var values: [Value]
            var index: Int = 0
            var returnValue: Value = .undefined
            var body: (@Sendable () async throws -> Value)? = nil
            var fiber: Fiber? = nil
            var failure: PendingThrowBox? = nil
            var requests: [AsyncRequest] = []
        }

        private let gState: Mutex<State>
        public let isAsync: Bool

        /// A generator replaying values computed ahead of time (built-in iterators made as generators).
        public init(proto: Obj?, values: [Value] = [], returnValue: Value = .undefined, isAsync: Bool = false) {
            self.isAsync = isAsync
            self.gState = Mutex(State(genState: .suspendedStart, values: values, index: 0, returnValue: returnValue))
            super.init(proto: proto)
        }

        /// A program generator: `body` runs lazily, as a fiber, while `next`/`return`/`throw` drive it.
        public init(proto: Obj?, isAsync: Bool, body: @escaping @Sendable () async throws -> Value) {
            self.isAsync = isAsync
            self.gState = Mutex(State(genState: .suspendedStart, values: [], index: 0, returnValue: .undefined, body: body))
            super.init(proto: proto)
        }

        public override var tag: String { isAsync ? "AsyncGenerator" : "Generator" }

        // parity: psychoscript/src/runtime/objects.ts#GeneratorObj.describe [status=implemented hash=f23c382e571c]
        public override var describe: String { "a generator" }

        public var state: GeneratorState {
            gState.withLock { $0.genState }
        }

        var isLazy: Bool { gState.withLock { $0.body != nil } }

        public func stepNext() -> Step {
            gState.withLock { s in
                if s.genState == .completed {
                    return Step(value: .undefined, done: true)
                }
                if s.index < s.values.count {
                    s.genState = .suspendedYield
                    let val = s.values[s.index]
                    s.index += 1
                    return Step(value: val, done: false)
                }
                s.genState = .completed
                return Step(value: s.returnValue, done: true)
            }
        }

        public func stepReturn(_ value: Value) -> Step {
            gState.withLock { s in
                s.genState = .completed
                return Step(value: value, done: true)
            }
        }

        // MARK: Lazy (fiber) generators

        /// Runs the body until it yields or completes, starting it or resuming it from its `yield` with `input`.
        private func drive(_ input: FiberInput, scheduler: ProgramScheduler) async -> FiberSignal {
            let (fiber, body) = gState.withLock { s -> (Fiber?, (@Sendable () async throws -> Value)?) in
                s.genState = .executing
                return (s.fiber, s.fiber == nil ? s.body : nil)
            }
            if let fiber {
                return await fiber.resume(input)
            }
            guard let body else { return .finished }
            let started = Fiber(allowsAwait: isAsync, generator: self)
            gState.withLock { $0.fiber = started }
            return await started.start(scheduler: scheduler) { [weak self] in
                do {
                    let value = try await body()
                    self?.gState.withLock { $0.returnValue = value }
                } catch ControlSignal.returnValue(let value) {
                    // `return(v)` completed the body from a `yield`.
                    self?.gState.withLock { $0.returnValue = value }
                } catch {
                    self?.gState.withLock { $0.failure = PendingThrowBox(error) }
                }
            }
        }

        /// What the body's run ended with, once it parked or finished.
        private func settleSignal(_ signal: FiberSignal) -> Swift.Result<Step, Error>? {
            switch signal {
            case .awaiting:
                return nil
            case .yielded(let v):
                gState.withLock { $0.genState = .suspendedYield }
                return .success(Step(value: v, done: false))
            case .finished:
                return gState.withLock { s -> Swift.Result<Step, Error> in
                    s.genState = .completed
                    s.fiber = nil
                    if let failure = s.failure {
                        s.failure = nil
                        return .failure(failure.error)
                    }
                    let value = s.returnValue
                    s.returnValue = .undefined
                    return .success(Step(value: value, done: true))
                }
            }
        }

        /// One `next`/`return`/`throw` on a synchronous program generator (upstream `generatorStep`).
        public func syncStep(_ kind: GeneratorRequestKind, _ value: Value, scheduler: ProgramScheduler) async throws -> Step {
            let current = state
            switch current {
            case .executing:
                throw typeError("Generator is already running.")
            case .completed:
                switch kind {
                case .next: return Step(value: .undefined, done: true)
                case .return: return Step(value: value, done: true)
                case .throw: throw Throw(value)
                }
            case .suspendedStart:
                if kind == .return {
                    gState.withLock { $0.genState = .completed; $0.body = nil }
                    return Step(value: value, done: true)
                }
                if kind == .throw {
                    gState.withLock { $0.genState = .completed; $0.body = nil }
                    throw Throw(value)
                }
            case .suspendedYield:
                break
            }
            let input: FiberInput
            switch kind {
            case .next: input = .outcome(.fulfilled(value))
            case .throw: input = .outcome(.rejected(value))
            case .return: input = .returning(value)
            }
            let signal = await drive(input, scheduler: scheduler)
            switch settleSignal(signal) {
            case .success(let step)?: return step
            case .failure(let error)?: throw error
            case nil: throw typeError("A synchronous generator cannot await.")
            }
        }

        /// Inside the body: `yield value` (or `await` in an async generator, see `Evaluator.awaitValue`).
        func yieldFromBody(_ value: Value, fiber: Fiber) async -> FiberInput {
            await fiber.park(.yielded(value))
        }

        // MARK: Async generators (upstream AsyncGeneratorEnqueue / AsyncGeneratorResumeNext)

        /// `next`/`return`/`throw` on an async program generator: queues the request and answers with its promise.
        public func asyncEnqueue(_ kind: GeneratorRequestKind, _ value: Value, builtins: Builtins, eval: Evaluator) async -> PromiseObj {
            let promise = PromiseObj(proto: builtins.Promise)
            let idle = gState.withLock { s -> Bool in
                s.requests.append(AsyncRequest(kind: kind, value: value, promise: promise))
                return s.genState != .executing
            }
            if idle { await resumeNext(builtins: builtins, eval: eval) }
            return promise
        }

        /// Answers queued requests while the generator is not running.
        func resumeNext(builtins: Builtins, eval: Evaluator) async {
            while true {
                let next = gState.withLock { s -> (AsyncRequest, GeneratorState)? in
                    guard s.genState != .executing, let head = s.requests.first else { return nil }
                    return (head, s.genState)
                }
                guard let (request, current) = next else { return }
                if current == .completed || (current == .suspendedStart && request.kind != .next) {
                    gState.withLock { s in
                        s.genState = .completed
                        s.body = nil
                        s.requests.removeFirst()
                    }
                    switch request.kind {
                    case .next:
                        request.promise.fulfill(.object(iteratorResult(builtins, value: .undefined, done: true)))
                    case .throw:
                        request.promise.reject(request.value)
                    case .return:
                        // `return(v)` on a completed async generator awaits `v` first.
                        let awaited = eval.promiseResolve(request.value)
                        awaited.addReaction { outcome in
                            switch outcome {
                            case .fulfilled(let v): request.promise.fulfill(.object(iteratorResult(builtins, value: v, done: true)))
                            case .rejected(let r): request.promise.reject(r)
                            }
                        }
                    }
                    continue
                }
                let input: FiberInput
                switch request.kind {
                case .next: input = .outcome(.fulfilled(request.value))
                case .throw: input = .outcome(.rejected(request.value))
                case .return: input = .returning(request.value)
                }
                let signal = await drive(input, scheduler: eval.scheduler)
                await handleAsyncSignal(signal, builtins: builtins, eval: eval)
                return
            }
        }

        /// The body parked or finished after running: answers the head request, then the rest.
        func handleAsyncSignal(_ signal: FiberSignal, builtins: Builtins, eval: Evaluator) async {
            guard let outcome = settleSignal(signal) else { return }
            let head = gState.withLock { s -> AsyncRequest? in
                s.requests.isEmpty ? nil : s.requests.removeFirst()
            }
            if let head {
                switch outcome {
                case .success(let step):
                    head.promise.fulfill(.object(iteratorResult(builtins, value: step.value, done: step.done)))
                case .failure(let error):
                    head.promise.reject(materialize(builtins, error))
                }
            }
            await resumeNext(builtins: builtins, eval: eval)
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Step [status=implemented hash=682c569065d6]
    public struct Step: Sendable {
        public let value: Value
        public let done: Bool

        public init(value: Value, done: Bool) {
            self.value = value
            self.done = done
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Cursor [status=implemented hash=37ac66df8623]
    public struct Cursor: Sendable {
        public let next: @Sendable () throws -> Step

        public init(next: @escaping @Sendable () throws -> Step) {
            self.next = next
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#CustomIterator [status=implemented hash=2dfeb30c3058]
    public struct CustomIterator: Sendable {
        public let object: Obj
        public let nextMethod: Value

        public init(object: Obj, nextMethod: Value) {
            self.object = object
            self.nextMethod = nextMethod
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#IterationKind [status=implemented hash=5bf9e0749a94]
    public enum IterationKind: String, Equatable, Hashable, Sendable, Codable {
        case keys
        case values
        case entries
    }

    // parity: psychoscript/src/runtime/objects.ts#PositionSource [status=implemented hash=e288d6bb89d5]
    public enum PositionSource: Sendable {
        case array(Arr)
        case string(JSString)
        case bytes(Bytes)
        case map(MapObj)
        case set(SetObj)
        case headers(HeadersObj)
        case searchParams(URLSearchParamsObj)
    }

    // parity: psychoscript/src/runtime/objects.ts#Position [status=implemented hash=7041e43b2d2a]
    public final class Position: Sendable {
        private let cursorBox: TableCursor
        public let source: PositionSource
        public let kind: IterationKind
        public let arrays: Obj?

        public init(source: PositionSource, kind: IterationKind, arrays: Obj? = nil) {
            self.source = source
            self.kind = kind
            self.arrays = arrays
            let cursor = TableCursor(index: 0, done: false)
            self.cursorBox = cursor
            switch source {
            case .map(let m): m.table.track(cursor)
            case .set(let s): s.table.track(cursor)
            default: break
            }
        }

        public var index: Int {
            get { cursorBox.index }
            set { cursorBox.index = newValue }
        }

        public var done: Bool {
            get { cursorBox.done }
            set { cursorBox.done = newValue }
        }

        private func yieldStep(key: Value, value: Value) -> Step {
            switch kind {
            case .keys: return Step(value: key, done: false)
            case .values: return Step(value: value, done: false)
            case .entries: return Step(value: .object(Arr(proto: arrays, items: [key, value])), done: false)
            }
        }

        private func finish() -> Step {
            cursorBox.done = true
            return Step(value: .undefined, done: true)
        }

        // parity: psychoscript/src/runtime/objects.ts#Position.step [status=implemented hash=2c3b70962e94]
        public func step() -> Step {
            if cursorBox.done { return Step(value: .undefined, done: true) }
            switch source {
            case .string(let str):
                let units = str.utf16Units
                let idx = cursorBox.index
                guard idx < units.count else { return finish() }
                let u = units[idx]
                if u >= 0xD800 && u <= 0xDBFF, idx + 1 < units.count {
                    let lo = units[idx + 1]
                    if lo >= 0xDC00 && lo <= 0xDFFF {
                        cursorBox.index = idx + 2
                        let cp = 0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00))
                        return Step(value: .string(JSString(codePoint: cp)), done: false)
                    }
                }
                cursorBox.index = idx + 1
                return Step(value: .string(JSString(unit: u)), done: false)
            case .map(let m):
                let at = m.table.advance(cursorBox)
                guard at >= 0, let (k, v) = m.table.entry(at: at) else { return Step(value: .undefined, done: true) }
                return yieldStep(key: k, value: v)
            case .set(let s):
                let at = s.table.advance(cursorBox)
                guard at >= 0, let (k, _) = s.table.entry(at: at) else { return Step(value: .undefined, done: true) }
                return yieldStep(key: k, value: k)
            case .headers(let h):
                let list = h.sortedEntries()
                let idx = cursorBox.index
                guard idx < list.count else { return finish() }
                cursorBox.index = idx + 1
                return yieldStep(key: .string(JSString(list[idx].0)), value: .string(JSString(list[idx].1)))
            case .searchParams(let sp):
                let list = sp.pairs
                let idx = cursorBox.index
                guard idx < list.count else { return finish() }
                cursorBox.index = idx + 1
                return yieldStep(key: .string(JSString(list[idx].0)), value: .string(JSString(list[idx].1)))
            case .array(let arr):
                let items = arr.items
                let idx = cursorBox.index
                guard idx < items.count else { return finish() }
                cursorBox.index = idx + 1
                return yieldStep(key: .number(Double(idx)), value: items[idx])
            case .bytes(let b):
                let data = b.data
                let idx = cursorBox.index
                guard idx < data.count else { return finish() }
                cursorBox.index = idx + 1
                return yieldStep(key: .number(Double(idx)), value: .number(Double(data[idx])))
            }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#IteratorObj [status=implemented hash=18d9b2055471]
    public final class IteratorObj: Opaque, @unchecked Sendable {
        public let cursor: Cursor
        /// What a built-in position iterator walks, so iteration can tell an array iterator once the protector clears.
        public let source: PositionSource?

        public init(proto: Obj?, cursor: Cursor, source: PositionSource? = nil) {
            self.cursor = cursor
            self.source = source
            super.init(proto: proto)
        }

        public override var tag: String { "Iterator" }

        // parity: psychoscript/src/runtime/objects.ts#IteratorObj.describe [status=implemented hash=fdef95409458]
        public override var describe: String { "an iterator" }
    }

    // parity: psychoscript/src/runtime/objects.ts#positionIterator [status=implemented hash=b243e01a82e3]
    public static func positionIterator(
        proto: Obj?,
        arrayProto: Obj?,
        source: PositionSource,
        kind: IterationKind
    ) -> IteratorObj {
        let pos = Position(source: source, kind: kind, arrays: arrayProto)
        return IteratorObj(proto: proto, cursor: Cursor { pos.step() }, source: source)
    }

    // parity: psychoscript/src/runtime/objects.ts#Wrapper [status=implemented hash=0e016bb77168]
    public class Wrapper: Obj, @unchecked Sendable {
        // parity: psychoscript/src/runtime/objects.ts#Wrapper.inspect [status=implemented hash=361a036c27c5]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return jsToString().toHostString()
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#DateObj [status=implemented hash=94b9ae8acaf9]
    public final class DateObj: Wrapper, @unchecked Sendable {
        private let msBox: Mutex<Double>

        public init(proto: Obj?, epochMs: Double) {
            self.msBox = Mutex(epochMs)
            super.init(proto: proto)
        }

        public var epochMs: Double {
            get { msBox.withLock { $0 } }
            set { msBox.withLock { $0 = newValue } }
        }

        public override var tag: String { "Date" }

        @inline(never)
        public func toISOString() throws -> String {
            let ms = epochMs
            guard ms.isFinite else { throw CodemodeLanguage.rangeError("Invalid time value.") }
            return CodemodeLanguage.formatISODate(epochMs: ms)
        }

        // parity: psychoscript/src/runtime/objects.ts#DateObj.toString [status=implemented hash=61588c38428e]
        public override func jsToString() -> JSString {
            let ms = epochMs
            guard ms.isFinite else { return "Invalid Date" }
            return JSString(CodemodeLanguage.formatISODate(epochMs: ms))
        }

        // parity: psychoscript/src/runtime/objects.ts#DateObj.toPrimitive [status=implemented hash=8d3d8d376b87]
        public override func toPrimitive(hint: Hint) -> Value {
            if hint == .number { return .number(epochMs) }
            return .string(jsToString())
        }

        // parity: psychoscript/src/runtime/objects.ts#DateObj.toHost [status=implemented hash=9d118f3e3e12]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            _ = item
            return .string(jsToString().toHostString())
        }

        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return jsToString().toHostString()
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#RegExpObj [status=implemented hash=ac7016e48125]
    public final class RegExpObj: Wrapper, @unchecked Sendable {
        public let pattern: JSString
        public let flags: String
        public let compiled: ECMAScriptRegExp
        private let lastIndexBox = Mutex<Double>(0)

        public init(proto: Obj?, compiled: ECMAScriptRegExp) {
            self.compiled = compiled
            self.pattern = JSString(utf16: compiled.patternUnits)
            self.flags = compiled.flags.canonicalString
            super.init(proto: proto)
        }

        public init(proto: Obj?, pattern: JSString, flags: String) {
            let compiled = (try? ECMAScriptRegExp(pattern: pattern.utf16Units, flags: Array(flags.utf16)))
                ?? (try! ECMAScriptRegExp(pattern: [], flags: []))
            self.compiled = compiled
            self.pattern = pattern
            self.flags = compiled.flags.canonicalString
            super.init(proto: proto)
        }

        public convenience init(proto: Obj?, pattern: String, flags: String) {
            self.init(proto: proto, pattern: JSString(pattern), flags: flags)
        }

        /// The pattern as `RegExp.prototype.source` shows it (EscapeRegExpPattern).
        public var source: JSString { JSString(utf16: compiled.escapedSourceUnits) }

        public var lastIndexNumber: Double {
            get { lastIndexBox.withLock { $0 } }
            set { lastIndexBox.withLock { $0 = newValue } }
        }

        public var lastIndex: Int {
            get {
                let n = lastIndexNumber
                if n.isNaN || n <= 0 { return 0 }
                if !n.isFinite { return Int.max }
                return Int(min(n.rounded(.towardZero), Double(Int.max)))
            }
            set { lastIndexNumber = Double(max(0, newValue)) }
        }

        public override var tag: String { "RegExp" }

        // parity: psychoscript/src/runtime/objects.ts#RegExpObj.regex [status=implemented hash=d5d239be00bb]
        public var regex: ECMAScriptRegExp { compiled }

        // parity: psychoscript/src/runtime/objects.ts#RegExpObj.use [status=implemented hash=4494333ab316]
        public func use<T>(_ work: (ECMAScriptRegExp, inout Double) throws -> T) rethrows -> T {
            var idx = lastIndexNumber
            defer { lastIndexNumber = idx }
            return try work(compiled, &idx)
        }

        // parity: psychoscript/src/runtime/objects.ts#RegExpObj.toString [status=implemented hash=0e8045c353fa]
        public override func jsToString() -> JSString {
            JSString("/") + source + JSString("/" + flags)
        }

        // parity: psychoscript/src/runtime/objects.ts#RegExpObj.toHost [status=implemented hash=cb210836aa66]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            _ = item
            return .string(jsToString().toHostString())
        }

        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return jsToString().toHostString()
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#MapObj [status=implemented hash=4a066e5d3d53]
    public final class MapObj: Wrapper, @unchecked Sendable {
        public let table = OrderedTable()

        public override var tag: String { "Map" }

        // parity: psychoscript/src/runtime/objects.ts#MapObj.inspect [status=implemented hash=fa6e3a1aaf8f]
        public override func inspect(_ item: (Value) -> String) -> String {
            let entries = table.liveEntries().map { "[\(item($0.0)),\(item($0.1))]" }
            return "Map(\(entries.count)) [\(entries.joined(separator: ","))]"
        }

        // parity: psychoscript/src/runtime/objects.ts#MapObj.toHost [status=implemented hash=bd2a17211ba5]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            .array(table.liveEntries().map { k, v in
                .array([item(k) ?? .null, item(v) ?? .null])
            })
        }

        // parity: psychoscript/src/runtime/objects.ts#MapObj.iterator [status=implemented hash=d54b3216bc35]
        public override func iterator(_ builtins: Builtins) -> Cursor? {
            let pos = Position(source: .map(self), kind: .entries, arrays: builtins.Array)
            return Cursor { pos.step() }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#SetObj [status=implemented hash=6ef5c35836aa]
    public final class SetObj: Wrapper, @unchecked Sendable {
        public let table = OrderedTable()

        public override var tag: String { "Set" }

        // parity: psychoscript/src/runtime/objects.ts#SetObj.inspect [status=implemented hash=15c11dbec983]
        public override func inspect(_ item: (Value) -> String) -> String {
            let items = table.liveKeys().map(item)
            return "Set(\(items.count)) [\(items.joined(separator: ","))]"
        }

        // parity: psychoscript/src/runtime/objects.ts#SetObj.toHost [status=implemented hash=5ab785c2db81]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            .array(table.liveKeys().map { item($0) ?? .null })
        }

        // parity: psychoscript/src/runtime/objects.ts#SetObj.iterator [status=implemented hash=3b67db699e30]
        public override func iterator(_ builtins: Builtins) -> Cursor? {
            let pos = Position(source: .set(self), kind: .values, arrays: builtins.Array)
            return Cursor { pos.step() }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#WeakMapObj [status=implemented hash=ccefeea13554]
    public final class WeakMapObj: Wrapper, @unchecked Sendable {
        private let mapBox = Mutex<[ObjectIdentifier: Value]>([:])

        public override var tag: String { "WeakMap" }

        // parity: psychoscript/src/runtime/objects.ts#WeakMapObj.inspect [status=implemented hash=89c019638558]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return "WeakMap { <items unknown> }"
        }

        public func get(_ obj: Obj) -> Value { mapBox.withLock { $0[ObjectIdentifier(obj)] ?? .undefined } }
        public func has(_ obj: Obj) -> Bool { mapBox.withLock { $0[ObjectIdentifier(obj)] != nil } }
        public func set(_ obj: Obj, _ val: Value) { mapBox.withLock { $0[ObjectIdentifier(obj)] = val } }
        @discardableResult
        public func delete(_ obj: Obj) -> Bool { mapBox.withLock { $0.removeValue(forKey: ObjectIdentifier(obj)) != nil } }
    }

    // parity: psychoscript/src/runtime/objects.ts#WeakSetObj [status=implemented hash=e9d9461397ee]
    public final class WeakSetObj: Wrapper, @unchecked Sendable {
        private let setBox = Mutex<Set<ObjectIdentifier>>([])

        public override var tag: String { "WeakSet" }

        // parity: psychoscript/src/runtime/objects.ts#WeakSetObj.inspect [status=implemented hash=f4a82a2bce73]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return "WeakSet { <items unknown> }"
        }

        public func has(_ obj: Obj) -> Bool { setBox.withLock { $0.contains(ObjectIdentifier(obj)) } }
        public func add(_ obj: Obj) { setBox.withLock { _ = $0.insert(ObjectIdentifier(obj)) } }
        @discardableResult
        public func delete(_ obj: Obj) -> Bool { setBox.withLock { $0.remove(ObjectIdentifier(obj)) != nil } }
    }

    // parity: psychoscript/src/runtime/objects.ts#URLSearchParamsObj [status=implemented hash=fe229f1ef9a2]
    public final class URLSearchParamsObj: Wrapper, @unchecked Sendable {
        private let pairsBox: Mutex<[(String, String)]>

        public init(proto: Obj?, pairs: [(String, String)] = []) {
            self.pairsBox = Mutex(pairs)
            super.init(proto: proto)
        }

        public var pairs: [(String, String)] {
            get { pairsBox.withLock { $0 } }
            set { pairsBox.withLock { $0 = newValue } }
        }

        public override var tag: String { "URLSearchParams" }

        // parity: psychoscript/src/runtime/objects.ts#URLSearchParamsObj.toString [status=implemented hash=0c724ece7d0a]
        public override func jsToString() -> JSString {
            JSString(pairs.map { k, v in
                "\(CodemodeLanguage.formEncode(k))=\(CodemodeLanguage.formEncode(v))"
            }.joined(separator: "&"))
        }

        // parity: psychoscript/src/runtime/objects.ts#URLSearchParamsObj.toHost [status=implemented hash=8414ef4f12df]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            _ = item
            return .array(pairs.map { .array([.string($0.0), .string($0.1)]) })
        }

        // parity: psychoscript/src/runtime/objects.ts#URLSearchParamsObj.iterator [status=implemented hash=d54b3216bc35]
        public override func iterator(_ builtins: Builtins) -> Cursor? {
            let pos = Position(source: .searchParams(self), kind: .entries, arrays: builtins.Array)
            return Cursor { pos.step() }
        }

        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return jsToString().toHostString()
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#HeadersObj [status=implemented hash=aec0ca5023ce]
    public final class HeadersObj: Wrapper, @unchecked Sendable {
        private let mapBox: Mutex<[String: String]>

        public init(proto: Obj?, initial: [String: String] = [:]) {
            var lowered: [String: String] = [:]
            for (k, v) in initial {
                let lk = k.lowercased()
                if let existing = lowered[lk] {
                    lowered[lk] = "\(existing), \(v)"
                } else {
                    lowered[lk] = v
                }
            }
            self.mapBox = Mutex(lowered)
            super.init(proto: proto)
        }

        public override var tag: String { "Headers" }

        // parity: psychoscript/src/runtime/objects.ts#HeadersObj.inspect [status=implemented hash=6817e885dbbe]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            let pairs = sortedEntries().map { k, v in
                "\(CodemodeLanguage.jsonEscapeString(k)):\(CodemodeLanguage.jsonEscapeString(v))"
            }
            return "Headers {\(pairs.joined(separator: ","))}"
        }

        // parity: psychoscript/src/runtime/objects.ts#HeadersObj.toHost [status=implemented hash=ec0a930ae4c2]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            _ = item
            return .object(asDictionary().mapValues { .string($0) })
        }

        // parity: psychoscript/src/runtime/objects.ts#HeadersObj.iterator [status=implemented hash=d54b3216bc35]
        public override func iterator(_ builtins: Builtins) -> Cursor? {
            let pos = Position(source: .headers(self), kind: .entries, arrays: builtins.Array)
            return Cursor { pos.step() }
        }

        public func getHeader(_ name: String) -> String? {
            mapBox.withLock { $0[name.lowercased()] }
        }

        public func hasHeader(_ name: String) -> Bool {
            mapBox.withLock { $0[name.lowercased()] != nil }
        }

        public func setHeader(_ name: String, _ value: String) {
            mapBox.withLock { $0[name.lowercased()] = value }
        }

        public func appendHeader(_ name: String, _ value: String) {
            let lk = name.lowercased()
            mapBox.withLock { m in
                if let existing = m[lk] { m[lk] = "\(existing), \(value)" }
                else { m[lk] = value }
            }
        }

        public func deleteHeader(_ name: String) {
            mapBox.withLock { _ = $0.removeValue(forKey: name.lowercased()) }
        }

        public func sortedEntries() -> [(String, String)] {
            mapBox.withLock { m in
                m.keys.sorted().compactMap { k in m[k].map { (k, $0) } }
            }
        }

        public func asDictionary() -> [String: String] {
            mapBox.withLock { $0 }
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#URLObj [status=implemented hash=b2dfc2f5a848]
    public final class URLObj: Wrapper, @unchecked Sendable {
        private struct Parts: Sendable {
            var protocolStr: String
            var username: String
            var password: String
            var hostname: String
            var port: String
            var pathname: String
            var search: String
            var hash: String
        }

        private let partsBox: Mutex<Parts>
        public let searchParams: URLSearchParamsObj

        public init(
            proto: Obj?,
            searchParamsProto: Obj?,
            protocolStr: String,
            username: String,
            password: String,
            hostname: String,
            port: String,
            pathname: String,
            search: String,
            hash: String
        ) {
            self.partsBox = Mutex(Parts(
                protocolStr: protocolStr,
                username: username,
                password: password,
                hostname: hostname,
                port: port,
                pathname: pathname,
                search: search,
                hash: hash
            ))
            self.searchParams = URLSearchParamsObj(
                proto: searchParamsProto,
                pairs: CodemodeLanguage.parseQueryString(search)
            )
            super.init(proto: proto)
        }

        public override var tag: String { "URL" }

        public var protocolStr: String {
            get { partsBox.withLock { $0.protocolStr } }
            set { partsBox.withLock { $0.protocolStr = newValue } }
        }
        public var username: String {
            get { partsBox.withLock { $0.username } }
            set { partsBox.withLock { $0.username = newValue } }
        }
        public var password: String {
            get { partsBox.withLock { $0.password } }
            set { partsBox.withLock { $0.password = newValue } }
        }
        public var hostname: String {
            get { partsBox.withLock { $0.hostname } }
            set { partsBox.withLock { $0.hostname = newValue } }
        }
        public var port: String {
            get { partsBox.withLock { $0.port } }
            set { partsBox.withLock { $0.port = newValue } }
        }
        public var pathname: String {
            get { partsBox.withLock { $0.pathname } }
            set { partsBox.withLock { $0.pathname = newValue } }
        }
        public var search: String {
            let qs = searchParams.jsToString().toWellFormedString()
            if !qs.isEmpty { return "?\(qs)" }
            return partsBox.withLock { $0.search }
        }
        public var hashStr: String {
            get { partsBox.withLock { $0.hash } }
            set { partsBox.withLock { $0.hash = newValue } }
        }

        public var host: String {
            let p = partsBox.withLock { $0 }
            return p.port.isEmpty ? p.hostname : "\(p.hostname):\(p.port)"
        }

        public var origin: String {
            let p = partsBox.withLock { $0 }
            if p.protocolStr == "http:" || p.protocolStr == "https:" {
                return "\(p.protocolStr)//\(host)"
            }
            return "null"
        }

        public var href: String {
            let p = partsBox.withLock { $0 }
            var auth = ""
            if !p.username.isEmpty || !p.password.isEmpty {
                auth = p.password.isEmpty ? "\(p.username)@" : "\(p.username):\(p.password)@"
            }
            let h = p.port.isEmpty ? p.hostname : "\(p.hostname):\(p.port)"
            let s = search
            return "\(p.protocolStr)//\(auth)\(h)\(p.pathname)\(s)\(p.hash)"
        }

        // parity: psychoscript/src/runtime/objects.ts#URLObj.toString [status=implemented hash=5d785bac38a1]
        public override func jsToString() -> JSString { JSString(href) }

        // parity: psychoscript/src/runtime/objects.ts#URLObj.toHost [status=implemented hash=e619b7325ffa]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            _ = item
            return .string(href)
        }

        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return href
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#Bytes [status=implemented hash=75eb8520f393]
    /// The memory a Uint8Array views; `subarray` makes another view of the same store (upstream: a host
    /// Uint8Array's ArrayBuffer).
    public final class ByteStore: Sendable {
        let bytes: Mutex<[UInt8]>
        init(_ data: [UInt8]) { bytes = Mutex(data) }
    }

    public class Bytes: Wrapper, @unchecked Sendable {
        public let store: ByteStore
        public let offset: Int
        public let length: Int

        public init(proto: Obj?, data: [UInt8]) {
            self.store = ByteStore(data)
            self.offset = 0
            self.length = data.count
            super.init(proto: proto)
        }

        /// A view of `length` bytes of `store` from `offset`.
        public init(proto: Obj?, store: ByteStore, offset: Int, length: Int) {
            self.store = store
            self.offset = offset
            self.length = length
            super.init(proto: proto)
        }

        /// The viewed bytes; assigning writes them through to the store (a view's length is fixed).
        public var data: [UInt8] {
            get {
                let (start, count) = (offset, length)
                return store.bytes.withLock { Array($0[start..<(start + count)]) }
            }
            set {
                let (start, count) = (offset, length)
                store.bytes.withLock { all in
                    let n = min(count, newValue.count)
                    if n > 0 { all.replaceSubrange(start..<(start + n), with: newValue[0..<n]) }
                }
            }
        }

        /// Writes one byte through to the store.
        public func setByte(_ index: Int, _ value: UInt8) {
            guard index >= 0, index < length else { return }
            let at = offset + index
            store.bytes.withLock { $0[at] = value }
        }

        /// A view of `start..<end` of these bytes, of the same kind (a Buffer's is a Buffer).
        public func view(_ builtins: Builtins, start: Int, end: Int) -> Bytes {
            let count = max(0, end - start)
            if self is BufferObj { return BufferObj(proto: builtins.Buffer, store: store, offset: offset + start, length: count) }
            return Bytes(proto: builtins.Uint8Array, store: store, offset: offset + start, length: count)
        }

        public override var tag: String { "Uint8Array" }

        // parity: psychoscript/src/runtime/objects.ts#Bytes.toString [status=implemented hash=fec9e28744d8]
        public override func jsToString() -> JSString {
            JSString(data.map(String.init).joined(separator: ","))
        }

        // parity: psychoscript/src/runtime/objects.ts#Bytes.inspect [status=implemented hash=ecea006048d8]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            return "Uint8Array(\(data.count)) [\(data.map(String.init).joined(separator: ","))]"
        }

        // parity: psychoscript/src/runtime/objects.ts#Bytes.toHost [status=implemented hash=ea199e6f9110]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            _ = item
            return .array(data.map { .int(Int64($0)) })
        }

        // parity: psychoscript/src/runtime/objects.ts#Bytes.iterator [status=implemented hash=562562bb5226]
        public override func iterator(_ builtins: Builtins) -> Cursor? {
            if !CodemodeLanguage.arrayIterationIntact(builtins) { return nil }
            let pos = Position(source: .bytes(self), kind: .values, arrays: builtins.Array)
            return Cursor { pos.step() }
        }

        // parity: psychoscript/src/runtime/objects.ts#Bytes.derive [status=implemented hash=83f1202c9d20]
        /// New bytes of this one's kind, as `slice`, `subarray`, `map` and `filter` make them (a Buffer's are a Buffer).
        public func derive(_ builtins: Builtins, _ bytes: [UInt8]) -> Bytes {
            Bytes(proto: builtins.Uint8Array, data: bytes)
        }
    }

    // parity: psychoscript/src/stdlib/buffer.ts#BufferObj [status=implemented hash=b6abc1208f58]
    public final class BufferObj: Bytes, @unchecked Sendable {
        public override var tag: String { "Buffer" }

        // parity: psychoscript/src/stdlib/buffer.ts#BufferObj.derive [status=implemented hash=711aafaec7aa]
        public override func derive(_ builtins: Builtins, _ bytes: [UInt8]) -> Bytes {
            BufferObj(proto: builtins.Buffer, data: bytes)
        }

        // parity: psychoscript/src/stdlib/buffer.ts#BufferObj.toString [status=implemented hash=dfb87aa69579]
        public override func jsToString() -> JSString {
            JSString(String(decoding: data, as: UTF8.self))
        }

        // parity: psychoscript/src/stdlib/buffer.ts#BufferObj.toHost [status=implemented hash=12e39c28619e]
        public override func toHost(_ item: (Value) -> JSONValue?) -> JSONValue {
            _ = item
            return .string(bytesToBase64(data))
        }

        // parity: psychoscript/src/stdlib/buffer.ts#BufferObj.inspect [status=implemented hash=b4d8b5d866b7]
        public override func inspect(_ item: (Value) -> String) -> String {
            _ = item
            let bytes = data
            let shown = bytes.prefix(50).map { byte in
                let hex = String(byte, radix: 16, uppercase: false)
                return hex.count == 1 ? "0\(hex)" : hex
            }.joined(separator: " ")
            let more = bytes.count > 50 ? " ... \(bytes.count - 50) more bytes" : ""
            return "<Buffer\(shown.isEmpty ? "" : " \(shown)")\(more)>"
        }
    }

    // parity: psychoscript/src/stdlib/bytes.ts#TextDecoderObj [status=implemented hash=3a7d62285d0a]
    public final class TextDecoderObj: Wrapper, @unchecked Sendable {
        private struct StreamState: Sendable {
            var queued: [UInt8] = []
            var seen: Bool = false
        }

        public let encoding: String
        public let fatal: Bool
        public let ignoreBOM: Bool
        private let streamState = Mutex(StreamState())

        public init(proto: Obj?, encoding: String = "utf-8", fatal: Bool = false, ignoreBOM: Bool = false) {
            self.encoding = encoding
            self.fatal = fatal
            self.ignoreBOM = ignoreBOM
            super.init(proto: proto)
            CodemodeLanguage.define(self, "encoding", .string(JSString(encoding)), CodemodeLanguage.readonly)
            CodemodeLanguage.define(self, "fatal", .bool(fatal), CodemodeLanguage.readonly)
            CodemodeLanguage.define(self, "ignoreBOM", .bool(ignoreBOM), CodemodeLanguage.readonly)
        }

        public override var tag: String { "TextDecoder" }

        /// Decodes UTF-8 bytes with optional streaming incomplete-sequence buffering, BOM stripping, and fatal validation.
        // parity: psychoscript/src/stdlib/bytes.ts#TextDecoderObj.decode [status=implemented hash=fa053c6aebf6]
        public func decode(_ input: [UInt8], stream: Bool = false) throws -> String {
            let (combined, stripBOM) = try streamState.withLock { s -> ([UInt8], Bool) in
                var bytes = input
                if !s.queued.isEmpty && !bytes.isEmpty {
                    try CodemodeLanguage.checkArrayLength(s.queued.count + bytes.count)
                    var joined = s.queued
                    joined.append(contentsOf: bytes)
                    bytes = joined
                } else if bytes.isEmpty {
                    bytes = s.queued
                }
                let boundary: Int
                if stream {
                    var trailing = 0
                    var i = bytes.count - 1
                    while i >= 0 && trailing < 3 && (bytes[i] & 0xC0) == 0x80 {
                        trailing += 1
                        i -= 1
                    }
                    if i >= 0 {
                        let lead = bytes[i]
                        let expected: Int
                        if (lead & 0x80) == 0 { expected = 1 }
                        else if (lead & 0xE0) == 0xC0 { expected = 2 }
                        else if (lead & 0xF0) == 0xE0 { expected = 3 }
                        else if (lead & 0xF8) == 0xF0 { expected = 4 }
                        else { expected = 1 }
                        let available = bytes.count - i
                        boundary = available < expected ? i : bytes.count
                    } else {
                        boundary = bytes.count
                    }
                } else {
                    boundary = bytes.count
                }
                s.queued = boundary < bytes.count ? Array(bytes[boundary...]) : []
                let chunk = boundary == bytes.count ? bytes : Array(bytes[..<boundary])
                let shouldStrip = !ignoreBOM && !s.seen
                if !stream {
                    s.seen = false
                } else if !chunk.isEmpty {
                    s.seen = true
                }
                return (chunk, shouldStrip)
            }

            let text: String
            if fatal {
                guard let strict = String(bytes: combined, encoding: .utf8) else {
                    throw CodemodeLanguage.typeError("TextDecoder.decode: the input is not valid utf-8.")
                }
                text = strict
            } else {
                text = String(decoding: combined, as: UTF8.self)
            }
            if stripBOM && text.unicodeScalars.first == "\u{FEFF}" {
                return String(text.dropFirst())
            }
            return text
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#HostNamespace [status=implemented hash=e0bc7309022d]
    public final class HostNamespace: Sendable {
        public let path: [String]
        public let handler: NamespaceHandler

        public init(path: [String] = [], handler: NamespaceHandler) {
            self.path = path
            self.handler = handler
        }

        public func child(_ segment: String) -> HostNamespace {
            HostNamespace(path: path + [segment], handler: handler)
        }
    }

    // parity: psychoscript/src/streaming-response.ts#StreamingResponse [status=adapted hash=4ef92e639535]
    public final class StreamingResponse: Sendable {
        public let url: String
        public let status: Int
        public let statusText: String
        public let headers: [String: String]
        public let bodyBytes: [UInt8]
        public let redirected: Bool

        public init(
            url: String,
            status: Int,
            statusText: String = "",
            headers: [String: String] = [:],
            bodyBytes: [UInt8] = [],
            redirected: Bool = false
        ) {
            self.url = url
            self.status = status
            self.statusText = statusText
            self.headers = headers
            self.bodyBytes = bodyBytes
            self.redirected = redirected
        }

        public var ok: Bool { status >= 200 && status < 300 }
    }

    // MARK: - Object & Value Helpers (src/language/runtime/objects.ts)

    // parity: psychoscript/src/runtime/objects.ts#coerceToString [status=implemented hash=3bdfa14b7936]
    public static func coerceToString(_ value: Value) -> JSString {
        switch value {
        case .undefined: return "undefined"
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JSString(formatJSNumber(n))
        case .string(let s): return s
        case .symbol(let sym): return JSString(symbolString(sym))
        case .hostNamespace: return "[object Object]"
        case .object(let obj):
            if let arr = obj as? Arr {
                return arr.items.map { item -> JSString in
                    item.isNullish ? "" : coerceToString(item)
                }.joinedJS(separator: ",")
            }
            return obj.jsToString()
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#coerceToNumber [status=implemented hash=e5ceb344502d]
    public static func coerceToNumber(_ value: Value) -> Double {
        switch value {
        case .undefined: return .nan
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let n): return n
        case .string(let s):
            return stringToNumber(s)
        case .symbol: return .nan
        case .hostNamespace: return .nan
        case .object(let obj): return obj.toNumber()
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#coerceToInteger [status=implemented hash=3c3eeb1f4dcc]
    public static func coerceToInteger(_ value: Value) -> Int {
        let n = coerceToNumber(value)
        if n.isNaN || n == 0 { return 0 }
        if n == .infinity { return Int.max }
        if n == -.infinity { return Int.min }
        let t = n.rounded(.towardZero)
        if t >= Double(Int.max) { return Int.max }
        if t <= Double(Int.min) { return Int.min }
        return Int(t)
    }

    // parity: psychoscript/src/runtime/objects.ts#isRuntimeReference [status=implemented hash=eb8168371301]
    public static func isRuntimeReference(_ value: Value) -> Bool {
        switch value {
        case .hostNamespace: return true
        case .object(let obj): return obj is Opaque || obj is Wrapper
        default: return false
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#parseArrayIndex [status=implemented hash=b49e0ee018a3]
    public static func parseArrayIndex(_ key: JSString) -> Int? {
        guard let swiftKey = key.wellFormedString, !swiftKey.isEmpty else { return nil }
        if swiftKey == "0" { return 0 }
        let bytes = Array(swiftKey.utf8)
        if bytes[0] == UInt8(ascii: "0") { return nil }
        var acc: UInt64 = 0
        for b in bytes {
            guard b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") else { return nil }
            acc = acc * 10 + UInt64(b - UInt8(ascii: "0"))
            if acc >= UInt64(UInt32.max) { return nil }
        }
        return Int(acc)
    }

    // parity: psychoscript/src/runtime/objects.ts#own [status=implemented hash=669d32534fb2]
    public static func own(_ obj: Obj, _ key: PropertyKey) -> Slot? {
        if let arr = obj as? Arr, case .string(let s) = key {
            if s == "length" {
                return .data(value: .number(Double(arr.count)), writable: true, enumerable: false, configurable: false)
            }
            if let idx = parseArrayIndex(s), idx < arr.count, !arr.isHole(idx) {
                return .data(value: arr.item(at: idx), writable: true, enumerable: true, configurable: true)
            }
        }
        if let bytes = obj as? Bytes, case .string(let s) = key {
            if s == "length" {
                return .data(value: .number(Double(bytes.length)), writable: false, enumerable: false, configurable: false)
            }
            if let idx = parseArrayIndex(s), idx < bytes.data.count {
                return .data(value: .number(Double(bytes.data[idx])), writable: true, enumerable: true, configurable: false)
            }
        }
        let slot = obj.getSlot(key)
        // An error's `stack` formats its header on first read (see `StackSlot`).
        if key == .string("stack"), let error = obj as? ErrorObj, let stack = error.stackSlot,
           case .data(_, let w, let e, let c)? = slot, let text = stack.resolve(error) {
            return .data(value: text, writable: w, enumerable: e, configurable: c)
        }
        return slot
    }

    /// A slot's value for `receiver`. A program getter can only run as program code: inside `withReads` its value
    /// comes from the read-ahead table (or is recorded as missing); anywhere else reaching one is an error.
    static func read(_ slot: Slot, _ receiver: Value, _ key: PropertyKey) -> Value {
        switch slot {
        case .data(let value, _, _, _): return value
        case .accessor(nil, _, _, _): return .undefined
        case .accessor(.native(let getter, _)?, _, _, _):
            do { return try getter(receiver) } catch {
                Reads.current?.record(error)
                return .undefined
            }
        case .accessor(.program?, _, _, _): return programRead(receiver, key)
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#hasOwn [status=implemented hash=33209d0b02b0]
    public static func hasOwn(_ obj: Obj, _ key: JSString) -> Bool {
        own(obj, .string(key)) != nil
    }

    // parity: psychoscript/src/runtime/objects.ts#getOwn [status=implemented hash=590b0afd192b]
    public static func getOwn(_ obj: Obj, _ key: JSString) -> Value {
        getOwn(obj, .string(key))
    }

    public static func getOwn(_ obj: Obj, _ key: PropertyKey) -> Value {
        guard let slot = own(obj, key) else { return .undefined }
        return read(slot, .object(obj), key)
    }

    // parity: psychoscript/src/runtime/objects.ts#lookup [status=implemented hash=643e31957884]
    /// [[Get]]'s lookup: the slot `key` names on `target` or its prototype chain.
    public static func lookup(_ obj: Obj, _ key: PropertyKey) -> Slot? {
        var current: Obj? = obj
        var depth = 0
        while let cur = current, depth < 64 {
            if let slot = own(cur, key) { return slot }
            current = cur.proto
            depth += 1
        }
        return nil
    }

    // parity: psychoscript/src/runtime/objects.ts#get [status=implemented hash=dad0c4fa21ce]
    public static func get(_ obj: Obj, _ key: JSString) -> Value {
        get(obj, .string(key), receiver: .object(obj))
    }

    public static func get(_ obj: Obj, _ key: PropertyKey, receiver: Value? = nil) -> Value {
        guard let slot = lookup(obj, key) else { return .undefined }
        return read(slot, receiver ?? .object(obj), key)
    }

    // parity: psychoscript/src/runtime/objects.ts#GetterCall [status=implemented hash=a32375409ac7]
    /// A program getter a caller that runs program code calls itself, with the read's receiver as `this`.
    public final class GetterCall: Sendable {
        public let getter: Callable

        public init(_ getter: Callable) {
            self.getter = getter
        }
    }

    /// What [[Get]] gives a caller that can run program code: the value, or the program getter to call.
    public enum Access: Sendable {
        case value(Value)
        case getter(GetterCall)
    }

    // parity: psychoscript/src/runtime/objects.ts#access [status=implemented hash=ec09122ef908]
    /// [[Get]] for callers that can run program code (the evaluator's member reads): the value, or the program getter.
    public static func access(_ obj: Obj, _ key: PropertyKey, receiver: Value? = nil) throws -> Access {
        guard let slot = lookup(obj, key) else { return .value(.undefined) }
        switch slot {
        case .data(let value, _, _, _): return .value(value)
        case .accessor(nil, _, _, _): return .value(.undefined)
        case .accessor(.native(let getter, _)?, _, _, _): return .value(try getter(receiver ?? .object(obj)))
        case .accessor(.program(let fn)?, _, _, _): return .getter(GetterCall(fn))
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#peek [status=implemented hash=227ea8b63f20]
    /// [[Get]] for display and diagnostics, which never run program code: a program getter reads as `undefined`.
    public static func peek(_ obj: Obj, _ key: PropertyKey, receiver: Value? = nil) -> Value {
        guard let slot = lookup(obj, key) else { return .undefined }
        switch slot {
        case .data(let value, _, _, _): return value
        case .accessor(.native(let getter, _)?, _, _, _): return (try? getter(receiver ?? .object(obj))) ?? .undefined
        case .accessor: return .undefined
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#accessorLabel [status=implemented hash=4967726e3935]
    /// How display shows a program accessor in place of its value, in Node's words.
    public static func accessorLabel(_ slot: AccessorSlot) -> String {
        if slot.get != nil && slot.set != nil { return "[Getter/Setter]" }
        return slot.get != nil ? "[Getter]" : "[Setter]"
    }

    // parity: psychoscript/src/runtime/objects.ts#reads [status=adapted hash=c672b420ad79]
    /// The program getters a built-in reads ahead (see `withReads`), scoped to the task running the built-in instead of
    /// a module global. While a `withReads` body runs again after its getters were read, `table` has their values by
    /// receiver and key; inside `withReads` (`depth` > 0) a getter not in the table reads as `undefined` and is recorded
    /// in `missing`, once per pair. In a native's own scope (`depth` 0) reaching one records the error the native
    /// call then throws (see `trappingAccessors`).
    public final class ReadsContext: Sendable {
        fileprivate struct Entry: Sendable {
            let receiver: Value
            let key: PropertyKey
            let value: Value
        }

        private struct State: Sendable {
            var table: [Entry]
            var missing: [(Value, PropertyKey)]? = nil
            var failure: PendingThrowBox? = nil
        }

        public let depth: Int
        private let state: Mutex<State>

        fileprivate init(depth: Int, table: [Entry]) {
            self.depth = depth
            self.state = Mutex(State(table: table))
        }

        fileprivate var tableSnapshot: [Entry] { state.withLock { $0.table } }

        fileprivate func known(_ receiver: Value, _ key: PropertyKey) -> Value? {
            state.withLock { s in
                s.table.first { $0.key == key && CodemodeLanguage.sameReadReceiver($0.receiver, receiver) }?.value
            }
        }

        fileprivate func remember(_ receiver: Value, _ key: PropertyKey, _ value: Value) {
            state.withLock { $0.table.append(Entry(receiver: receiver, key: key, value: value)) }
        }

        fileprivate func recordMissing(_ receiver: Value, _ key: PropertyKey) {
            state.withLock { s in
                var missing = s.missing ?? []
                if !missing.contains(where: { $0.1 == key && CodemodeLanguage.sameReadReceiver($0.0, receiver) }) {
                    missing.append((receiver, key))
                }
                s.missing = missing
            }
        }

        fileprivate var hasMissing: Bool { state.withLock { $0.missing != nil } }

        fileprivate func takeMissing() -> [(Value, PropertyKey)]? {
            state.withLock { s in
                let out = s.missing
                s.missing = nil
                return out
            }
        }

        /// A failure a non-throwing read met (an unreachable program accessor, or a native getter that threw).
        func record(_ error: Error) {
            state.withLock { s in
                if s.failure == nil { s.failure = PendingThrowBox(error) }
            }
        }

        fileprivate func takeFailure() -> Error? {
            state.withLock { s in
                let out = s.failure?.error
                s.failure = nil
                return out
            }
        }
    }

    /// An error carried across the reads context's lock.
    struct PendingThrowBox: @unchecked Sendable {
        let error: Error
        init(_ error: Error) { self.error = error }
    }

    /// The reads context of the running task.
    public enum Reads {
        @TaskLocal public static var current: ReadsContext?
    }

    /// Whether two read receivers are the same, as upstream's `Map` keys compare them (SameValueZero).
    static func sameReadReceiver(_ a: Value, _ b: Value) -> Bool {
        if case .number(let x) = a, case .number(let y) = b, x.isNaN && y.isNaN { return true }
        return strictEqual(a, b)
    }

    /// The test switch for reaching a program accessor no built-in path covers.
    public struct AccessorDefect: Error, Sendable {
        public let key: String
    }

    // parity: psychoscript/src/runtime/objects.ts#accessorRule [status=implemented hash=efa3e15d7cb6]
    /// When `check` is on (tests turn it on), a built-in reaching a program accessor it has no path for is a defect.
    public enum AccessorRule {
        private static let state = Mutex(false)
        public static var check: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    static func keyLabel(_ key: PropertyKey) -> String {
        switch key {
        case .string(let s): return s.toWellFormedString()
        case .symbol(let sym): return sym.description
        }
    }

    static func programRead(_ receiver: Value, _ key: PropertyKey) -> Value {
        guard let ctx = Reads.current else { return .undefined }
        if let known = ctx.known(receiver, key) { return known }
        if ctx.depth == 0 {
            ctx.record(unreachableAccessor(key))
            return .undefined
        }
        ctx.recordMissing(receiver, key)
        return .undefined
    }

    // parity: psychoscript/src/runtime/objects.ts#unreachableAccessor [status=implemented hash=83b9993c2030]
    /// A built-in met a program getter or setter it cannot call: a TypeError, or a defect under `AccessorRule.check`.
    public static func unreachableAccessor(_ key: PropertyKey) -> Error {
        if AccessorRule.check { return AccessorDefect(key: keyLabel(key)) }
        return typeError(
            "A built-in cannot call the getter or setter '\(keyLabel(key))' here; read the property into a variable first."
        )
    }

    /// Runs a native body in its own reads scope: a program getter its non-throwing reads reach outside `withReads`
    /// (or a native getter that threw there) fails the call, as upstream's throwing `get` does.
    static func trappingAccessors(_ call: @escaping NativeCall) -> NativeCall {
        { thisValue, args, site, evaluator in
            let scope = ReadsContext(depth: 0, table: Reads.current?.tableSnapshot ?? [])
            let result: Swift.Result<Value, Error>
            do {
                result = .success(try await Reads.$current.withValue(scope) {
                    try await call(thisValue, args, site, evaluator)
                })
            } catch {
                result = .failure(error)
            }
            if let failure = scope.takeFailure() { throw failure }
            return try result.get()
        }
    }

    static func trappingAccessors(_ construct: @escaping NativeConstruct) -> NativeConstruct {
        { args, newTarget, evaluator in
            let scope = ReadsContext(depth: 0, table: Reads.current?.tableSnapshot ?? [])
            let result: Swift.Result<Value, Error>
            do {
                result = .success(try await Reads.$current.withValue(scope) {
                    try await construct(args, newTarget, evaluator)
                })
            } catch {
                result = .failure(error)
            }
            if let failure = scope.takeFailure() { throw failure }
            return try result.get()
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#has [status=implemented hash=045306adc6ba]
    public static func has(_ obj: Obj, _ key: PropertyKey) -> Bool {
        lookup(obj, key) != nil
    }

    public static func has(_ obj: Obj, _ key: JSString) -> Bool {
        has(obj, .string(key))
    }

    // parity: psychoscript/src/runtime/objects.ts#hasPrototype [status=implemented hash=ef967377673b]
    public static func hasPrototype(_ value: Value, _ prototype: Obj) -> Bool {
        guard case .object(let obj) = value else { return false }
        var current = obj.proto
        var depth = 0
        while let cur = current, depth < 64 {
            if cur === prototype { return true }
            current = cur.proto
            depth += 1
        }
        return false
    }

    // parity: psychoscript/src/runtime/objects.ts#rejectAddition [status=implemented hash=818b26f65530]
    public static func rejectAddition(_ key: String) throws -> Never {
        throw typeError("Cannot add property \(key), object is not extensible.")
    }

    /// An array's or Uint8Array's element or array `length` write: `nil` when `key` is neither.
    static func writeElement(_ obj: Obj, _ key: PropertyKey, _ value: Value) throws -> Bool? {
        guard case .string(let s) = key else { return nil }
        if let bytes = obj as? Bytes {
            guard let idx = parseArrayIndex(s) else { return nil }
            var d = bytes.data
            if idx < d.count {
                d[idx] = UInt8(truncatingIfNeeded: coerceToInteger(value))
                bytes.data = d
            }
            return true
        }
        guard let arr = obj as? Arr else { return nil }
        if let idx = parseArrayIndex(s) {
            if idx >= arr.count && !arr.extensible { try rejectAddition(s.toWellFormedString()) }
            try arr.setItem(at: idx, value: value)
            return true
        }
        guard s == "length" else { return nil }
        let length = coerceToNumber(value)
        guard length.isFinite, length >= 0, length == length.rounded(.towardZero) else {
            throw rangeError("Invalid array length")
        }
        let newLen = Int(length)
        try checkArrayLength(newLen)
        arr.setLength(newLen)
        return true
    }

    /// What [[Set]] did: wrote, refused, or reached a program setter for the caller to call.
    public enum SetResult: Sendable {
        case written
        case refused
        case setter(Callable)
    }

    // parity: psychoscript/src/runtime/objects.ts#set [status=implemented hash=d25822093c68]
    /// [[Set]]: an inherited setter or read-only property decides before an own data property is created. A program
    /// setter is not called here: it is returned, for the caller to call with `target` as `this` and `[value]`.
    public static func setValue(_ obj: Obj, _ key: PropertyKey, _ value: Value) throws -> SetResult {
        // Overwriting an array's present element: no setter or read-only slot can decide first.
        if let arr = obj as? Arr, case .string(let s) = key, let idx = parseArrayIndex(s), idx < arr.count {
            try arr.setItem(at: idx, value: value)
            return .written
        }
        var current: Obj? = obj
        var depth = 0
        chain: while let cur = current, depth < 64 {
            if let slot = own(cur, key) {
                switch slot {
                case .accessor(_, nil, _, _):
                    return .refused
                case .accessor(_, .program(let fn)?, _, _):
                    return .setter(fn)
                case .accessor(_, .native(let setter, _)?, _, _):
                    try setter(.object(obj), value)
                    return .written
                case .data(_, let writable, let enumerable, let configurable):
                    if !writable { return .refused }
                    if cur !== obj { break chain }
                    if let written = try writeElement(obj, key, value) { return written ? .written : .refused }
                    obj.setSlot(key, .data(value: value, writable: writable, enumerable: enumerable, configurable: configurable))
                    return .written
                }
            }
            current = cur.proto
            depth += 1
        }
        if let written = try writeElement(obj, key, value) { return written ? .written : .refused }
        guard obj.extensible else {
            try rejectAddition(keyLabel(key))
        }
        obj.setSlot(key, .data(value: value, writable: true, enumerable: true, configurable: true))
        return .written
    }

    /// [[Set]] for built-ins: a refusal is a TypeError, and a program setter is one they cannot call.
    public static func set(_ obj: Obj, _ key: JSString, _ value: Value) throws {
        try set(obj, .string(key), value)
    }

    public static func set(_ obj: Obj, _ key: PropertyKey, _ value: Value) throws {
        switch try setValue(obj, key, value) {
        case .written: return
        case .refused: throw failedAssignment(.object(obj), key, node: nil)
        case .setter: throw unreachableAccessor(key)
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#define [status=implemented hash=dfa4346ea10d]
    public static func define(_ obj: Obj, _ key: JSString, _ value: Value, _ attrs: Attributes = data) {
        define(obj, .string(key), value, attrs)
    }

    public static func define(_ obj: Obj, _ key: PropertyKey, _ value: Value, _ attrs: Attributes = data) {
        if obj is Arr || obj is Bytes {
            do {
                if try writeElement(obj, key, value) != nil { return }
            } catch {
                Reads.current?.record(error)
                return
            }
        }
        obj.setSlot(key, .data(value: value, writable: attrs.writable, enumerable: attrs.enumerable, configurable: attrs.configurable))
    }

    // parity: psychoscript/src/runtime/objects.ts#defineAccessor [status=implemented hash=94a035229c20]
    /// A built-in's native accessor. Made with the intrinsics, each half gets its companion program function.
    public static func defineAccessor(
        _ obj: Obj,
        _ key: JSString,
        get: Getter? = nil,
        set: Setter? = nil,
        enumerable: Bool = false,
        configurable: Bool = true
    ) {
        defineAccessor(obj, .string(key), get: get, set: set, enumerable: enumerable, configurable: configurable)
    }

    public static func defineAccessor(
        _ obj: Obj,
        _ key: PropertyKey,
        get: Getter? = nil,
        set: Setter? = nil,
        enumerable: Bool = false,
        configurable: Bool = true
    ) {
        let functions = Making.functions
        let label: String = switch key {
        case .string(let s): s.toWellFormedString()
        case .symbol(let sym): "[\(sym.description)]"
        }
        let getHalf: GetterHalf? = get.map { getter in
            let companion = functions.map { fnProto in
                Native(
                    proto: fnProto,
                    options: NativeOptions(name: "get \(label)", call: { thisValue, _, _, _ in try getter(thisValue) }),
                    companion: .getter(getter)
                )
            }
            return .native(getter, companion: companion)
        }
        let setHalf: SetterHalf? = set.map { setter in
            let companion = functions.map { fnProto in
                Native(
                    proto: fnProto,
                    options: NativeOptions(name: "set \(label)", length: 1, call: { thisValue, args, _, _ in
                        try setter(thisValue, args.first ?? .undefined)
                        return .undefined
                    }),
                    companion: .setter(setter)
                )
            }
            return .native(setter, companion: companion)
        }
        obj.setSlot(key, .accessor(get: getHalf, set: setHalf, enumerable: enumerable, configurable: configurable))
    }

    /// Which half of an accessor an object literal's `get x() {}` or `set x(v) {}` defines.
    public enum AccessorHalfKind: Sendable {
        case get
        case set
    }

    // parity: psychoscript/src/runtime/objects.ts#defineAccessorHalf [status=implemented hash=809ff2a8c7e1]
    /// An object literal's `get x() {}` or `set x(v) {}`: an existing accessor keeps its other half; a data property,
    /// or no property, becomes an accessor with only this half.
    public static func defineAccessorHalf(
        _ target: Obj,
        _ key: PropertyKey,
        half: AccessorHalfKind,
        fn: Callable,
        enumerable: Bool = true
    ) {
        var slot = AccessorSlot(get: nil, set: nil, enumerable: enumerable, configurable: true)
        if case .accessor(let g, let s, _, _)? = target.getSlot(key) {
            slot.get = g
            slot.set = s
        }
        switch half {
        case .get: slot.get = .program(fn)
        case .set: slot.set = .program(fn)
        }
        target.hasProgramAccessors = true
        target.setSlot(key, slot.slot)
    }

    // parity: psychoscript/src/runtime/objects.ts#Descriptor [status=implemented hash=097d4fbe0ef2]
    /// A property descriptor a program gave: a field present means the descriptor has it (`"get" in desc`).
    public struct Descriptor: Sendable {
        public var value: Value?
        public var writable: Bool?
        public var get: Callable??
        public var set: Callable??
        public var enumerable: Bool?
        public var configurable: Bool?

        public init(
            value: Value? = nil,
            writable: Bool? = nil,
            get: Callable?? = nil,
            set: Callable?? = nil,
            enumerable: Bool? = nil,
            configurable: Bool? = nil
        ) {
            self.value = value
            self.writable = writable
            self.get = get
            self.set = set
            self.enumerable = enumerable
            self.configurable = configurable
        }

        var isAccessorDescriptor: Bool { self.get != nil || self.set != nil }
        var isDataDescriptor: Bool { value != nil || writable != nil }
    }

    // parity: psychoscript/src/runtime/objects.ts#defineOwnProperty [status=implemented hash=d0016a7bdd09]
    /// ValidateAndApplyPropertyDescriptor for an own property: false where the spec answers false (the caller
    /// throws), and a TypeError for what the object model cannot hold (an accessor on an array element, elements
    /// whose attributes differ from their array's shared ones). Everything is checked before anything changes.
    public static func defineOwnProperty(_ target: Obj, _ key: PropertyKey, _ desc: Descriptor) throws -> Bool {
        let current = own(target, key)
        if current == nil && !target.extensible { return false }
        if let current, !compatible(current, desc) { return false }
        if target is Arr || target is Bytes, case .string(let s) = key {
            if let at = parseArrayIndex(s) { return try defineElement(target, at, current, desc) }
            if let arr = target as? Arr, s == "length" { return try defineLength(arr, desc) }
        }
        let slot = current.map { applied($0, desc) } ?? created(desc)
        if isProgramAccessor(slot) { target.hasProgramAccessors = true }
        target.setSlot(key, slot)
        return true
    }

    /// Whether `desc` may change a non-configurable `current` (a configurable one may change in any way).
    private static func compatible(_ current: Slot, _ desc: Descriptor) -> Bool {
        if current.configurable { return true }
        if desc.configurable == true { return false }
        if let e = desc.enumerable, e != current.enumerable { return false }
        switch current {
        case .data(let value, let writable, _, _):
            if desc.isAccessorDescriptor { return false }
            if writable { return true }
            if desc.writable == true { return false }
            if let next = desc.value, !sameValue(next, value) { return false }
            return true
        case .accessor(let g, let s, _, _):
            if desc.isDataDescriptor { return false }
            if let next = desc.get, !sameHalf(accessorHalf(getter: next), g) { return false }
            if let next = desc.set, !sameHalf(accessorHalf(setter: next), s) { return false }
            return true
        }
    }

    /// SameValue (`Object.is`).
    static func sameValue(_ a: Value, _ b: Value) -> Bool {
        if case .number(let x) = a, case .number(let y) = b {
            if x.isNaN && y.isNaN { return true }
            if x == 0 && y == 0 { return x.sign == y.sign }
            return x == y
        }
        return strictEqual(a, b)
    }

    /// A new property: what the descriptor gives, and false or undefined for what it leaves out.
    private static func created(_ desc: Descriptor) -> Slot {
        let enumerable = desc.enumerable ?? false
        let configurable = desc.configurable ?? false
        if desc.isAccessorDescriptor {
            return .accessor(
                get: accessorHalf(getter: desc.get ?? nil),
                set: accessorHalf(setter: desc.set ?? nil),
                enumerable: enumerable,
                configurable: configurable
            )
        }
        return .data(value: desc.value ?? .undefined, writable: desc.writable ?? false, enumerable: enumerable, configurable: configurable)
    }

    /// An existing property with the descriptor's fields applied: a kind change keeps only the attributes.
    private static func applied(_ current: Slot, _ desc: Descriptor) -> Slot {
        var merged = desc
        merged.enumerable = desc.enumerable ?? current.enumerable
        merged.configurable = desc.configurable ?? current.configurable
        switch current {
        case .data(let value, let writable, _, _):
            if desc.isAccessorDescriptor { return created(merged) }
            return .data(
                value: desc.value ?? value,
                writable: desc.writable ?? writable,
                enumerable: merged.enumerable ?? false,
                configurable: merged.configurable ?? false
            )
        case .accessor(let g, let s, _, _):
            if desc.isDataDescriptor { return created(merged) }
            return .accessor(
                get: desc.get.map { accessorHalf(getter: $0) } ?? g,
                set: desc.set.map { accessorHalf(setter: $0) } ?? s,
                enumerable: merged.enumerable ?? false,
                configurable: merged.configurable ?? false
            )
        }
    }

    /// An array or Uint8Array element: elements have no slots, so only data with the collection's attributes fits.
    private static func defineElement(_ target: Obj, _ at: Int, _ current: Slot?, _ desc: Descriptor) throws -> Bool {
        if desc.isAccessorDescriptor {
            throw typeError("Accessor properties are not supported on array elements; store the value or use a plain object.")
        }
        if let bytes = target as? Bytes, at >= bytes.data.count { return false }
        let shared = target is Arr ? data : Attributes(writable: true, enumerable: true, configurable: false)
        let base: Attributes = if case .data(_, let w, let e, let c)? = current {
            Attributes(writable: w, enumerable: e, configurable: c)
        } else {
            Attributes(writable: false, enumerable: false, configurable: false)
        }
        let writable = desc.writable ?? base.writable
        let enumerable = desc.enumerable ?? base.enumerable
        let configurable = desc.configurable ?? base.configurable
        if writable != shared.writable || enumerable != shared.enumerable || configurable != shared.configurable {
            throw typeError(
                "Array elements share their attributes; only writable, enumerable and configurable equal to the array's are supported."
            )
        }
        if current == nil || desc.value != nil {
            _ = try writeElement(target, .string(JSString(String(at))), desc.value ?? .undefined)
        }
        return true
    }

    /// An array's `length`: its value, or making it read-only, which the shared element attributes can't separate.
    private static func defineLength(_ target: Arr, _ desc: Descriptor) throws -> Bool {
        if desc.isAccessorDescriptor || desc.configurable == true || desc.enumerable == true { return false }
        if desc.writable == false {
            throw typeError("Making an array's length read-only is not supported; use Object.freeze.")
        }
        if let value = desc.value {
            let length = coerceToNumber(value)
            if length != Double(target.count), try writeElement(target, .string("length"), .number(length)) == false {
                return false
            }
        }
        return true
    }

    // parity: psychoscript/src/runtime/objects.ts#remove [status=implemented hash=37367f2f91e4]
    @discardableResult
    public static func remove(_ obj: Obj, _ key: PropertyKey) -> Bool {
        if case .string(let s) = key {
            if let bytes = obj as? Bytes, let idx = parseArrayIndex(s) {
                return idx >= bytes.data.count
            }
            if let arr = obj as? Arr {
                if let idx = parseArrayIndex(s) {
                    arr.removeItem(at: idx)
                    return true
                }
                if s == "length" { return false }
            }
        }
        if let slot = own(obj, key), !slot.configurable { return false }
        return obj.deleteSlot(key)
    }

    /// Object.seal / Object.freeze: no new properties, and every own property non-configurable (and, frozen,
    /// read-only).
    static func lockProperties(_ obj: Obj, freeze: Bool) {
        obj.extensible = false
        for (k, slot) in obj.allSlotsSnapshot() {
            switch slot {
            case .data(let val, let w, let e, _):
                obj.setSlot(k, .data(value: val, writable: freeze ? false : w, enumerable: e, configurable: false))
            case .accessor(let g, let st, let e, _):
                obj.setSlot(k, .accessor(get: g, set: st, enumerable: e, configurable: false))
            }
        }
    }

    static func isLocked(_ obj: Obj, frozen: Bool) -> Bool {
        if obj.extensible { return false }
        // Array elements live outside the property table and follow the array's extensibility.
        if obj is Arr { return true }
        for (_, slot) in obj.allSlotsSnapshot() {
            if slot.configurable { return false }
            if frozen, case .data(_, true, _, _) = slot { return false }
        }
        return true
    }

    // parity: psychoscript/src/runtime/objects.ts#ownKeys [status=implemented hash=feef712030dc]
    public static func ownKeys(_ obj: Obj) -> [JSString] {
        var idxKeys: [(Int, JSString)] = []
        var strKeys: [JSString] = []
        if let arr = obj as? Arr {
            let holes = arr.holes
            for i in 0..<arr.count where !holes.contains(i) { idxKeys.append((i, JSString(String(i)))) }
        } else if let bytes = obj as? Bytes {
            for i in 0..<bytes.data.count { idxKeys.append((i, JSString(String(i)))) }
        }
        for key in obj.orderedKeys() {
            guard case .string(let s) = key else { continue }
            if let idx = parseArrayIndex(s) {
                if !idxKeys.contains(where: { $0.0 == idx }) { idxKeys.append((idx, s)) }
            } else {
                strKeys.append(s)
            }
        }
        idxKeys.sort { $0.0 < $1.0 }
        return idxKeys.map(\.1) + strKeys
    }

    // parity: psychoscript/src/runtime/objects.ts#enumerableKeys [status=implemented hash=aaa1d81f94d5]
    public static func enumerableKeys(_ obj: Obj) -> [JSString] {
        var idxKeys: [(Int, JSString)] = []
        var strKeys: [JSString] = []
        if let arr = obj as? Arr {
            let holes = arr.holes
            for i in 0..<arr.count where !holes.contains(i) { idxKeys.append((i, JSString(String(i)))) }
        } else if let bytes = obj as? Bytes {
            for i in 0..<bytes.data.count { idxKeys.append((i, JSString(String(i)))) }
        }
        for (key, slot) in obj.allSlotsSnapshot() where slot.enumerable {
            guard case .string(let s) = key else { continue }
            if let idx = parseArrayIndex(s) {
                if !idxKeys.contains(where: { $0.0 == idx }) { idxKeys.append((idx, s)) }
            } else {
                strKeys.append(s)
            }
        }
        idxKeys.sort { $0.0 < $1.0 }
        return idxKeys.map(\.1) + strKeys
    }

    /// Own enumerable keys including the iterator symbols: what spread and `Object.assign` copy.
    static func enumerableCopyKeys(_ obj: Obj) -> [PropertyKey] {
        var out = enumerableKeys(obj).map { PropertyKey.string($0) }
        for (key, slot) in obj.allSlotsSnapshot() where slot.enumerable {
            if key == .symbol(IteratorSymbol) || key == .symbol(AsyncIteratorSymbol) { out.append(key) }
        }
        return out
    }

    // parity: psychoscript/src/runtime/objects.ts#keys [status=implemented hash=a521782cd83a]
    public static func keys(_ obj: Obj) -> [JSString] {
        enumerableKeys(obj)
    }

    // parity: psychoscript/src/runtime/objects.ts#entries [status=implemented hash=2623c5e3a869]
    public static func entries(_ obj: Obj) -> [(JSString, Value)] {
        enumerableKeys(obj).map { ($0, getOwn(obj, $0)) }
    }

    // parity: psychoscript/src/runtime/objects.ts#shownEntries [status=implemented hash=259cc3db1a71]
    /// Own enumerable string entries for display, which runs no program code: a program accessor shows as its label.
    public static func shownEntries(_ obj: Obj) -> [(JSString, Value)] {
        guard obj.hasProgramAccessors else { return entries(obj) }
        return keys(obj).map { key in
            if let slot = own(obj, .string(key)), isProgramAccessor(slot), let accessor = slot.accessorSlot {
                return (key, .string(JSString(accessorLabel(accessor))))
            }
            return (key, getOwn(obj, key))
        }
    }

    // parity: psychoscript/src/runtime/objects.ts#iteratorResult [status=implemented hash=242e75c440a1]
    public static func iteratorResult(_ builtins: Builtins, value: Value, done: Bool) -> Obj {
        let obj = Obj(proto: builtins.Object)
        define(obj, "value", value)
        define(obj, "done", .bool(done))
        return obj
    }

    // parity: psychoscript/src/runtime/objects.ts#record [status=implemented hash=2bc09a81efe9]
    public static func record(_ builtins: Builtins, _ pairs: [(JSString, Value)]) -> Obj {
        let obj = Obj(proto: builtins.Object)
        for (k, v) in pairs { define(obj, k, v) }
        return obj
    }

    // parity: psychoscript/src/runtime/objects.ts#copyDataProperties [status=implemented hash=e49d3b07411d]
    /// CopyDataProperties for a source without program accessors (spread and rest): defines data on `target`, so no
    /// setter on its chain runs.
    public static func copyDataProperties(_ target: Obj, _ source: Obj, skip: Set<PropertyKey> = []) {
        for key in enumerableCopyKeys(source) where !skip.contains(key) {
            define(target, key, getOwn(source, key))
        }
    }

    // MARK: - Operations (src/language/runtime/operations.ts)

    // parity: psychoscript/src/runtime/operations.ts#compareText [status=implemented hash=60bb1e59107c]
    public static func compareText(_ left: JSString, _ right: JSString) -> Int {
        JSString.compareUTF16(left, right)
    }

    public static func compareText(_ left: String, _ right: String) -> Int {
        JSString.compareUTF16(JSString(left), JSString(right))
    }

    // parity: psychoscript/src/runtime/operations.ts#propertyKey [status=implemented hash=dcb9eeb17173]
    public static func propertyKey(_ value: Value) -> PropertyKey {
        switch value {
        case .symbol(let s): return .symbol(s)
        case .string(let s): return .string(s)
        default: return .string(coerceToString(value))
        }
    }

    /// Native engines name the callee (`search(...).catch is not a function`), including call chains; nil when a link
    /// cannot be named, so a chain is either named completely or not at all.
    // Upstream: psychoscript/src/runtime/operations.ts#calleeDescription (implemented).
    public static func calleeDescription(_ expr: Expression?) -> String? {
        guard let expr else { return nil }
        switch expr {
        case .identifier(let name, _):
            return name
        case .call(let callee, _, _, _):
            return calleeDescription(callee).map { "\($0)(...)" }
        case .member(let object, let property, _, _):
            let key: String?
            switch property {
            case .identifier(let name, _): key = name
            case .computed(.literalString(let value, _), _): key = value.toWellFormedString()
            default: key = nil
            }
            guard let key, let target = calleeDescription(object) else { return nil }
            return "\(target).\(key)"
        default:
            return nil
        }
    }

    /// Whether `callCallable` can call `value` (a program or built-in function, or a host namespace path).
    public static func isCallableValue(_ value: Value) -> Bool {
        switch value {
        case .hostNamespace: return true
        case .object(let obj): return obj is Callable
        default: return false
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#notAFunction [status=implemented hash=d86d1f304ab4]
    public static func notAFunction(_ description: String? = nil, node: AstNode? = nil) -> PendingThrow {
        typeError("\(description ?? "The called value") is not a function.", node: node)
    }

    // parity: psychoscript/src/runtime/operations.ts#notConstructible [status=implemented hash=a2a3069a66bd]
    public static func notConstructible(_ callee: Value, name: String? = nil, node: AstNode? = nil) -> PendingThrow {
        let label = name ?? "The called value"
        if case .object(let obj) = callee {
            if obj is Fn {
                return typeError("\(label) is not a constructor: only classes can be constructed with new. Use a class, or call it as a function that returns an object.", node: node)
            }
            if obj is Builtin {
                return typeError("new \(label)(...) is not supported; call \(label)(...) without new instead.", node: node)
            }
        }
        return typeError("\(label) is not a constructor.", node: node)
    }

    /// What `instanceof` gives before running program code: the answer, or the program `prototype` getter to run first.
    public enum InstanceofResult: Sendable {
        case result(Bool)
        case getter(GetterCall)
    }

    // parity: psychoscript/src/runtime/operations.ts#instanceofValue [status=implemented hash=dbefe37019dd]
    /// OrdinaryHasInstance: walk the left operand's chain looking for the constructor's `prototype`, unless that is a
    /// program getter, which the caller runs first (then `hasInstance`).
    public static func instanceofValue(_ lhs: Value, _ rhs: Value, node: AstNode? = nil) throws -> InstanceofResult {
        guard case .object(let rhsObj) = rhs, rhsObj is Callable else {
            throw typeError("The right-hand side of 'instanceof' is not callable.", node: node)
        }
        switch try accessProperty(rhsObj, .string("prototype"), node: node) {
        case .getter(let call): return .getter(call)
        case .value(let proto): return .result(try hasInstance(lhs, proto, node: node))
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#hasInstance [status=implemented hash=de205f152c20]
    /// The rest of OrdinaryHasInstance, once `prototype` is read.
    public static func hasInstance(_ lhs: Value, _ prototype: Value, node: AstNode?) throws -> Bool {
        guard case .object(let protoObj) = prototype else {
            throw typeError("The right-hand side of 'instanceof' has no 'prototype' object.", node: node)
        }
        return hasPrototype(lhs, protoObj)
    }

    public static func strictEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.undefined, .undefined), (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.symbol(a), .symbol(b)): return a == b
        case let (.object(a), .object(b)): return a === b
        case let (.hostNamespace(a), .hostNamespace(b)): return a === b
        default: return false
        }
    }

    public static func looseEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        if strictEqual(lhs, rhs) { return true }
        switch (lhs, rhs) {
        case (.null, .undefined), (.undefined, .null): return true
        case (.number, .string), (.string, .number):
            return coerceToNumber(lhs) == coerceToNumber(rhs)
        case (.bool, _):
            return looseEqual(.number(coerceToNumber(lhs)), rhs)
        case (_, .bool):
            return looseEqual(lhs, .number(coerceToNumber(rhs)))
        case (.object(let o), .string), (.object(let o), .number):
            return looseEqual(o.toPrimitive(hint: .default), rhs)
        case (.string, .object(let o)), (.number, .object(let o)):
            return looseEqual(lhs, o.toPrimitive(hint: .default))
        default:
            return false
        }
    }

    public static func toInt32(_ value: Double) -> Int32 {
        guard value.isFinite && value != 0 else { return 0 }
        let mod = value.truncatingRemainder(dividingBy: 4_294_967_296.0)
        var int64Val = Int64(mod.rounded(.towardZero))
        if int64Val < 0 { int64Val += 4_294_967_296 }
        return Int32(truncatingIfNeeded: UInt32(int64Val & 0xFFFF_FFFF))
    }

    public static func toUInt32(_ value: Double) -> UInt32 {
        UInt32(bitPattern: toInt32(value))
    }

    // parity: psychoscript/src/runtime/operations.ts#applyBinaryOperator [status=implemented hash=e33eda0e2f49]
    public static func applyBinaryOperator(_ op: BinaryOperator, _ lhs: Value, _ rhs: Value, node: AstNode? = nil) throws -> Value {
        switch op {
        case .seq: return .bool(strictEqual(lhs, rhs))
        case .sne: return .bool(!strictEqual(lhs, rhs))
        case .eq: return .bool(looseEqual(lhs, rhs))
        case .ne: return .bool(!looseEqual(lhs, rhs))
        case .in:
            if case .object(let rhsObj) = rhs {
                return .bool(has(rhsObj, propertyKey(lhs)))
            }
            if case .hostNamespace(let ns) = rhs {
                let key = coerceToString(lhs)
                let ks = (try? ns.handler.keys(ns.path)) ?? []
                return .bool(ks.contains(key.toWellFormedString()))
            }
            throw typeError("Cannot use 'in' operator to search in \(describeValue(rhs)).", node: node)
        case .instanceof:
            switch try instanceofValue(lhs, rhs, node: node) {
            case .result(let answer): return .bool(answer)
            case .getter:
                // A caller that can run program code reads the getter first (see `Evaluator.instanceOf`).
                guard case .object(let rhsObj) = rhs else { return .bool(false) }
                return .bool(try hasInstance(lhs, get(rhsObj, "prototype"), node: node))
            }
        case .add:
            let lPrim = if case .object(let o) = lhs { o.toPrimitive(hint: .default) } else { lhs }
            let rPrim = if case .object(let o) = rhs { o.toPrimitive(hint: .default) } else { rhs }
            if case .string = lPrim {
                let res = coerceToString(lPrim) + coerceToString(rPrim)
                try checkStringLength(res.utf16Count)
                return .string(res)
            }
            if case .string = rPrim {
                let res = coerceToString(lPrim) + coerceToString(rPrim)
                try checkStringLength(res.utf16Count)
                return .string(res)
            }
            return .number(coerceToNumber(lPrim) + coerceToNumber(rPrim))
        case .sub: return .number(coerceToNumber(lhs) - coerceToNumber(rhs))
        case .mul: return .number(coerceToNumber(lhs) * coerceToNumber(rhs))
        case .div: return .number(coerceToNumber(lhs) / coerceToNumber(rhs))
        case .mod: return .number(coerceToNumber(lhs).truncatingRemainder(dividingBy: coerceToNumber(rhs)))
        case .exp: return .number(pow(coerceToNumber(lhs), coerceToNumber(rhs)))
        case .bitAnd: return .number(Double(toInt32(coerceToNumber(lhs)) & toInt32(coerceToNumber(rhs))))
        case .bitOr: return .number(Double(toInt32(coerceToNumber(lhs)) | toInt32(coerceToNumber(rhs))))
        case .bitXor: return .number(Double(toInt32(coerceToNumber(lhs)) ^ toInt32(coerceToNumber(rhs))))
        case .shl:
            let shift = Int32(toUInt32(coerceToNumber(rhs)) & 0x1F)
            return .number(Double(toInt32(coerceToNumber(lhs)) << shift))
        case .sar:
            let shift = Int32(toUInt32(coerceToNumber(rhs)) & 0x1F)
            return .number(Double(toInt32(coerceToNumber(lhs)) >> shift))
        case .shr:
            let shift = toUInt32(coerceToNumber(rhs)) & 0x1F
            return .number(Double(toUInt32(coerceToNumber(lhs)) >> shift))
        case .lt, .le, .gt, .ge:
            let lPrim = if case .object(let o) = lhs { o.toPrimitive(hint: .number) } else { lhs }
            let rPrim = if case .object(let o) = rhs { o.toPrimitive(hint: .number) } else { rhs }
            if case .string(let ls) = lPrim, case .string(let rs) = rPrim {
                let c = compareText(ls, rs)
                switch op {
                case .lt: return .bool(c < 0)
                case .le: return .bool(c <= 0)
                case .gt: return .bool(c > 0)
                case .ge: return .bool(c >= 0)
                default: return .bool(false)
                }
            }
            let ln = coerceToNumber(lPrim)
            let rn = coerceToNumber(rPrim)
            switch op {
            case .lt: return .bool(ln < rn)
            case .le: return .bool(ln <= rn)
            case .gt: return .bool(ln > rn)
            case .ge: return .bool(ln >= rn)
            default: return .bool(false)
            }
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#operatorConversion [status=implemented hash=7af6b6bced3d]
    public static func operatorConversion(_ op: BinaryOperator) -> Hint? {
        switch op {
        case .add: return .default
        case .sub, .mul, .div, .mod, .exp, .lt, .le, .gt, .ge, .bitAnd, .bitOr, .bitXor, .shl, .sar, .shr:
            return .number
        default:
            return nil
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#isThenable [status=implemented hash=0e6f8c9c87f8]
    /// A thenable an async body adopts. A program `then` getter counts: the adoption reads it, in program code.
    public static func isThenable(_ value: Value) -> Bool {
        guard case .object(let obj) = value else { return false }
        if obj is PromiseObj { return true }
        guard let slot = lookup(obj, .string("then")) else { return false }
        if isProgramAccessor(slot) { return true }
        if case .object(let thenObj) = get(obj, "then"), thenObj is Callable { return true }
        return false
    }

    // parity: psychoscript/src/runtime/operations.ts#builtinCursor [status=implemented hash=b517eef58ff9]
    /// A built-in iterator over `value` that needs no program code to start: an iterator object, a string, a collection.
    public static func builtinCursor(_ value: Value, builtins: Builtins) -> Cursor? {
        switch value {
        case .string(let s):
            return positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .string(s), kind: .values).cursor
        case .object(let obj):
            if let iter = obj as? IteratorObj {
                // A built-in iterator over an array is stepped by its `next` once a program has replaced it.
                if arrayIterationIntact(builtins) { return iter.cursor }
                switch iter.source {
                case .array?, .bytes?: return nil
                default: return iter.cursor
                }
            }
            if let gen = obj as? GeneratorObj {
                // A program generator runs its body as it is stepped: through its `next`, as program code.
                if gen.isLazy { return nil }
                return Cursor { gen.stepNext() }
            }
            return obj.iterator(builtins)
        default:
            return nil
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#requireIteratorObject [status=implemented hash=7feb4550ef24]
    public static func requireIteratorObject(_ value: Value, node: AstNode? = nil) throws -> Obj {
        guard case .object(let obj) = value else {
            throw typeError("Iterator result is not an object.", node: node)
        }
        return obj
    }

    // parity: psychoscript/src/runtime/operations.ts#requireIteratorMethod [status=implemented hash=fe04e5f487f9]
    public static func requireIteratorMethod(_ value: Value, async: Bool = false, node: AstNode? = nil) throws -> Callable {
        guard case .object(let obj) = value else {
            throw typeError("\(describeValue(value)) is not iterable.", node: node)
        }
        let sym = async ? AsyncIteratorSymbol : IteratorSymbol
        let method = get(obj, .symbol(sym))
        if case .object(let fn) = method, let callable = fn as? Callable { return callable }
        if async {
            let syncMethod = get(obj, .symbol(IteratorSymbol))
            if case .object(let fn) = syncMethod, let callable = fn as? Callable { return callable }
        }
        throw typeError("\(describeValue(value)) is not iterable.", node: node)
    }

    // parity: psychoscript/src/runtime/operations.ts#forInKeys [status=implemented hash=2eaa2ae17f03]
    public static func forInKeys(_ value: Value) -> [JSString] {
        switch value {
        case .object(let obj):
            var seen = Set<JSString>()
            var result: [JSString] = []
            var current: Obj? = obj
            var depth = 0
            while let cur = current, depth < 64 {
                for key in enumerableKeys(cur) {
                    if seen.insert(key).inserted { result.append(key) }
                }
                current = cur.proto
                depth += 1
            }
            return result
        case .hostNamespace(let ns):
            return ((try? ns.handler.keys(ns.path)) ?? []).map { JSString($0) }
        case .string(let s):
            // Matches upstream `enumerableSource` (`[...value]`): one enumerable index per code-point / lone-surrogate chunk.
            return (0..<s.codePointStrings().count).map { JSString(String($0)) }
        default:
            return []
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#requireMemberBase [status=implemented hash=b11cdc8a6a5f]
    public static func requireMemberBase(_ value: Value, property: String? = nil, node: AstNode? = nil) throws {
        if value.isNullish {
            let suffix = property.map { " '\($0)'" } ?? ""
            throw typeError("Cannot read properties of \(value.isUndefined ? "undefined" : "null") (reading\(suffix)).", node: node)
        }
    }

    /// A resolved member: a host namespace path, a value a primitive owns, or the object to read through and the
    /// receiver inherited accessors see.
    public enum MemberReference: Sendable {
        case namespace(HostNamespace)
        case value(Value)
        case member(target: Obj, key: PropertyKey, receiver: Value)
    }

    /// The reference a member read resolves to (strings own `length` and indexes; other primitives read through their
    /// wrapper prototype).
    public static func resolveReference(_ base: Value, _ key: PropertyKey, builtins: Builtins, node: AstNode? = nil) throws -> MemberReference {
        try requireMemberBase(base, property: key.stringKey, node: node)
        switch base {
        case .hostNamespace(let ns):
            guard case .string(let seg) = key else { return .value(.undefined) }
            if seg == "then" || seg == "catch" || seg == "finally" { return .value(.undefined) }
            return .namespace(ns.child(seg.toWellFormedString()))
        case .string(let str):
            if case .string(let s) = key {
                if s == "length" { return .value(.number(Double(str.utf16Count))) }
                if let idx = parseArrayIndex(s), let unit = str.unit(at: idx) {
                    return .value(.string(JSString(unit: unit)))
                }
            }
            return .member(target: builtins.String, key: key, receiver: base)
        case .number:
            return .member(target: builtins.Number, key: key, receiver: base)
        case .bool:
            return .member(target: builtins.Boolean, key: key, receiver: base)
        case .object(let obj):
            return .member(target: obj, key: key, receiver: base)
        default:
            return .value(.undefined)
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#resolveProperty [status=implemented hash=4461169ae62f]
    public static func resolveProperty(_ base: Value, _ key: PropertyKey, builtins: Builtins, node: AstNode? = nil) throws -> Value {
        switch try resolveReference(base, key, builtins: builtins, node: node) {
        case .namespace(let ns): return .hostNamespace(ns)
        case .value(let value): return value
        case .member(let target, let key, let receiver): return try readProperty(target, key, node: node, receiver: receiver)
        }
    }

    /// One destructured property, read the way a member expression would read it (primitives use their prototype).
    public static func destructuredProperty(_ base: Value, _ key: PropertyKey, builtins: Builtins, node: AstNode? = nil) throws -> Value {
        try resolveProperty(base, key, builtins: builtins, node: node)
    }

    // parity: psychoscript/src/runtime/operations.ts#requirePromiseProperty [status=implemented hash=a1017429a787]
    /// Rejects reading a property a promise doesn't have, so a missing await cannot hide.
    public static func requirePromiseProperty(_ reference: MemberReference, node: AstNode?) throws {
        guard case .member(let target as PromiseObj, let key, _) = reference, !has(target, key) else { return }
        throw invalidData(
            "This value is an un-awaited Promise; await it first - e.g. `const result = await load(...)`.",
            node: node
        )
    }

    // parity: psychoscript/src/runtime/operations.ts#accessProperty [status=implemented hash=9b9b9f1abd0a]
    /// [[Get]] for callers that run program code, located at `node`: the value, or a program getter to call.
    public static func accessProperty(_ target: Obj, _ key: PropertyKey, node: AstNode?, receiver: Value? = nil) throws -> Access {
        do {
            return try access(target, key, receiver: receiver)
        } catch {
            throw locate(error, node: node)
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#readProperty [status=implemented hash=26a0e3a9b971]
    /// Accessors throw without a location; the member or pattern that read them supplies it.
    public static func readProperty(_ target: Obj, _ key: PropertyKey, node: AstNode?, receiver: Value? = nil) throws -> Value {
        get(target, key, receiver: receiver)
    }

    public static func readProperty(_ base: Value, _ key: JSString, builtins: Builtins, node: AstNode? = nil) throws -> Value {
        try resolveProperty(base, .string(key), builtins: builtins, node: node)
    }

    // parity: psychoscript/src/runtime/operations.ts#writableReference [status=implemented hash=33534f54d5cd]
    public static func writableReference(_ base: Value, _ key: PropertyKey, node: AstNode? = nil) throws -> Obj {
        guard case .object(let obj) = base else {
            throw typeError("Cannot set properties of \(describeValue(base)).", node: node)
        }
        return obj
    }

    // parity: psychoscript/src/runtime/operations.ts#assignToReference [status=implemented hash=ca98dac7b8ab]
    /// Assigns `target[key] = next`: the program setter to call with `target` and `[next]`, if the write reaches one.
    @discardableResult
    public static func assignToReference(_ base: Value, _ key: PropertyKey, _ value: Value, node: AstNode? = nil) throws -> Callable? {
        let obj = try writableReference(base, key, node: node)
        let written: SetResult
        do {
            // An accessor decides what a write stores (or refuses it), so only a data write can make a cycle.
            if case .object(let next) = value, hasCircularReference(obj, .object(next)) {
                let viaAccessor: Bool = if case .accessor? = lookup(obj, key) { true } else { false }
                if !viaAccessor { throw circularValue(obj is Arr ? "Array assignment result" : "Object assignment result") }
            }
            written = try setValue(obj, key, value)
        } catch {
            throw locate(error, node: node)
        }
        switch written {
        case .written: return nil
        case .refused: throw failedAssignment(base, key, node: node)
        case .setter(let fn): return fn
        }
    }

    // parity: psychoscript/src/runtime/operations.ts#failedAssignment [status=implemented hash=7e9d92e68423]
    /// Why `[[Set]]` refused: an accessor with only a getter, or a read-only property.
    public static func failedAssignment(_ receiver: Value, _ key: PropertyKey, node: AstNode?) -> PendingThrow {
        if case .object(let obj) = receiver, case .accessor? = lookup(obj, key) {
            return typeError(
                "Cannot set property '\(keyLabel(key))' of \(describeValue(receiver)) which has only a getter.",
                node: node
            )
        }
        return typeError("Cannot assign to read only property '\(keyLabel(key))'.", node: node)
    }

    // MARK: - Intrinsics (src/language/runtime/intrinsics.ts)

    // parity: psychoscript/src/runtime/intrinsics.ts#ErrorType [status=implemented hash=f3ad9524b63c]
    public enum ErrorType: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case error = "Error"
        case typeError = "TypeError"
        case rangeError = "RangeError"
        case syntaxError = "SyntaxError"
        case referenceError = "ReferenceError"
        case evalError = "EvalError"
        case uriError = "URIError"
        case aggregateError = "AggregateError"
    }

    // parity: psychoscript/src/runtime/intrinsics.ts#errorTypes [status=implemented hash=095d8a6f1575]
    public static let errorTypes: [ErrorType] = ErrorType.allCases

    // parity: psychoscript/src/runtime/intrinsics.ts#isErrorType [status=implemented hash=5e0499c396d5]
    public static func isErrorType(_ name: String) -> Bool {
        ErrorType(rawValue: name) != nil
    }

    // parity: psychoscript/src/runtime/intrinsics.ts#Builtins [status=implemented hash=26dfcf4edfb3]
    public struct Builtins: Sendable {
        public let Object: Obj
        public let Function: Obj
        public let Array: Arr
        public let String: Obj
        public let Number: Obj
        public let Boolean: Obj
        public let Date: Obj
        public let RegExp: Obj
        public let Map: Obj
        public let Set: Obj
        public let WeakMap: Obj
        public let WeakSet: Obj
        public let URL: Obj
        public let URLSearchParams: Obj
        public let Headers: Obj
        public let Uint8Array: Obj
        public let Buffer: Obj
        public let TextEncoder: Obj
        public let TextDecoder: Obj
        public let Promise: Obj
        public let PromiseLike: Obj
        public let Iterator: Obj
        public let IteratorHelper: Obj
        public let AsyncIterator: Obj
        public let Generator: Obj
        public let AsyncGenerator: Obj
        public let AsyncFromSyncIterator: Obj
        public let Error: Obj
        public let TypeError: Obj
        public let RangeError: Obj
        public let SyntaxError: Obj
        public let ReferenceError: Obj
        public let EvalError: Obj
        public let URIError: Obj
        public let AggregateError: Obj

        public func errorProto(_ type: ErrorType) -> Obj {
            switch type {
            case .error: return Error
            case .typeError: return TypeError
            case .rangeError: return RangeError
            case .syntaxError: return SyntaxError
            case .referenceError: return ReferenceError
            case .evalError: return EvalError
            case .uriError: return URIError
            case .aggregateError: return AggregateError
            }
        }

        public var allPrototypes: [Obj] {
            [
                Object, Function, Array, String, Number, Boolean, Date, RegExp,
                Map, Set, WeakMap, WeakSet, URL, URLSearchParams, Headers,
                Uint8Array, Buffer, TextEncoder, TextDecoder, Promise, PromiseLike,
                Iterator, IteratorHelper, AsyncIterator, Generator, AsyncGenerator,
                AsyncFromSyncIterator, Error, TypeError, RangeError, SyntaxError,
                ReferenceError, EvalError, URIError, AggregateError,
            ]
        }
    }

    // parity: psychoscript/src/runtime/intrinsics.ts#createErrorValue [status=implemented hash=2b409a9c8dc5]
    /// A new error; its `stack` is `name: message` as of its first read, then `trace`, the `    at` lines where it was made.
    public static func createErrorValue(_ prototype: Obj, message: JSString?, trace: String = "") -> ErrorObj {
        let value = ErrorObj(proto: prototype)
        if let message {
            define(value, "message", .string(message), hidden)
        }
        value.setSlot(.string("stack"), .data(value: .undefined, writable: true, enumerable: false, configurable: true))
        value.stackSlot = StackSlot(trace: trace)
        return value
    }

    // parity: psychoscript/src/runtime/intrinsics.ts#primitivePrototype [status=implemented hash=7368a3d7b3af]
    public static func primitivePrototype(_ builtins: Builtins, _ value: Value) -> Obj? {
        switch value {
        case .string: return builtins.String
        case .number: return builtins.Number
        case .bool: return builtins.Boolean
        default: return nil
        }
    }

    // parity: psychoscript/src/runtime/intrinsics.ts#createBuiltins [status=implemented hash=058efb96112a]
    public static func createBuiltins() -> Builtins {
        let object = Obj(proto: nil)
        let fn = Native(proto: object, options: NativeOptions(name: "", call: { _, _, _, _ in .undefined }))
        let plain = { Obj(proto: object) }
        let error = plain()
        define(error, "name", .string("Error"), hidden)
        define(error, "message", .string(""), hidden)
        func derived(_ type: ErrorType) -> Obj {
            let p = Obj(proto: error)
            define(p, "name", .string(JSString(type.rawValue)), hidden)
            define(p, "message", .string(""), hidden)
            return p
        }
        let iterator = plain()
        let asyncIterator = plain()
        let uint8Array = plain()
        return Builtins(
            Object: object,
            Function: fn,
            Array: Arr(proto: object),
            String: plain(),
            Number: plain(),
            Boolean: plain(),
            Date: plain(),
            RegExp: plain(),
            Map: plain(),
            Set: plain(),
            WeakMap: plain(),
            WeakSet: plain(),
            URL: plain(),
            URLSearchParams: plain(),
            Headers: plain(),
            Uint8Array: uint8Array,
            Buffer: Obj(proto: uint8Array),
            TextEncoder: plain(),
            TextDecoder: plain(),
            Promise: plain(),
            PromiseLike: plain(),
            Iterator: iterator,
            IteratorHelper: Obj(proto: iterator),
            AsyncIterator: asyncIterator,
            Generator: Obj(proto: iterator),
            AsyncGenerator: Obj(proto: asyncIterator),
            AsyncFromSyncIterator: Obj(proto: asyncIterator),
            Error: error,
            TypeError: derived(.typeError),
            RangeError: derived(.rangeError),
            SyntaxError: derived(.syntaxError),
            ReferenceError: derived(.referenceError),
            EvalError: derived(.evalError),
            URIError: derived(.uriError),
            AggregateError: derived(.aggregateError)
        )
    }

    // MARK: - Native Helpers (src/language/runtime/native.ts)

    // parity: psychoscript/src/runtime/native.ts#Impl [status=implemented hash=1eba0ab36b20]
    public typealias Impl = NativeCall

    // parity: psychoscript/src/runtime/native.ts#native [status=implemented hash=483d705c33fb]
    public static func native(_ builtins: Builtins, _ options: NativeOptions) -> Native {
        Native(proto: builtins.Function, options: options)
    }

    // parity: psychoscript/src/runtime/native.ts#fn [status=implemented hash=5f3dd095b24e]
    public static func nativeFn(_ builtins: Builtins, name: String, length: Int = 0, call: @escaping NativeCall) -> Native {
        Native(proto: builtins.Function, options: NativeOptions(name: name, length: length, call: call))
    }

    // parity: psychoscript/src/runtime/native.ts#Method [status=implemented hash=8a982f797a85]
    public struct Method: Sendable {
        public let name: String
        public let length: Int
        public let call: NativeCall

        public init(_ name: String, _ length: Int, _ call: @escaping NativeCall) {
            self.name = name
            self.length = length
            self.call = call
        }
    }

    // parity: psychoscript/src/runtime/native.ts#methods [status=implemented hash=7104436dc4da]
    public static func methods(_ builtins: Builtins, _ target: Obj, _ list: [Method]) {
        for m in list {
            define(target, JSString(m.name), .object(nativeFn(builtins, name: m.name, length: m.length, call: m.call)), hidden)
        }
    }

    // parity: psychoscript/src/runtime/native.ts#iteratorMethods [status=implemented hash=7aa71970110c]
    public static func iteratorMethods(_ builtins: Builtins, _ target: Obj, _ fn: Native) {
        define(target, .symbol(IteratorSymbol), .object(fn), hidden)
    }

    // parity: psychoscript/src/runtime/native.ts#constants [status=implemented hash=bccacfbd75a1]
    public static func constants(_ target: Obj, _ values: [(String, Value)]) {
        for (k, v) in values {
            define(target, JSString(k), v, frozen)
        }
    }

    // parity: psychoscript/src/runtime/native.ts#constructor [status=implemented hash=eaa39eccf7f7]
    public static func constructor(_ builtins: Builtins, _ prototype: Obj, _ options: NativeOptions) -> Native {
        let ctor = Native(proto: builtins.Function, options: options)
        define(ctor, "prototype", .object(prototype), frozen)
        define(prototype, "constructor", .object(ctor), hidden)
        return ctor
    }

    // parity: psychoscript/src/runtime/native.ts#requiresNew [status=implemented hash=9c134b4427fd]
    public static func requiresNew(_ name: String) -> NativeCall {
        { _, _, site, _ in
            throw typeError("Class constructor \(name) cannot be invoked without 'new'.", node: site)
        }
    }

    // parity: psychoscript/src/runtime/native.ts#prototypeFrom [status=implemented hash=0d6b10aa9530]
    public static func prototypeFrom(_ newTarget: Callable, fallback: Obj) -> Obj {
        if case .object(let proto) = get(newTarget, "prototype") {
            return proto
        }
        return fallback
    }

    // parity: psychoscript/src/runtime/native.ts#receiver [status=implemented hash=e777c1817fa6]
    public static func receiver<T: Obj>(_ type: T.Type, _ value: Value, _ method: String) throws -> T {
        guard case .object(let obj) = value, let typed = obj as? T else {
            throw typeError("\(method) called on incompatible receiver \(describeValue(value)).")
        }
        return typed
    }

    // MARK: - Callback Helpers (src/language/runtime/callback.ts)

    // parity: psychoscript/src/runtime/callback.ts#invokeMethod [status=implemented hash=1f50f47ea396]
    public static func invokeMethod(
        _ evaluator: Evaluator,
        target: Value,
        name: JSString,
        args: [Value],
        site: AstNode? = nil
    ) async throws -> Value {
        let fn = try resolveProperty(target, .string(name), builtins: evaluator.builtins, node: site)
        return try await evaluator.callCallable(fn, thisValue: target, args: args, site: site)
    }

    // parity: psychoscript/src/runtime/callback.ts#conversions [status=implemented hash=a1369e3ebfe2]
    public static func conversions(_ hint: Hint, _ values: [Value], coerce: Bool = false) -> [Value] {
        values.map { val in
            let prim: Value = if case .object(let obj) = val { obj.toPrimitive(hint: hint) } else { val }
            if !coerce { return prim }
            switch hint {
            case .string: return .string(coerceToString(prim))
            case .number: return .number(coerceToNumber(prim))
            case .default: return prim
            }
        }
    }

    // parity: psychoscript/src/runtime/callback.ts#withPrimitives [status=implemented hash=12f48b580f23]
    public static func withPrimitives(
        _ hint: Hint,
        _ values: [Value],
        coerce: Bool = false,
        _ body: ([Value]) throws -> Value
    ) throws -> Value {
        try body(conversions(hint, values, coerce: coerce))
    }

    // parity: psychoscript/src/runtime/callback.ts#requireCallback [status=implemented hash=1f3e31a6c3db]
    public static func requireCallback(_ value: Value, _ method: String) throws -> Callable {
        guard case .object(let obj) = value, let callable = obj as? Callable else {
            // Upstream labels callbacks without `.prototype` (`Array.map`, `Map.forEach`).
            throw typeError("\(method.replacingOccurrences(of: ".prototype.", with: ".")) expects a function callback.")
        }
        return callable
    }

    // parity: psychoscript/src/runtime/callback.ts#isSupportedCallback [status=implemented hash=34efe771f205]
    public static func isSupportedCallback(_ value: Value) -> Bool {
        guard case .object(let obj) = value else { return false }
        if let n = obj as? Native { return n.supportsCallback }
        return obj is Callable
    }

    // parity: psychoscript/src/runtime/callback.ts#withReads [status=adapted hash=40e9e7a331df]
    /// Runs a native body whose [[Get]]s may meet program getters. A getter not read yet gives `undefined` and is
    /// recorded; if any were, the body's result (or failure, which a placeholder may have caused) is dropped for a
    /// `Prefetch`: the getters run in program code through `evaluator`, then the body runs again from the start, and
    /// the getters' values are read from the table this time. So the body must be repeatable until it returns: it
    /// reads, checks and allocates, but changes nothing it does not own. A body whose path depends on a read stops at
    /// `readsPending()`. Upstream hands the `Prefetch` to the VM; the async natives here carry it out themselves.
    public static func withReads(_ evaluator: Evaluator, _ body: () async throws -> Value) async throws -> Value {
        let outer = Reads.current
        let context = ReadsContext(depth: (outer?.depth ?? 0) + 1, table: outer?.tableSnapshot ?? [])
        while true {
            let outcome: Swift.Result<Value, Error>
            do {
                outcome = .success(try await Reads.$current.withValue(context) { try await body() })
            } catch {
                outcome = .failure(error)
            }
            guard let missing = context.takeMissing(), !missing.isEmpty else {
                if let failure = context.takeFailure() { throw failure }
                return try outcome.get()
            }
            _ = context.takeFailure()
            let prefetch = Prefetch(reads: missing.flatMap { [$0.0, propertyKeyValue($0.1)] })
            try evaluator.checkLimits()
            for (receiver, key, value) in try await evaluator.runPrefetch(prefetch) {
                context.remember(receiver, key, value)
            }
        }
    }

    // parity: psychoscript/src/runtime/callback.ts#readsPending [status=implemented hash=538865c71a5a]
    /// Whether a read in this `withReads` round met a getter not read yet, so what it gave is only a placeholder.
    public static func readsPending() -> Bool {
        Reads.current?.hasMissing ?? false
    }

    /// A property key as the program value it is.
    static func propertyKeyValue(_ key: PropertyKey) -> Value {
        switch key {
        case .string(let s): return .string(s)
        case .symbol(let sym): return .symbol(sym)
        }
    }

    // MARK: - Error Normalization & Globals (src/language/runtime/errors.ts)

    // parity: psychoscript/src/runtime/errors.ts#errorMessage [status=implemented hash=1621010dc9f2]
    public static func errorMessage(_ error: Error) -> String {
        if let pt = error as? PendingThrow { return pt.message }
        if let hf = error as? HostFailure { return hf.message }
        if let se = error as? SnapshotError { return se.message }
        if let pf = error as? ParseFailure { return pf.diagnostic.message }
        return String(describing: error)
    }

    // parity: psychoscript/src/runtime/errors.ts#errorType [status=implemented hash=fba5e4fff22b]
    public static func errorType(_ error: Error) -> ErrorType {
        if let pt = error as? PendingThrow { return pt.type }
        return .error
    }

    // parity: psychoscript/src/runtime/errors.ts#normalizeError [status=implemented hash=7e37ab48a60f]
    public static func normalizeError(_ error: Error) -> Diagnostic {
        if let pf = error as? ParseFailure {
            return pf.diagnostic
        }
        if let pt = error as? PendingThrow {
            let loc = pt.node?.location
            return Diagnostic(
                kind: pt.kind,
                message: "\(pt.type.rawValue): \(pt.message)\(formatLocation(loc))",
                location: loc,
                suggestions: pt.suggestions
            )
        }
        if let hf = error as? HostFailure {
            return Diagnostic(
                kind: hf.kind,
                message: hf.message,
                suggestions: hf.suggestions.isEmpty ? nil : hf.suggestions
            )
        }
        if let thrown = error as? Throw {
            if case .object(let errObj as ErrorObj) = thrown.value {
                if let failure = errObj.failure {
                    return normalizeError(failure)
                }
                return Diagnostic(kind: "ExecutionFailure", message: errorToString(errObj).toHostString())
            }
            let message: String
            if containsRuntimeReference(thrown.value) {
                message = "a non-data value"
            } else if case .string(let s) = thrown.value {
                message = s.toHostString()
            } else {
                message = formatValue(thrown.value)
            }
            return Diagnostic(kind: "ExecutionFailure", message: "Uncaught: \(message)")
        }
        return Diagnostic(kind: "ExecutionFailure", message: errorMessage(error))
    }

    // parity: psychoscript/src/runtime/errors.ts#locate [status=implemented hash=3196b99124bc]
    public static func locate(_ error: Error, node: AstNode?) -> Error {
        if let pt = error as? PendingThrow {
            if let node, pt.node == nil || inPrelude(pt.node!) {
                pt.node = node
            }
            return pt
        }
        if error is Throw || error is HostFailure || error is ParseFailure || error is Interruption {
            return error
        }
        return PendingThrow(type: errorType(error), message: errorMessage(error), node: node)
    }

    // parity: psychoscript/src/runtime/errors.ts#materialize [status=implemented hash=e4ff86ee75c5]
    /// The program value a handler receives for a failure; one failure always yields the same value. A host failure has
    /// no site of its own, so its `stack` names `site`, where the handler observed it, when there is one.
    public static func materialize(_ builtins: Builtins, _ thrown: Error, site: AstNode? = nil) -> Value {
        if let t = thrown as? Throw { return t.value }
        if let pt = thrown as? PendingThrow {
            if let existing = pt.value { return .object(existing) }
            let node = pt.node
            let trace = if let node, node.location != nil, !inPrelude(node) { stackFrame(node) } else { "" }
            let created = createErrorValue(builtins.errorProto(pt.type), message: JSString(pt.message), trace: trace)
            created.failure = pt
            pt.value = created
            return .object(created)
        }
        if let hf = thrown as? HostFailure {
            let trace = if let site, site.location != nil { stackFrame(site) } else { "" }
            let created = createErrorValue(builtins.Error, message: JSString(hf.message), trace: trace)
            return .object(created)
        }
        let diag = normalizeError(thrown)
        return .object(createErrorValue(builtins.errorProto(errorType(thrown)), message: JSString(diag.message)))
    }

    // parity: psychoscript/src/runtime/errors.ts#stackFrame [status=implemented hash=654ee57bde24]
    /// One V8-style `stack` line for a program site: `at name (<program>:line:col)`, or `at <program>:line:col` at
    /// top level. The location is in the submitted source and never names a host file.
    public static func stackFrame(_ node: AstNode, name: String? = nil) -> String {
        let location = sourceLocation(node)
        let at = "<program>:\(location.line):\(location.column)"
        return "\n    at \(name.map { "\($0) (\(at))" } ?? at)"
    }

    // parity: psychoscript/src/runtime/errors.ts#createAggregateErrorValue [status=implemented hash=910584be722d]
    public static func createAggregateErrorValue(
        _ builtins: Builtins,
        errors: [Value],
        message: JSString,
        proto: Obj? = nil,
        trace: String = ""
    ) -> ErrorObj {
        let value = createErrorValue(proto ?? builtins.AggregateError, message: message, trace: trace)
        define(value, "errors", .object(Arr(proto: builtins.Array, items: errors)), hidden)
        return value
    }

    // parity: psychoscript/src/runtime/errors.ts#errorGlobal [status=implemented hash=f1fdf42256f8]
    /// The error constructors. An error made here gets a `stack` whose `    at` lines are `trace` (the evaluator's frames
    /// where it was made); its header is formatted on first read.
    public static func errorGlobal(_ type: ErrorType, builtins: Builtins, trace: @escaping @Sendable (Evaluator) -> String = { _ in "" }) -> Native {
        let proto = builtins.errorProto(type)
        let makeError: @Sendable ([Value], Callable, Evaluator) async throws -> Value = { args, newTarget, eval in
            let targetProto = prototypeFrom(newTarget, fallback: proto)
            if type == .aggregateError {
                let items = try await eval.collectIterable(args.first ?? .undefined)
                return try await withReads(eval) {
                    let msg: JSString = args.count > 1 && !args[1].isUndefined ? coerceToString(args[1]) : ""
                    let created = createAggregateErrorValue(builtins, errors: items, message: msg, proto: targetProto, trace: trace(eval))
                    if args.count > 2, case .object(let opts) = args[2], has(opts, "cause") {
                        define(created, "cause", get(opts, "cause"), hidden)
                    }
                    return .object(created)
                }
            }
            return try await withReads(eval) {
                let msg: JSString? = args.first.flatMap { $0.isUndefined ? nil : coerceToString($0) }
                let created = createErrorValue(targetProto, message: msg, trace: trace(eval))
                if args.count > 1, case .object(let opts) = args[1], has(opts, "cause") {
                    define(created, "cause", get(opts, "cause"), hidden)
                }
                return .object(created)
            }
        }
        let ctor = constructor(builtins, proto, NativeOptions(
            name: type.rawValue,
            length: type == .aggregateError ? 2 : 1,
            call: { _, args, _, eval in
                let selfCtor = get(proto, "constructor")
                let target: Callable = if case .object(let c as Callable) = selfCtor { c } else {
                    Native(proto: builtins.Function, options: NativeOptions(name: type.rawValue, call: { _, _, _, _ in .undefined }))
                }
                return try await makeError(args, target, eval)
            },
            construct: makeError
        ))
        if type == .error {
            methods(builtins, proto, [
                Method("toString", 0) { thisVal, _, _, eval in
                    try await withReads(eval) {
                        let obj = try receiver(Obj.self, thisVal, "Error.prototype.toString")
                        return .string(errorToString(obj, read: { get($0, $1) }))
                    }
                },
            ])
            methods(builtins, ctor, [
                Method("isError", 1) { _, args, _, _ in
                    if case .object(let obj) = args.first { return .bool(obj is ErrorObj) }
                    return .bool(false)
                },
            ])
        }
        return ctor
    }

    // MARK: - JSON <-> Value Conversion (src/language/data.ts)

    // parity: psychoscript/src/data.ts#Json [status=implemented hash=6dcd2d847149]
    public typealias DataJson = Json

    // parity: psychoscript/src/data.ts#fromJson [status=implemented hash=10e5e330a78a]
    public static func fromJson(_ builtins: Builtins, _ value: JSONValue, depth: Int = 0) throws -> Value {
        guard depth <= MAX_VALUE_DEPTH else {
            throw invalidData("Value exceeds maximum nesting depth of \(MAX_VALUE_DEPTH).")
        }
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(JSString(s))
        case .array(let items):
            var converted: [Value] = []
            converted.reserveCapacity(items.count)
            for item in items {
                converted.append(try fromJson(builtins, item, depth: depth + 1))
            }
            return .object(Arr(proto: builtins.Array, items: converted))
        case .object(let dict):
            let obj = Obj(proto: builtins.Object)
            for key in dict.keys.sorted() {
                if key == "__proto__" { continue }
                if let v = dict[key] {
                    define(obj, JSString(key), try fromJson(builtins, v, depth: depth + 1))
                }
            }
            return .object(obj)
        }
    }

    /// Converts a program `Value` to `OpenCodeSchema.JSONValue` at the Swift host/tool boundary.
    ///
    /// Upstream psychoscript lives in JS, where host strings can carry lone UTF-16 surrogates directly;
    /// Swift `String` / `JSONValue` can only hold well-formed Unicode scalar sequences. At this boundary,
    /// `JSString.toHostString()` replaces each unpaired UTF-16 surrogate with U+FFFD so returning or
    /// passing values to Swift tools never crashes or fails UTF-8/JSON encoding.
    public static func toJsonValue(_ value: Value, depth: Int = 0, dropFunctions: Bool = false) throws -> JSONValue? {
        guard depth <= MAX_VALUE_DEPTH else {
            throw rangeError("Value exceeds the maximum depth of \(MAX_VALUE_DEPTH).")
        }
        switch value {
        case .undefined: return nil
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n):
            guard n.isFinite else { return .null }
            if n == Double(Int64(n)) && n >= -9_007_199_254_740_991 && n <= 9_007_199_254_740_991 && !(n == 0 && n.sign == .minus) {
                return .int(Int64(n))
            }
            return .double(n)
        case .string(let s): return .string(s.toHostString())
        case .symbol:
            if dropFunctions { return nil }
            throw invalidData("Cannot serialize symbol across boundary.")
        case .hostNamespace:
            if dropFunctions { return nil }
            throw invalidData("Cannot return a tool namespace reference.")
        case .object(let obj):
            if obj is Callable {
                if dropFunctions { return nil }
                throw invalidData("Functions cannot be returned as data.")
            }
            if let dateObj = obj as? DateObj {
                return dateObj.epochMs.isFinite ? .string(CodemodeLanguage.formatISODate(epochMs: dateObj.epochMs)) : .null
            }
            if let urlObj = obj as? URLObj { return .string(urlObj.href) }
            if let spObj = obj as? URLSearchParamsObj { return .string(spObj.jsToString().toHostString()) }
            if let hObj = obj as? HeadersObj {
                var out: [String: JSONValue] = [:]
                for (k, v) in hObj.sortedEntries() { out[k] = .string(v) }
                return .object(out)
            }
            if obj is Bytes {
                throw invalidData("A Uint8Array cannot cross to the host; pass text instead, e.g. `new TextDecoder().decode(bytes)` or `bytes.toBase64()`.")
            }
            if let arr = obj as? Arr {
                var list: [JSONValue] = []
                list.reserveCapacity(arr.count)
                for item in arr.items {
                    list.append(try toJsonValue(item, depth: depth + 1, dropFunctions: dropFunctions) ?? .null)
                }
                return .array(list)
            }
            if let setObj = obj as? SetObj {
                var list: [JSONValue] = []
                for item in setObj.table.liveKeys() {
                    list.append(try toJsonValue(item, depth: depth + 1, dropFunctions: dropFunctions) ?? .null)
                }
                return .array(list)
            }
            if let errObj = obj as? ErrorObj {
                var out: [String: JSONValue] = [:]
                out["name"] = .string(coerceToString(get(errObj, "name")).toHostString())
                out["message"] = .string(coerceToString(get(errObj, "message")).toHostString())
                for (k, v) in entries(errObj) where k != "__proto__" {
                    if let j = try toJsonValue(v, depth: depth + 1, dropFunctions: dropFunctions) {
                        out[k.toHostString()] = j
                    }
                }
                return .object(out)
            }
            if obj is MapObj || obj is RegExpObj {
                return .object([:])
            }
            var out: [String: JSONValue] = [:]
            for (k, v) in entries(obj) where k != "__proto__" {
                if let j = try toJsonValue(v, depth: depth + 1, dropFunctions: dropFunctions) {
                    out[k.toHostString()] = j
                }
            }
            return .object(out)
        }
    }

    // MARK: - Host Functions & Host Boundary (src/language/host-function.ts, host.ts, runtime/extensions.ts)

    /// Structured host error carrying an optional JavaScript error name (e.g. `"Error"`, `"TypeError"`).
    public struct HostError: Error, Sendable, CustomStringConvertible {
        public let name: String
        public let message: String

        public init(_ message: String, name: String = "Error") {
            self.name = name
            self.message = message
        }

        public var description: String { message }
    }

    public enum Host {
        // parity: psychoscript/src/host-function.ts#Call [status=implemented hash=805892fe7fb2]
        public struct Call: Sendable {
            public let key: String
            public let suspending: @Sendable () -> Bool
            public let signal: AbortSignal

            public init(
                key: String,
                suspending: @escaping @Sendable () -> Bool = { false },
                signal: AbortSignal = AbortSignal()
            ) {
                self.key = key
                self.suspending = suspending
                self.signal = signal
            }
        }

        // parity: psychoscript/src/host-function.ts#DurableCall [status=implemented hash=6a779cb9b1f9]
        public struct DurableCall: Sendable {
            public let key: String
            public let suspending: @Sendable () -> Bool
            public let signal: AbortSignal
            public let args: [Value]

            public init(
                key: String,
                args: [Value],
                suspending: @escaping @Sendable () -> Bool = { false },
                signal: AbortSignal = AbortSignal()
            ) {
                self.key = key
                self.args = args
                self.suspending = suspending
                self.signal = signal
            }
        }

        // parity: psychoscript/src/host-function.ts#Snapshot [status=implemented hash=013523a19867]
        public typealias Snapshot = Contract.Snapshot

        // parity: psychoscript/src/host-function.ts#Type [status=implemented hash=013523a19867]
        public typealias CallType = Contract.CallType

        // parity: psychoscript/src/host-function.ts#Options [status=implemented hash=d9b9747fd829]
        public struct Options: Sendable {
            public let type: CallType
            public let idempotent: Bool
            public let snapshot: Snapshot?
            public let constructible: Bool
            public let takesFunctions: Bool
            public let name: String?
            public let length: Int?

            public init(
                type: CallType = .sync,
                idempotent: Bool = false,
                snapshot: Snapshot? = nil,
                constructible: Bool = false,
                takesFunctions: Bool = false,
                name: String? = nil,
                length: Int? = nil
            ) {
                self.type = type
                self.idempotent = type == .async && idempotent
                self.snapshot = snapshot
                self.constructible = constructible
                self.takesFunctions = takesFunctions
                self.name = name
                self.length = length
            }
        }

        // parity: psychoscript/src/host-function.ts#Fn [status=implemented hash=6e0f5b70b88a]
        public typealias Fn = Contract.Fn

        // parity: psychoscript/src/host-function.ts#DurableFn [status=implemented hash=6e0f5b70b88a]
        public typealias DurableFn = Contract.DurableFn

        public enum ResolvedTarget: Sendable {
            case fn(Fn)
            case durable(DurableFn)
            case failure(HostFailure)
        }

        // parity: psychoscript/src/host-function.ts#Namespace [status=implemented hash=6e0f5b70b88a]
        public typealias Namespace = Contract.Namespace

        // parity: psychoscript/src/host-function.ts#fn [status=implemented hash=97d45b5aa07a]
        public static func fn(
            _ run: @escaping @Sendable ([Value], Call, Builtins) async throws -> Value,
            options: Options = Options()
        ) -> Fn {
            Fn(
                run: run,
                type: options.type,
                idempotent: options.idempotent,
                snapshot: options.snapshot,
                constructible: options.constructible,
                takesFunctions: options.takesFunctions,
                sourceName: options.name,
                sourceLength: options.length
            )
        }

        /// Overload for Promise-based host functions returning `HostReturn` (values, Promises, or `HostWork`).
        public static func fnReturn(
            _ run: @escaping @Sendable ([Value], Call, Builtins) async throws -> HostReturn,
            options: Options = Options()
        ) -> Fn {
            Fn(
                runReturn: { args, contractCall, builtins in
                    try await run(args, contractCall.hostCall, builtins)
                },
                type: options.type,
                idempotent: options.idempotent,
                snapshot: options.snapshot,
                constructible: options.constructible,
                takesFunctions: options.takesFunctions,
                sourceName: options.name,
                sourceLength: options.length
            )
        }

        /// Creates a plain host function suitable for `HostGlobalValue.plainFn` or embedding in returned objects.
        public static func plainFn(
            name: String = "",
            length: Int = 0,
            _ run: @escaping @Sendable ([Value], Builtins) async throws -> HostReturn
        ) -> PlainHostFn {
            PlainHostFn(name: name, length: length, run)
        }

        /// Creates a `Value` embedding a plain host function inside an object/array returned from a host function.
        public static func plainValue(
            builtins: Builtins,
            name: String = "",
            length: Int = 0,
            _ run: @escaping @Sendable ([Value], Builtins) async throws -> HostReturn
        ) -> Value {
            .object(PlainHostFnObj(proto: builtins.Function, plainFn: PlainHostFn(name: name, length: length, run)))
        }

        // parity: psychoscript/src/host-function.ts#durableFn [status=implemented hash=a7094672e63c]
        public static func durableFn(
            start: @escaping @Sendable ([Value], Call) async throws -> JSONValue,
            wait: @escaping @Sendable (JSONValue, DurableCall, Builtins) async throws -> Value,
            cancel: @escaping @Sendable (JSONValue, DurableCall) async throws -> Void
        ) -> DurableFn {
            DurableFn(start: start, wait: wait, cancel: cancel)
        }

        // parity: psychoscript/src/host-function.ts#namespace [status=implemented hash=9a40cc45ad66]
        public static func namespace(
            keys: @escaping @Sendable ([String]) throws -> [String],
            resolve: @escaping @Sendable ([String]) -> ResolvedTarget
        ) -> Namespace {
            Namespace(keys: keys, resolve: resolve)
        }

        // parity: psychoscript/src/host-function.ts#fail [status=implemented hash=9b85a78dcc5c]
        public static func fail(_ kind: String, _ message: String, suggestions: [String] = []) -> HostFailure {
            HostFailure(kind: kind, message: message, suggestions: suggestions)
        }

        // parity: psychoscript/src/host-function.ts#missing [status=implemented hash=1689a7fa6fe6]
        public static func missing(_ message: String, suggestions: [String] = [], kind: String = "ExecutionFailure") -> HostFailure {
            HostFailure(kind: kind, message: message, suggestions: suggestions)
        }

        // parity: psychoscript/src/host-function.ts#Failure [status=implemented hash=5dd2dd1d91c8]
        public typealias Failure = HostFailure
    }

    public enum HostGlobalValue: Sendable {
        case fn(Host.Fn)
        case durableFn(Host.DurableFn)
        case namespace(Host.Namespace)
        case plainFn(PlainHostFn)
        case object([String: HostGlobalValue])
        case literal(JSONValue)
        case value(Value)
    }

    // parity: psychoscript/src/host.ts#Promises [status=implemented hash=e265b97184fc]
    public struct Promises: Sendable {
        public let pendingCount: Int

        public init(pendingCount: Int = 0) {
            self.pendingCount = pendingCount
        }
    }

    // parity: psychoscript/src/host.ts#BLOCK [status=implemented hash=e7fb5cb466a7]
    public static let BLOCK = RuntimeSymbol("codemode.host.block")

    // parity: psychoscript/src/host.ts#ENTERED [status=implemented hash=76b018ac576f]
    public static let ENTERED = RuntimeSymbol("codemode.host.entered")

    // parity: psychoscript/src/host.ts#HostResult [status=implemented hash=9a8db9347a85]
    public enum HostResult: Sendable {
        case value(Value)
        case error(Error)
        /// The arguments hold program getters to run first (as program code); then the call is made again.
        case prefetch(Prefetch)
    }

    // parity: psychoscript/src/host.ts#HostVm [status=implemented hash=8191b2aefeb4]
    public protocol HostVm: Sendable {
        var builtins: Builtins { get }
    }

    /// Where a host function is; the program names it in errors by its label (for example `sleep` or `store.get`).
    // parity: psychoscript/src/host.ts#HostTarget [status=implemented hash=2cabac2c0723]
    public enum HostTarget: Sendable {
        case fn(Host.Fn)
        case durable(Host.DurableFn)
    }

    // parity: psychoscript/src/host.ts#VISIT_BUDGET [status=implemented hash=95912b9e09cc]
    public static let VISIT_BUDGET: Int = 100_000

    // parity: psychoscript/src/host.ts#HostCalls [status=implemented hash=4d1c074b748a]
    public final class HostCalls: Sendable {
        public struct InboxDelivery: Sendable {
            public let call: HostCall
            public let completion: Completion

            public init(call: HostCall, completion: Completion) {
                self.call = call
                self.completion = completion
            }
        }

        private struct State: Sendable {
            var runId: String
            var nextId: Int = 0
            var queued: [HostCall] = []
            var running: [Int: HostCall] = [:]
            var activeCalls: [HostCall] = []
            var blocked: HostCall? = nil
            var input: InboxDelivery? = nil
            var inbox: [InboxDelivery] = []
            var shape: [String] = []
        }

        private let state: Mutex<State>

        public init(runId: String = OpenCodeUtil.uuid()) {
            self.state = Mutex(State(runId: runId))
        }

        public var runId: String {
            get { state.withLock { $0.runId } }
            set { state.withLock { $0.runId = newValue } }
        }

        public var shape: [String] {
            get { state.withLock { $0.shape } }
            set { state.withLock { $0.shape = newValue } }
        }

        public var hasPendingInput: Bool {
            state.withLock { $0.input != nil }
        }

        public var hasInbox: Bool {
            state.withLock { !$0.inbox.isEmpty }
        }

        public func nextKey() -> String {
            state.withLock { s in
                let id = s.nextId
                s.nextId += 1
                return "\(s.runId):\(id)"
            }
        }

        public func registerCall(_ call: HostCall) {
            state.withLock { s in
                s.activeCalls.append(call)
                s.running[call.id] = call
            }
        }

        public func removeCall(key: String) {
            state.withLock { s in
                s.activeCalls.removeAll { $0.key == key }
                s.running = s.running.filter { $0.value.key != key }
            }
        }

        public func call(id: Int) -> HostCall? {
            state.withLock { $0.running[id] }
        }

        public func calls() -> [HostCall] {
            state.withLock { $0.activeCalls }
        }

        /// Enqueues a host function call, returning its promise for async/durable targets or `BLOCK` for blocking calls.
        /// Program getters in the arguments (`values`) run first, as program code, before anything else happens for
        /// the call: no promise and no call id, only a `prefetch` the caller runs before calling again.
        // parity: psychoscript/src/host.ts#HostCalls.call [status=implemented hash=8b477b22f2dd]
        public func call(
            target: HostTarget,
            label: String,
            path: String? = nil,
            builtins: Builtins,
            values: [Value] = []
        ) -> HostResult {
            if let prefetch = cross(values) { return .prefetch(prefetch) }
            let (id, key) = state.withLock { s -> (Int, String) in
                let id = s.nextId
                s.nextId += 1
                return (id, "\(s.runId):\(id)")
            }
            switch target {
            case .durable:
                let promise = PromiseObj(proto: builtins.Promise, hostCallKey: key)
                let resolving = Resolving(promise: promise)
                let hostCall = HostCall(id: id, key: key, label: label, path: path, status: .queued, blocking: false, resolving: resolving)
                state.withLock { s in
                    s.queued.append(hostCall)
                    s.activeCalls.append(hostCall)
                }
                return .value(.object(promise))
            case .fn(let fn):
                if fn.type == .async {
                    let promise = PromiseObj(proto: builtins.Promise, hostCallKey: key)
                    let resolving = Resolving(promise: promise)
                    let hostCall = HostCall(id: id, key: key, label: label, path: path, status: .queued, blocking: false, resolving: resolving)
                    state.withLock { s in
                        s.queued.append(hostCall)
                        s.activeCalls.append(hostCall)
                    }
                    return .value(.object(promise))
                }
                let hostCall = HostCall(id: id, key: key, label: label, path: path, status: .queued, blocking: true)
                state.withLock { s in
                    s.queued.append(hostCall)
                    s.activeCalls.append(hostCall)
                    s.blocked = hostCall
                }
                return .value(.symbol(CodemodeLanguage.BLOCK))
            }
        }

        /// Copies the arguments to the host ahead of the call: a `Prefetch` while program getters in them are still to run.
        private func cross(_ values: [Value]) -> Prefetch? {
            var budget = CodemodeLanguage.VISIT_BUDGET
            var seen = Set<ObjectIdentifier>()
            func hasProgramGetter(_ value: Value) -> Bool {
                guard case .object(let obj) = value, budget > 0, seen.insert(ObjectIdentifier(obj)).inserted else { return false }
                budget -= 1
                if obj.hasProgramAccessors { return true }
                if let arr = obj as? Arr { return arr.items.contains(where: hasProgramGetter) }
                return CodemodeLanguage.entries(obj).contains { hasProgramGetter($0.1) }
            }
            return values.contains(where: hasProgramGetter) ? Prefetch(reads: []) : nil
        }

        /// Continues a blocked host call with its completion outcome.
        // parity: psychoscript/src/host.ts#HostCalls.resume [status=implemented hash=21e845cd9984]
        public func resume(_ delivery: InboxDelivery) -> HostResult {
            delivery.call.status = .completed
            switch delivery.completion {
            case .ok(let value):
                return .value(value)
            case .error(let error):
                return .error(error)
            }
        }

        /// Hands queued host calls over to the driver, marking them as running.
        // parity: psychoscript/src/host.ts#HostCalls.handOver [status=implemented hash=d7d0ad230d50]
        public func handOver() -> [HostCall] {
            state.withLock { s in
                let handed = s.queued
                s.queued.removeAll()
                for c in handed {
                    c.status = .running
                    s.running[c.id] = c
                }
                return handed
            }
        }

        /// Records completion of a running host call by ID, queueing delivery to inbox or resuming a blocked call.
        // parity: psychoscript/src/host.ts#HostCalls.complete [status=implemented hash=8c0ff6694e88]
        public func complete(id: Int, completion: Completion) {
            state.withLock { s in
                guard let call = s.running.removeValue(forKey: id) else { return }
                s.activeCalls.removeAll { $0.id == id }
                if call.blocking {
                    call.status = .completed
                    if s.blocked?.id == call.id {
                        s.blocked = nil
                        s.input = InboxDelivery(call: call, completion: completion)
                    }
                    return
                }
                s.inbox.append(InboxDelivery(call: call, completion: completion))
            }
        }

        /// Delivers the oldest completed concurrent call from the inbox and settles its promise.
        // parity: psychoscript/src/host.ts#HostCalls.deliver [status=implemented hash=82ca683093f3]
        @discardableResult
        public func deliver() -> Bool {
            let delivery = state.withLock { s -> InboxDelivery? in
                s.inbox.isEmpty ? nil : s.inbox.removeFirst()
            }
            guard let delivery else { return false }
            delivery.call.status = .completed
            if let resolving = delivery.call.resolving {
                switch delivery.completion {
                case .ok(let value):
                    resolving.resolve(value)
                case .error(let error):
                    resolving.reject(error)
                }
            }
            return true
        }
    }

    /// A live response's state, read through a host function: the one kind of accessor made after the intrinsics.
    /// Defined with `defineAccessorHalf`, so `Object.getOwnPropertyDescriptor(…).get` is a real function
    /// (`get <name>`), where a native accessor made after the intrinsics would have no function to show.
    public static func hostGetter(_ builtins: Builtins, _ name: String, _ read: @escaping @Sendable () -> Bool) -> Native {
        native(builtins, NativeOptions(name: "get \(name)", call: { _, _, _, _ in .bool(read()) }))
    }

    // parity: psychoscript/src/runtime/extensions.ts#hostGlobals [status=adapted hash=3ad6ad593d21]
    public static func hostGlobals(
        builtins: Builtins,
        hostCalls: HostCalls,
        globals: [String: HostGlobalValue],
        translate: Translate = Translate(),
        adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)? = nil
    ) -> [(String, Value)] {
        func buildValue(name: String, item: HostGlobalValue) -> Value {
            switch item {
            case .value(let v):
                return v
            case .literal(let j):
                return (try? fromJson(builtins, j)) ?? .undefined
            case .namespace(let ns):
                let handler = NamespaceHandler(
                    keys: ns.keys,
                    resolve: ns.resolve
                )
                return .hostNamespace(HostNamespace(path: [], handler: handler))
            case .object(let dict):
                let obj = Obj(proto: builtins.Object)
                for key in dict.keys.sorted() {
                    if let child = dict[key] {
                        define(obj, JSString(key), buildValue(name: "\(name).\(key)", item: child))
                    }
                }
                return .object(obj)
            case .fn(let hostFn):
                return .object(wrapHostFn(name: name, hostFn: hostFn, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: adapt))
            case .plainFn(let plainFn):
                return .object(wrapPlainHostFn(name: name, plainFn: plainFn, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: adapt))
            case .durableFn(let durable):
                return .object(wrapDurableFn(name: name, durable: durable, builtins: builtins, hostCalls: hostCalls))
            }
        }
        return globals.keys.sorted().compactMap { name in
            globals[name].map { (name, buildValue(name: name, item: $0)) }
        }
    }

    /// Computes the program-visible `name` and `length` for a wrapped host function (v0.2.1):
    /// a `Host.fn` keeps its source function's own `name` and `length` (falling back to the trailing
    /// label segment when anonymous); a plain host function keeps its own `name` verbatim (even `""`).
    internal static func hostFunctionDisplay(label: String, hostFn: Host.Fn) -> (name: String, length: Int) {
        let fallback: String
        if let dot = label.lastIndex(of: ".") {
            fallback = String(label[label.index(after: dot)...])
        } else {
            fallback = label
        }
        let displayName: String
        if hostFn.isPlainSource {
            displayName = hostFn.sourceName ?? ""
        } else if let own = hostFn.sourceName, !own.isEmpty {
            displayName = own
        } else {
            displayName = fallback
        }
        let displayLength = max(0, hostFn.sourceLength ?? 0)
        return (displayName, displayLength)
    }

    internal static func labelLeafName(_ label: String) -> String {
        if let dot = label.lastIndex(of: ".") {
            return String(label[label.index(after: dot)...])
        }
        return label
    }

    /// Wraps a plain host function as a `sync` host function that takes functions and runs `adapt` on its return value.
    internal static func wrapPlainHostFn(
        name: String,
        plainFn: PlainHostFn,
        builtins: Builtins,
        hostCalls: HostCalls,
        translate: Translate,
        adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)?
    ) -> Native {
        let fn = Contract.Fn(
            runReturn: { args, call, builtins in
                let raw = try await plainFn.run(args, builtins)
                return adapt?(raw, call) ?? raw
            },
            type: .sync,
            idempotent: false,
            snapshot: nil,
            constructible: false,
            takesFunctions: true,
            sourceName: plainFn.name,
            sourceLength: plainFn.length,
            isPlainSource: true
        )
        return wrapHostFn(name: name, hostFn: fn, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: adapt)
    }

    /// Walks a value returned by a host function, wrapping any embedded `PlainHostFnObj` using the run's `adapt` hook.
    internal static func adaptReturnedHostValues(
        _ value: Value,
        label: String,
        builtins: Builtins,
        hostCalls: HostCalls,
        translate: Translate,
        adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)?,
        seen: inout Set<ObjectIdentifier>
    ) -> Value {
        guard case .object(let obj) = value else { return value }
        if let plainObj = obj as? PlainHostFnObj {
            return .object(wrapPlainHostFn(
                name: label,
                plainFn: plainObj.plainFn,
                builtins: builtins,
                hostCalls: hostCalls,
                translate: translate,
                adapt: adapt
            ))
        }
        guard seen.insert(ObjectIdentifier(obj)).inserted else { return value }
        if let arr = obj as? Arr {
            var changed = false
            var items = arr.items
            for idx in items.indices {
                let adapted = adaptReturnedHostValues(
                    items[idx],
                    label: "\(label)[\(idx)]",
                    builtins: builtins,
                    hostCalls: hostCalls,
                    translate: translate,
                    adapt: adapt,
                    seen: &seen
                )
                if case .object(let a) = adapted, case .object(let b) = items[idx], a !== b {
                    items[idx] = adapted
                    changed = true
                }
            }
            if changed { arr.items = items }
            return value
        }
        if type(of: obj) == Obj.self {
            for key in keys(obj) {
                let raw = peek(obj, .string(key))
                let adapted = adaptReturnedHostValues(
                    raw,
                    label: "\(label).\(key.toHostString())",
                    builtins: builtins,
                    hostCalls: hostCalls,
                    translate: translate,
                    adapt: adapt,
                    seen: &seen
                )
                if case .object(let a) = adapted, case .object(let b) = raw, a !== b {
                    define(obj, key, adapted)
                }
            }
        }
        return value
    }

    /// Maps an error from host work or a host function into the program-facing error and optional unmaterialized raw error.
    internal static func mapHostError(
        _ error: any Error,
        site: AstNode?,
        builtins: Builtins
    ) -> (thrown: any Error, raw: (any Error)?) {
        if error is Contract.Interrupted || error is Interruption {
            let intr = Interruption("interrupted")
            return (intr, intr)
        }
        if let defect = error as? Contract.HostDefect {
            let located = locate(defect.error, node: site)
            return (located, located)
        }
        if let hf = error as? HostFailure {
            return (hf, hf)
        }
        if let pt = error as? PendingThrow {
            return (pt, pt)
        }
        if let t = error as? Throw {
            return (t, nil)
        }
        if let he = error as? HostError {
            let errType = ErrorType(rawValue: he.name) ?? .error
            let errObj = createErrorValue(builtins.errorProto(errType), message: JSString(he.message))
            return (Throw(.object(errObj)), nil)
        }
        let errObj = createErrorValue(builtins.errorProto(errorType(error)), message: JSString(errorMessage(error)))
        return (Throw(.object(errObj)), nil)
    }

    /// Runs `HostWork` to settlement inside `eval`, registering its abort/stop handle so aborting or
    /// ending the run stops it and awaits its cleanup before finishing.
    internal static func settleHostWork(
        _ work: Contract.HostWork,
        label: String,
        site: AstNode?,
        builtins: Builtins,
        hostCalls: HostCalls,
        translate: Translate,
        adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)?,
        eval: Evaluator,
        controller: AbortController,
        asPending: Bool
    ) async throws -> Value {
        let context = eval.runContext
        if asPending {
            let promise = PromiseObj(proto: builtins.Promise)
            promise.attachAbortController(controller)
            let token = eval.registerHostWork(controller: controller)
            let task = Task<(outcome: PromiseOutcome, rawError: (any Error)?), Never> {
                defer { eval.finishHostWork(token) }
                let settled = await work.run(context: context, signal: controller.signal)
                switch settled {
                case .ok(.value(let v)):
                    var seen = Set<ObjectIdentifier>()
                    let adapted = adaptReturnedHostValues(v, label: label, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: adapt, seen: &seen)
                    return (.fulfilled(adapted), nil)
                case .ok(.promise(let p)):
                    return (.fulfilled(.object(p)), nil)
                case .ok(.work(let inner)):
                    let innerSettled = await inner.run(context: context, signal: controller.signal)
                    switch innerSettled {
                    case .ok(.value(let v)):
                        var seen = Set<ObjectIdentifier>()
                        let adapted = adaptReturnedHostValues(v, label: label, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: adapt, seen: &seen)
                        return (.fulfilled(adapted), nil)
                    case .ok(.promise(let p)):
                        return (.fulfilled(.object(p)), nil)
                    case .ok:
                        return (.fulfilled(.undefined), nil)
                    case .error(let err):
                        let mapped = mapHostError(err, site: site, builtins: builtins)
                        if mapped.raw is Interruption { return (.rejected(.undefined), mapped.raw) }
                        return (.rejected(materialize(builtins, mapped.thrown, site: site)), mapped.raw)
                    }
                case .ok(.effect):
                    let err = typeError("\(label) produced an Effect, which the program cannot hold.")
                    return (.rejected(materialize(builtins, err, site: site)), err)
                case .error(let err):
                    let mapped = mapHostError(err, site: site, builtins: builtins)
                    if mapped.raw is Interruption { return (.rejected(.undefined), mapped.raw) }
                    return (.rejected(materialize(builtins, mapped.thrown, site: site)), mapped.raw)
                }
            }
            promise.attachHostTask(task)
            eval.trackPromise(promise)
            eval.trackHostWorkTask(token, task: Task { _ = await task.value })
            return .object(promise)
        }

        // Blocking call (sync or sync-thenable returning HostWork): waits for settlement.
        let token = eval.registerHostWork(controller: controller)
        let workTask = Task<Contract.Settled, Never> {
            defer { eval.finishHostWork(token) }
            return await work.run(context: context, signal: controller.signal)
        }
        eval.trackHostWorkTask(token, task: Task { _ = await workTask.value })
        let settled = await workTask.value
        switch settled {
        case .ok(.value(let v)):
            var seen = Set<ObjectIdentifier>()
            return adaptReturnedHostValues(v, label: label, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: adapt, seen: &seen)
        case .ok(.promise(let p)):
            Contract.promiseControllers.set(p) { controller }
            p.attachAbortController(controller)
            eval.trackPromise(p)
            return .object(p)
        case .ok(.work(let inner)):
            return try await settleHostWork(
                inner,
                label: label,
                site: site,
                builtins: builtins,
                hostCalls: hostCalls,
                translate: translate,
                adapt: adapt,
                eval: eval,
                controller: AbortController(),
                asPending: true
            )
        case .ok(.effect):
            throw typeError("\(label) produced an Effect, which the program cannot hold.")
        case .error(let err):
            throw mapHostError(err, site: site, builtins: builtins).thrown
        }
    }

    internal static func wrapHostFn(
        name: String,
        hostFn: Host.Fn,
        builtins: Builtins,
        hostCalls: HostCalls,
        translate: Translate,
        adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)? = nil
    ) -> Native {
        let invoke: NativeCall = { _, args, site, eval in
            let effectiveAdapt = adapt ?? eval.adapt
            let preparedArgs = try await prepareHostArgs(args, name: name, translate: translate, takesFunctions: hostFn.takesFunctions, eval: eval)
            let key = hostCalls.nextKey()
            let controller = AbortController()
            let suspendingFn: @Sendable () -> Bool = { [weak eval] in eval?.isSuspending ?? false }
            let hostCallInfo = Host.Call(key: key, suspending: suspendingFn, signal: controller.signal)
            let contractCallInfo = Contract.Call(key: key, suspending: suspendingFn, signal: controller.signal, context: eval.runContext)
            let record = HostCall(
                key: key,
                label: name,
                path: name,
                status: .running,
                blocking: hostFn.type != .async,
                idempotent: hostFn.idempotent,
                abortController: controller
            )
            hostCalls.registerCall(record)

            switch hostFn.type {
            case .async:
                let promise = PromiseObj(proto: builtins.Promise, hostCallKey: key)
                promise.attachAbortController(controller)
                let abortToken = eval.registerAbortController(controller)
                let task = Task<(outcome: PromiseOutcome, rawError: (any Error)?), Never> {
                    defer {
                        eval.unregisterAbortController(abortToken)
                        hostCalls.removeCall(key: key)
                    }
                    do {
                        let ret: HostReturn
                        if let runReturn = hostFn.runReturn {
                            let raw = try await runReturn(preparedArgs, contractCallInfo, builtins)
                            ret = effectiveAdapt?(raw, contractCallInfo) ?? raw
                        } else {
                            let val = try await hostFn.run(preparedArgs, hostCallInfo, builtins)
                            ret = .value(val)
                        }
                        switch ret {
                        case .value(let v):
                            var seen = Set<ObjectIdentifier>()
                            let adapted = adaptReturnedHostValues(v, label: name, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: effectiveAdapt, seen: &seen)
                            return (.fulfilled(adapted), nil)
                        case .promise(let p):
                            Contract.promiseControllers.set(p) { controller }
                            p.attachAbortController(controller)
                            switch await p.awaitOutcome() {
                            case .fulfilled(let v):
                                var seen = Set<ObjectIdentifier>()
                                let adapted = adaptReturnedHostValues(v, label: name, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: effectiveAdapt, seen: &seen)
                                return (.fulfilled(adapted), nil)
                            case .rejected(let r):
                                return (.rejected(r), p.rawRejection)
                            }
                        case .work(let w):
                            let hwToken = eval.registerHostWork(controller: controller)
                            let workTask = Task<Contract.Settled, Never> {
                                defer { eval.finishHostWork(hwToken) }
                                return await w.run(context: eval.runContext, signal: controller.signal)
                            }
                            eval.trackHostWorkTask(hwToken, task: Task { _ = await workTask.value })
                            switch await workTask.value {
                            case .ok(.value(let v)):
                                var seen = Set<ObjectIdentifier>()
                                let adapted = adaptReturnedHostValues(v, label: name, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: effectiveAdapt, seen: &seen)
                                return (.fulfilled(adapted), nil)
                            case .ok(.promise(let p)):
                                return (.fulfilled(.object(p)), nil)
                            case .ok(.work(let inner)):
                                let innerSettled = await inner.run(context: eval.runContext, signal: controller.signal)
                                switch innerSettled {
                                case .ok(.value(let v)):
                                    var seen = Set<ObjectIdentifier>()
                                    let adapted = adaptReturnedHostValues(v, label: name, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: effectiveAdapt, seen: &seen)
                                    return (.fulfilled(adapted), nil)
                                case .ok(.promise(let p)):
                                    return (.fulfilled(.object(p)), nil)
                                case .ok:
                                    return (.fulfilled(.undefined), nil)
                                case .error(let err):
                                    let mapped = mapHostError(err, site: site, builtins: builtins)
                                    if mapped.raw is Interruption { return (.rejected(.undefined), mapped.raw) }
                                    return (.rejected(materialize(builtins, mapped.thrown, site: site)), mapped.raw)
                                }
                            case .ok(.effect):
                                let err = typeError("\(name) produced an Effect, which the program cannot hold.")
                                return (.rejected(materialize(builtins, err, site: site)), err)
                            case .error(let err):
                                let mapped = mapHostError(err, site: site, builtins: builtins)
                                if mapped.raw is Interruption { return (.rejected(.undefined), mapped.raw) }
                                return (.rejected(materialize(builtins, mapped.thrown, site: site)), mapped.raw)
                            }
                        case .effect:
                            let err = typeError("\(name) produced an Effect, which the program cannot hold.")
                            return (.rejected(materialize(builtins, err, site: site)), err)
                        }
                    } catch {
                        let mapped = mapHostError(error, site: site, builtins: builtins)
                        if mapped.raw is Interruption { return (.rejected(.undefined), mapped.raw) }
                        return (.rejected(materialize(builtins, mapped.thrown, site: site)), mapped.raw)
                    }
                }
                promise.attachHostTask(task)
                eval.trackPromise(promise)
                return .object(promise)
            case .sync, .syncThenable:
                let abortToken = eval.registerAbortController(controller)
                var keepControllerAlive = false
                defer {
                    if !keepControllerAlive { eval.unregisterAbortController(abortToken) }
                    hostCalls.removeCall(key: key)
                }
                let ret: HostReturn
                do {
                    if let runReturn = hostFn.runReturn {
                        let raw = try await runReturn(preparedArgs, contractCallInfo, builtins)
                        ret = effectiveAdapt?(raw, contractCallInfo) ?? raw
                    } else {
                        let val = try await hostFn.run(preparedArgs, hostCallInfo, builtins)
                        ret = .value(val)
                    }
                } catch {
                    throw mapHostError(error, site: site, builtins: builtins).thrown
                }

                let finalVal: Value
                switch ret {
                case .value(let v):
                    if case .object(let p as PromiseObj) = v {
                        keepControllerAlive = true
                        Contract.promiseControllers.set(p) { controller }
                        p.attachAbortController(controller)
                        p.registerExternalHostWorkIfNeeded(in: eval.scheduler)
                        eval.trackPromise(p)
                        return .object(p)
                    }
                    var seen = Set<ObjectIdentifier>()
                    finalVal = adaptReturnedHostValues(v, label: name, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: effectiveAdapt, seen: &seen)
                case .promise(let p):
                    keepControllerAlive = true
                    Contract.promiseControllers.set(p) { controller }
                    p.attachAbortController(controller)
                    p.registerExternalHostWorkIfNeeded(in: eval.scheduler)
                    eval.trackPromise(p)
                    return .object(p)
                case .work(let w):
                    let settledVal = try await settleHostWork(
                        w,
                        label: name,
                        site: site,
                        builtins: builtins,
                        hostCalls: hostCalls,
                        translate: translate,
                        adapt: effectiveAdapt,
                        eval: eval,
                        controller: controller,
                        asPending: false
                    )
                    if case .object(let p as PromiseObj) = settledVal {
                        keepControllerAlive = true
                        return .object(p)
                    }
                    finalVal = settledVal
                case .effect:
                    throw typeError("\(name) produced an Effect, which the program cannot hold.")
                }
                return hostFn.type == .syncThenable ? promiseLike(builtins, value: finalVal) : finalVal
            }
        }
        let construct: NativeConstruct?
        if hostFn.constructible {
            construct = { args, _, eval in
                try await invoke(.undefined, args, EvalFrames.current?.site, eval)
            }
        } else {
            construct = nil
        }
        let display = hostFunctionDisplay(label: name, hostFn: hostFn)
        return Native(
            proto: builtins.Function,
            options: NativeOptions(name: display.name, length: display.length, call: invoke, construct: construct)
        )
    }

    internal static func wrapDurableFn(
        name: String,
        durable: Host.DurableFn,
        builtins: Builtins,
        hostCalls: HostCalls
    ) -> Native {
        Native(
            proto: builtins.Function,
            options: NativeOptions(name: labelLeafName(name), length: 0, call: { _, args, site, eval in
                let key = hostCalls.nextKey()
                let waitController = AbortController()
                let suspendingFn: @Sendable () -> Bool = { [weak eval] in eval?.isSuspending ?? false }
                let startCallInfo = Host.Call(key: key, suspending: suspendingFn, signal: AbortSignal())
                let startContractCall = Contract.Call(key: key, suspending: suspendingFn, signal: AbortSignal(), context: eval.runContext)
                let durableCall = Host.DurableCall(key: key, args: args, suspending: suspendingFn, signal: waitController.signal)
                let contractDurableCall = Contract.DurableCall(key: key, args: args, suspending: suspendingFn, signal: waitController.signal, context: eval.runContext)
                let record = HostCall(
                    key: key,
                    label: name,
                    path: name,
                    status: .running,
                    blocking: false,
                    abortController: waitController
                )
                hostCalls.registerCall(record)
                let promise = PromiseObj(proto: builtins.Promise, hostCallKey: key)
                promise.attachAbortController(waitController)
                let abortToken = eval.registerAbortController(waitController)
                let resumedData = eval.takeResumedDurableData(forKey: key)
                let startToken = eval.registerDurableStart()
                let task = Task<(outcome: PromiseOutcome, rawError: (any Error)?), Never> {
                    defer {
                        eval.unregisterAbortController(abortToken)
                        hostCalls.removeCall(key: key)
                    }
                    do {
                        let startData: JSONValue
                        do {
                            defer { eval.finishDurableStart(startToken) }
                            if let existing = resumedData {
                                startData = existing
                            } else if let startWork = durable.startWork {
                                let w = startWork(args, startContractCall)
                                switch await w.run(context: eval.runContext, signal: nil) {
                                case .ok(.value(let v)):
                                    startData = (try? toJsonValue(v, dropFunctions: true)) ?? .null
                                case .ok:
                                    startData = .null
                                case .error(let err):
                                    throw err
                                }
                            } else {
                                startData = try await durable.start(args, startCallInfo)
                            }
                            record.status = .started
                            record.durableData = startData
                            let cancelHook: @Sendable () async -> Void = { [weak eval] in
                                guard let eval else { return }
                                let cancelCtrl = AbortController()
                                if let cancelWork = durable.cancelWork {
                                    let cw = cancelWork(
                                        startData,
                                        Contract.DurableCall(key: key, args: args, suspending: { false }, signal: cancelCtrl.signal, context: eval.runContext)
                                    )
                                    _ = await cw.run(context: eval.runContext, signal: cancelCtrl.signal)
                                } else {
                                    try? await durable.cancel(
                                        startData,
                                        Host.DurableCall(key: key, args: args, suspending: { false }, signal: cancelCtrl.signal)
                                    )
                                }
                            }
                            _ = eval.registerStartedDurable(key: key, path: name, data: startData, cancel: cancelHook)
                        }
                        if waitController.signal.aborted {
                            return (.rejected(.undefined), Interruption("interrupted"))
                        }
                        let value: Value
                        if let waitWork = durable.waitWork {
                            let w = waitWork(startData, contractDurableCall, builtins)
                            let hwToken = eval.registerHostWork(controller: waitController)
                            let wt = Task<Contract.Settled, Never> {
                                defer { eval.finishHostWork(hwToken) }
                                return await w.run(context: eval.runContext, signal: waitController.signal)
                            }
                            eval.trackHostWorkTask(hwToken, task: Task { _ = await wt.value })
                            switch await wt.value {
                            case .ok(.value(let v)): value = v
                            case .ok(.promise(let p)): value = .object(p)
                            case .ok: value = .undefined
                            case .error(let err):
                                if !waitController.signal.aborted { eval.unregisterStartedDurable(key: key) }
                                throw err
                            }
                        } else {
                            do {
                                value = try await durable.wait(startData, durableCall, builtins)
                            } catch {
                                if !waitController.signal.aborted { eval.unregisterStartedDurable(key: key) }
                                throw error
                            }
                        }
                        eval.unregisterStartedDurable(key: key)
                        var seen = Set<ObjectIdentifier>()
                        let adapted = adaptReturnedHostValues(value, label: name, builtins: builtins, hostCalls: hostCalls, translate: eval.translate, adapt: eval.adapt, seen: &seen)
                        return (.fulfilled(adapted), nil)
                    } catch {
                        let mapped = mapHostError(error, site: site, builtins: builtins)
                        if mapped.raw is Interruption { return (.rejected(.undefined), mapped.raw) }
                        return (.rejected(materialize(builtins, mapped.thrown, site: site)), mapped.raw)
                    }
                }
                promise.attachHostTask(task)
                eval.trackPromise(promise)
                return .object(promise)
            })
        )
    }

    /// A host call's arguments with their program getters run ahead, as program code and in order, so the host only
    /// ever reads data (upstream `HostCalls.cross` plus `$vmReplay`). Objects without program getters are kept.
    static func crossProgramGetters(_ value: Value, eval: Evaluator, seen: inout Set<ObjectIdentifier>) async throws -> Value {
        guard case .object(let obj) = value, !(obj is Callable), seen.insert(ObjectIdentifier(obj)).inserted else { return value }
        if let arr = obj as? Arr {
            var items = arr.items
            var changed = false
            for index in items.indices {
                let crossed = try await crossProgramGetters(items[index], eval: eval, seen: &seen)
                if case .object(let a) = crossed, case .object(let b) = items[index], a === b { continue }
                items[index] = crossed
                changed = true
            }
            return changed ? .object(Arr(proto: arr.proto, items: items)) : value
        }
        guard type(of: obj) == Obj.self else { return value }
        var pairs: [(JSString, Value)] = []
        var changed = obj.hasProgramAccessors
        for key in keys(obj) {
            let raw = try await eval.getValue(obj, .string(key), receiver: value)
            let crossed = try await crossProgramGetters(raw, eval: eval, seen: &seen)
            if case .object(let a) = crossed, case .object(let b) = raw, a !== b { changed = true }
            pairs.append((key, crossed))
        }
        guard changed else { return value }
        let copy = Obj(proto: obj.proto)
        for (key, item) in pairs { define(copy, key, item) }
        return .object(copy)
    }

    private static func prepareHostArgs(_ args: [Value], name: String, translate: Translate, takesFunctions: Bool, eval: Evaluator) async throws -> [Value] {
        var seen = Set<ObjectIdentifier>()
        var crossedArgs: [Value] = []
        for arg in args { crossedArgs.append(try await crossProgramGetters(arg, eval: eval, seen: &seen)) }
        var out: [Value] = []
        out.reserveCapacity(args.count)
        for (index, arg) in crossedArgs.enumerated() {
            var ancestors = Set<ObjectIdentifier>()
            let copied = try await copyToHost(
                arg,
                label: "Argument \(index + 1) to \(name)",
                depth: 0,
                translate: translate,
                takesFunctions: takesFunctions,
                ancestors: &ancestors,
                builtins: eval.builtins,
                eval: eval
            )
            out.append(copied ?? .undefined)
        }
        return out
    }

    // MARK: - Scheduler, Promises, Async & Generators (scheduler.ts, runtime/promises.ts, async.ts, generators.ts)

    // parity: psychoscript/src/scheduler.ts#Combination [status=implemented hash=5db6b48e3661]
    public enum Combination: String, Equatable, Hashable, Sendable, Codable {
        case all
        case allSettled
        case race
        case any
    }

    // parity: psychoscript/src/scheduler.ts#Reaction [status=implemented hash=a13895d1e73b]
    public struct Reaction: Sendable {
        public let onFulfilled: Value
        public let onRejected: Value
        public let target: PromiseObj

        public init(onFulfilled: Value, onRejected: Value, target: PromiseObj) {
            self.onFulfilled = onFulfilled
            self.onRejected = onRejected
            self.target = target
        }
    }

    // parity: psychoscript/src/scheduler.ts#Job [status=implemented hash=6dd061449c55]
    public struct Job: Sendable {
        public let description: String
        public let run: @Sendable () async -> Void

        public init(description: String, run: @escaping @Sendable () async -> Void) {
            self.description = description
            self.run = run
        }
    }

    // parity: psychoscript/src/scheduler.ts#HostPolicy [status=implemented hash=05293e22cf1a]
    public enum HostPolicy: String, Equatable, Hashable, Sendable, Codable {
        case block
        case cancel
        case detach
    }

    public enum HostCallStatus: String, Equatable, Hashable, Sendable, Codable {
        case queued
        case running
        case started
        case completed
    }

    // parity: psychoscript/src/scheduler.ts#HostCall [status=implemented hash=edc8260ce92a]
    public final class HostCall: Sendable {
        private struct MutableState: Sendable {
            var status: HostCallStatus
            var durableData: JSONValue? = nil
        }

        private let stateBox: Mutex<MutableState>
        public let id: Int
        public let key: String
        public let label: String
        public let path: String?
        public let blocking: Bool
        public let idempotent: Bool
        public let holdsFunctions: Bool
        public let resolving: Resolving?
        public let abortController: AbortController?

        public init(
            id: Int = 0,
            key: String,
            label: String,
            path: String? = nil,
            status: HostCallStatus = .queued,
            blocking: Bool = false,
            idempotent: Bool = false,
            holdsFunctions: Bool = false,
            resolving: Resolving? = nil,
            abortController: AbortController? = nil
        ) {
            self.id = id
            self.key = key
            self.label = label
            self.path = path
            self.blocking = blocking
            self.idempotent = idempotent
            self.holdsFunctions = holdsFunctions
            self.resolving = resolving
            self.abortController = abortController
            self.stateBox = Mutex(MutableState(status: status))
        }

        public var status: HostCallStatus {
            get { stateBox.withLock { $0.status } }
            set { stateBox.withLock { $0.status = newValue } }
        }

        public var durableData: JSONValue? {
            get { stateBox.withLock { $0.durableData } }
            set { stateBox.withLock { $0.durableData = newValue } }
        }
    }

    // parity: psychoscript/src/scheduler.ts#Resolving [status=implemented hash=1df996fb0717]
    public final class Resolving: Sendable {
        private let resolvedBox = Mutex<Bool>(false)
        public let promise: PromiseObj
        public let site: AstNode?
        private let scheduler: VmScheduler?

        public init(promise: PromiseObj, scheduler: VmScheduler? = nil, site: AstNode? = nil) {
            self.promise = promise
            self.scheduler = scheduler
            self.site = site
        }

        public func claim() -> Bool {
            resolvedBox.withLock { already in
                if already { return false }
                already = true
                return true
            }
        }

        // parity: psychoscript/src/scheduler.ts#Resolving.resolve [status=implemented hash=74c4b88d36f4]
        public func resolve(_ resolution: Value) {
            guard claim() else { return }
            if let scheduler {
                scheduler.resolveWith(promise, resolution: resolution, site: site)
            } else {
                promise.fulfill(resolution)
            }
        }

        // parity: psychoscript/src/scheduler.ts#Resolving.reject [status=implemented hash=d1eda77bae4a]
        public func reject(_ reason: Error) {
            guard claim() else { return }
            if let scheduler {
                scheduler.reject(promise, reason: reason)
            } else if let thrown = reason as? Throw {
                promise.reject(thrown.value)
            } else {
                promise.reject(.string(JSString(CodemodeLanguage.errorMessage(reason))))
            }
        }
    }

    // parity: psychoscript/src/scheduler.ts#Stop [status=implemented hash=725ce712050e]
    public enum Stop: Sendable {
        case done(Completion)
        case waitHost
        case slice
    }

    // parity: psychoscript/src/async.ts#SettlingTarget [status=implemented hash=08417e01c2ef]
    public enum SettlingTarget: Sendable {
        case promise(PromiseObj)
        case resolving(Resolving)
        case finallyTarget(FinallyTarget)
        case asyncClose(AsyncFromSyncCloseTarget)
    }

    // parity: psychoscript/src/async.ts#FinallyTarget [status=implemented hash=c2653ecf9572]
    public final class FinallyTarget: Sendable {
        public let onFinally: Value
        public let target: PromiseObj
        public let made: Resolving
        public let outcome: Completion

        public init(onFinally: Value, target: PromiseObj, outcome: Completion = .ok(.undefined)) {
            self.onFinally = onFinally
            self.target = target
            self.made = Resolving(promise: target)
            self.outcome = outcome
        }

        // parity: psychoscript/src/async.ts#FinallyTarget.resolve [status=implemented hash=a431581a6eed]
        public func resolve(_ result: Value) {
            _ = result
            switch outcome {
            case .ok(let value): made.resolve(value)
            case .error(let error): made.reject(error)
            }
        }

        // parity: psychoscript/src/async.ts#FinallyTarget.reject [status=implemented hash=56d09b8cec15]
        public func reject(_ reason: Error) {
            made.reject(reason)
        }
    }

    // parity: psychoscript/src/async.ts#AsyncFromSyncCloseTarget [status=implemented hash=ea2a15ea597a]
    public final class AsyncFromSyncCloseTarget: Sendable {
        public let iterator: Obj
        public let made: Resolving?
        public let reason: Error?

        public init(iterator: Obj, made: Resolving? = nil, reason: Error? = nil) {
            self.iterator = iterator
            self.made = made
            self.reason = reason
        }

        // parity: psychoscript/src/async.ts#AsyncFromSyncCloseTarget.resolve [status=implemented hash=9e36ba47acfc]
        public func resolve(_ value: Value) {
            _ = value
            if let made, let reason {
                made.reject(reason)
            }
        }

        // parity: psychoscript/src/async.ts#AsyncFromSyncCloseTarget.reject [status=implemented hash=9363e32fc5fa]
        public func reject(_ error: Error) {
            if let made {
                made.reject(reason ?? error)
            }
        }
    }

    // parity: psychoscript/src/async.ts#VmScheduler [status=implemented hash=bcc865ac8a77]
    public final class VmScheduler: Sendable {
        public struct ParkedEntry: Sendable {
            public let promise: PromiseObj
            public let node: AstNode?
            public let result: Value

            public init(promise: PromiseObj, node: AstNode?, result: Value) {
                self.promise = promise
                self.node = node
                self.result = result
            }
        }

        private struct State: Sendable {
            var queue: [Job] = []
            var head: Int = 0
            var pending: Int = 0
            var nextID: Int = 0
            var reactions: [ObjectIdentifier: [Reaction]] = [:]
            var parked: [(frame: Frame, entry: ParkedEntry)] = []
            var unhandled: [(id: Int, promise: ObjectIdentifier, diagnostic: Diagnostic)] = []
            var callProgram: (@Sendable (Callable, Value, [Value]) async throws -> Value)? = nil
        }

        private let state = Mutex(State())
        public let builtins: Builtins?

        /// Calls a program function (`callee`, `this`, arguments) as program code: how a thenable's `then` getter runs.
        public var callProgram: (@Sendable (Callable, Value, [Value]) async throws -> Value)? {
            get { state.withLock { $0.callProgram } }
            set { state.withLock { $0.callProgram = newValue } }
        }

        /// The `thenable-get` job: reads a thenable's program `then` getter, then adopts the thenable through it once.
        private func resolveThenableGet(_ promise: PromiseObj, thenable: Value, getter: Callable) async {
            guard let call = callProgram else {
                settle(promise, completion: .ok(thenable))
                return
            }
            do {
                let then = try await call(getter, thenable, [])
                guard case .object(let thenObj) = then, let thenFn = thenObj as? Callable else {
                    settle(promise, completion: .ok(thenable))
                    return
                }
                let settled = Mutex(false)
                let once: @Sendable (Completion) -> Void = { [weak self] completion in
                    let first = settled.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    if first { self?.settle(promise, completion: completion) }
                }
                let resolve = Native(proto: builtins?.Function, options: NativeOptions(name: "", length: 1, call: { _, args, _, _ in
                    once(.ok(args.first ?? .undefined))
                    return .undefined
                }))
                let reject = Native(proto: builtins?.Function, options: NativeOptions(name: "", length: 1, call: { _, args, _, _ in
                    once(.error(Throw(args.first ?? .undefined)))
                    return .undefined
                }))
                do {
                    _ = try await call(thenFn, thenable, [.object(resolve), .object(reject)])
                } catch {
                    once(.error(error))
                }
            } catch {
                settle(promise, completion: .error(error))
            }
        }

        public init(builtins: Builtins? = nil) {
            self.builtins = builtins
        }

        // parity: psychoscript/src/async.ts#VmScheduler.hasJobs [status=implemented hash=a238103e4475]
        public var hasJobs: Bool {
            state.withLock { $0.head < $0.queue.count }
        }

        // parity: psychoscript/src/async.ts#VmScheduler.newPromise [status=implemented hash=d2a354acc9cd]
        public func newPromise() throws -> PromiseObj {
            try state.withLock { s in
                if s.pending >= CodemodeLanguage.MAX_PENDING_PROMISES {
                    throw CodemodeLanguage.rangeError(
                        "Too many pending promises (limit \(CodemodeLanguage.MAX_PENDING_PROMISES)); await promises before creating more."
                    )
                }
                s.pending += 1
                s.nextID += 1
                return PromiseObj(proto: builtins?.Promise)
            }
        }

        // parity: psychoscript/src/async.ts#VmScheduler.resolving [status=implemented hash=5574a0c106dd]
        public func resolving(_ promise: PromiseObj, site: AstNode? = nil) -> Resolving {
            Resolving(promise: promise, scheduler: self, site: site)
        }

        // parity: psychoscript/src/async.ts#VmScheduler.then [status=implemented hash=3582c7db1b68]
        public func then(_ promise: PromiseObj, reaction: Reaction) {
            promise.isObserved = true
            let oid = ObjectIdentifier(promise)
            switch promise.status {
            case .pending:
                state.withLock { s in
                    s.reactions[oid, default: []].append(reaction)
                }
            case .fulfilled(let value):
                enqueue(Job(description: "reaction") {
                    reaction.target.fulfill(value)
                })
            case .rejected(let reason):
                state.withLock { s in
                    s.unhandled.removeAll { $0.promise == oid }
                }
                enqueue(Job(description: "reaction") {
                    reaction.target.reject(reason)
                })
            }
        }

        // parity: psychoscript/src/async.ts#VmScheduler.detach [status=implemented hash=7028db2f537a]
        public func detach(_ promise: PromiseObj, target: PromiseObj) {
            let oid = ObjectIdentifier(promise)
            let targetId = ObjectIdentifier(target)
            state.withLock { s in
                s.reactions[oid]?.removeAll { ObjectIdentifier($0.target) == targetId }
            }
        }

        // parity: psychoscript/src/async.ts#VmScheduler.promiseResolve [status=implemented hash=8981bc0b5c48]
        public func promiseResolve(_ value: Value) throws -> PromiseObj {
            if case .object(let p as PromiseObj) = value {
                return p
            }
            let promise = try newPromise()
            resolveWith(promise, resolution: value)
            return promise
        }

        // parity: psychoscript/src/async.ts#VmScheduler.reject [status=implemented hash=f11cf55ef507]
        public func reject(_ promise: PromiseObj, reason: Error) {
            settle(promise, completion: .error(reason))
        }

        // parity: psychoscript/src/async.ts#VmScheduler.resolveWith [status=implemented hash=2ce10452c5aa]
        public func resolveWith(_ promise: PromiseObj, resolution: Value, site: AstNode? = nil) {
            if case .object(let obj) = resolution, obj === promise {
                let cycle = CodemodeLanguage.typeError("Chaining cycle detected: a promise cannot resolve with itself.", node: site)
                settle(promise, completion: .error(cycle))
                return
            }
            if case .object(let thenable) = resolution {
                let access: Access
                do {
                    access = try CodemodeLanguage.access(thenable, .string("then"), receiver: resolution)
                } catch {
                    settle(promise, completion: .error(error))
                    return
                }
                if case .getter(let call) = access {
                    // A program `then` getter is program code, so it runs in a job of its own.
                    enqueue(Job(description: "thenable-get") { [weak self] in
                        guard let self else { return }
                        await self.resolveThenableGet(promise, thenable: resolution, getter: call.getter)
                    })
                    return
                }
                let thenProp: Value = if case .value(let v) = access { v } else { .undefined }
                if CodemodeLanguage.typeofValue(thenProp) == "function" {
                    enqueue(Job(description: "thenable") { [weak self] in
                        if let resolvedPromise = thenable as? PromiseObj {
                            let outcome = await resolvedPromise.awaitOutcome()
                            switch outcome {
                            case .fulfilled(let v): self?.settle(promise, completion: .ok(v))
                            case .rejected(let r): self?.settle(promise, completion: .error(Throw(r)))
                            }
                        } else {
                            self?.settle(promise, completion: .ok(resolution))
                        }
                    })
                    return
                }
            }
            settle(promise, completion: .ok(resolution))
        }

        // parity: psychoscript/src/async.ts#VmScheduler.settle [status=implemented hash=31b0099359b4]
        public func settle(_ promise: PromiseObj, completion: Completion) {
            guard case .pending = promise.status else { return }
            let oid = ObjectIdentifier(promise)
            let reactions = state.withLock { s -> [Reaction] in
                if s.pending > 0 { s.pending -= 1 }
                return s.reactions.removeValue(forKey: oid) ?? []
            }
            switch completion {
            case .ok(let value):
                promise.fulfill(value)
                for reaction in reactions {
                    enqueue(Job(description: "reaction.fulfilled") {
                        reaction.target.fulfill(value)
                    })
                }
            case .error(let error):
                let reasonVal: Value
                if let thrown = error as? Throw {
                    reasonVal = thrown.value
                } else if let b = builtins {
                    reasonVal = CodemodeLanguage.materialize(b, error)
                } else {
                    reasonVal = .string(JSString(CodemodeLanguage.errorMessage(error)))
                }
                promise.reject(reasonVal)
                if !promise.isObserved && !(error is Interruption) {
                    let failure = CodemodeLanguage.normalizeError(error)
                    let diag = Diagnostic(
                        kind: failure.kind,
                        message: "Unhandled rejection from an un-awaited promise: \(failure.message)",
                        location: failure.location,
                        suggestions: failure.suggestions
                    )
                    state.withLock { s in
                        let seq = s.nextID
                        s.nextID += 1
                        s.unhandled.append((id: seq, promise: oid, diagnostic: diag))
                    }
                }
                for reaction in reactions {
                    enqueue(Job(description: "reaction.rejected") {
                        reaction.target.reject(reasonVal)
                    })
                }
            }
        }

        // parity: psychoscript/src/async.ts#VmScheduler.enqueue [status=implemented hash=40eb2aa80944]
        public func enqueue(_ job: Job) {
            state.withLock { $0.queue.append(job) }
        }

        // parity: psychoscript/src/async.ts#VmScheduler.dequeue [status=implemented hash=829999d933f8]
        public func dequeue() -> Job? {
            state.withLock { s in
                if s.head >= s.queue.count {
                    if s.head > 0 {
                        s.queue.removeAll(keepingCapacity: false)
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

        // parity: psychoscript/src/async.ts#VmScheduler.compact [status=implemented hash=68aeeda86cf7]
        public func compact() {
            state.withLock { s in
                if s.head > 0 {
                    s.queue.removeFirst(min(s.head, s.queue.count))
                    s.head = 0
                }
            }
        }

        // parity: psychoscript/src/async.ts#VmScheduler.park [status=implemented hash=ab893d49e1fb]
        public func park(frames: [Frame], promise: PromiseObj, node: AstNode?, result: Value) {
            guard let root = frames.first else { return }
            state.withLock { s in
                s.parked.append((frame: root, entry: ParkedEntry(promise: promise, node: node, result: result)))
            }
            promise.isObserved = true
        }

        // parity: psychoscript/src/async.ts#VmScheduler.stuckAwait [status=implemented hash=fd33789c96d4]
        public func stuckAwait() -> AstNode? {
            state.withLock { s in
                var results = Set<ObjectIdentifier>()
                for item in s.parked {
                    if case .object(let p as PromiseObj) = item.entry.result {
                        results.insert(ObjectIdentifier(p))
                    }
                }
                let located = s.parked.compactMap { item -> (ObjectIdentifier, AstNode)? in
                    guard let node = item.entry.node else { return nil }
                    return (ObjectIdentifier(item.entry.promise), node)
                }
                if let root = located.first(where: { !results.contains($0.0) }) {
                    return root.1
                }
                return located.first?.1
            }
        }

        // parity: psychoscript/src/async.ts#VmScheduler.diagnostics [status=implemented hash=1d147ff0c1aa]
        public func diagnostics() -> [Diagnostic] {
            state.withLock { s in
                s.unhandled.sorted { $0.id < $1.id }.map(\.diagnostic)
            }
        }

        /// Runs one job: a reaction, a thenable's adoption, or a thenable's program `then` getter (`thenable-get`),
        /// each of which carries its own work.
        // parity: psychoscript/src/async.ts#VmScheduler.beginJob [status=implemented hash=85d509240aad]
        public func beginJob(_ job: Job) async {
            await job.run()
        }

        /// Calls a settling callable (a Promise executor or `Promise.try` function): a resolver function settles at
        /// once; anything else (an async or generator function, or a class constructor, which throws when called) is
        /// called as a frame that settles `target`.
        // parity: psychoscript/src/async.ts#VmScheduler.enterSettlingCall [status=implemented hash=93ff3c26cb89]
        @discardableResult
        public func enterSettlingCall(
            callable: Value,
            args: [Value],
            mode: FrameMode,
            target: SettlingTarget
        ) -> Int {
            if case .object(let fn as Fn) = callable, case .classConstructor = fn.payload.kind {
                return 1
            }
            if case .object(let resolver as Resolver) = callable {
                let res = resolver.invoke(thisValue: .undefined, args: args)
                if mode == .normal {
                    settleTarget(target, with: res)
                }
                return 0
            }
            return 1
        }

        // parity: psychoscript/src/async.ts#VmScheduler.handlePromisePush [status=implemented hash=2c2355e747b4]
        public func handlePromisePush(
            kindName: String,
            callable: Value,
            args: [Value],
            target: SettlingTarget
        ) -> Int? {
            guard kindName == "Promise executor" || kindName == "Promise.try" else { return nil }
            let mode: FrameMode = kindName == "Promise.try" ? .normal : .asyncFn
            return enterSettlingCall(callable: callable, args: args, mode: mode, target: target)
        }

        private func settleTarget(_ target: SettlingTarget, with value: Value) {
            switch target {
            case .promise(let p): p.fulfill(value)
            case .resolving(let r): r.resolve(value)
            case .finallyTarget(let f): f.resolve(value)
            case .asyncClose(let c): c.resolve(value)
            }
        }

        public func drain() async {
            while let job = dequeue() {
                await beginJob(job)
            }
        }
    }

    // parity: psychoscript/src/async.ts#registerAsyncIntrinsics [status=implemented hash=5b8678a06993]
    public static func registerAsyncIntrinsics(_ registry: inout [String: VmIntrinsic]) {
        registry["isPromise"] = VmIntrinsic(name: "isPromise") { args in
            if case .object(let obj) = args.first { return .bool(obj is PromiseObj) }
            return .bool(false)
        }
        // Only whether there is an iterator method: the for...of that combines reads it (a getter too) in program
        // code, so a program accessor counts without running.
        registry["$IsIterable"] = VmIntrinsic(name: "$IsIterable") { args in
            guard case .object(let obj) = args.first else { return .bool(false) }
            if obj is Arr || obj is SetObj || obj is MapObj || obj is Bytes || obj is IteratorObj || obj is GeneratorObj {
                return .bool(true)
            }
            guard let slot = lookup(obj, .symbol(IteratorSymbol)) else { return .bool(false) }
            if isProgramAccessor(slot) { return .bool(true) }
            return .bool(!peek(obj, .symbol(IteratorSymbol)).isNullish)
        }
    }

    // parity: psychoscript/src/runtime/promises.ts#JobCall [status=implemented hash=bb03ff51d726]
    public struct JobCall: Sendable {
        public let callable: Callable
        public let args: [Value]

        public init(callable: Callable, args: [Value]) {
            self.callable = callable
            self.args = args
        }
    }

    // parity: psychoscript/src/runtime/promises.ts#capability [status=implemented hash=c4d2d5ed2b57]
    public static func capability(_ builtins: Builtins) -> (promise: PromiseObj, resolve: Resolver, reject: Resolver) {
        let p = PromiseObj(proto: builtins.Promise)
        let flag = ResolvingFlag()
        let res = Resolver(proto: builtins.Function, promise: p, isReject: false, flag: flag)
        let rej = Resolver(proto: builtins.Function, promise: p, isReject: true, flag: flag)
        return (p, res, rej)
    }

    /// Settles `target` with a handler's result: a value is resolved (a thenable adopted), a throw rejects.
    static func settleFromCall(_ target: PromiseObj, eval: Evaluator, _ call: () async throws -> Value) async {
        do {
            let result = try await call()
            eval.resolvePromise(target, with: result)
        } catch let intr as Interruption {
            _ = intr
        } catch {
            target.reject(materialize(eval.builtins, error))
        }
    }

    // parity: psychoscript/src/runtime/promises.ts#react [status=adapted hash=27fc80564313]
    /// `promise.then(onFulfilled, onRejected)`: a PromiseReactionJob calls the handler, whose result or failure
    /// settles the derived promise; a missing handler passes the outcome through.
    public static func react(
        _ promise: PromiseObj,
        onFulfilled: Value,
        onRejected: Value,
        builtins: Builtins,
        eval: Evaluator
    ) -> PromiseObj {
        let derived = PromiseObj(proto: builtins.Promise)
        let fulfilled: Callable? = if case .object(let cb as Callable) = onFulfilled { cb } else { nil }
        let rejected: Callable? = if case .object(let cb as Callable) = onRejected { cb } else { nil }
        promise.addReaction { outcome in
            switch outcome {
            case .fulfilled(let value):
                guard let fulfilled else { derived.fulfill(value); return }
                await settleFromCall(derived, eval: eval) {
                    try await eval.callCallable(.object(fulfilled), thisValue: .undefined, args: [value], site: nil)
                }
            case .rejected(let reason):
                guard let rejected else { derived.reject(reason); return }
                await settleFromCall(derived, eval: eval) {
                    try await eval.callCallable(.object(rejected), thisValue: .undefined, args: [reason], site: nil)
                }
            }
        }
        return derived
    }

    // parity: psychoscript/src/runtime/promises.ts#adoptThenable [status=adapted hash=5c6dc5131e28]
    /// `Promise.resolve(value)`: a promise as is, anything else a new promise resolved with it.
    public static func adoptThenable(_ value: Value, builtins: Builtins, eval: Evaluator) -> PromiseObj {
        _ = builtins
        return eval.promiseResolve(value)
    }

    // parity: psychoscript/src/runtime/promises.ts#finishCombination [status=adapted hash=b007713d1f94]
    /// Promise.all / allSettled / race / any: each element is resolved to a promise observed through a reaction, so
    /// the result settles in the job where the deciding element's reaction runs, or at once for an empty input.
    public static func finishCombination(
        _ kind: Combination,
        items: [Value],
        builtins: Builtins,
        eval: Evaluator
    ) -> PromiseObj {
        final class Box: @unchecked Sendable {
            var values: [Value]
            var remaining: Int
            var done = false
            init(count: Int) {
                values = Array(repeating: .undefined, count: count)
                remaining = count + 1
            }
        }
        let made = PromiseObj(proto: builtins.Promise)
        let box = Box(count: items.count)
        let finish: @Sendable () -> Void = {
            box.remaining -= 1
            guard box.remaining == 0, !box.done else { return }
            box.done = true
            if kind == .any {
                made.reject(.object(createAggregateErrorValue(builtins, errors: box.values, message: "All promises were rejected")))
            } else {
                eval.resolvePromise(made, with: .object(Arr(proto: builtins.Array, items: box.values)))
            }
        }
        for (index, item) in items.enumerated() {
            let member = eval.promiseResolve(item)
            member.addReaction { outcome in
                guard !box.done else { return }
                switch (kind, outcome) {
                case (.race, .fulfilled(let v)):
                    box.done = true
                    eval.resolvePromise(made, with: v)
                case (.race, .rejected(let r)), (.all, .rejected(let r)):
                    box.done = true
                    made.reject(r)
                case (.all, .fulfilled(let v)):
                    box.values[index] = v
                    finish()
                case (.any, .fulfilled(let v)):
                    box.done = true
                    eval.resolvePromise(made, with: v)
                case (.any, .rejected(let r)):
                    box.values[index] = r
                    finish()
                case (.allSettled, .fulfilled(let v)):
                    box.values[index] = .object(record(builtins, [("status", .string("fulfilled")), ("value", v)]))
                    finish()
                case (.allSettled, .rejected(let r)):
                    box.values[index] = .object(record(builtins, [("status", .string("rejected")), ("reason", r)]))
                    finish()
                }
            }
        }
        if kind == .race {
            box.remaining = Int.max
        } else {
            finish()
        }
        return made
    }

    // parity: psychoscript/src/runtime/promises.ts#promiseLike [status=implemented hash=75ac1d5b30fc]
    public static func promiseLike(_ builtins: Builtins, value: Value) -> Value {
        guard case .object(let obj) = value else { return value }
        if !hasOwn(obj, "then") {
            // The hidden then/catch/finally settle with a plain copy, so awaiting the result does not recurse.
            let copy = Obj(proto: builtins.Object)
            for key in ownKeys(obj) {
                if let slot = own(obj, .string(key)) { copy.setSlot(.string(key), slot) }
            }
            if obj.hasProgramAccessors { copy.hasProgramAccessors = true }
            let captured: Value = .object(copy)
            define(obj, "then", .object(nativeFn(builtins, name: "then", length: 2) { _, args, _, eval in
                let p = eval.promiseResolve(captured)
                return .object(react(p, onFulfilled: args.first ?? .undefined, onRejected: args.count > 1 ? args[1] : .undefined, builtins: builtins, eval: eval))
            }), hidden)
            define(obj, "catch", .object(nativeFn(builtins, name: "catch", length: 1) { _, args, _, eval in
                let p = eval.promiseResolve(captured)
                return .object(react(p, onFulfilled: .undefined, onRejected: args.first ?? .undefined, builtins: builtins, eval: eval))
            }), hidden)
            define(obj, "finally", .object(nativeFn(builtins, name: "finally", length: 1) { _, args, _, eval in
                .object(chainFinally(eval.promiseResolve(captured), cleanup: args.first ?? .undefined, builtins: builtins, eval: eval))
            }), hidden)
        }
        return value
    }

    /// Promise.prototype.finally: the cleanup runs as a reaction; once its own result settles (one more job, the
    /// spec's `then(valueThunk)`), the original outcome passes through, and a failing cleanup wins.
    static func chainFinally(_ source: PromiseObj, cleanup: Value, builtins: Builtins, eval: Evaluator) -> PromiseObj {
        let made = PromiseObj(proto: builtins.Promise)
        guard case .object(let cb as Callable) = cleanup else {
            source.addReaction { outcome in made.settle(outcome) }
            return made
        }
        source.addReaction { outcome in
            let result: Value
            do {
                result = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [], site: nil)
            } catch is Interruption {
                return
            } catch {
                made.reject(materialize(builtins, error))
                return
            }
            let after = eval.promiseResolve(result)
            let cleaned = PromiseObj(proto: builtins.Promise)
            after.addReaction { cleanupOutcome in
                switch cleanupOutcome {
                case .fulfilled: cleaned.fulfill(.undefined)
                case .rejected(let r): cleaned.reject(r)
                }
            }
            cleaned.addReaction { cleanedOutcome in
                switch cleanedOutcome {
                case .fulfilled:
                    switch outcome {
                    case .fulfilled(let v): eval.resolvePromise(made, with: v)
                    case .rejected(let r): made.reject(r)
                    }
                case .rejected(let r):
                    made.reject(r)
                }
            }
        }
        return made
    }

    // parity: psychoscript/src/runtime/promises.ts#promiseGlobal [status=adapted hash=77e17a1c5fc2]
    public static func promiseGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Promise, [
            Method("then", 2) { thisVal, args, _, eval in
                let p = try receiver(PromiseObj.self, thisVal, "Promise.prototype.then")
                let onFul = args.first ?? .undefined
                let onRej = args.count > 1 ? args[1] : .undefined
                return .object(react(p, onFulfilled: onFul, onRejected: onRej, builtins: builtins, eval: eval))
            },
            Method("catch", 1) { thisVal, args, _, eval in
                let p = try receiver(PromiseObj.self, thisVal, "Promise.prototype.catch")
                let onRej = args.first ?? .undefined
                return .object(react(p, onFulfilled: .undefined, onRejected: onRej, builtins: builtins, eval: eval))
            },
            Method("finally", 1) { thisVal, args, _, eval in
                let p = try receiver(PromiseObj.self, thisVal, "Promise.prototype.finally")
                return .object(chainFinally(p, cleanup: args.first ?? .undefined, builtins: builtins, eval: eval))
            },
        ])

        let ctor = constructor(builtins, builtins.Promise, NativeOptions(
            name: "Promise",
            length: 1,
            call: requiresNew("Promise"),
            construct: { args, _, eval in
                guard case .object(let executor as Fn) = args.first ?? .undefined else {
                    throw typeError("new Promise(...) expects an executor function (e.g. new Promise((resolve, reject) => { ... })).")
                }
                let cap = capability(builtins)
                do {
                    _ = try await eval.callCallable(.object(executor), thisValue: .undefined, args: [.object(cap.resolve), .object(cap.reject)], site: nil)
                } catch let intr as Interruption {
                    throw intr
                } catch {
                    if cap.resolve.flag.claim() { cap.promise.reject(materialize(builtins, error)) }
                }
                return .object(cap.promise)
            }
        ))

        methods(builtins, ctor, [
            Method("resolve", 1) { _, args, _, eval in
                .object(eval.promiseResolve(args.first ?? .undefined))
            },
            Method("reject", 1) { _, args, _, _ in
                .object(PromiseObj(proto: builtins.Promise, status: .rejected(args.first ?? .undefined)))
            },
            Method("all", 1) { _, args, _, eval in
                let items = try await eval.collectIterable(args.first ?? .undefined)
                return .object(finishCombination(.all, items: items, builtins: builtins, eval: eval))
            },
            Method("allSettled", 1) { _, args, _, eval in
                let items = try await eval.collectIterable(args.first ?? .undefined)
                return .object(finishCombination(.allSettled, items: items, builtins: builtins, eval: eval))
            },
            Method("race", 1) { _, args, _, eval in
                let items = try await eval.collectIterable(args.first ?? .undefined)
                return .object(finishCombination(.race, items: items, builtins: builtins, eval: eval))
            },
            Method("any", 1) { _, args, _, eval in
                let items = try await eval.collectIterable(args.first ?? .undefined)
                return .object(finishCombination(.any, items: items, builtins: builtins, eval: eval))
            },
            Method("withResolvers", 0) { _, _, _, _ in
                let cap = capability(builtins)
                return .object(record(builtins, [
                    ("promise", .object(cap.promise)),
                    ("resolve", .object(cap.resolve)),
                    ("reject", .object(cap.reject)),
                ]))
            },
            Method("try", 1) { _, args, _, eval in
                guard isCallableValue(args.first ?? .undefined) else {
                    throw typeError("Promise.try expects a function, received \(describeValue(args.first ?? .undefined)).")
                }
                let rest = args.count > 1 ? Array(args.dropFirst()) : []
                let made = PromiseObj(proto: builtins.Promise)
                await settleFromCall(made, eval: eval) {
                    try await eval.callCallable(args[0], thisValue: .undefined, args: rest, site: nil)
                }
                return .object(made)
            },
        ])
        return ctor
    }

    // MARK: - Generators (src/language/generators.ts, src/language/runtime/generators.ts)

    // parity: psychoscript/src/generators.ts#AsyncFromSyncIterator [status=implemented hash=c88bd1ccb96e]
    public final class AsyncFromSyncIterator: Opaque, @unchecked Sendable {
        public let syncIterator: Obj

        public init(proto: Obj?, syncIterator: Obj) {
            self.syncIterator = syncIterator
            super.init(proto: proto)
        }

        public override var tag: String { "AsyncFromSyncIterator" }

        // parity: psychoscript/src/generators.ts#AsyncFromSyncIterator.describe [status=implemented hash=fdef95409458]
        public override var describe: String { "an iterator" }
    }

    // parity: psychoscript/src/generators.ts#generatorStep [status=implemented hash=dcfadd582acf]
    public static func generatorStep(_ gen: GeneratorObj, request: GeneratorRequest, builtins: Builtins) throws -> Obj {
        switch request.kind {
        case .next:
            let s = gen.stepNext()
            return iteratorResult(builtins, value: s.value, done: s.done)
        case .return:
            let s = gen.stepReturn(request.value)
            return iteratorResult(builtins, value: s.value, done: s.done)
        case .throw:
            _ = gen.stepReturn(.undefined)
            throw Throw(request.value)
        }
    }

    // parity: psychoscript/src/generators.ts#generatorRequest [status=implemented hash=da6c19370f59]
    public static func generatorRequest(_ kind: GeneratorRequestKind, _ value: Value = .undefined) -> GeneratorRequest {
        GeneratorRequest(kind: kind, value: value)
    }

    // parity: psychoscript/src/generators.ts#finishAwaitReturn [status=implemented hash=ccf04ef48938]
    public static func finishAwaitReturn(_ value: Value, builtins: Builtins) -> PromiseObj {
        PromiseObj(proto: builtins.Promise, status: .fulfilled(value))
    }

    // parity: psychoscript/src/generators.ts#execGeneratorStart [status=implemented hash=6c0d6cbf12d4]
    public static func execGeneratorStart(_ builtins: Builtins, values: [Value], returnValue: Value = .undefined, isAsync: Bool = false) -> GeneratorObj {
        GeneratorObj(proto: isAsync ? builtins.AsyncGenerator : builtins.Generator, values: values, returnValue: returnValue, isAsync: isAsync)
    }

    // parity: psychoscript/src/generators.ts#execYield [status=implemented hash=546f971ac4f5]
    public static func execYield(_ value: Value, into buffer: inout [Value]) {
        buffer.append(value)
    }

    // parity: psychoscript/src/generators.ts#execResume [status=implemented hash=90e526cc1132]
    public static func execResume(_ gen: GeneratorObj, _ request: GeneratorRequest, builtins: Builtins) throws -> Obj {
        try generatorStep(gen, request: request, builtins: builtins)
    }

    /// `await` in a job: only a host call waiting on its arguments awaits under synchronous code (a getter an iterator
    /// op runs, a constructor, a synchronous generator's body), and then the whole job waits, as here the awaiting task
    /// suspends its whole call chain.
    // parity: psychoscript/src/generators.ts#execAwait [status=implemented hash=d5bdbf047158]
    public static func execAwait(_ value: Value) async throws -> Value {
        if case .object(let p as PromiseObj) = value {
            switch await p.awaitOutcome() {
            case .fulfilled(let v): return v
            case .rejected(let r): throw Throw(r)
            }
        }
        return value
    }

    /// `yield*`: the iterator protocol's reads (`next`, `done`, `value`) may meet program getters, which run as
    /// program code (`Evaluator.collectIterable` reads through `redoRead`).
    // parity: psychoscript/src/generators.ts#execYstar [status=implemented hash=2347e2a4041f]
    public static func execYstar(_ iterable: Value, eval: Evaluator, into buffer: inout [Value]) async throws {
        let items = try await eval.collectIterable(iterable)
        buffer.append(contentsOf: items)
    }

    /// A delegate's step result: `done` then `value`, each read through a program getter when there is one.
    // parity: psychoscript/src/generators.ts#execYstarResult [status=implemented hash=3b6b177c7993]
    public static func execYstarResult(_ result: Value, eval: Evaluator) async throws -> (done: Bool, value: Value) {
        let obj = try requireIteratorObject(result)
        let done = try await eval.redoRead(obj, .string("done"), receiver: result)
        let value = try await eval.redoRead(obj, .string("value"), receiver: result)
        return (done.isTruthy, value)
    }

    // parity: psychoscript/src/generators.ts#resumeVmGenerator [status=implemented hash=85a51ee5d16a]
    public static func resumeVmGenerator(_ gen: GeneratorObj, _ request: GeneratorRequest, builtins: Builtins) throws -> Obj {
        try generatorStep(gen, request: request, builtins: builtins)
    }

    // parity: psychoscript/src/generators.ts#completeGeneratorReturn [status=implemented hash=c6798fa85873]
    public static func completeGeneratorReturn(_ gen: GeneratorObj, _ value: Value, builtins: Builtins) -> Obj {
        let s = gen.stepReturn(value)
        return iteratorResult(builtins, value: s.value, done: s.done)
    }

    // parity: psychoscript/src/generators.ts#unwindGenerator [status=implemented hash=f2cc9ec28f5b]
    public static func unwindGenerator(_ gen: GeneratorObj) {
        _ = gen.stepReturn(.undefined)
    }

    // parity: psychoscript/src/generators.ts#handleAdapterPush [status=implemented hash=15ed78b22ef7]
    public static func handleAdapterPush(_ push: Push) -> Value {
        push.slots.first ?? .undefined
    }

    // parity: psychoscript/src/generators.ts#registerGeneratorIntrinsics [status=implemented hash=0126aa74c5a5]
    public static func registerGeneratorIntrinsics(_ registry: inout [String: VmIntrinsic]) {
        registry["isGenerator"] = VmIntrinsic(name: "isGenerator") { args in
            if case .object(let obj) = args.first { return .bool(obj is GeneratorObj) }
            return .bool(false)
        }
        // An async-from-sync iterator: the sync iterator method's result must be an object.
        registry["$AfsRequireObj"] = VmIntrinsic(name: "$AfsRequireObj") { args in
            .object(try requireIteratorObject(args.first ?? .undefined))
        }
        // An iterator method the prelude read (a getter too): undefined when absent, else it must be a function.
        registry["$AfsMethod"] = VmIntrinsic(name: "$AfsMethod") { args in
            let method = args.count > 1 ? args[1] : .undefined
            if method.isNullish { return .undefined }
            guard case .object(let fn) = method, fn is Callable else {
                let kind = args.count > 2 ? coerceToString(args[2]) : "method"
                throw typeError("Iterator \(kind) is not a function.")
            }
            return method
        }
    }

    // parity: psychoscript/src/runtime/generators.ts#generatorGlobals [status=implemented hash=d08aa9052536]
    public static func generatorGlobals(_ builtins: Builtins) {
        // A program generator steps its body lazily (`GeneratorObj.syncStep` / `asyncEnqueue`); a generator made from
        // values ahead of time replays them.
        @Sendable func step(_ kind: GeneratorRequestKind, _ thisVal: Value, _ args: [Value], _ eval: Evaluator, _ name: String) async throws -> Value {
            let gen = try receiver(GeneratorObj.self, thisVal, "Generator.prototype.\(name)")
            let value = args.first ?? .undefined
            if gen.isLazy || gen.state == .executing {
                if gen.isAsync {
                    return .object(await gen.asyncEnqueue(kind, value, builtins: builtins, eval: eval))
                }
                let result = try await gen.syncStep(kind, value, scheduler: eval.scheduler)
                return .object(iteratorResult(builtins, value: result.value, done: result.done))
            }
            switch kind {
            case .next:
                let res = try generatorStep(gen, request: generatorRequest(.next, value), builtins: builtins)
                return gen.isAsync ? .object(PromiseObj(proto: builtins.Promise, status: .fulfilled(.object(res)))) : .object(res)
            case .return:
                let res = completeGeneratorReturn(gen, value, builtins: builtins)
                return gen.isAsync ? .object(PromiseObj(proto: builtins.Promise, status: .fulfilled(.object(res)))) : .object(res)
            case .throw:
                if gen.isAsync {
                    unwindGenerator(gen)
                    return .object(PromiseObj(proto: builtins.Promise, status: .rejected(value)))
                }
                return .object(try generatorStep(gen, request: generatorRequest(.throw, value), builtins: builtins))
            }
        }
        let nextMethod = Method("next", 1) { thisVal, args, _, eval in try await step(.next, thisVal, args, eval, "next") }
        let returnMethod = Method("return", 1) { thisVal, args, _, eval in try await step(.return, thisVal, args, eval, "return") }
        let throwMethod = Method("throw", 1) { thisVal, args, _, eval in try await step(.throw, thisVal, args, eval, "throw") }
        methods(builtins, builtins.Generator, [nextMethod, returnMethod, throwMethod])
        // Iterator helpers (`map`, `take`, ...) are lazy generators over their source.
        methods(builtins, builtins.IteratorHelper, [nextMethod, returnMethod])
        methods(builtins, builtins.AsyncGenerator, [nextMethod, returnMethod, throwMethod])
        define(builtins.Generator, .symbol(IteratorSymbol), .object(nativeFn(builtins, name: "[Symbol.iterator]") { thisVal, _, _, _ in thisVal }), hidden)
        define(builtins.AsyncGenerator, .symbol(AsyncIteratorSymbol), .object(nativeFn(builtins, name: "[Symbol.asyncIterator]") { thisVal, _, _, _ in thisVal }), hidden)
    }
    // MARK: - Standard Library Part 1 (Object, Array, String, Number, Boolean, Math, JSON, Console, Value)

    // parity: psychoscript/src/stdlib/object.ts#enumerableSource [status=implemented hash=8a1c8ebfa939]
    public static func enumerableSource(_ value: Value) -> [(JSString, Value)] {
        if case .string(let s) = value {
            return s.codePointStrings().enumerated().map { (JSString(String($0.offset)), .string($0.element)) }
        }
        guard case .object(let obj) = value else { return [] }
        return entries(obj)
    }

    // parity: psychoscript/src/stdlib/object.ts#objectAssign [status=implemented hash=f69d9cc51fb8]
    public static func objectAssign(_ eval: Evaluator, _ target: Value, sources: [Value]) async throws -> Value {
        guard case .object(let targetObj) = target else {
            throw typeError("Cannot convert undefined or null to object.")
        }
        let froms = sources.compactMap { source -> Obj? in
            if case .object(let obj) = source { return obj }
            return nil
        }
        // Program getters on a source or setters on the target's chain run in program code, Get then Set per key.
        if froms.contains(where: \.hasProgramAccessors) || accessorsOnChain(targetObj) {
            for from in froms {
                for key in enumerableCopyKeys(from) where own(from, key)?.enumerable == true {
                    let value = try await eval.getValue(from, key)
                    try await eval.writeMember(target, key, value)
                }
            }
            return target
        }
        for src in sources {
            if src.isNullish { continue }
            for (k, v) in enumerableSource(src) {
                try rejectCircularInsertion(targetObj, v, label: "Object.assign result")
                try set(targetObj, k, v)
            }
        }
        return target
    }

    /// Whether a program accessor was defined anywhere on `target`'s chain.
    static func accessorsOnChain(_ target: Obj) -> Bool {
        var current: Obj? = target
        var depth = 0
        while let cur = current, depth < 64 {
            if cur.hasProgramAccessors { return true }
            current = cur.proto
            depth += 1
        }
        return false
    }

    /// Object.entries / Object.values over an object with program getters: each key's enumerability is checked as it
    /// is visited, so a getter that deletes or hides a later key is seen.
    static func objectEntries(_ eval: Evaluator, _ source: Obj, values: Bool) async throws -> Value {
        var result: [Value] = []
        for key in keys(source) where own(source, .string(key))?.enumerable == true {
            let value = try await eval.getValue(source, .string(key))
            result.append(values ? value : .object(Arr(proto: eval.builtins.Array, items: [.string(key), value])))
            try checkArrayLength(result.count)
        }
        return .object(Arr(proto: eval.builtins.Array, items: result))
    }

    /// ToPropertyDescriptor, under `withReads`: each field through the chain, in the spec's order.
    static func toPropertyDescriptor(_ value: Value) throws -> Descriptor {
        guard case .object(let obj) = value else {
            throw typeError("Property description must be an object: \(describeValue(value))")
        }
        var desc = Descriptor()
        if has(obj, "enumerable") { desc.enumerable = get(obj, "enumerable").isTruthy }
        if has(obj, "configurable") { desc.configurable = get(obj, "configurable").isTruthy }
        if has(obj, "value") { desc.value = get(obj, "value") }
        if has(obj, "writable") { desc.writable = get(obj, "writable").isTruthy }
        for half in ["get", "set"] where has(obj, JSString(half)) {
            let fn = get(obj, JSString(half))
            let callable: Callable?
            switch fn {
            case .undefined: callable = nil
            case .object(let c as Callable): callable = c
            default:
                throw typeError("\(half == "get" ? "Getter" : "Setter") must be a function: \(describeValue(fn))")
            }
            if half == "get" { desc.get = .some(callable) } else { desc.set = .some(callable) }
        }
        if desc.isAccessorDescriptor && desc.isDataDescriptor {
            throw typeError("Invalid property descriptor. Cannot both specify accessors and a value or writable attribute.")
        }
        return desc
    }

    /// DefinePropertyOrThrow.
    static func defineOrThrow(_ target: Obj, _ key: PropertyKey, _ desc: Descriptor) throws {
        if let value = desc.value, case .object = value {
            try rejectCircularInsertion(target, value, label: target is Arr ? "Array assignment result" : "Object assignment result")
        }
        if try defineOwnProperty(target, key, desc) { return }
        if !target.extensible && own(target, key) == nil {
            throw typeError("Cannot define property \(keyLabel(key)), object is not extensible")
        }
        throw typeError("Cannot redefine property: \(keyLabel(key))")
    }

    static func requireTarget(_ value: Value, _ name: String) throws -> Obj {
        if case .object(let obj) = value { return obj }
        throw typeError("Object.\(name) called on non-object")
    }

    /// ObjectDefineProperties: every descriptor is read (getters included) before the first one is defined.
    static func defineProperties(_ target: Obj, _ props: Value) throws -> Obj {
        if props.isNullish { throw typeError("Cannot convert \(coerceToString(props)) to object") }
        var descriptors: [(PropertyKey, Descriptor)] = []
        switch props {
        case .object(let obj):
            for key in ownKeys(obj) where own(obj, .string(key))?.enumerable == true {
                descriptors.append((.string(key), try toPropertyDescriptor(get(obj, key))))
            }
        case .string(let str):
            // ToObject: a string's indexes are its only own enumerable properties.
            for (index, chunk) in str.codePointStrings().enumerated() {
                descriptors.append((.string(JSString(String(index))), try toPropertyDescriptor(.string(chunk))))
            }
        default:
            break
        }
        if readsPending() { return target }
        for (key, desc) in descriptors { try defineOrThrow(target, key, desc) }
        return target
    }

    /// FromPropertyDescriptor: a native accessor half shows as its companion function.
    static func fromSlot(_ builtins: Builtins, _ slot: Slot?) -> Value {
        guard let slot else { return .undefined }
        switch slot {
        case .data(let value, let writable, let enumerable, let configurable):
            return .object(record(builtins, [
                ("value", value), ("writable", .bool(writable)),
                ("enumerable", .bool(enumerable)), ("configurable", .bool(configurable)),
            ]))
        case .accessor(let g, let s, let enumerable, let configurable):
            return .object(record(builtins, [
                ("get", accessorFunction(g).map { .object($0) } ?? .undefined),
                ("set", accessorFunction(s).map { .object($0) } ?? .undefined),
                ("enumerable", .bool(enumerable)), ("configurable", .bool(configurable)),
            ]))
        }
    }

    /// The own properties a primitive has after ToObject, which only a string's are: its indexes and `length`.
    static func primitiveSlot(_ value: Value, _ key: PropertyKey) -> Slot? {
        guard case .string(let str) = value, case .string(let k) = key else { return nil }
        if k == "length" { return .data(value: .number(Double(str.utf16Count)), writable: false, enumerable: false, configurable: false) }
        guard let at = parseArrayIndex(k), let unit = str.unit(at: at) else { return nil }
        return .data(value: .string(JSString(unit: unit)), writable: false, enumerable: true, configurable: false)
    }

    static func primitiveKeys(_ value: Value) -> [JSString] {
        guard case .string(let str) = value else { return [] }
        return (0..<str.utf16Count).map { JSString(String($0)) } + ["length"]
    }

    static func requireObjectCoercible(_ value: Value, _ name: String) throws {
        if value.isNullish { throw typeError("Object.\(name) cannot convert \(coerceToString(value)) to an object.") }
        if case .hostNamespace(let ns) = value {
            let root = ns.path.first ?? "tools"
            throw typeError("Object.\(name) cannot read \(root): it is a namespace of host functions, not an object.")
        }
    }

    // parity: psychoscript/src/stdlib/object.ts#objectGlobal [status=implemented hash=0d5e77835d68]
    public static func objectGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Object, [
            Method("hasOwnProperty", 1) { thisVal, args, _, _ in
                guard case .object(let obj) = thisVal else { return .bool(false) }
                return .bool(own(obj, propertyKey(args.first ?? .undefined)) != nil)
            },
            Method("toString", 0) { thisVal, _, _, _ in
                switch thisVal {
                case .undefined: return .string("[object Undefined]")
                case .null: return .string("[object Null]")
                case .bool: return .string("[object Boolean]")
                case .number: return .string("[object Number]")
                case .string: return .string("[object String]")
                case .symbol: return .string("[object Symbol]")
                case .hostNamespace: return .string("[object Object]")
                case .object(let obj): return .string("[object \(obj.tag)]")
                }
            },
            Method("valueOf", 0) { thisVal, _, _, _ in thisVal },
            Method("toLocaleString", 0) { thisVal, _, site, eval in
                try await withReads(eval) {
                    let fn = try resolveProperty(thisVal, .string("toString"), builtins: builtins, node: site)
                    if readsPending() { return .undefined }
                    return try await eval.callCallable(fn, thisValue: thisVal, args: [], site: site)
                }
            },
        ])

        let ctor = constructor(builtins, builtins.Object, NativeOptions(
            name: "Object",
            length: 1,
            call: { _, args, _, _ in
                guard let first = args.first, !first.isNullish else {
                    return .object(Obj(proto: builtins.Object))
                }
                return first
            },
            construct: { args, _, _ in
                guard let first = args.first, !first.isNullish else {
                    return .object(Obj(proto: builtins.Object))
                }
                return first
            }
        ))

        methods(builtins, ctor, [
            Method("keys", 1) { _, args, _, _ in
                let target = args.first ?? .undefined
                if case .hostNamespace(let ns) = target {
                    let ks = (try? ns.handler.keys(ns.path)) ?? []
                    return .object(Arr(proto: builtins.Array, items: ks.map { .string(JSString($0)) }))
                }
                if case .string(let s) = target {
                    return .object(Arr(proto: builtins.Array, items: (0..<s.codePointStrings().count).map { .string(JSString(String($0))) }))
                }
                guard case .object(let obj) = target else {
                    if target.isNullish { throw typeError("Cannot convert undefined or null to object.") }
                    return .object(Arr(proto: builtins.Array))
                }
                return .object(Arr(proto: builtins.Array, items: keys(obj).map { .string($0) }))
            },
            Method("values", 1) { _, args, _, eval in
                let target = args.first ?? .undefined
                if case .string(let s) = target {
                    return .object(Arr(proto: builtins.Array, items: s.codePointStrings().map { .string($0) }))
                }
                guard case .object(let obj) = target else {
                    if target.isNullish { throw typeError("Cannot convert undefined or null to object.") }
                    return .object(Arr(proto: builtins.Array))
                }
                if obj.hasProgramAccessors { return try await objectEntries(eval, obj, values: true) }
                return .object(Arr(proto: builtins.Array, items: entries(obj).map(\.1)))
            },
            Method("entries", 1) { _, args, _, eval in
                let target = args.first ?? .undefined
                if case .string(let s) = target {
                    let list = s.codePointStrings().enumerated().map { idx, chunk in
                        Value.object(Arr(proto: builtins.Array, items: [.string(JSString(String(idx))), .string(chunk)]))
                    }
                    return .object(Arr(proto: builtins.Array, items: list))
                }
                guard case .object(let obj) = target else {
                    if target.isNullish { throw typeError("Cannot convert undefined or null to object.") }
                    return .object(Arr(proto: builtins.Array))
                }
                if obj.hasProgramAccessors { return try await objectEntries(eval, obj, values: false) }
                let list = entries(obj).map { k, v in
                    Value.object(Arr(proto: builtins.Array, items: [.string(k), v]))
                }
                return .object(Arr(proto: builtins.Array, items: list))
            },
            Method("fromEntries", 1) { _, args, _, eval in
                let items = try await eval.collectIterable(args.first ?? .undefined)
                let out = Obj(proto: builtins.Object)
                for item in items {
                    let pair = try await eval.collectIterable(item)
                    let k = coerceToString(pair.first ?? .undefined)
                    let v = pair.count > 1 ? pair[1] : .undefined
                    if k != "__proto__" { define(out, k, v) }
                }
                return .object(out)
            },
            Method("assign", 2) { _, args, _, eval in
                try await objectAssign(eval, args.first ?? .undefined, sources: Array(args.dropFirst()))
            },
            Method("create", 2) { _, args, _, eval in
                let protoVal = args.first ?? .undefined
                let proto: Obj?
                if case .null = protoVal { proto = nil }
                else if case .object(let o) = protoVal { proto = o }
                else { throw typeError("Object prototype may only be an Object or null.") }
                guard args.count > 1, !args[1].isUndefined else { return .object(Obj(proto: proto)) }
                return try await withReads(eval) { .object(try defineProperties(Obj(proto: proto), args[1])) }
            },
            Method("hasOwn", 2) { _, args, _, _ in
                let target = args.first ?? .undefined
                let key = propertyKey(args.count > 1 ? args[1] : .undefined)
                if case .string(let s) = target, case .string(let k) = key {
                    if k == "length" { return .bool(true) }
                    if let idx = parseArrayIndex(k), idx < s.codePointStrings().count { return .bool(true) }
                    return .bool(false)
                }
                guard case .object(let obj) = target else { return .bool(false) }
                return .bool(own(obj, key) != nil)
            },
            Method("is", 2) { _, args, _, _ in
                let a = args.first ?? .undefined
                let b = args.count > 1 ? args[1] : .undefined
                if case .number(let x) = a, case .number(let y) = b {
                    if x.isNaN && y.isNaN { return .bool(true) }
                    if x == 0 && y == 0 { return .bool(x.sign == y.sign) }
                    return .bool(x == y)
                }
                return .bool(strictEqual(a, b))
            },
            Method("freeze", 1) { _, args, _, _ in
                if case .object(let obj) = args.first { lockProperties(obj, freeze: true) }
                return args.first ?? .undefined
            },
            Method("isFrozen", 1) { _, args, _, _ in
                guard case .object(let obj) = args.first else { return .bool(true) }
                return .bool(isLocked(obj, frozen: true))
            },
            Method("seal", 1) { _, args, _, _ in
                if case .object(let obj) = args.first { lockProperties(obj, freeze: false) }
                return args.first ?? .undefined
            },
            Method("isSealed", 1) { _, args, _, _ in
                guard case .object(let obj) = args.first else { return .bool(true) }
                return .bool(isLocked(obj, frozen: false))
            },
            Method("getPrototypeOf", 1) { _, args, _, _ in
                guard case .object(let obj) = args.first else { return .null }
                return obj.proto.map { .object($0) } ?? .null
            },
            Method("getOwnPropertyNames", 1) { _, args, _, _ in
                let value = args.first ?? .undefined
                if case .hostNamespace(let ns) = value {
                    let ks = (try? ns.handler.keys(ns.path)) ?? []
                    return .object(Arr(proto: builtins.Array, items: ks.map { .string(JSString($0)) }))
                }
                try requireObjectCoercible(value, "getOwnPropertyNames")
                var names: [JSString] = if case .object(let obj) = value { ownKeys(obj) } else { primitiveKeys(value) }
                if case .object(let obj) = value, obj is Arr, !names.contains("length") { names.append("length") }
                if case .string = value, !names.contains("length") { names.append("length") }
                return .object(Arr(proto: builtins.Array, items: names.map { .string($0) }))
            },
            Method("defineProperty", 3) { _, args, _, eval in
                let target = try requireTarget(args.first ?? .undefined, "defineProperty")
                let key = try withPrimitives(.string, [args.count > 1 ? args[1] : .undefined]) { keys in keys[0] }
                return try await withReads(eval) {
                    let desc = try toPropertyDescriptor(args.count > 2 ? args[2] : .undefined)
                    if readsPending() { return .object(target) }
                    try defineOrThrow(target, propertyKey(key), desc)
                    return .object(target)
                }
            },
            Method("defineProperties", 2) { _, args, _, eval in
                let target = try requireTarget(args.first ?? .undefined, "defineProperties")
                return try await withReads(eval) { .object(try defineProperties(target, args.count > 1 ? args[1] : .undefined)) }
            },
            Method("getOwnPropertyDescriptor", 2) { _, args, _, _ in
                let value = args.first ?? .undefined
                try requireObjectCoercible(value, "getOwnPropertyDescriptor")
                return try withPrimitives(.string, [args.count > 1 ? args[1] : .undefined]) { raw in
                    let key = propertyKey(raw[0])
                    if case .object(let obj) = value { return fromSlot(builtins, own(obj, key)) }
                    return fromSlot(builtins, primitiveSlot(value, key))
                }
            },
            Method("getOwnPropertyDescriptors", 1) { _, args, _, _ in
                let value = args.first ?? .undefined
                try requireObjectCoercible(value, "getOwnPropertyDescriptors")
                let result = Obj(proto: builtins.Object)
                if case .object(let obj) = value {
                    for key in ownKeys(obj) { define(result, key, fromSlot(builtins, own(obj, .string(key)))) }
                } else {
                    for key in primitiveKeys(value) { define(result, key, fromSlot(builtins, primitiveSlot(value, .string(key)))) }
                }
                return .object(result)
            },
            Method("groupBy", 2) { _, args, _, eval in
                let items = try await eval.collectIterable(args.first ?? .undefined)
                let cb = try requireCallback(args.count > 1 ? args[1] : .undefined, "Object.groupBy")
                let result = Obj(proto: nil)
                for (idx, item) in items.enumerated() {
                    let keyVal = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [item, .number(Double(idx))], site: nil)
                    let key = coerceToString(keyVal)
                    if case .object(let existing as Arr) = getOwn(result, key) {
                        try existing.append(item)
                    } else {
                        define(result, key, .object(Arr(proto: builtins.Array, items: [item])))
                    }
                }
                return .object(result)
            },
        ])
        return ctor
    }

    // MARK: Array (src/language/stdlib/array.ts)

    // parity: psychoscript/src/stdlib/array.ts#SortInto [status=implemented hash=9a818eec150b]
    public typealias SortInto = ([Value]) -> Void

    // parity: psychoscript/src/stdlib/array.ts#SORT_RUN [status=implemented hash=5c0fb43880fe]
    public static let SORT_RUN: Int = 32

    // parity: psychoscript/src/stdlib/array.ts#sortArray [status=implemented hash=88a05a0acf3f]
    public static func sortArray(_ items: [Value], compare: Callable?, eval: Evaluator) async throws -> [Value] {
        var result = items
        if let compare {
            // Stable merge sort with async JS comparator
            func mergeSort(_ slice: [Value]) async throws -> [Value] {
                if slice.count <= 1 { return slice }
                let mid = slice.count / 2
                let left = try await mergeSort(Array(slice[..<mid]))
                let right = try await mergeSort(Array(slice[mid...]))
                var merged: [Value] = []
                merged.reserveCapacity(slice.count)
                var i = 0, j = 0
                while i < left.count && j < right.count {
                    let cmpVal = try await eval.callCallable(.object(compare), thisValue: .undefined, args: [left[i], right[j]], site: nil)
                    let num = coerceToNumber(cmpVal)
                    if num > 0 {
                        merged.append(right[j]); j += 1
                    } else {
                        merged.append(left[i]); i += 1
                    }
                }
                while i < left.count { merged.append(left[i]); i += 1 }
                while j < right.count { merged.append(right[j]); j += 1 }
                return merged
            }
            result = try await mergeSort(result)
        } else {
            result.sort { a, b in
                if a.isUndefined && b.isUndefined { return false }
                if a.isUndefined { return false }
                if b.isUndefined { return true }
                return compareText(coerceToString(a), coerceToString(b)) < 0
            }
        }
        return result
    }

    // parity: psychoscript/src/stdlib/array.ts#sorted [status=implemented hash=4c6834896604]
    public static func sorted(_ arr: Arr, compare: Callable?, eval: Evaluator) async throws -> [Value] {
        try await sortArray(arr.items, compare: compare, eval: eval)
    }

    private static func resolveSliceIndex(_ raw: Int, length: Int) -> Int {
        if raw < 0 { return max(length + raw, 0) }
        return min(raw, length)
    }

    // parity: psychoscript/src/stdlib/array.ts#arrayGlobal [status=implemented hash=6132942f8265]
    public static func arrayGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Array, [
            Method("push", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.push")
                for a in args { try arr.append(a) }
                return .number(Double(arr.count))
            },
            Method("pop", 0) { thisVal, _, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.pop")
                var list = arr.items
                guard !list.isEmpty else { return .undefined }
                let last = list.removeLast()
                arr.items = list
                return last
            },
            Method("shift", 0) { thisVal, _, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.shift")
                var list = arr.items
                guard !list.isEmpty else { return .undefined }
                let first = list.removeFirst()
                arr.items = list
                return first
            },
            Method("unshift", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.unshift")
                try checkArrayLength(arr.count + args.count)
                arr.items = args + arr.items
                return .number(Double(arr.count))
            },
            Method("slice", 2) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.slice")
                let list = arr.items
                let start = args.first.map { $0.isUndefined ? 0 : resolveSliceIndex(coerceToInteger($0), length: list.count) } ?? 0
                let end = args.count > 1 && !args[1].isUndefined ? resolveSliceIndex(coerceToInteger(args[1]), length: list.count) : list.count
                if start >= end { return .object(Arr(proto: builtins.Array)) }
                return .object(Arr(proto: builtins.Array, items: Array(list[start..<end])))
            },
            Method("splice", 2) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.splice")
                var list = arr.items
                let start = args.first.map { resolveSliceIndex(coerceToInteger($0), length: list.count) } ?? 0
                let delCount: Int
                if args.count < 2 {
                    delCount = list.count - start
                } else {
                    delCount = min(max(0, coerceToInteger(args[1])), list.count - start)
                }
                let insertItems = args.count > 2 ? Array(args.dropFirst(2)) : []
                let removed = Array(list[start..<(start + delCount)])
                list.replaceSubrange(start..<(start + delCount), with: insertItems)
                arr.items = list
                return .object(Arr(proto: builtins.Array, items: removed))
            },
            Method("concat", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.concat")
                var out = arr.items
                for arg in args {
                    if case .object(let other as Arr) = arg {
                        try checkArrayLength(out.count + other.count)
                        out.append(contentsOf: other.items)
                    } else {
                        try checkArrayLength(out.count + 1)
                        out.append(arg)
                    }
                }
                return .object(Arr(proto: builtins.Array, items: out))
            },
            Method("join", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.join")
                let sep: JSString = args.first.map { $0.isUndefined ? "," : coerceToString($0) } ?? ","
                let joined = arr.items.map { $0.isNullish ? JSString.empty : coerceToString($0) }.joinedJS(separator: sep)
                try checkStringLength(joined.utf16Count)
                return .string(joined)
            },
            Method("reverse", 0) { thisVal, _, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.reverse")
                arr.items = arr.items.reversed()
                return .object(arr)
            },
            Method("toReversed", 0) { thisVal, _, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.toReversed")
                return .object(Arr(proto: builtins.Array, items: arr.items.reversed()))
            },
            Method("sort", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.sort")
                let cmp: Callable? = if let first = args.first, !first.isUndefined { try requireCallback(first, "Array.prototype.sort") } else { nil }
                arr.items = try await sorted(arr, compare: cmp, eval: eval)
                return .object(arr)
            },
            Method("toSorted", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.toSorted")
                let cmp: Callable? = if let first = args.first, !first.isUndefined { try requireCallback(first, "Array.prototype.toSorted") } else { nil }
                return .object(Arr(proto: builtins.Array, items: try await sorted(arr, compare: cmp, eval: eval)))
            },
            Method("indexOf", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.indexOf")
                let needle = args.first ?? .undefined
                let list = arr.items
                let holes = arr.holes
                let from = args.count > 1 ? resolveSliceIndex(coerceToInteger(args[1]), length: list.count) : 0
                for i in from..<list.count where !holes.contains(i) && strictEqual(list[i], needle) {
                    return .number(Double(i))
                }
                return .number(-1)
            },
            Method("lastIndexOf", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.lastIndexOf")
                let needle = args.first ?? .undefined
                let list = arr.items
                if list.isEmpty { return .number(-1) }
                let from = args.count > 1 ? min(list.count - 1, coerceToInteger(args[1])) : list.count - 1
                let start = from < 0 ? list.count + from : from
                if start < 0 { return .number(-1) }
                for i in stride(from: start, through: 0, by: -1) where strictEqual(list[i], needle) {
                    return .number(Double(i))
                }
                return .number(-1)
            },
            Method("includes", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.includes")
                let needle = args.first ?? .undefined
                let list = arr.items
                let from = args.count > 1 ? resolveSliceIndex(coerceToInteger(args[1]), length: list.count) : 0
                let key = SameValueZeroKey(needle)
                for i in from..<list.count where SameValueZeroKey(list[i]) == key {
                    return .bool(true)
                }
                return .bool(false)
            },
            Method("at", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.at")
                let list = arr.items
                var idx = coerceToInteger(args.first ?? .undefined)
                if idx < 0 { idx += list.count }
                return idx >= 0 && idx < list.count ? list[idx] : .undefined
            },
            Method("with", 2) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.with")
                var list = arr.items
                var idx = coerceToInteger(args.first ?? .undefined)
                if idx < 0 { idx += list.count }
                guard idx >= 0 && idx < list.count else { throw rangeError("Invalid index : \(idx)") }
                list[idx] = args.count > 1 ? args[1] : .undefined
                return .object(Arr(proto: builtins.Array, items: list))
            },
            Method("fill", 1) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.fill")
                var list = arr.items
                let val = args.first ?? .undefined
                let start = args.count > 1 && !args[1].isUndefined ? resolveSliceIndex(coerceToInteger(args[1]), length: list.count) : 0
                let end = args.count > 2 && !args[2].isUndefined ? resolveSliceIndex(coerceToInteger(args[2]), length: list.count) : list.count
                if start < end {
                    for i in start..<end { list[i] = val }
                }
                arr.items = list
                return .object(arr)
            },
            Method("map", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.map")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.map")
                let thisArg = args.count > 1 ? args[1] : .undefined
                let list = arr.items
                let holes = arr.holes
                var out: [Value] = []
                out.reserveCapacity(list.count)
                for (idx, item) in list.enumerated() {
                    // A hole stays a hole: the callback is not called for it.
                    if holes.contains(idx) { out.append(.undefined); continue }
                    out.append(try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, .number(Double(idx)), thisVal], site: nil))
                }
                return .object(Arr(proto: builtins.Array, items: out, holes: holes.filter { $0 < out.count }))
            },
            Method("filter", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.filter")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.filter")
                let thisArg = args.count > 1 ? args[1] : .undefined
                var out: [Value] = []
                let holes = arr.holes
                for (idx, item) in arr.items.enumerated() where !holes.contains(idx) {
                    let res = try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, .number(Double(idx)), thisVal], site: nil)
                    if res.isTruthy { out.append(item) }
                }
                return .object(Arr(proto: builtins.Array, items: out))
            },
            Method("flatMap", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.flatMap")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.flatMap")
                let thisArg = args.count > 1 ? args[1] : .undefined
                var out: [Value] = []
                let holes = arr.holes
                for (idx, item) in arr.items.enumerated() where !holes.contains(idx) {
                    let res = try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, .number(Double(idx)), thisVal], site: nil)
                    if case .object(let sub as Arr) = res { out.append(contentsOf: sub.items) }
                    else { out.append(res) }
                }
                return .object(Arr(proto: builtins.Array, items: out))
            },
            Method("flat", 0) { thisVal, args, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.flat")
                let depth = args.first.map { $0.isUndefined ? 1 : max(0, coerceToInteger($0)) } ?? 1
                func flatten(_ items: [Value], _ d: Int) -> [Value] {
                    if d <= 0 { return items }
                    var out: [Value] = []
                    for item in items {
                        if case .object(let sub as Arr) = item {
                            out.append(contentsOf: flatten(sub.items, d - 1))
                        } else {
                            out.append(item)
                        }
                    }
                    return out
                }
                return .object(Arr(proto: builtins.Array, items: flatten(arr.items, depth)))
            },
            Method("forEach", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.forEach")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.forEach")
                let thisArg = args.count > 1 ? args[1] : .undefined
                let holes = arr.holes
                for (idx, item) in arr.items.enumerated() where !holes.contains(idx) {
                    _ = try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, .number(Double(idx)), thisVal], site: nil)
                }
                return .undefined
            },
            Method("reduce", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.reduce")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.reduce")
                let list = arr.items
                var acc: Value
                var startIdx: Int
                if args.count > 1 {
                    acc = args[1]
                    startIdx = 0
                } else {
                    guard !list.isEmpty else { throw typeError("Array.reduce of an empty array with no initial value.") }
                    acc = list[0]
                    startIdx = 1
                }
                for i in startIdx..<list.count {
                    acc = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [acc, list[i], .number(Double(i)), thisVal], site: nil)
                }
                return acc
            },
            Method("reduceRight", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.reduceRight")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.reduceRight")
                let list = arr.items
                var acc: Value
                var startIdx: Int
                if args.count > 1 {
                    acc = args[1]
                    startIdx = list.count - 1
                } else {
                    guard !list.isEmpty else { throw typeError("Array.reduceRight of an empty array with no initial value.") }
                    acc = list[list.count - 1]
                    startIdx = list.count - 2
                }
                if startIdx >= 0 {
                    for i in stride(from: startIdx, through: 0, by: -1) {
                        acc = try await eval.callCallable(.object(cb), thisValue: .undefined, args: [acc, list[i], .number(Double(i)), thisVal], site: nil)
                    }
                }
                return acc
            },
            Method("find", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.find")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.find")
                let thisArg = args.count > 1 ? args[1] : .undefined
                for (idx, item) in arr.items.enumerated() {
                    if try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, .number(Double(idx)), thisVal], site: nil).isTruthy {
                        return item
                    }
                }
                return .undefined
            },
            Method("findIndex", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.findIndex")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.findIndex")
                let thisArg = args.count > 1 ? args[1] : .undefined
                for (idx, item) in arr.items.enumerated() {
                    if try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, .number(Double(idx)), thisVal], site: nil).isTruthy {
                        return .number(Double(idx))
                    }
                }
                return .number(-1)
            },
            Method("findLast", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.findLast")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.findLast")
                let thisArg = args.count > 1 ? args[1] : .undefined
                let list = arr.items
                for idx in stride(from: list.count - 1, through: 0, by: -1) {
                    if try await eval.callCallable(.object(cb), thisValue: thisArg, args: [list[idx], .number(Double(idx)), thisVal], site: nil).isTruthy {
                        return list[idx]
                    }
                }
                return .undefined
            },
            Method("findLastIndex", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.findLastIndex")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.findLastIndex")
                let thisArg = args.count > 1 ? args[1] : .undefined
                let list = arr.items
                for idx in stride(from: list.count - 1, through: 0, by: -1) {
                    if try await eval.callCallable(.object(cb), thisValue: thisArg, args: [list[idx], .number(Double(idx)), thisVal], site: nil).isTruthy {
                        return .number(Double(idx))
                    }
                }
                return .number(-1)
            },
            Method("some", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.some")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.some")
                let thisArg = args.count > 1 ? args[1] : .undefined
                let holes = arr.holes
                for (idx, item) in arr.items.enumerated() where !holes.contains(idx) {
                    if try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, .number(Double(idx)), thisVal], site: nil).isTruthy {
                        return .bool(true)
                    }
                }
                return .bool(false)
            },
            Method("every", 1) { thisVal, args, _, eval in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.every")
                let cb = try requireCallback(args.first ?? .undefined, "Array.prototype.every")
                let thisArg = args.count > 1 ? args[1] : .undefined
                let holes = arr.holes
                for (idx, item) in arr.items.enumerated() where !holes.contains(idx) {
                    if !(try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, .number(Double(idx)), thisVal], site: nil).isTruthy) {
                        return .bool(false)
                    }
                }
                return .bool(true)
            },
            Method("keys", 0) { thisVal, _, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.keys")
                return .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .array(arr), kind: .keys))
            },
            Method("values", 0) { thisVal, _, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.values")
                return .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .array(arr), kind: .values))
            },
            Method("entries", 0) { thisVal, _, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.entries")
                return .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .array(arr), kind: .entries))
            },
            Method("toString", 0) { thisVal, _, _, _ in
                let arr = try receiver(Arr.self, thisVal, "Array.prototype.toString")
                return .string(arr.items.map { $0.isNullish ? JSString.empty : coerceToString($0) }.joinedJS(separator: ","))
            },
        ])
        if case .object(let valsFn as Native) = getOwn(builtins.Array, "values") {
            iteratorMethods(builtins, builtins.Array, valsFn)
        }

        let makeArray: @Sendable ([Value]) throws -> Value = { args in
            if args.count == 1, case .number(let len) = args[0] {
                let intLen = Int(len)
                guard len.isFinite && Double(intLen) == len && intLen >= 0 && intLen <= MAX_ARRAY_LENGTH else {
                    throw rangeError("Invalid array length.")
                }
                try checkArrayLength(intLen)
                return .object(Arr(proto: builtins.Array, items: Array(repeating: .undefined, count: intLen), holes: Set(0..<intLen)))
            }
            return .object(Arr(proto: builtins.Array, items: args))
        }
        let ctor = constructor(builtins, builtins.Array, NativeOptions(
            name: "Array",
            length: 1,
            call: { _, args, _, _ in try makeArray(args) },
            construct: { args, _, _ in try makeArray(args) }
        ))
        methods(builtins, ctor, [
            Method("isArray", 1) { _, args, _, _ in
                if case .object(let obj) = args.first { return .bool(obj is Arr) }
                return .bool(false)
            },
            Method("of", 0) { _, args, _, _ in
                .object(Arr(proto: builtins.Array, items: args))
            },
            Method("from", 1) { _, args, _, eval in
                let src = args.first ?? .undefined
                var items: [Value]
                if case .object(let obj) = src, !(obj is Arr), !(obj is SetObj), !(obj is MapObj), has(obj, "length"), get(obj, .symbol(IteratorSymbol)).isUndefined {
                    let len = max(0, coerceToInteger(get(obj, "length")))
                    try checkArrayLength(len)
                    items = (0..<len).map { get(obj, JSString(String($0))) }
                } else {
                    items = try await eval.collectIterable(src)
                }
                if args.count > 1, !args[1].isUndefined {
                    let mapFn = try requireCallback(args[1], "Array.from")
                    let thisArg = args.count > 2 ? args[2] : .undefined
                    var mapped: [Value] = []
                    mapped.reserveCapacity(items.count)
                    for (idx, item) in items.enumerated() {
                        mapped.append(try await eval.callCallable(.object(mapFn), thisValue: thisArg, args: [item, .number(Double(idx))], site: nil))
                    }
                    items = mapped
                }
                return .object(Arr(proto: builtins.Array, items: items))
            },
        ])
        return ctor
    }

    // MARK: String (src/language/stdlib/string.ts)

    // parity: psychoscript/src/stdlib/string.ts#stringGlobal [status=implemented hash=ada05e2557d3]
    public static func stringGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.String, [
            Method("charAt", 1) { thisVal, args, _, _ in
                let str = coerceToString(thisVal)
                let idx = coerceToInteger(args.first ?? .number(0))
                guard let unit = str.unit(at: idx) else { return .string("") }
                return .string(JSString(unit: unit))
            },
            Method("charCodeAt", 1) { thisVal, args, _, _ in
                let str = coerceToString(thisVal)
                let idx = coerceToInteger(args.first ?? .number(0))
                guard let unit = str.unit(at: idx) else { return .number(.nan) }
                return .number(Double(unit))
            },
            Method("codePointAt", 1) { thisVal, args, _, _ in
                let str = coerceToString(thisVal)
                let idx = coerceToInteger(args.first ?? .number(0))
                guard let cp = str.codePoint(at: idx) else { return .undefined }
                return .number(Double(cp))
            },
            Method("at", 1) { thisVal, args, _, _ in
                let str = coerceToString(thisVal)
                var idx = coerceToInteger(args.first ?? .number(0))
                if idx < 0 { idx += str.utf16Count }
                guard let unit = str.unit(at: idx) else { return .undefined }
                return .string(JSString(unit: unit))
            },
            Method("slice", 2) { thisVal, args, _, _ in
                let str = coerceToString(thisVal)
                let count = str.utf16Count
                let start = args.first.map { $0.isUndefined ? 0 : resolveSliceIndex(coerceToInteger($0), length: count) } ?? 0
                let end = args.count > 1 && !args[1].isUndefined ? resolveSliceIndex(coerceToInteger(args[1]), length: count) : count
                return .string(str.sliceUTF16(from: start, to: end))
            },
            Method("substring", 2) { thisVal, args, _, _ in
                let str = coerceToString(thisVal)
                let count = str.utf16Count
                let a = max(0, min(count, args.first.map { $0.isUndefined ? 0 : coerceToInteger($0) } ?? 0))
                let b = max(0, min(count, args.count > 1 && !args[1].isUndefined ? coerceToInteger(args[1]) : count))
                return .string(str.sliceUTF16(from: min(a, b), to: max(a, b)))
            },
            Method("indexOf", 1) { thisVal, args, _, _ in
                let hay = coerceToString(thisVal)
                let needle = coerceToString(args.first ?? .undefined)
                let pos = args.count > 1 ? coerceToInteger(args[1]) : 0
                return .number(Double(hay.indexOf(needle, from: pos)))
            },
            Method("lastIndexOf", 1) { thisVal, args, _, _ in
                let hay = coerceToString(thisVal)
                let needle = coerceToString(args.first ?? .undefined)
                let pos: Int?
                if args.count > 1 && !args[1].isUndefined {
                    let raw = coerceToNumber(args[1])
                    pos = raw.isNaN ? nil : coerceToInteger(.number(raw))
                } else {
                    pos = nil
                }
                return .number(Double(hay.lastIndexOf(needle, from: pos)))
            },
            Method("includes", 1) { thisVal, args, _, _ in
                let hay = coerceToString(thisVal)
                if case .object(let rx) = args.first, rx is RegExpObj {
                    throw typeError("String.includes cannot take a regular expression; use regex.test(string) or String.search instead.")
                }
                let needle = coerceToString(args.first ?? .undefined)
                let pos = max(0, args.count > 1 ? coerceToInteger(args[1]) : 0)
                return .bool(hay.includes(needle, from: pos))
            },
            Method("startsWith", 1) { thisVal, args, _, _ in
                let hay = coerceToString(thisVal)
                if case .object(let rx) = args.first, rx is RegExpObj {
                    throw typeError("String.startsWith cannot take a regular expression; use regex.test(string) or String.search instead.")
                }
                let needle = coerceToString(args.first ?? .undefined)
                let pos = max(0, args.count > 1 ? coerceToInteger(args[1]) : 0)
                return .bool(hay.startsWith(needle, from: pos))
            },
            Method("endsWith", 1) { thisVal, args, _, _ in
                let hay = coerceToString(thisVal)
                if case .object(let rx) = args.first, rx is RegExpObj {
                    throw typeError("String.endsWith cannot take a regular expression; use regex.test(string) or String.search instead.")
                }
                let needle = coerceToString(args.first ?? .undefined)
                let end: Int? = args.count > 1 && !args[1].isUndefined ? coerceToInteger(args[1]) : nil
                return .bool(hay.endsWith(needle, endPosition: end))
            },
            Method("split", 2) { thisVal, args, _, eval in
                let str = coerceToString(thisVal)
                let limit: Int
                if args.count > 1 && !args[1].isUndefined {
                    limit = Int(toUInt32(coerceToNumber(args[1])))
                } else {
                    limit = Int(UInt32.max)
                }
                if limit == 0 { return .object(Arr(proto: builtins.Array)) }
                guard let sepArg = args.first, !sepArg.isUndefined else {
                    return .object(Arr(proto: builtins.Array, items: [.string(str)]))
                }
                if case .object(let rx as RegExpObj) = sepArg {
                    let parts = try regexSplit(str, regex: rx, limit: limit, eval: eval)
                    try checkArrayLength(parts.count)
                    return .object(Arr(proto: builtins.Array, items: parts))
                }
                let sep = coerceToString(sepArg)
                let parts = str.split(separator: sep, limit: limit).map { Value.string($0) }
                return .object(Arr(proto: builtins.Array, items: parts))
            },
            Method("trim", 0) { thisVal, _, _, _ in
                .string(coerceToString(thisVal).trim())
            },
            Method("trimStart", 0) { thisVal, _, _, _ in
                .string(coerceToString(thisVal).trimStart())
            },
            Method("trimEnd", 0) { thisVal, _, _, _ in
                .string(coerceToString(thisVal).trimEnd())
            },
            Method("toLowerCase", 0) { thisVal, _, _, _ in .string(coerceToString(thisVal).lowercased()) },
            Method("toUpperCase", 0) { thisVal, _, _, _ in .string(coerceToString(thisVal).uppercased()) },
            Method("repeat", 1) { thisVal, args, _, _ in
                let s = coerceToString(thisVal)
                let raw = coerceToNumber(args.first ?? .number(0))
                if raw < 0 || raw.isInfinite { throw rangeError("Invalid count value") }
                let n = raw.isNaN ? 0 : Int(raw.rounded(.towardZero))
                let unitCount = s.utf16Count
                if unitCount > 0 && n > MAX_STRING_LENGTH / unitCount {
                    try checkStringLength(MAX_STRING_LENGTH + 1)
                }
                try checkStringLength(unitCount * n)
                return .string(s.repeated(count: n))
            },
            Method("padStart", 2) { thisVal, args, _, _ in
                let s = coerceToString(thisVal)
                let targetLen = max(0, coerceToInteger(args.first ?? .number(0)))
                let fill: JSString = args.count > 1 && !args[1].isUndefined ? coerceToString(args[1]) : " "
                if targetLen <= s.utf16Count || fill.isEmpty { return .string(s) }
                let needed = targetLen - s.utf16Count
                try checkStringLength(targetLen)
                var padUnits: [UInt16] = []
                padUnits.reserveCapacity(needed + s.utf16Count)
                let fillUnits = fill.utf16Units
                while padUnits.count < needed {
                    padUnits.append(contentsOf: fillUnits)
                }
                var combined = Array(padUnits.prefix(needed))
                combined.append(contentsOf: s.utf16Units)
                return .string(JSString(utf16: combined))
            },
            Method("padEnd", 2) { thisVal, args, _, _ in
                let s = coerceToString(thisVal)
                let targetLen = max(0, coerceToInteger(args.first ?? .number(0)))
                let fill: JSString = args.count > 1 && !args[1].isUndefined ? coerceToString(args[1]) : " "
                if targetLen <= s.utf16Count || fill.isEmpty { return .string(s) }
                let needed = targetLen - s.utf16Count
                try checkStringLength(targetLen)
                var padUnits: [UInt16] = []
                padUnits.reserveCapacity(needed)
                let fillUnits = fill.utf16Units
                while padUnits.count < needed {
                    padUnits.append(contentsOf: fillUnits)
                }
                var combined = s.utf16Units
                combined.append(contentsOf: padUnits.prefix(needed))
                return .string(JSString(utf16: combined))
            },
            Method("replace", 2) { thisVal, args, _, eval in
                let str = coerceToString(thisVal)
                let search = args.first ?? .undefined
                let rep = args.count > 1 ? args[1] : .undefined
                if case .object(let rx as RegExpObj) = search {
                    return .string(try await regexReplace(str, regex: rx, replacement: rep, replaceAll: rx.flags.contains("g"), eval: eval))
                }
                return .string(try await stringReplace(str, needle: coerceToString(search), replacement: rep, all: false, eval: eval))
            },
            Method("replaceAll", 2) { thisVal, args, _, eval in
                let str = coerceToString(thisVal)
                let search = args.first ?? .undefined
                let rep = args.count > 1 ? args[1] : .undefined
                if case .object(let rx as RegExpObj) = search {
                    guard rx.flags.contains("g") else {
                        throw typeError("String.replaceAll requires a regular expression with the global (g) flag: write /\(rx.source.toHostString())/\(rx.flags)g, or use String.replace to replace only the first match.")
                    }
                    return .string(try await regexReplace(str, regex: rx, replacement: rep, replaceAll: true, eval: eval))
                }
                return .string(try await stringReplace(str, needle: coerceToString(search), replacement: rep, all: true, eval: eval))
            },
            Method("match", 1) { thisVal, args, _, eval in
                let str = coerceToString(thisVal)
                let rx: RegExpObj
                if case .object(let r as RegExpObj) = args.first {
                    rx = r
                } else {
                    let pat: JSString = args.first.map { $0.isUndefined ? .empty : coerceToString($0) } ?? .empty
                    rx = try compileStringPattern(builtins, source: pat, method: "match", extraFlags: "")
                }
                return try regexMatch(str, regex: rx, builtins: builtins, eval: eval)
            },
            Method("search", 1) { thisVal, args, _, eval in
                let str = coerceToString(thisVal)
                let rx: RegExpObj
                if case .object(let r as RegExpObj) = args.first {
                    rx = r
                } else {
                    let pat: JSString = args.first.map { $0.isUndefined ? .empty : coerceToString($0) } ?? .empty
                    rx = try compileStringPattern(builtins, source: pat, method: "search", extraFlags: "")
                }
                return .number(Double(try regexSearch(str, regex: rx, eval: eval)))
            },
            Method("concat", 1) { thisVal, args, _, _ in
                var parts: [JSString] = [coerceToString(thisVal)]
                parts.reserveCapacity(args.count + 1)
                for a in args { parts.append(coerceToString(a)) }
                let out = parts.joinedJS()
                try checkStringLength(out.utf16Count)
                return .string(out)
            },
            Method("localeCompare", 1) { thisVal, args, _, eval in
                let value = coerceToString(thisVal)
                let that = coerceToString(args.first ?? .undefined)
                let locales = args.count > 1 ? args[1] : .undefined
                let options = args.count > 2 ? args[2] : .undefined
                if locales.isUndefined && options.isUndefined {
                    return .number(Double(try collate(value, that, tags: nil, options: [:])))
                }
                if case .null = locales {
                    throw typeError("String.localeCompare cannot take null locales or options; pass undefined for the defaults.")
                }
                if case .null = options {
                    throw typeError("String.localeCompare cannot take null locales or options; pass undefined for the defaults.")
                }
                return try await withReads(eval) {
                    // The collator reads a locale list and these options; objects among them convert to strings first.
                    var list: [Value]? = nil
                    if case .object(let obj) = locales {
                        let length = max(0, coerceToInteger(get(obj, "length")))
                        try checkArrayLength(length)
                        list = (0..<length).map { get(obj, JSString(String($0))) }
                    }
                    var read: [Value] = []
                    if case .object(let obj) = options {
                        read = collatorOptions.map { key in
                            let option = get(obj, JSString(key))
                            if collatorFlags.contains(key), case .object = option { return .bool(true) }
                            return option
                        }
                    }
                    return try withPrimitives(.string, (list ?? []) + read) { primitives in
                        let tags: [String]? = if let list {
                            primitives.prefix(list.count).map { coerceToString($0).toWellFormedString() }
                        } else if case .undefined = locales {
                            nil
                        } else {
                            [coerceToString(locales).toWellFormedString()]
                        }
                        var hostOptions: [String: Value] = [:]
                        if case .object = options {
                            for (index, key) in collatorOptions.enumerated() {
                                hostOptions[key] = primitives[(list?.count ?? 0) + index]
                            }
                        }
                        return .number(Double(try collate(value, that, tags: tags, options: hostOptions)))
                    }
                }
            },
            Method("toString", 0) { thisVal, _, _, _ in .string(coerceToString(thisVal)) },
            Method("valueOf", 0) { thisVal, _, _, _ in .string(coerceToString(thisVal)) },
        ])

        let ctor = constructor(builtins, builtins.String, NativeOptions(
            name: "String",
            length: 1,
            call: { _, args, _, eval in
                if args.isEmpty { return .string("") }
                if case .symbol(let sym) = args[0] { return .string(JSString(symbolString(sym))) }
                return .string(try await eval.toStringValue(args[0]))
            }
        ))
        methods(builtins, ctor, [
            Method("fromCharCode", 1) { _, args, _, _ in
                let units = args.map { UInt16(truncatingIfNeeded: toInt32(coerceToNumber($0))) }
                return .string(JSString(utf16: units))
            },
            Method("raw", 1) { _, args, _, eval in
                try await withReads(eval) {
                    let template = args.first ?? .undefined
                    let raw: Value = if case .object(let t) = template { get(t, "raw") } else { .undefined }
                    guard case .object(let rawObj) = raw else {
                        throw typeError("String.raw expects a template object with a raw array.")
                    }
                    let count = max(0, coerceToInteger(get(rawObj, "length")))
                    try checkArrayLength(count)
                    // Each literal is followed by its substitution, except the last literal, or when substitutions run out.
                    var parts: [Value] = []
                    for index in 0..<count {
                        parts.append(get(rawObj, JSString(String(index))))
                        if index + 1 < count && index + 1 < args.count { parts.append(args[index + 1]) }
                    }
                    return try withPrimitives(.string, parts, coerce: true) { strings in
                        let output = strings.map { coerceToString($0) }.joinedJS()
                        try checkStringLength(output.utf16Count)
                        return .string(output)
                    }
                }
            },
            Method("fromCodePoint", 1) { _, args, _, _ in
                var units: [UInt16] = []
                units.reserveCapacity(args.count)
                for a in args {
                    let n = coerceToNumber(a)
                    guard n.isFinite && n >= 0 && n <= 0x10FFFF && n == n.rounded(.towardZero) else {
                        throw rangeError("Arguments contain a value that is out of range of code points")
                    }
                    let cp = UInt32(n)
                    if cp <= 0xFFFF {
                        units.append(UInt16(cp))
                    } else {
                        let adjusted = cp - 0x10000
                        units.append(UInt16(0xD800 + (adjusted >> 10)))
                        units.append(UInt16(0xDC00 + (adjusted & 0x3FF)))
                    }
                }
                return .string(JSString(utf16: units))
            },
        ])
        return ctor
    }

    /// The options Intl.Collator reads; the boolean ones take an object as true instead of converting it.
    static let collatorOptions = ["usage", "localeMatcher", "collation", "numeric", "caseFirst", "sensitivity", "ignorePunctuation"]
    static let collatorFlags: Set<String> = ["numeric", "ignorePunctuation"]

    /// A well-formed BCP 47 language tag, as Intl's canonicalization requires before it looks a locale up.
    static func isLanguageTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...8).contains(first.count), first.count != 4,
              first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// The locale Intl resolves a tag list to: the first tag, or en-US (Bun's default whatever the host says).
    static func intlLocale(_ tags: [String]?, method: String) throws -> Locale {
        for tag in tags ?? [] where !isLanguageTag(tag) {
            throw rangeError("\(method): Incorrect locale information provided")
        }
        guard let first = tags?.first else { return Locale(identifier: "en_US") }
        return Locale(identifier: first)
    }

    /// One Intl option that must be one of `allowed`.
    static func intlOption(_ options: [String: Value], _ key: String, _ allowed: [String], method: String) throws -> String? {
        guard let value = options[key], !value.isUndefined else { return nil }
        let text = coerceToString(value).toWellFormedString()
        guard allowed.contains(text) else {
            throw rangeError("\(method): Value \(text) out of range for Intl.Collator options property \(key)")
        }
        return text
    }

    /// String.prototype.localeCompare through the host collator: -1, 0 or 1.
    ///
    /// When either string contains lone UTF-16 surrogates, compares using a cross-platform 3-step UCA proxy:
    /// 1. Base comparison with lone surrogates mapped to U+D7FF (the unassigned slot right before surrogates in UCA).
    /// 2. Lexicographical tie-break on code units in `0xD7FF...0xDFFF` (excluding valid surrogate pairs).
    /// 3. Full sensitivity tie-break on the proxy strings.
    static func collate(_ value: JSString, _ that: JSString, tags: [String]?, options: [String: Value]) throws -> Int {
        let method = "String.localeCompare"
        let locale = try intlLocale(tags, method: method)
        _ = try intlOption(options, "usage", ["sort", "search"], method: method)
        _ = try intlOption(options, "localeMatcher", ["lookup", "best fit"], method: method)
        _ = try intlOption(options, "caseFirst", ["upper", "lower", "false"], method: method)
        let sensitivity = try intlOption(options, "sensitivity", ["base", "accent", "case", "variant"], method: method)
        var compareOptions: String.CompareOptions = []
        if options["numeric"]?.isTruthy == true { compareOptions.insert(.numeric) }
        switch sensitivity {
        case "base": compareOptions.formUnion([.caseInsensitive, .diacriticInsensitive])
        case "accent": compareOptions.insert(.caseInsensitive)
        case "case": compareOptions.insert(.diacriticInsensitive)
        default: break
        }
        var lhs = value
        var rhs = that
        if options["ignorePunctuation"]?.isTruthy == true {
            let strip = { (text: String) in
                String(String.UnicodeScalarView(text.unicodeScalars.filter {
                    !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespaces.contains($0)
                }))
            }
            lhs = lhs.mapWellFormedSpans(strip)
            rhs = rhs.mapWellFormedSpans(strip)
        }
        if let a = lhs.wellFormedString, let b = rhs.wellFormedString {
            switch a.compare(b, options: compareOptions, range: nil, locale: locale) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        }
        let proxyA = lhs.ucaPrimaryProxy()
        let proxyB = rhs.ucaPrimaryProxy()
        let baseOptions = compareOptions.union([.caseInsensitive, .diacriticInsensitive])
        switch proxyA.compare(proxyB, options: baseOptions, range: nil, locale: locale) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: break
        }
        let keyA = lhs.ucaSurrogateTieKey()
        let keyB = rhs.ucaSurrogateTieKey()
        for (x, y) in zip(keyA, keyB) where x != y {
            return x < y ? -1 : 1
        }
        if keyA.count != keyB.count {
            return keyA.count < keyB.count ? -1 : 1
        }
        switch proxyA.compare(proxyB, options: compareOptions, range: nil, locale: locale) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    // MARK: Number, Boolean, Math, JSON, Console, Value Coercion

    // parity: psychoscript/src/stdlib/value.ts#Coercion [status=implemented hash=20283ed3f897]
    public enum Coercion: String, Equatable, Hashable, Sendable, Codable {
        case parseInt
        case parseFloat
        case isFinite
        case isNaN
    }

    // parity: psychoscript/src/stdlib/value.ts#coerce [status=implemented hash=ca8297de8d24]
    public static func coerce(_ kind: Coercion, args: [Value]) -> Value {
        switch kind {
        case .parseInt:
            let str = coerceToString(args.first ?? .undefined).trimStart().toWellFormedString()
            var radix = args.count > 1 && !args[1].isUndefined ? Int(toInt32(coerceToNumber(args[1]))) : 0
            var sign = 1.0
            var slice = str[...]
            if slice.hasPrefix("-") { sign = -1.0; slice = slice.dropFirst() }
            else if slice.hasPrefix("+") { slice = slice.dropFirst() }
            if radix == 0 {
                if slice.hasPrefix("0x") || slice.hasPrefix("0X") { radix = 16; slice = slice.dropFirst(2) }
                else { radix = 10 }
            } else if radix == 16 && (slice.hasPrefix("0x") || slice.hasPrefix("0X")) {
                slice = slice.dropFirst(2)
            }
            guard radix >= 2 && radix <= 36 else { return .number(.nan) }
            var digits = ""
            for ch in slice {
                if let d = Int(String(ch), radix: radix) {
                    _ = d
                    digits.append(ch)
                } else {
                    break
                }
            }
            guard !digits.isEmpty else { return .number(.nan) }
            var acc = 0.0
            for ch in digits {
                let d = Double(Int(String(ch), radix: radix) ?? 0)
                acc = acc * Double(radix) + d
            }
            return .number(sign * acc)
        case .parseFloat:
            let str = coerceToString(args.first ?? .undefined).trimStart().toWellFormedString()
            if str.hasPrefix("Infinity") || str.hasPrefix("+Infinity") { return .number(.infinity) }
            if str.hasPrefix("-Infinity") { return .number(-.infinity) }
            var end = str.startIndex
            var seenDot = false
            var seenExp = false
            var seenDigit = false
            var i = str.startIndex
            if i < str.endIndex && (str[i] == "+" || str[i] == "-") { i = str.index(after: i) }
            while i < str.endIndex {
                let c = str[i]
                if c >= "0" && c <= "9" { seenDigit = true; i = str.index(after: i); end = i }
                else if c == "." && !seenDot && !seenExp { seenDot = true; i = str.index(after: i); if seenDigit { end = i } }
                else if (c == "e" || c == "E") && seenDigit && !seenExp {
                    seenExp = true
                    var j = str.index(after: i)
                    if j < str.endIndex && (str[j] == "+" || str[j] == "-") { j = str.index(after: j) }
                    var expDigit = false
                    while j < str.endIndex && str[j] >= "0" && str[j] <= "9" { expDigit = true; j = str.index(after: j) }
                    if expDigit { i = j; end = j } else { break }
                } else { break }
            }
            guard seenDigit, let val = Double(str[..<end]) else { return .number(.nan) }
            return .number(val)
        case .isFinite:
            return .bool(coerceToNumber(args.first ?? .undefined).isFinite)
        case .isNaN:
            return .bool(coerceToNumber(args.first ?? .undefined).isNaN)
        }
    }

    // parity: psychoscript/src/stdlib/value.ts#coercion [status=implemented hash=5dc6dde24513]
    public static func coercion(_ builtins: Builtins, _ kind: Coercion, length: Int = 1) -> Native {
        nativeFn(builtins, name: kind.rawValue, length: length) { _, args, _, _ in
            coerce(kind, args: args)
        }
    }

    // parity: psychoscript/src/stdlib/number.ts#numberGlobal [status=implemented hash=120e7751e4a8]
    public static func numberGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Number, [
            Method("toFixed", 1) { thisVal, args, _, _ in
                let n = coerceToNumber(thisVal)
                let digits = args.first.map { $0.isUndefined ? 0 : coerceToInteger($0) } ?? 0
                guard digits >= 0 && digits <= 100 else { throw rangeError("toFixed() digits argument must be between 0 and 100") }
                if !n.isFinite { return .string(JSString(formatJSNumber(n))) }
                return .string(JSString(String(format: "%.\(digits)f", n)))
            },
            Method("toString", 1) { thisVal, args, _, _ in
                let n = coerceToNumber(thisVal)
                let radix = args.first.map { $0.isUndefined ? 10 : coerceToInteger($0) } ?? 10
                guard radix >= 2 && radix <= 36 else { throw rangeError("toString() radix must be between 2 and 36") }
                if radix == 10 || !n.isFinite { return .string(JSString(formatJSNumber(n))) }
                return .string(JSString(String(Int64(n.rounded(.towardZero)), radix: radix)))
            },
            Method("valueOf", 0) { thisVal, _, _, _ in .number(coerceToNumber(thisVal)) },
        ])
        let ctor = constructor(builtins, builtins.Number, NativeOptions(
            name: "Number",
            length: 1,
            call: { _, args, _, _ in .number(args.isEmpty ? 0 : coerceToNumber(args[0])) }
        ))
        constants(ctor, [
            ("MAX_SAFE_INTEGER", .number(9_007_199_254_740_991)),
            ("MIN_SAFE_INTEGER", .number(-9_007_199_254_740_991)),
            ("MAX_VALUE", .number(Double.greatestFiniteMagnitude)),
            ("MIN_VALUE", .number(Double.leastNonzeroMagnitude)),
            ("EPSILON", .number(Double.ulpOfOne)),
            ("POSITIVE_INFINITY", .number(.infinity)),
            ("NEGATIVE_INFINITY", .number(-.infinity)),
            ("NaN", .number(.nan)),
        ])
        methods(builtins, ctor, [
            Method("isFinite", 1) { _, args, _, _ in
                if case .number(let n) = args.first { return .bool(n.isFinite) }
                return .bool(false)
            },
            Method("isNaN", 1) { _, args, _, _ in
                if case .number(let n) = args.first { return .bool(n.isNaN) }
                return .bool(false)
            },
            Method("isInteger", 1) { _, args, _, _ in
                if case .number(let n) = args.first { return .bool(n.isFinite && n == n.rounded(.towardZero)) }
                return .bool(false)
            },
            Method("isSafeInteger", 1) { _, args, _, _ in
                if case .number(let n) = args.first {
                    return .bool(n.isFinite && n == n.rounded(.towardZero) && abs(n) <= 9_007_199_254_740_991)
                }
                return .bool(false)
            },
            Method("parseInt", 2) { _, args, _, _ in coerce(.parseInt, args: args) },
            Method("parseFloat", 1) { _, args, _, _ in coerce(.parseFloat, args: args) },
        ])
        return ctor
    }

    // parity: psychoscript/src/stdlib/number.ts#booleanGlobal [status=implemented hash=5dd1a26ccf11]
    public static func booleanGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Boolean, [
            Method("toString", 0) { thisVal, _, _, _ in .string(thisVal.isTruthy ? "true" : "false") },
            Method("valueOf", 0) { thisVal, _, _, _ in .bool(thisVal.isTruthy) },
        ])
        return constructor(builtins, builtins.Boolean, NativeOptions(
            name: "Boolean",
            length: 1,
            call: { _, args, _, _ in .bool((args.first ?? .undefined).isTruthy) }
        ))
    }

    // parity: psychoscript/src/stdlib/math.ts#mathGlobal [status=implemented hash=d1e973ab1379]
    public static func mathGlobal(_ builtins: Builtins) -> Obj {
        let m = Obj(proto: builtins.Object)
        constants(m, [
            ("E", .number(2.718281828459045)),
            ("LN2", .number(0.6931471805599453)),
            ("LN10", .number(2.302585092994046)),
            ("LOG2E", .number(1.4426950408889634)),
            ("LOG10E", .number(0.4342944819032518)),
            ("PI", .number(Double.pi)),
            ("SQRT1_2", .number(0.7071067811865476)),
            ("SQRT2", .number(1.4142135623730951)),
        ])
        methods(builtins, m, [
            Method("abs", 1) { _, a, _, _ in .number(abs(coerceToNumber(a.first ?? .undefined))) },
            Method("ceil", 1) { _, a, _, _ in .number(ceil(coerceToNumber(a.first ?? .undefined))) },
            Method("floor", 1) { _, a, _, _ in .number(floor(coerceToNumber(a.first ?? .undefined))) },
            Method("round", 1) { _, a, _, _ in
                let x = coerceToNumber(a.first ?? .undefined)
                if !x.isFinite { return .number(x) }
                return .number(floor(x + 0.5))
            },
            Method("trunc", 1) { _, a, _, _ in .number(trunc(coerceToNumber(a.first ?? .undefined))) },
            Method("sign", 1) { _, a, _, _ in
                let x = coerceToNumber(a.first ?? .undefined)
                if x.isNaN || x == 0 { return .number(x) }
                return .number(x > 0 ? 1 : -1)
            },
            Method("sqrt", 1) { _, a, _, _ in .number(sqrt(coerceToNumber(a.first ?? .undefined))) },
            Method("cbrt", 1) { _, a, _, _ in
                let x = coerceToNumber(a.first ?? .undefined)
                let r = cbrt(x)
                if r.isFinite {
                    let n = r.rounded()
                    if n * n * n == x { return .number(n) }
                }
                return .number(r)
            },
            Method("pow", 2) { _, a, _, _ in .number(pow(coerceToNumber(a.first ?? .undefined), coerceToNumber(a.count > 1 ? a[1] : .undefined))) },
            Method("exp", 1) { _, a, _, _ in .number(exp(coerceToNumber(a.first ?? .undefined))) },
            Method("log", 1) { _, a, _, _ in .number(log(coerceToNumber(a.first ?? .undefined))) },
            Method("log2", 1) { _, a, _, _ in .number(log2(coerceToNumber(a.first ?? .undefined))) },
            Method("log10", 1) { _, a, _, _ in .number(log10(coerceToNumber(a.first ?? .undefined))) },
            Method("sin", 1) { _, a, _, _ in .number(sin(coerceToNumber(a.first ?? .undefined))) },
            Method("cos", 1) { _, a, _, _ in .number(cos(coerceToNumber(a.first ?? .undefined))) },
            Method("tan", 1) { _, a, _, _ in .number(tan(coerceToNumber(a.first ?? .undefined))) },
            Method("asin", 1) { _, a, _, _ in .number(asin(coerceToNumber(a.first ?? .undefined))) },
            Method("acos", 1) { _, a, _, _ in .number(acos(coerceToNumber(a.first ?? .undefined))) },
            Method("atan", 1) { _, a, _, _ in .number(atan(coerceToNumber(a.first ?? .undefined))) },
            Method("atan2", 2) { _, a, _, _ in .number(atan2(coerceToNumber(a.first ?? .undefined), coerceToNumber(a.count > 1 ? a[1] : .undefined))) },
            Method("hypot", 2) { _, a, _, _ in
                var sum = 0.0
                for v in a { let x = coerceToNumber(v); if x.isInfinite { return .number(.infinity) }; sum += x * x }
                return .number(sqrt(sum))
            },
            Method("min", 2) { _, a, _, _ in
                var best = Double.infinity
                for v in a {
                    let x = coerceToNumber(v)
                    if x.isNaN { return .number(.nan) }
                    if x < best { best = x }
                }
                return .number(best)
            },
            Method("max", 2) { _, a, _, _ in
                var best = -Double.infinity
                for v in a {
                    let x = coerceToNumber(v)
                    if x.isNaN { return .number(.nan) }
                    if x > best { best = x }
                }
                return .number(best)
            },
            Method("imul", 2) { _, a, _, _ in
                let x = toInt32(coerceToNumber(a.first ?? .number(0)))
                let y = toInt32(coerceToNumber(a.count > 1 ? a[1] : .number(0)))
                return .number(Double(x &* y))
            },
            Method("clz32", 1) { _, a, _, _ in
                .number(Double(toUInt32(coerceToNumber(a.first ?? .number(0))).leadingZeroBitCount))
            },
            Method("random", 0) { _, _, _, _ in .number(Double.random(in: 0..<1)) },
        ])
        return m
    }

    // parity: psychoscript/src/stdlib/json.ts#jsonGlobal [status=implemented hash=48206fa5b732]
    public static func jsonGlobal(_ builtins: Builtins) -> Obj {
        let j = Obj(proto: builtins.Object)
        methods(builtins, j, [
            Method("parse", 2) { _, args, _, eval in
                try await jsonParse(args, builtins: builtins, eval: eval)
            },
            Method("stringify", 3) { _, args, _, eval in
                try await jsonStringify(args, builtins: builtins, eval: eval)
            },
        ])
        return j
    }

    internal static func pureJsonToValue(_ builtins: Builtins, _ value: PureJSONValue) -> Value {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(JSString(s))
        case .array(let items): return .object(Arr(proto: builtins.Array, items: items.map { pureJsonToValue(builtins, $0) }))
        case .object(let pairs):
            let obj = Obj(proto: builtins.Object)
            for (k, v) in pairs where k != "__proto__" {
                define(obj, JSString(k), pureJsonToValue(builtins, v))
            }
            return .object(obj)
        }
    }

    internal static func valueToPureJSON(_ value: Value, seen: inout Set<ObjectIdentifier>) throws -> PureJSONValue? {
        switch value {
        case .undefined, .symbol: return nil
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return n.isFinite ? .number(n) : .null
        case .string(let s): return .string(s.toHostString())
        case .hostNamespace: return .object([])
        case .object(let obj):
            if obj is Callable { return nil }
            if let d = obj as? DateObj {
                return d.epochMs.isFinite ? .string(CodemodeLanguage.formatISODate(epochMs: d.epochMs)) : .null
            }
            if let u = obj as? URLObj { return .string(u.href) }
            let oid = ObjectIdentifier(obj)
            guard seen.insert(oid).inserted else {
                throw typeError("Converting circular structure to JSON.")
            }
            defer { seen.remove(oid) }
            if let arr = obj as? Arr {
                var out: [PureJSONValue] = []
                out.reserveCapacity(arr.count)
                for item in arr.items {
                    out.append(try valueToPureJSON(item, seen: &seen) ?? .null)
                }
                return .array(out)
            }
            var pairs: [(String, PureJSONValue)] = []
            for (k, v) in entries(obj) {
                if let p = try valueToPureJSON(v, seen: &seen) {
                    pairs.append((k.toHostString(), p))
                }
            }
            return .object(pairs)
        }
    }

    // MARK: Console (src/language/stdlib/console.ts)

    // parity: psychoscript/src/stdlib/console.ts#formatValue [status=implemented hash=758574ee6dcc]
    public static func formatValue(_ value: Value) -> String {
        switch value {
        case .undefined: return "undefined"
        case .string(let s): return s.toHostString()
        default:
            var seen = Set<ObjectIdentifier>()
            return formatConsoleValue(value, seen: &seen, depth: 0)
        }
    }

    private static func formatConsoleValue(_ value: Value, seen: inout Set<ObjectIdentifier>, depth: Int) -> String {
        switch value {
        case .null, .undefined: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return formatJSNumber(n)
        case .string(let s): return s.jsonQuotedString()
        case .symbol(let sym): return symbolString(sym)
        case .hostNamespace: return "[opaque reference]"
        case .object(let obj):
            if depth > 32 { return "..." }
            let oid = ObjectIdentifier(obj)
            if !seen.insert(oid).inserted { return "[Circular]" }
            defer { seen.remove(oid) }
            return obj.inspect { child in formatConsoleValue(child, seen: &seen, depth: depth + 1) }
        }
    }

    // parity: psychoscript/src/stdlib/console.ts#consoleGlobal [status=implemented hash=1892674cca24]
    public static func consoleGlobal(_ builtins: Builtins, appendLog: @escaping @Sendable (String) -> Void) -> Obj {
        let consoleObj = Obj(proto: builtins.Object)
        let names = ["log", "info", "debug", "warn", "error", "dir", "table"]
        methods(builtins, consoleObj, names.map { name in
            Method(name, 0) { _, args, _, _ in
                let formatted: String
                if name == "dir" {
                    formatted = args.isEmpty ? "undefined" : formatValue(args[0])
                } else if name == "table" {
                    formatted = formatConsoleTable(args.first ?? .undefined, columnsArg: args.count > 1 ? args[1] : .undefined)
                } else {
                    let prefix = name == "warn" ? "[warn] " : (name == "error" ? "[error] " : (name == "debug" ? "[debug] " : ""))
                    formatted = prefix + args.map(formatValue).joined(separator: " ")
                }
                appendLog(formatted)
                return .undefined
            }
        })
        return consoleObj
    }

    private static func formatConsoleTable(_ value: Value, columnsArg: Value) -> String {
        if value.isUndefined { return "undefined" }
        if containsOpaqueReference(value) { return "[opaque reference]" }
        let columns: [String]? = if case .object(let arr as Arr) = columnsArg { arr.items.map { coerceToString($0).toHostString() } } else { nil }
        var rows: [(String, [String: Value])] = []
        if case .object(let arr as Arr) = value {
            for (idx, item) in arr.items.enumerated() {
                if case .object(let obj) = item, !(obj is Arr) {
                    var dict: [String: Value] = [:]
                    for (k, v) in entries(obj) { dict[k.toHostString()] = v }
                    rows.append((String(idx), dict))
                } else {
                    rows.append((String(idx), ["Value": item]))
                }
            }
        } else if case .object(let obj) = value {
            for (k, v) in entries(obj) {
                if case .object(let inner) = v, !(inner is Arr) {
                    var dict: [String: Value] = [:]
                    for (ik, iv) in entries(inner) { dict[ik.toHostString()] = iv }
                    rows.append((k.toHostString(), dict))
                } else {
                    rows.append((k.toHostString(), ["Value": v]))
                }
            }
        } else {
            rows.append(("0", ["Value": value]))
        }
        var keyList: [String] = columns ?? []
        if columns == nil {
            var seen = Set<String>()
            for (_, dict) in rows {
                for k in dict.keys.sorted() where seen.insert(k).inserted {
                    keyList.append(k)
                }
            }
        }
        let header = (["(index)"] + keyList).joined(separator: "\t")
        let body = rows.map { idx, dict in
            ([idx] + keyList.map { k in
                guard let v = dict[k], !v.isUndefined else { return "" }
                return formatValue(v)
            }).joined(separator: "\t")
        }
        return ([header] + body).joined(separator: "\n")
    }
    // MARK: - Standard Library Part 2 (Date, RegExp, Collections, URL, Headers, Bytes, Buffer, Iterator, Web, Globals)

    /// The options Intl.DateTimeFormat reads.
    static let dateTimeOptions = [
        "localeMatcher", "calendar", "numberingSystem", "hour12", "hourCycle", "timeZone", "weekday", "era", "year",
        "month", "day", "dayPeriod", "hour", "minute", "second", "fractionalSecondDigits", "timeZoneName",
        "formatMatcher", "dateStyle", "timeStyle",
    ]

    /// A non-array object is array-like to Intl, so its elements are the tags.
    static func arrayLikeTags(_ locales: Obj) throws -> [Value] {
        let length = get(locales, "length")
        let count: Int
        if case .object = length {
            count = 0
        } else {
            let n = coerceToNumber(length)
            count = n.isNaN ? 0 : max(0, Int(min(n.rounded(.down), Double(Int32.max))))
        }
        try checkArrayLength(count)
        return (0..<count).filter { has(locales, JSString(String($0))) }.map { get(locales, JSString(String($0))) }
    }

    enum LocaleDateKind {
        case all
        case date
        case time
    }

    /// Date.prototype.toLocale{,Date,Time}String through the host's ICU formats, from an Intl.DateTimeFormat options
    /// skeleton, as Intl builds one.
    static func formatLocaleDate(_ time: Double, kind: LocaleDateKind, tags: [String]?, options: [String: Value], method: String) throws -> String {
        guard time.isFinite else { return "Invalid Date" }
        let locale = try intlLocale(tags, method: method)
        func option(_ key: String, _ allowed: [String]) throws -> String? {
            guard let value = options[key], !value.isUndefined else { return nil }
            let text = coerceToString(value).toWellFormedString()
            guard allowed.contains(text) else {
                throw rangeError("\(method): Value \(text) out of range for Intl.DateTimeFormat options property \(key)")
            }
            return text
        }
        let textual = ["narrow", "short", "long"]
        let digits = ["numeric", "2-digit"]
        let weekday = try option("weekday", textual)
        let era = try option("era", textual)
        let year = try option("year", digits)
        let month = try option("month", digits + textual)
        let day = try option("day", digits)
        let hour = try option("hour", digits)
        let minute = try option("minute", digits)
        let second = try option("second", digits)
        let timeZoneName = try option("timeZoneName", ["short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric"])
        let hourCycle = try option("hourCycle", ["h11", "h12", "h23", "h24"])
        let styles = ["full", "long", "medium", "short"]
        let dateStyle = try option("dateStyle", styles)
        let timeStyle = try option("timeStyle", styles)
        _ = try option("localeMatcher", ["lookup", "best fit"])
        _ = try option("formatMatcher", ["basic", "best fit"])
        var fractional: Int? = nil
        if let value = options["fractionalSecondDigits"], !value.isUndefined {
            let n = coerceToNumber(value)
            guard n.isFinite, n >= 1, n <= 3 else {
                throw rangeError("\(method): fractionalSecondDigits value is out of range.")
            }
            fractional = Int(n.rounded(.down))
        }
        let hour12: Bool? = options["hour12"].flatMap { $0.isUndefined ? nil : $0.isTruthy }

        let formatter = DateFormatter()
        formatter.locale = locale
        if let zone = options["timeZone"], !zone.isUndefined {
            let name = coerceToString(zone).toWellFormedString()
            guard let tz = TimeZone(identifier: name.uppercased() == "UTC" ? "UTC" : name) else {
                throw rangeError("\(method): Invalid time zone specified: \(name)")
            }
            formatter.timeZone = tz
        } else {
            formatter.timeZone = TimeZone.current
        }

        let explicit = [weekday, era, year, month, day, hour, minute, second, timeZoneName].contains { $0 != nil } || fractional != nil
        if dateStyle != nil || timeStyle != nil {
            if explicit {
                throw typeError("\(method): Can't set option \(["weekday", "era", "year", "month", "day", "hour", "minute", "second", "timeZoneName"].first { options[$0].map { !$0.isUndefined } ?? false } ?? "fractionalSecondDigits") when \(dateStyle != nil ? "dateStyle" : "timeStyle") is used")
            }
            if kind == .date && timeStyle != nil { throw typeError("\(method): Invalid option : timeStyle") }
            if kind == .time && dateStyle != nil { throw typeError("\(method): Invalid option : dateStyle") }
            func style(_ name: String?) -> DateFormatter.Style {
                switch name {
                case "full": return .full
                case "long": return .long
                case "medium": return .medium
                case "short": return .short
                default: return .none
                }
            }
            formatter.dateStyle = style(dateStyle)
            formatter.timeStyle = style(timeStyle)
            return formatter.string(from: Date(timeIntervalSince1970: time / 1000))
        }

        // ToDateTimeOptions: the defaults a method adds when none of its fields were given.
        let hasDate = [weekday, year, month, day].contains { $0 != nil }
        let hasTime = [hour, minute, second].contains { $0 != nil } || fractional != nil
            || options["dayPeriod"].map { !$0.isUndefined } == true
        var y = year, mo = month, d = day, h = hour, mi = minute, se = second
        switch kind {
        case .all where !hasDate && !hasTime:
            (y, mo, d, h, mi, se) = ("numeric", "numeric", "numeric", "numeric", "numeric", "numeric")
        case .date where !hasDate:
            (y, mo, d) = ("numeric", "numeric", "numeric")
        case .time where !hasTime:
            (h, mi, se) = ("numeric", "numeric", "numeric")
        default:
            break
        }
        var skeleton = ""
        switch era {
        case "narrow": skeleton += "GGGGG"
        case "long": skeleton += "GGGG"
        case "short": skeleton += "G"
        default: break
        }
        switch y {
        case "2-digit": skeleton += "yy"
        case "numeric": skeleton += "y"
        default: break
        }
        switch mo {
        case "numeric": skeleton += "M"
        case "2-digit": skeleton += "MM"
        case "narrow": skeleton += "MMMMM"
        case "short": skeleton += "MMM"
        case "long": skeleton += "MMMM"
        default: break
        }
        switch weekday {
        case "narrow": skeleton += "EEEEE"
        case "short": skeleton += "EEE"
        case "long": skeleton += "EEEE"
        default: break
        }
        switch d {
        case "numeric": skeleton += "d"
        case "2-digit": skeleton += "dd"
        default: break
        }
        if let h {
            let symbol: String
            if let hour12 {
                symbol = hour12 ? "h" : "H"
            } else {
                switch hourCycle {
                case "h11": symbol = "K"
                case "h12": symbol = "h"
                case "h23": symbol = "H"
                case "h24": symbol = "k"
                default: symbol = "j"
                }
            }
            skeleton += h == "2-digit" ? symbol + symbol : symbol
        }
        switch mi {
        case "numeric": skeleton += "m"
        case "2-digit": skeleton += "mm"
        default: break
        }
        switch se {
        case "numeric": skeleton += "s"
        case "2-digit": skeleton += "ss"
        default: break
        }
        if let fractional { skeleton += String(repeating: "S", count: fractional) }
        switch timeZoneName {
        case "short": skeleton += "z"
        case "long": skeleton += "zzzz"
        case "shortOffset": skeleton += "O"
        case "longOffset": skeleton += "OOOO"
        case "shortGeneric": skeleton += "v"
        case "longGeneric": skeleton += "vvvv"
        default: break
        }
        formatter.setLocalizedDateFormatFromTemplate(skeleton)
        return formatter.string(from: Date(timeIntervalSince1970: time / 1000))
    }

    // parity: psychoscript/src/stdlib/date.ts#dateGlobal [status=implemented hash=f6731be8fcdb]
    public static func dateGlobal(_ builtins: Builtins) -> Native {
        let localeMethods: [Method] = [
            ("toLocaleString", LocaleDateKind.all),
            ("toLocaleDateString", .date),
            ("toLocaleTimeString", .time),
        ].map { name, kind in
            Method(name, 0) { thisVal, args, _, eval in
                let time = try receiver(DateObj.self, thisVal, "Date.prototype.\(name)").epochMs
                let locales = args.first ?? .undefined
                let options = args.count > 1 ? args[1] : .undefined
                if case .null = locales { throw typeError("Cannot convert undefined or null to object.") }
                if case .null = options { throw typeError("Cannot convert undefined or null to object.") }
                return try await withReads(eval) {
                    // Bun's default locale is en-US whatever the environment says; pinning it keeps output off the host's.
                    let tags: [Value]
                    switch locales {
                    case .undefined: tags = [.string("en-US")]
                    case .object(let arr as Arr): tags = arr.items
                    case .object(let obj): tags = try arrayLikeTags(obj)
                    default: tags = [locales]
                    }
                    var entries: [(String, Value)] = []
                    if case .object(let opts) = options {
                        for key in dateTimeOptions {
                            let value = get(opts, JSString(key))
                            if value.isUndefined { continue }
                            entries.append((key, key == "hour12" ? .bool(value.isTruthy) : value))
                        }
                    }
                    // Program objects among the arguments are converted first, as Intl's ToString would.
                    let tagStrings = conversions(.string, tags).map { coerceToString($0).toWellFormedString() }
                    let optionValues = conversions(.string, entries.map(\.1))
                    var hostOptions: [String: Value] = [:]
                    for (index, entry) in entries.enumerated() {
                        hostOptions[entry.0] = entry.0 == "fractionalSecondDigits" ? .number(coerceToNumber(optionValues[index])) : optionValues[index]
                    }
                    return .string(JSString(try formatLocaleDate(time, kind: kind, tags: tagStrings, options: hostOptions, method: "Date.prototype.\(name)")))
                }
            }
        }
        methods(builtins, builtins.Date, localeMethods)
        methods(builtins, builtins.Date, [
            Method("getTime", 0) { thisVal, _, _, _ in .number(try receiver(DateObj.self, thisVal, "Date.prototype.getTime").epochMs) },
            Method("valueOf", 0) { thisVal, _, _, _ in .number(try receiver(DateObj.self, thisVal, "Date.prototype.valueOf").epochMs) },
            Method("toISOString", 0) { thisVal, _, _, _ in .string(JSString(try receiver(DateObj.self, thisVal, "Date.prototype.toISOString").toISOString())) },
            Method("toJSON", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.toJSON")
                return d.epochMs.isFinite ? .string(JSString(try d.toISOString())) : .null
            },
            Method("toString", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.toString")
                return .string(d.jsToString())
            },
            Method("toUTCString", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.toUTCString")
                return .string(d.jsToString())
            },
            Method("getUTCFullYear", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.getUTCFullYear")
                return .number(utcComponents(d.epochMs).year)
            },
            Method("getUTCMonth", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.getUTCMonth")
                return .number(utcComponents(d.epochMs).month)
            },
            Method("getUTCDate", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.getUTCDate")
                return .number(utcComponents(d.epochMs).day)
            },
            Method("getUTCHours", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.getUTCHours")
                return .number(utcComponents(d.epochMs).hour)
            },
            Method("getUTCMinutes", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.getUTCMinutes")
                return .number(utcComponents(d.epochMs).minute)
            },
            Method("getUTCSeconds", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.getUTCSeconds")
                return .number(utcComponents(d.epochMs).second)
            },
            Method("getUTCMilliseconds", 0) { thisVal, _, _, _ in
                let d = try receiver(DateObj.self, thisVal, "Date.prototype.getUTCMilliseconds")
                return .number(utcComponents(d.epochMs).millisecond)
            },
        ])
        let ctor = constructor(builtins, builtins.Date, NativeOptions(
            name: "Date",
            length: 7,
            call: { _, _, _, _ in .string(JSString(formatISODate(epochMs: currentEpochMs()))) },
            construct: { args, _, _ in
                if args.isEmpty { return .object(DateObj(proto: builtins.Date, epochMs: currentEpochMs())) }
                if args.count == 1 {
                    if case .object(let other as DateObj) = args[0] {
                        return .object(DateObj(proto: builtins.Date, epochMs: other.epochMs))
                    }
                    if case .string(let s) = args[0] {
                        return .object(DateObj(proto: builtins.Date, epochMs: parseISODate(s.toWellFormedString())))
                    }
                    return .object(DateObj(proto: builtins.Date, epochMs: timeClip(coerceToNumber(args[0]))))
                }
                let y = coerceToInteger(args[0])
                let fullYear = (y >= 0 && y <= 99) ? 1900 + y : y
                let m = coerceToInteger(args[1])
                let day = args.count > 2 ? coerceToInteger(args[2]) : 1
                let h = args.count > 3 ? coerceToInteger(args[3]) : 0
                let min = args.count > 4 ? coerceToInteger(args[4]) : 0
                let sec = args.count > 5 ? coerceToInteger(args[5]) : 0
                let ms = args.count > 6 ? coerceToInteger(args[6]) : 0
                return .object(DateObj(proto: builtins.Date, epochMs: makeUTCEpochMs(year: fullYear, month: m, day: day, hour: h, minute: min, second: sec, ms: ms)))
            }
        ))
        methods(builtins, ctor, [
            Method("now", 0) { _, _, _, _ in .number(currentEpochMs()) },
            Method("parse", 1) { _, args, _, _ in .number(parseISODate(coerceToString(args.first ?? .undefined).toWellFormedString())) },
            Method("UTC", 7) { _, args, _, _ in
                guard !args.isEmpty else { return .number(.nan) }
                let y = coerceToInteger(args[0])
                let fullYear = (y >= 0 && y <= 99) ? 1900 + y : y
                let m = args.count > 1 ? coerceToInteger(args[1]) : 0
                let day = args.count > 2 ? coerceToInteger(args[2]) : 1
                let h = args.count > 3 ? coerceToInteger(args[3]) : 0
                let min = args.count > 4 ? coerceToInteger(args[4]) : 0
                let sec = args.count > 5 ? coerceToInteger(args[5]) : 0
                let ms = args.count > 6 ? coerceToInteger(args[6]) : 0
                return .number(timeClip(makeUTCEpochMs(year: fullYear, month: m, day: day, hour: h, minute: min, second: sec, ms: ms)))
            },
        ])
        return ctor
    }

    // MARK: RegExp (src/language/stdlib/regexp.ts)

    // parity: psychoscript/src/stdlib/regexp.ts#withHostRegex [status=adapted hash=976b7d368513]
    public static func withHostRegex<T>(_ pattern: String, flags: String, _ body: (ECMAScriptRegExp) throws -> T) throws -> T {
        let regex = try ECMAScriptRegExp(pattern: pattern, flags: flags)
        return try body(regex)
    }

    static func makeRegexInterruptCheck(_ eval: Evaluator?) -> (() throws -> Void)? {
        guard let eval else { return nil }
        return {
            if Task.isCancelled { throw Interruption("cancelled") }
            try eval.checkDeadline()
        }
    }

    static func compileStringPattern(_ builtins: Builtins, source: JSString, method: String, extraFlags: String) throws -> RegExpObj {
        do {
            let compiled = try ECMAScriptRegExp(pattern: source.utf16Units, flags: Array(extraFlags.utf16))
            return RegExpObj(proto: builtins.RegExp, compiled: compiled)
        } catch let err {
            throw syntaxError("String.\(method) received the string \(jsonQuote(source)), which is not a valid regular expression pattern (\(err.reason)). \(escapeRegexHint)")
        }
    }

    private static func sliceUTF16(_ units: [UInt16], _ range: Range<Int>) -> JSString {
        if range.isEmpty { return .empty }
        return JSString(utf16: units[range])
    }

    private static func indicesToValue(_ match: ECMAScriptRegExpMatch, builtins: Builtins) -> Value {
        func pair(_ r: Range<Int>?) -> Value {
            guard let r else { return .undefined }
            return .object(Arr(proto: builtins.Array, items: [.number(Double(r.lowerBound)), .number(Double(r.upperBound))]))
        }
        let items = match.captures.map(pair)
        let result = Arr(proto: builtins.Array, items: items)
        if match.namedGroupNames.isEmpty {
            define(result, "groups", .undefined)
        } else {
            let groups = Obj(proto: builtins.Object)
            for name in match.namedGroupNames {
                define(groups, JSString(name), pair(match.namedCaptures[name] ?? nil))
            }
            define(result, "groups", .object(groups))
        }
        return .object(result)
    }

    /// A match as `exec` returns it: the groups, `index`, `input`, `groups` (when named groups exist), and `indices` (when `d` is set).
    // parity: psychoscript/src/stdlib/regexp.ts#matchToValue [status=implemented hash=36713a943eac]
    public static func matchToValue(
        _ match: ECMAScriptRegExpMatch,
        in string: JSString,
        units: [UInt16],
        builtins: Builtins
    ) -> Value {
        var items: [Value] = []
        items.reserveCapacity(match.captures.count)
        for cap in match.captures {
            if let r = cap {
                items.append(.string(sliceUTF16(units, r)))
            } else {
                items.append(.undefined)
            }
        }
        let arr = Arr(proto: builtins.Array, items: items)
        define(arr, "index", .number(Double(match.range.lowerBound)))
        define(arr, "input", .string(string))
        if !match.namedGroupNames.isEmpty {
            let groups = Obj(proto: builtins.Object)
            for name in match.namedGroupNames {
                if let r = match.namedCaptures[name] ?? nil {
                    define(groups, JSString(name), .string(sliceUTF16(units, r)))
                } else {
                    define(groups, JSString(name), .undefined)
                }
            }
            define(arr, "groups", .object(groups))
        }
        if match.hasIndices {
            define(arr, "indices", indicesToValue(match, builtins: builtins))
        }
        return .object(arr)
    }

    static let escapeRegexHint = "To match special characters like ( ) [ ] { } + * ? . literally, escape them with a backslash (e.g. \"\\\\(\") or test for them with String.includes instead."

    // parity: psychoscript/src/stdlib/regexp.ts#constructRegExp [status=implemented hash=08387c9f6fa9]
    public static func constructRegExp(_ builtins: Builtins, args: [Value]) throws -> RegExpObj {
        let patternArg = args.first ?? .undefined
        let flagsArg = args.count > 1 ? args[1] : .undefined
        let pattern: JSString
        let flags: JSString
        if !flagsArg.isUndefined, case .string = flagsArg {} else if !flagsArg.isUndefined {
            throw syntaxError("RegExp flags must be a string of flag characters (e.g. \"g\", \"gi\"), not \(flagsArg.isNullish ? "null" : typeofValue(flagsArg)).")
        }
        if case .object(let existing as RegExpObj) = patternArg {
            pattern = existing.source
            flags = flagsArg.isUndefined ? JSString(existing.flags) : coerceToString(flagsArg)
        } else {
            pattern = patternArg.isUndefined ? .empty : coerceToString(patternArg)
            flags = flagsArg.isUndefined ? .empty : coerceToString(flagsArg)
        }
        do {
            let compiled = try ECMAScriptRegExp(pattern: pattern.utf16Units, flags: flags.utf16Units)
            return RegExpObj(proto: builtins.RegExp, compiled: compiled)
        } catch let err {
            if err.kind == .invalidFlags {
                throw syntaxError("new RegExp(...) received invalid flags \(jsonQuote(flags)) (\(err.reason)). Valid flags are d, g, i, m, s, u, v, and y.")
            }
            throw syntaxError("new RegExp(...) received \(jsonQuote(pattern)), which is not a valid regular expression pattern (\(err.reason)). \(escapeRegexHint)")
        }
    }

    /// One `RegExpBuiltinExec` step on UTF-16 code units: a match starting at or after `lastIndex`
    /// (exactly at it with `y`), updating `lastIndex` for global and sticky expressions.
    static func regexExec(_ regex: RegExpObj, units: [UInt16], eval: Evaluator? = nil) throws -> ECMAScriptRegExpMatch? {
        let compiled = regex.compiled
        let tracksIndex = compiled.flags.contains(.global) || compiled.flags.contains(.sticky)
        let start = tracksIndex ? regex.lastIndex : 0
        if start > units.count {
            if tracksIndex { regex.lastIndexNumber = 0 }
            return nil
        }
        guard let m = try compiled.exec(in: units, startIndex: start, checkInterrupt: makeRegexInterruptCheck(eval)) else {
            if tracksIndex { regex.lastIndexNumber = 0 }
            return nil
        }
        if tracksIndex { regex.lastIndexNumber = Double(m.range.upperBound) }
        return m
    }

    static func regexExec(_ regex: RegExpObj, _ input: JSString, eval: Evaluator? = nil) throws -> ECMAScriptRegExpMatch? {
        try regexExec(regex, units: input.utf16Units, eval: eval)
    }

    internal static func regexMatch(_ input: JSString, regex: RegExpObj, builtins: Builtins, eval: Evaluator? = nil) throws -> Value {
        let units = input.utf16Units
        if regex.compiled.flags.contains(.global) {
            regex.lastIndexNumber = 0
            let unicode = regex.compiled.flags.isUnicodeMode
            var found: [Value] = []
            while let m = try regexExec(regex, units: units, eval: eval) {
                found.append(.string(sliceUTF16(units, m.range)))
                if m.range.isEmpty {
                    regex.lastIndexNumber = Double(ECMAScriptRegExp.advanceIndex(in: units, from: m.range.lowerBound, unicode: unicode))
                }
            }
            return found.isEmpty ? .null : .object(Arr(proto: builtins.Array, items: found))
        }
        guard let m = try regexExec(regex, units: units, eval: eval) else { return .null }
        return matchToValue(m, in: input, units: units, builtins: builtins)
    }

    /// AdvanceStringIndex: one code unit, or one code point under the `u`/`v` flag.
    static func advanceIndex(_ input: JSString, _ index: Int, unicode: Bool) -> Int {
        ECMAScriptRegExp.advanceIndex(in: input.utf16Units, from: index, unicode: unicode)
    }

    internal static func regexSearch(_ input: JSString, regex: RegExpObj, eval: Evaluator? = nil) throws -> Int {
        let units = input.utf16Units
        let prev = regex.lastIndexNumber
        regex.lastIndexNumber = 0
        defer { regex.lastIndexNumber = prev }
        guard let m = try regexExec(regex, units: units, eval: eval) else { return -1 }
        return m.range.lowerBound
    }

    // Upstream: psychoscript/src/stdlib/regexp.ts#split (implemented).
    /// RegExp.prototype[Symbol.split]: sticky matching at each position, with captures spliced in (unmatched -> undefined).
    internal static func regexSplit(_ input: JSString, regex: RegExpObj, limit: Int, eval: Evaluator? = nil) throws -> [Value] {
        let units = input.utf16Units
        let size = units.count
        let compiled = regex.compiled
        let unicode = compiled.flags.isUnicodeMode
        let check = makeRegexInterruptCheck(eval)
        var parts: [Value] = []
        if limit == 0 { return [] }
        if size == 0 {
            let m = try compiled.exec(in: units, startIndex: 0, anchored: true, checkInterrupt: check)
            return m == nil ? [.string(input)] : []
        }
        var p = 0
        var q = 0
        while q < size {
            try check?()
            guard let m = try compiled.exec(in: units, startIndex: q, anchored: true, checkInterrupt: check) else {
                q = ECMAScriptRegExp.advanceIndex(in: units, from: q, unicode: unicode)
                continue
            }
            let e = min(m.range.upperBound, size)
            if e == p {
                q = ECMAScriptRegExp.advanceIndex(in: units, from: q, unicode: unicode)
                continue
            }
            parts.append(.string(sliceUTF16(units, p..<q)))
            if parts.count == limit { return parts }
            p = e
            for idx in 1..<m.captures.count {
                if let r = m.captures[idx] {
                    parts.append(.string(sliceUTF16(units, r)))
                } else {
                    parts.append(.undefined)
                }
                if parts.count == limit { return parts }
            }
            q = p
        }
        parts.append(.string(sliceUTF16(units, p..<size)))
        return parts
    }

    /// GetSubstitution: `$$`, `$&`, `` $` ``, `$'`, `$n`/`$nn`, and `$<name>`.
    static func expandReplacement(_ template: JSString, matched: JSString, position: Int, input: JSString, captures: [Value], groups: Value) -> JSString {
        let inputUnits = input.utf16Units
        let endPos = min(position + matched.utf16Count, inputUnits.count)
        let capUnits: [[UInt16]?] = captures.map { v in
            if case .string(let s) = v { return s.utf16Units }
            return nil
        }
        var namedMap: [String: [UInt16]?]? = nil
        if case .object(let groupsObj) = groups {
            var dict: [String: [UInt16]?] = [:]
            for key in ownKeys(groupsObj) {
                let val = get(groupsObj, key)
                dict[key.toWellFormedString()] = val.isUndefined ? nil : coerceToString(val).utf16Units
            }
            namedMap = dict
        }
        let out = ECMAScriptRegExp.expandReplacement(
            template: template.utf16Units,
            input: inputUnits,
            matchRange: position..<endPos,
            captures: capUnits,
            namedCaptures: namedMap
        )
        return JSString(utf16: out)
    }

    internal static func regexReplace(
        _ input: JSString,
        regex: RegExpObj,
        replacement: Value,
        replaceAll: Bool,
        eval: Evaluator
    ) async throws -> JSString {
        let units = input.utf16Units
        let unicode = regex.compiled.flags.isUnicodeMode
        var matches: [ECMAScriptRegExpMatch] = []
        if replaceAll {
            regex.lastIndexNumber = 0
            while let m = try regexExec(regex, units: units, eval: eval) {
                matches.append(m)
                if m.range.isEmpty {
                    regex.lastIndexNumber = Double(ECMAScriptRegExp.advanceIndex(in: units, from: m.range.lowerBound, unicode: unicode))
                }
            }
        } else if let m = try regexExec(regex, units: units, eval: eval) {
            matches.append(m)
        }
        if matches.isEmpty { return input }
        let hasNamed = !regex.compiled.namedGroupNames.isEmpty
        var outUnits: [UInt16] = []
        var cursor = 0
        for m in matches {
            let start = m.range.lowerBound
            let end = m.range.upperBound
            if start > cursor {
                outUnits.append(contentsOf: units[cursor..<start])
            }
            let matched = sliceUTF16(units, m.range)
            var captures: [Value] = []
            captures.reserveCapacity(max(0, m.captures.count - 1))
            var capUnits: [[UInt16]?] = []
            for idx in 1..<m.captures.count {
                if let r = m.captures[idx] {
                    captures.append(.string(sliceUTF16(units, r)))
                    capUnits.append(Array(units[r]))
                } else {
                    captures.append(.undefined)
                    capUnits.append(nil)
                }
            }
            var groupsVal: Value = .undefined
            var namedUnits: [String: [UInt16]?]? = nil
            if hasNamed {
                let g = Obj(proto: eval.builtins.Object)
                var dict: [String: [UInt16]?] = [:]
                for name in m.namedGroupNames {
                    if let r = m.namedCaptures[name] ?? nil {
                        define(g, JSString(name), .string(sliceUTF16(units, r)))
                        dict[name] = Array(units[r])
                    } else {
                        define(g, JSString(name), .undefined)
                        dict[name] = nil
                    }
                }
                groupsVal = .object(g)
                namedUnits = dict
            }
            if case .object(let cb as Callable) = replacement {
                var cbArgs: [Value] = [.string(matched)] + captures
                cbArgs.append(.number(Double(start)))
                cbArgs.append(.string(input))
                if hasNamed { cbArgs.append(groupsVal) }
                let repStr = coerceToString(try await eval.callCallable(.object(cb), thisValue: .undefined, args: cbArgs, site: nil))
                outUnits.append(contentsOf: repStr.utf16Units)
            } else {
                let templateUnits = coerceToString(replacement).utf16Units
                let expanded = ECMAScriptRegExp.expandReplacement(
                    template: templateUnits,
                    input: units,
                    matchRange: m.range,
                    captures: capUnits,
                    namedCaptures: namedUnits
                )
                outUnits.append(contentsOf: expanded)
            }
            cursor = end
        }
        if cursor < units.count {
            outUnits.append(contentsOf: units[cursor..<units.count])
        }
        return JSString(utf16: outUnits)
    }

    // parity: psychoscript/src/stdlib/regexp.ts#regexpGlobal [status=implemented hash=38dcf3d03ad1]
    public static func regexpGlobal(_ builtins: Builtins) -> Native {
        defineAccessor(builtins.RegExp, "source", get: { thisVal in
            .string(try receiver(RegExpObj.self, thisVal, "RegExp.prototype.source").source)
        })
        defineAccessor(builtins.RegExp, "flags", get: { thisVal in
            .string(JSString(try receiver(RegExpObj.self, thisVal, "RegExp.prototype.flags").flags))
        })
        defineAccessor(
            builtins.RegExp,
            "lastIndex",
            get: { thisVal in .number(try receiver(RegExpObj.self, thisVal, "RegExp.prototype.lastIndex").lastIndexNumber) },
            set: { thisVal, val in
                let rx = try receiver(RegExpObj.self, thisVal, "RegExp.prototype.lastIndex")
                rx.lastIndexNumber = coerceToNumber(val)
            }
        )
        let flagGetters: [(String, ECMAScriptRegExpFlags)] = [
            ("hasIndices", .hasIndices),
            ("global", .global),
            ("ignoreCase", .ignoreCase),
            ("multiline", .multiline),
            ("sticky", .sticky),
            ("unicode", .unicode),
            ("unicodeSets", .unicodeSets),
            ("dotAll", .dotAll),
        ]
        for (propName, flagBit) in flagGetters {
            defineAccessor(builtins.RegExp, JSString(propName), get: { thisVal in
                .bool(try receiver(RegExpObj.self, thisVal, "RegExp.prototype.\(propName)").compiled.flags.contains(flagBit))
            })
        }
        methods(builtins, builtins.RegExp, [
            Method("test", 1) { thisVal, args, _, eval in
                let rx = try receiver(RegExpObj.self, thisVal, "RegExp.prototype.test")
                let str = coerceToString(args.first ?? .undefined)
                return .bool(try regexExec(rx, str, eval: eval) != nil)
            },
            Method("exec", 1) { thisVal, args, _, eval in
                let rx = try receiver(RegExpObj.self, thisVal, "RegExp.prototype.exec")
                let str = coerceToString(args.first ?? .undefined)
                let units = str.utf16Units
                guard let m = try regexExec(rx, units: units, eval: eval) else { return .null }
                return matchToValue(m, in: str, units: units, builtins: builtins)
            },
            Method("toString", 0) { thisVal, _, _, _ in
                .string(try receiver(RegExpObj.self, thisVal, "RegExp.prototype.toString").jsToString())
            },
        ])
        return constructor(builtins, builtins.RegExp, NativeOptions(
            name: "RegExp",
            length: 2,
            call: { _, args, _, _ in .object(try constructRegExp(builtins, args: args)) },
            construct: { args, _, _ in .object(try constructRegExp(builtins, args: args)) }
        ))
    }

    // MARK: Collections (src/language/stdlib/collections.ts)

    // parity: psychoscript/src/stdlib/collections.ts#weakKey [status=implemented hash=d9b54883074a]
    public static func weakKey(_ value: Value, method: String) throws -> Obj {
        guard case .object(let obj) = value else {
            let label = method.hasPrefix("WeakSet") ? "in weak set" : "as weak map key"
            throw typeError("Invalid value used \(label): \(describeValue(value)) cannot be held weakly.")
        }
        return obj
    }

    // parity: psychoscript/src/stdlib/collections.ts#mapGlobal [status=implemented hash=de32250d9fca]
    public static func mapGlobal(_ builtins: Builtins) -> Native {
        defineAccessor(builtins.Map, "size", get: { thisVal in
            .number(Double(try receiver(MapObj.self, thisVal, "Map.prototype.size").table.size))
        })
        methods(builtins, builtins.Map, [
            Method("get", 1) { thisVal, args, _, _ in try receiver(MapObj.self, thisVal, "Map.prototype.get").table.get(args.first ?? .undefined) },
            Method("has", 1) { thisVal, args, _, _ in .bool(try receiver(MapObj.self, thisVal, "Map.prototype.has").table.has(args.first ?? .undefined)) },
            Method("set", 2) { thisVal, args, _, _ in
                let m = try receiver(MapObj.self, thisVal, "Map.prototype.set")
                m.table.set(args.first ?? .undefined, args.count > 1 ? args[1] : .undefined)
                return .object(m)
            },
            Method("delete", 1) { thisVal, args, _, _ in .bool(try receiver(MapObj.self, thisVal, "Map.prototype.delete").table.delete(args.first ?? .undefined)) },
            Method("clear", 0) { thisVal, _, _, _ in try receiver(MapObj.self, thisVal, "Map.prototype.clear").table.clear(); return .undefined },
            Method("keys", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .map(try receiver(MapObj.self, thisVal, "Map.prototype.keys")), kind: .keys))
            },
            Method("values", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .map(try receiver(MapObj.self, thisVal, "Map.prototype.values")), kind: .values))
            },
            Method("entries", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .map(try receiver(MapObj.self, thisVal, "Map.prototype.entries")), kind: .entries))
            },
            Method("forEach", 1) { thisVal, args, _, eval in
                let m = try receiver(MapObj.self, thisVal, "Map.prototype.forEach")
                let cb = try requireCallback(args.first ?? .undefined, "Map.prototype.forEach")
                let thisArg = args.count > 1 ? args[1] : .undefined
                for (k, v) in m.table.liveEntries() {
                    _ = try await eval.callCallable(.object(cb), thisValue: thisArg, args: [v, k, thisVal], site: nil)
                }
                return .undefined
            },
        ])
        if case .object(let entriesFn as Native) = getOwn(builtins.Map, "entries") {
            iteratorMethods(builtins, builtins.Map, entriesFn)
        }
        return constructor(builtins, builtins.Map, NativeOptions(
            name: "Map",
            length: 0,
            call: requiresNew("Map"),
            construct: { args, _, eval in
                let m = MapObj(proto: builtins.Map)
                if let first = args.first, !first.isNullish {
                    for entry in try await eval.collectIterable(first) {
                        let pair = try await eval.collectIterable(entry)
                        m.table.set(pair.first ?? .undefined, pair.count > 1 ? pair[1] : .undefined)
                    }
                }
                return .object(m)
            }
        ))
    }

    // parity: psychoscript/src/stdlib/collections.ts#setGlobal [status=implemented hash=013379df77d2]
    public static func setGlobal(_ builtins: Builtins) -> Native {
        defineAccessor(builtins.Set, "size", get: { thisVal in
            .number(Double(try receiver(SetObj.self, thisVal, "Set.prototype.size").table.size))
        })
        methods(builtins, builtins.Set, [
            Method("has", 1) { thisVal, args, _, _ in .bool(try receiver(SetObj.self, thisVal, "Set.prototype.has").table.has(args.first ?? .undefined)) },
            Method("add", 1) { thisVal, args, _, _ in
                let s = try receiver(SetObj.self, thisVal, "Set.prototype.add")
                s.table.add(args.first ?? .undefined)
                return .object(s)
            },
            Method("delete", 1) { thisVal, args, _, _ in .bool(try receiver(SetObj.self, thisVal, "Set.prototype.delete").table.delete(args.first ?? .undefined)) },
            Method("clear", 0) { thisVal, _, _, _ in try receiver(SetObj.self, thisVal, "Set.prototype.clear").table.clear(); return .undefined },
            Method("keys", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .set(try receiver(SetObj.self, thisVal, "Set.prototype.keys")), kind: .values))
            },
            Method("values", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .set(try receiver(SetObj.self, thisVal, "Set.prototype.values")), kind: .values))
            },
            Method("entries", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .set(try receiver(SetObj.self, thisVal, "Set.prototype.entries")), kind: .entries))
            },
            Method("forEach", 1) { thisVal, args, _, eval in
                let s = try receiver(SetObj.self, thisVal, "Set.prototype.forEach")
                let cb = try requireCallback(args.first ?? .undefined, "Set.prototype.forEach")
                let thisArg = args.count > 1 ? args[1] : .undefined
                for item in s.table.liveKeys() {
                    _ = try await eval.callCallable(.object(cb), thisValue: thisArg, args: [item, item, thisVal], site: nil)
                }
                return .undefined
            },
        ])
        if case .object(let valuesFn as Native) = getOwn(builtins.Set, "values") {
            iteratorMethods(builtins, builtins.Set, valuesFn)
        }
        return constructor(builtins, builtins.Set, NativeOptions(
            name: "Set",
            length: 0,
            call: requiresNew("Set"),
            construct: { args, _, eval in
                let s = SetObj(proto: builtins.Set)
                if let first = args.first, !first.isNullish {
                    for item in try await eval.collectIterable(first) { s.table.add(item) }
                }
                return .object(s)
            }
        ))
    }

    // parity: psychoscript/src/stdlib/collections.ts#weakMapGlobal [status=implemented hash=2a9e03b3ce4a]
    public static func weakMapGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.WeakMap, [
            Method("get", 1) { thisVal, args, _, _ in
                let wm = try receiver(WeakMapObj.self, thisVal, "WeakMap.prototype.get")
                guard case .object(let obj) = args.first else { return .undefined }
                return wm.get(obj)
            },
            Method("has", 1) { thisVal, args, _, _ in
                let wm = try receiver(WeakMapObj.self, thisVal, "WeakMap.prototype.has")
                guard case .object(let obj) = args.first else { return .bool(false) }
                return .bool(wm.has(obj))
            },
            Method("set", 2) { thisVal, args, _, _ in
                let wm = try receiver(WeakMapObj.self, thisVal, "WeakMap.prototype.set")
                let k = try weakKey(args.first ?? .undefined, method: "WeakMap.prototype.set")
                wm.set(k, args.count > 1 ? args[1] : .undefined)
                return .object(wm)
            },
            Method("delete", 1) { thisVal, args, _, _ in
                let wm = try receiver(WeakMapObj.self, thisVal, "WeakMap.prototype.delete")
                guard case .object(let obj) = args.first else { return .bool(false) }
                return .bool(wm.delete(obj))
            },
        ])
        return constructor(builtins, builtins.WeakMap, NativeOptions(
            name: "WeakMap",
            length: 0,
            call: requiresNew("WeakMap"),
            construct: { args, _, eval in
                let wm = WeakMapObj(proto: builtins.WeakMap)
                if let first = args.first, !first.isNullish {
                    for entry in try await eval.collectIterable(first) {
                        let pair = try await eval.collectIterable(entry)
                        let k = try weakKey(pair.first ?? .undefined, method: "WeakMap")
                        wm.set(k, pair.count > 1 ? pair[1] : .undefined)
                    }
                }
                return .object(wm)
            }
        ))
    }

    // parity: psychoscript/src/stdlib/collections.ts#weakSetGlobal [status=implemented hash=5d66f7d8f071]
    public static func weakSetGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.WeakSet, [
            Method("has", 1) { thisVal, args, _, _ in
                let ws = try receiver(WeakSetObj.self, thisVal, "WeakSet.prototype.has")
                guard case .object(let obj) = args.first else { return .bool(false) }
                return .bool(ws.has(obj))
            },
            Method("add", 1) { thisVal, args, _, _ in
                let ws = try receiver(WeakSetObj.self, thisVal, "WeakSet.prototype.add")
                let k = try weakKey(args.first ?? .undefined, method: "WeakSet.prototype.add")
                ws.add(k)
                return .object(ws)
            },
            Method("delete", 1) { thisVal, args, _, _ in
                let ws = try receiver(WeakSetObj.self, thisVal, "WeakSet.prototype.delete")
                guard case .object(let obj) = args.first else { return .bool(false) }
                return .bool(ws.delete(obj))
            },
        ])
        return constructor(builtins, builtins.WeakSet, NativeOptions(
            name: "WeakSet",
            length: 0,
            call: requiresNew("WeakSet"),
            construct: { args, _, eval in
                let ws = WeakSetObj(proto: builtins.WeakSet)
                if let first = args.first, !first.isNullish {
                    for item in try await eval.collectIterable(first) {
                        ws.add(try weakKey(item, method: "WeakSet"))
                    }
                }
                return .object(ws)
            }
        ))
    }

    // MARK: URL, URLSearchParams, Headers, URI (src/language/stdlib/url.ts, headers.ts)

    // parity: psychoscript/src/stdlib/url.ts#PairsInto [status=implemented hash=3f14eeb0abba]
    public typealias PairsInto = [(String, String)]

    // parity: psychoscript/src/stdlib/url.ts#readPairs [status=implemented hash=e094046908d2]
    public static func readPairs(_ value: Value, eval: Evaluator) async throws -> PairsInto {
        if value.isNullish { return [] }
        if case .string(let s) = value { return parseQueryString(s.toWellFormedString()) }
        if case .object(let sp as URLSearchParamsObj) = value { return sp.pairs }
        if case .object(let h as HeadersObj) = value { return h.sortedEntries() }
        if case .object(let arr as Arr) = value {
            var out: PairsInto = []
            for item in arr.items {
                let pair = try await eval.collectIterable(item)
                guard pair.count == 2 else { throw typeError("Expected key-value pair of length 2.") }
                out.append((coerceToString(pair[0]).toWellFormedString(), coerceToString(pair[1]).toWellFormedString()))
            }
            return out
        }
        if case .object(let obj) = value {
            return entries(obj).map { ($0.0.toWellFormedString(), coerceToString($0.1).toWellFormedString()) }
        }
        return parseQueryString(coerceToString(value).toWellFormedString())
    }

    // parity: psychoscript/src/stdlib/url.ts#buildPairs [status=implemented hash=28e44d0502a6]
    public static func buildPairs(_ pairs: PairsInto) -> String {
        pairs.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
    }

    // parity: psychoscript/src/stdlib/url.ts#attempt [status=implemented hash=9030dd6e8b84]
    public static func attempt<T>(_ body: () throws -> T) -> T? {
        try? body()
    }

    // parity: psychoscript/src/stdlib/url.ts#pairsForEach [status=implemented hash=ccdd60d9469e]
    public static func pairsForEach(
        _ pairs: PairsInto,
        thisVal: Value,
        cb: Callable,
        thisArg: Value,
        eval: Evaluator
    ) async throws {
        for (k, v) in pairs {
            _ = try await eval.callCallable(.object(cb), thisValue: thisArg, args: [.string(JSString(v)), .string(JSString(k)), thisVal], site: nil)
        }
    }

    // parity: psychoscript/src/stdlib/url.ts#uriGlobal [status=implemented hash=804f855de773]
    public static func uriGlobal(_ builtins: Builtins, _ name: String) -> Native {
        nativeFn(builtins, name: name, length: 1) { _, args, _, _ in
            let str = coerceToString(args.first ?? .undefined)
            switch name {
            case "encodeURIComponent":
                guard let encoded = percentEncodeUTF16(str, preserveURIReserved: false) else {
                    throw uriError("\(name) received malformed URI data: String contained an illegal UTF-16 sequence.")
                }
                return .string(encoded)
            case "encodeURI":
                guard let encoded = percentEncodeUTF16(str, preserveURIReserved: true) else {
                    throw uriError("\(name) received malformed URI data: String contained an illegal UTF-16 sequence.")
                }
                return .string(encoded)
            case "decodeURIComponent", "decodeURI":
                // Upstream appends the host engine's own message (JavaScriptCore: "URI error").
                guard let decoded = percentDecodeUTF16(str, preserveURIReserved: name == "decodeURI") else {
                    throw uriError("\(name) received malformed URI data: URI error")
                }
                return .string(decoded)
            default:
                return .string(str)
            }
        }
    }

    // parity: psychoscript/src/stdlib/url.ts#urlSearchParamsGlobal [status=implemented hash=cb2c93e44360]
    public static func urlSearchParamsGlobal(_ builtins: Builtins) -> Native {
        defineAccessor(builtins.URLSearchParams, "size", get: { thisVal in
            .number(Double(try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.size").pairs.count))
        })
        methods(builtins, builtins.URLSearchParams, [
            Method("get", 1) { thisVal, args, _, _ in
                let sp = try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.get")
                let key = coerceToString(args.first ?? .undefined).toWellFormedString()
                return sp.pairs.first { $0.0 == key }.map { .string(JSString($0.1)) } ?? .null
            },
            Method("getAll", 1) { thisVal, args, _, _ in
                let sp = try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.getAll")
                let key = coerceToString(args.first ?? .undefined).toWellFormedString()
                return .object(Arr(proto: builtins.Array, items: sp.pairs.filter { $0.0 == key }.map { .string(JSString($0.1)) }))
            },
            Method("has", 1) { thisVal, args, _, _ in
                let sp = try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.has")
                let key = coerceToString(args.first ?? .undefined).toWellFormedString()
                return .bool(sp.pairs.contains { $0.0 == key })
            },
            Method("set", 2) { thisVal, args, _, _ in
                let sp = try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.set")
                let key = coerceToString(args.first ?? .undefined).toWellFormedString()
                let val = coerceToString(args.count > 1 ? args[1] : .undefined).toWellFormedString()
                var list = sp.pairs
                var replaced = false
                var next: [(String, String)] = []
                for (k, v) in list {
                    if k == key {
                        if !replaced { next.append((key, val)); replaced = true }
                    } else {
                        next.append((k, v))
                    }
                }
                if !replaced { next.append((key, val)) }
                list = next
                sp.pairs = list
                return .undefined
            },
            Method("append", 2) { thisVal, args, _, _ in
                let sp = try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.append")
                sp.pairs.append((coerceToString(args.first ?? .undefined).toWellFormedString(), coerceToString(args.count > 1 ? args[1] : .undefined).toWellFormedString()))
                return .undefined
            },
            Method("delete", 1) { thisVal, args, _, _ in
                let sp = try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.delete")
                let key = coerceToString(args.first ?? .undefined).toWellFormedString()
                sp.pairs = sp.pairs.filter { $0.0 != key }
                return .undefined
            },
            Method("sort", 0) { thisVal, _, _, _ in
                let sp = try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.sort")
                sp.pairs = sp.pairs.sorted { compareText($0.0, $1.0) < 0 }
                return .undefined
            },
            Method("keys", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .searchParams(try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.keys")), kind: .keys))
            },
            Method("values", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .searchParams(try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.values")), kind: .values))
            },
            Method("entries", 0) { thisVal, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .searchParams(try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.entries")), kind: .entries))
            },
            Method("forEach", 1) { thisVal, args, _, eval in
                let sp = try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.forEach")
                let cb = try requireCallback(args.first ?? .undefined, "URLSearchParams.prototype.forEach")
                try await pairsForEach(sp.pairs, thisVal: thisVal, cb: cb, thisArg: args.count > 1 ? args[1] : .undefined, eval: eval)
                return .undefined
            },
            Method("toString", 0) { thisVal, _, _, _ in
                .string(try receiver(URLSearchParamsObj.self, thisVal, "URLSearchParams.prototype.toString").jsToString())
            },
        ])
        if case .object(let entriesFn as Native) = getOwn(builtins.URLSearchParams, "entries") {
            iteratorMethods(builtins, builtins.URLSearchParams, entriesFn)
        }
        return constructor(builtins, builtins.URLSearchParams, NativeOptions(
            name: "URLSearchParams",
            length: 0,
            call: requiresNew("URLSearchParams"),
            construct: { args, _, eval in
                let pairs = try await readPairs(args.first ?? .undefined, eval: eval)
                return .object(URLSearchParamsObj(proto: builtins.URLSearchParams, pairs: pairs))
            }
        ))
    }

    // parity: psychoscript/src/stdlib/url.ts#urlGlobal [status=implemented hash=dabbd0472e1c]
    public static func urlGlobal(_ builtins: Builtins) -> Native {
        defineAccessor(builtins.URL, "href", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.href").href)) })
        defineAccessor(builtins.URL, "origin", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.origin").origin)) })
        defineAccessor(builtins.URL, "protocol", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.protocol").protocolStr)) })
        defineAccessor(builtins.URL, "username", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.username").username)) })
        defineAccessor(builtins.URL, "password", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.password").password)) })
        defineAccessor(builtins.URL, "host", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.host").host)) })
        defineAccessor(builtins.URL, "hostname", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.hostname").hostname)) })
        defineAccessor(builtins.URL, "port", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.port").port)) })
        defineAccessor(builtins.URL, "pathname", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.pathname").pathname)) }, set: { tv, v in
            try receiver(URLObj.self, tv, "URL.pathname").pathname = coerceToString(v).toWellFormedString()
        })
        defineAccessor(builtins.URL, "search", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.search").search)) })
        defineAccessor(builtins.URL, "searchParams", get: { .object(try receiver(URLObj.self, $0, "URL.searchParams").searchParams) })
        defineAccessor(builtins.URL, "hash", get: { .string(JSString(try receiver(URLObj.self, $0, "URL.hash").hashStr)) }, set: { tv, v in
            let s = coerceToString(v).toWellFormedString()
            try receiver(URLObj.self, tv, "URL.hash").hashStr = s.isEmpty || s.hasPrefix("#") ? s : "#\(s)"
        })
        methods(builtins, builtins.URL, [
            Method("toString", 0) { tv, _, _, _ in .string(JSString(try receiver(URLObj.self, tv, "URL.prototype.toString").href)) },
            Method("toJSON", 0) { tv, _, _, _ in .string(JSString(try receiver(URLObj.self, tv, "URL.prototype.toJSON").href)) },
        ])
        let ctor = constructor(builtins, builtins.URL, NativeOptions(
            name: "URL",
            length: 1,
            call: requiresNew("URL"),
            construct: { args, _, _ in
                let raw = coerceToString(args.first ?? .undefined).toWellFormedString()
                let base = args.count > 1 && !args[1].isUndefined ? coerceToString(args[1]).toWellFormedString() : nil
                guard let parsed = parseURL(raw, base: base, builtins: builtins) else {
                    throw typeError("Invalid URL: \(raw)")
                }
                return .object(parsed)
            }
        ))
        methods(builtins, ctor, [
            Method("parse", 1) { _, args, _, _ in
                let raw = coerceToString(args.first ?? .undefined).toWellFormedString()
                let base = args.count > 1 && !args[1].isUndefined ? coerceToString(args[1]).toWellFormedString() : nil
                return parseURL(raw, base: base, builtins: builtins).map { .object($0) } ?? .null
            },
            Method("canParse", 1) { _, args, _, _ in
                let raw = coerceToString(args.first ?? .undefined).toWellFormedString()
                let base = args.count > 1 && !args[1].isUndefined ? coerceToString(args[1]).toWellFormedString() : nil
                return .bool(parseURL(raw, base: base, builtins: builtins) != nil)
            },
        ])
        return ctor
    }

    // parity: psychoscript/src/stdlib/headers.ts#headersGlobal [status=implemented hash=8096552cd2a4]
    public static func headersGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Headers, [
            Method("get", 1) { tv, args, _, _ in
                let h = try receiver(HeadersObj.self, tv, "Headers.prototype.get")
                return h.getHeader(coerceToString(args.first ?? .undefined).toWellFormedString()).map { .string(JSString($0)) } ?? .null
            },
            Method("has", 1) { tv, args, _, _ in
                .bool(try receiver(HeadersObj.self, tv, "Headers.prototype.has").hasHeader(coerceToString(args.first ?? .undefined).toWellFormedString()))
            },
            Method("set", 2) { tv, args, _, _ in
                try receiver(HeadersObj.self, tv, "Headers.prototype.set").setHeader(coerceToString(args.first ?? .undefined).toWellFormedString(), coerceToString(args.count > 1 ? args[1] : .undefined).toWellFormedString())
                return .undefined
            },
            Method("append", 2) { tv, args, _, _ in
                try receiver(HeadersObj.self, tv, "Headers.prototype.append").appendHeader(coerceToString(args.first ?? .undefined).toWellFormedString(), coerceToString(args.count > 1 ? args[1] : .undefined).toWellFormedString())
                return .undefined
            },
            Method("delete", 1) { tv, args, _, _ in
                try receiver(HeadersObj.self, tv, "Headers.prototype.delete").deleteHeader(coerceToString(args.first ?? .undefined).toWellFormedString())
                return .undefined
            },
            Method("keys", 0) { tv, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .headers(try receiver(HeadersObj.self, tv, "Headers.prototype.keys")), kind: .keys))
            },
            Method("values", 0) { tv, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .headers(try receiver(HeadersObj.self, tv, "Headers.prototype.values")), kind: .values))
            },
            Method("entries", 0) { tv, _, _, _ in
                .object(positionIterator(proto: builtins.Iterator, arrayProto: builtins.Array, source: .headers(try receiver(HeadersObj.self, tv, "Headers.prototype.entries")), kind: .entries))
            },
            Method("forEach", 1) { tv, args, _, eval in
                let h = try receiver(HeadersObj.self, tv, "Headers.prototype.forEach")
                let cb = try requireCallback(args.first ?? .undefined, "Headers.prototype.forEach")
                try await pairsForEach(h.sortedEntries(), thisVal: tv, cb: cb, thisArg: args.count > 1 ? args[1] : .undefined, eval: eval)
                return .undefined
            },
        ])
        if case .object(let entriesFn as Native) = getOwn(builtins.Headers, "entries") {
            iteratorMethods(builtins, builtins.Headers, entriesFn)
        }
        return constructor(builtins, builtins.Headers, NativeOptions(
            name: "Headers",
            length: 0,
            call: requiresNew("Headers"),
            construct: { args, _, eval in
                let h = HeadersObj(proto: builtins.Headers)
                if let first = args.first, !first.isNullish {
                    for (k, v) in try await readPairs(first, eval: eval) {
                        h.appendHeader(k, v)
                    }
                }
                return .object(h)
            }
        ))
    }

    // MARK: Bytes, Buffer, TextEncoder, TextDecoder, Iterator, Web

    // parity: psychoscript/src/stdlib/bytes.ts#finishBytes [status=implemented hash=1ed02436cbbd]
    public static func finishBytes(_ builtins: Builtins, _ bytes: [UInt8]) -> Bytes {
        Bytes(proto: builtins.Uint8Array, data: bytes)
    }

    static let base64Alphabets = ["base64", "base64url"]
    static let lastChunkHandlings = ["loose", "strict", "stop-before-partial"]

    static func base64Options(_ value: Value, _ name: String) throws -> Obj? {
        switch value {
        case .undefined: return nil
        case .object(let obj): return obj
        default: throw typeError("\(name) requires that options be an object.")
        }
    }

    /// A string option of the base64 methods: one of `allowed`, defaulting to the first.
    static func base64Option(_ options: Obj?, _ key: String, _ allowed: [String], _ name: String) throws -> String {
        let value = options.map { get($0, JSString(key)) } ?? .undefined
        if value.isUndefined { return allowed[0] }
        if case .string(let s) = value, let wf = s.wellFormedString, allowed.contains(wf) { return wf }
        throw typeError("\(name) requires that \(key) be \(allowed.map { "\"\($0)\"" }.joined(separator: " or ")).")
    }

    /// ToUint8: what a Uint8Array stores for a number.
    static func toUint8(_ value: Value) -> UInt8 {
        let n = coerceToNumber(value)
        guard n.isFinite else { return 0 }
        return UInt8(truncatingIfNeeded: Int64(n.truncatingRemainder(dividingBy: 256)))
    }

    /// Uint8Array.prototype.toBase64 with its `alphabet` and `omitPadding` options.
    static func encodeBase64(_ bytes: [UInt8], alphabet: String, omitPadding: Bool) -> String {
        var text = bytesToBase64(bytes)
        if alphabet == "base64url" {
            text = String(text.map { $0 == "+" ? "-" : $0 == "/" ? "_" : $0 })
        }
        if omitPadding {
            while text.hasSuffix("=") { text.removeLast() }
        }
        return text
    }

    /// Uint8Array.fromBase64 (FromBase64 in the TC39 proposal): whitespace is skipped, only the chosen alphabet is
    /// accepted, and `lastChunkHandling` decides what an unpadded or partial last chunk means.
    static func decodeBase64(_ text: String, alphabet: String, lastChunkHandling: String) throws -> [UInt8] {
        struct Invalid: Error {}
        func value(_ c: UInt8) -> UInt32? {
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): return UInt32(c - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return UInt32(c - UInt8(ascii: "a") + 26)
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(c - UInt8(ascii: "0") + 52)
            case UInt8(ascii: "+"): return alphabet == "base64" ? 62 : nil
            case UInt8(ascii: "/"): return alphabet == "base64" ? 63 : nil
            case UInt8(ascii: "-"): return alphabet == "base64url" ? 62 : nil
            case UInt8(ascii: "_"): return alphabet == "base64url" ? 63 : nil
            default: return nil
            }
        }
        func isSpace(_ c: UInt8) -> Bool { c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20 }
        // Decodes a 2-4 character chunk; strict mode rejects nonzero bits a short chunk leaves unused.
        func decodeChunk(_ chunk: [UInt32], strict: Bool) throws -> [UInt8] {
            var padded = chunk
            while padded.count < 4 { padded.append(0) }
            let triple = (padded[0] << 18) | (padded[1] << 12) | (padded[2] << 6) | padded[3]
            let bytes = [UInt8((triple >> 16) & 0xFF), UInt8((triple >> 8) & 0xFF), UInt8(triple & 0xFF)]
            switch chunk.count {
            case 2:
                if strict && bytes[1] != 0 { throw Invalid() }
                return [bytes[0]]
            case 3:
                if strict && bytes[2] != 0 { throw Invalid() }
                return [bytes[0], bytes[1]]
            default:
                return bytes
            }
        }
        let input = Array(text.utf8)
        var out: [UInt8] = []
        var chunk: [UInt32] = []
        var index = 0
        while true {
            while index < input.count && isSpace(input[index]) { index += 1 }
            if index == input.count {
                if chunk.isEmpty { return out }
                if lastChunkHandling == "stop-before-partial" { return out }
                if lastChunkHandling == "strict" || chunk.count == 1 { throw Invalid() }
                out += try decodeChunk(chunk, strict: false)
                return out
            }
            let c = input[index]
            index += 1
            if c == UInt8(ascii: "=") {
                if chunk.count < 2 { throw Invalid() }
                while index < input.count && isSpace(input[index]) { index += 1 }
                if chunk.count == 2 {
                    if index == input.count {
                        if lastChunkHandling == "stop-before-partial" { return out }
                        throw Invalid()
                    }
                    guard input[index] == UInt8(ascii: "=") else { throw Invalid() }
                    index += 1
                    while index < input.count && isSpace(input[index]) { index += 1 }
                }
                if index < input.count { throw Invalid() }
                out += try decodeChunk(chunk, strict: lastChunkHandling == "strict")
                return out
            }
            guard let v = value(c) else { throw Invalid() }
            chunk.append(v)
            if chunk.count == 4 {
                out += try decodeChunk(chunk, strict: false)
                chunk.removeAll()
            }
        }
    }

    // parity: psychoscript/src/stdlib/bytes.ts#uint8ArrayGlobal [status=implemented hash=f95618097514]
    public static func uint8ArrayGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Uint8Array, [
            Method("subarray", 2) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.subarray")
                let s = args.first.map { resolveSliceIndex(coerceToInteger($0), length: b.length) } ?? 0
                let e = args.count > 1 && !args[1].isUndefined ? resolveSliceIndex(coerceToInteger(args[1]), length: b.length) : b.length
                // A view sharing the receiver's memory.
                return .object(b.view(builtins, start: s, end: max(s, e)))
            },
            Method("slice", 2) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.slice")
                let s = args.first.map { resolveSliceIndex(coerceToInteger($0), length: b.data.count) } ?? 0
                let e = args.count > 1 && !args[1].isUndefined ? resolveSliceIndex(coerceToInteger(args[1]), length: b.data.count) : b.data.count
                return .object(b.derive(builtins, s < e ? Array(b.data[s..<e]) : []))
            },
            Method("map", 1) { tv, args, _, eval in
                // A Uint8Array of the callback's values, of the same kind as the receiver: a Buffer's map makes a Buffer.
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.map")
                let cb = try requireCallback(args.first ?? .undefined, "Uint8Array.prototype.map")
                let thisArg = args.count > 1 ? args[1] : .undefined
                var out: [UInt8] = []
                for (index, byte) in b.data.enumerated() {
                    let mapped = try await eval.callCallable(.object(cb), thisValue: thisArg, args: [.number(Double(byte)), .number(Double(index)), tv], site: nil)
                    out.append(toUint8(mapped))
                }
                return .object(b.derive(builtins, out))
            },
            Method("filter", 1) { tv, args, _, eval in
                let b = try receiver(Bytes.self, tv, "Uint8Array.prototype.filter")
                let cb = try requireCallback(args.first ?? .undefined, "Uint8Array.prototype.filter")
                let thisArg = args.count > 1 ? args[1] : .undefined
                var out: [UInt8] = []
                for (index, byte) in b.data.enumerated() {
                    let keep = try await eval.callCallable(.object(cb), thisValue: thisArg, args: [.number(Double(byte)), .number(Double(index)), tv], site: nil)
                    if keep.isTruthy { out.append(byte) }
                }
                return .object(b.derive(builtins, out))
            },
            Method("toBase64", 0) { tv, args, _, eval in
                let bytes = try receiver(Bytes.self, tv, "Uint8Array.prototype.toBase64").data
                return try await withReads(eval) {
                    let options = try base64Options(args.first ?? .undefined, "Uint8Array.prototype.toBase64")
                    let alphabet = try base64Option(options, "alphabet", base64Alphabets, "Uint8Array.prototype.toBase64")
                    let omitPadding = options.map { get($0, "omitPadding").isTruthy } ?? false
                    return .string(JSString(encodeBase64(bytes, alphabet: alphabet, omitPadding: omitPadding)))
                }
            },
            Method("toHex", 0) { tv, _, _, _ in
                let d = try receiver(Bytes.self, tv, "Uint8Array.prototype.toHex").data
                return .string(JSString(d.map { String(format: "%02x", $0) }.joined()))
            },
        ])
        let ctor = constructor(builtins, builtins.Uint8Array, NativeOptions(
            name: "Uint8Array",
            length: 3,
            call: requiresNew("Uint8Array"),
            construct: { args, _, eval in
                guard let first = args.first else { return .object(finishBytes(builtins, [])) }
                if case .number(let n) = first {
                    let len = max(0, Int(n))
                    try checkArrayLength(len)
                    return .object(finishBytes(builtins, Array(repeating: 0, count: len)))
                }
                if case .object(let other as Bytes) = first {
                    return .object(finishBytes(builtins, other.data))
                }
                let items = try await eval.collectIterable(first)
                return .object(finishBytes(builtins, items.map { UInt8(truncatingIfNeeded: coerceToInteger($0)) }))
            }
        ))
        methods(builtins, ctor, [
            Method("fromBase64", 1) { _, args, _, eval in
                guard case .string(let text) = args.first ?? .undefined else {
                    throw typeError("Uint8Array.fromBase64 expects a string.")
                }
                return try await withReads(eval) {
                    let options = try base64Options(args.count > 1 ? args[1] : .undefined, "Uint8Array.fromBase64")
                    let alphabet = try base64Option(options, "alphabet", base64Alphabets, "Uint8Array.fromBase64")
                    let lastChunkHandling = try base64Option(options, "lastChunkHandling", lastChunkHandlings, "Uint8Array.fromBase64")
                    do {
                        guard let wf = text.wellFormedString else { throw syntaxError("Uint8Array.fromBase64: the string is not valid base64.") }
                        return .object(finishBytes(builtins, try decodeBase64(wf, alphabet: alphabet, lastChunkHandling: lastChunkHandling)))
                    } catch {
                        throw syntaxError("Uint8Array.fromBase64: the string is not valid base64.")
                    }
                }
            },
        ])
        define(ctor, "BYTES_PER_ELEMENT", .number(1), frozen)
        define(builtins.Uint8Array, "BYTES_PER_ELEMENT", .number(1), frozen)
        return ctor
    }

    /// The bytes `Buffer.from(...)` and `Buffer(...)` make from a non-string, non-Uint8Array source: an array, the
    /// `{ type: "Buffer", data }` form `toJSON` gives, or an array-like object. Under `withReads`.
    static func bufferBytes(_ value: Value, eval: Evaluator) async throws -> [UInt8] {
        if case .object(let arr as Arr) = value { return arr.items.map(toUint8) }
        if case .object(let obj) = value {
            let data = get(obj, "data")
            let type = get(obj, "type")
            // `type` and `data` decide the path, so a getter among them is read before `length` could be.
            if readsPending() { return [] }
            if case .string("Buffer") = type, case .object(let items as Arr) = data { return items.items.map(toUint8) }
            if case .number(let n) = get(obj, "length") {
                let count = max(0, n.isFinite ? Int(n) : 0)
                try checkArrayLength(count)
                return (0..<count).map { toUint8(get(obj, JSString(String($0)))) }
            }
            if !readsPending(), (try? requireIteratorMethod(value)) != nil {
                return try await eval.collectIterable(value).map(toUint8)
            }
        }
        throw typeError("The first argument must be of type string or an instance of Buffer, Uint8Array, or Array or an Array-like Object. Received \(describeValue(value))")
    }

    // parity: psychoscript/src/stdlib/buffer.ts#bufferGlobal [status=implemented hash=aca9f38f2fab]
    public static func bufferGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Buffer, [
            Method("toString", 1) { tv, args, _, _ in
                let b = try receiver(Bytes.self, tv, "Buffer.prototype.toString")
                let enc = (args.first.map { $0.isUndefined ? "utf8" : coerceToString($0).toWellFormedString() } ?? "utf8").lowercased()
                switch enc {
                case "base64": return .string(JSString(bytesToBase64(b.data)))
                case "hex": return .string(JSString(b.data.map { String(format: "%02x", $0) }.joined()))
                default: return .string(JSString(String(decoding: b.data, as: UTF8.self)))
                }
            },
        ])
        let bytesFrom: @Sendable ([Value], Evaluator) async throws -> [UInt8] = { args, eval in
            let first = args.first ?? .undefined
            if case .string(let s) = first {
                let enc = (args.count > 1 && !args[1].isUndefined ? coerceToString(args[1]).toWellFormedString() : "utf8").lowercased()
                if enc == "base64" { return (try? base64ToBytes(s.toWellFormedString())) ?? [] }
                return s.utf8BytesReplacingSurrogates()
            }
            if case .object(let b as Bytes) = first {
                let data = b.data
                let offset = args.count > 1 && !args[1].isUndefined ? resolveSliceIndex(coerceToInteger(args[1]), length: data.count) : 0
                var end = data.count
                if args.count > 2 && !args[2].isUndefined {
                    end = min(data.count, offset + max(0, coerceToInteger(args[2])))
                }
                return offset < end ? Array(data[offset..<end]) : []
            }
            return try await bufferBytes(first, eval: eval)
        }
        let ctor = constructor(builtins, builtins.Buffer, NativeOptions(
            name: "Buffer",
            length: 2,
            call: { _, args, _, eval in
                try await withReads(eval) { .object(BufferObj(proto: builtins.Buffer, data: try await bytesFrom(args, eval))) }
            },
            construct: { args, newTarget, eval in
                try await withReads(eval) {
                    .object(BufferObj(proto: prototypeFrom(newTarget, fallback: builtins.Buffer), data: try await bytesFrom(args, eval)))
                }
            }
        ))
        // Bun inherits this from Uint8Array; Buffer's constructor here does not.
        define(ctor, "BYTES_PER_ELEMENT", .number(1), frozen)
        methods(builtins, ctor, [
            Method("from", 3) { _, args, _, eval in
                try await withReads(eval) { .object(BufferObj(proto: builtins.Buffer, data: try await bytesFrom(args, eval))) }
            },
            Method("concat", 1) { _, args, _, eval in
                let list = try await eval.collectIterable(args.first ?? .undefined)
                var out: [UInt8] = []
                for item in list {
                    if case .object(let b as Bytes) = item { out.append(contentsOf: b.data) }
                }
                return .object(BufferObj(proto: builtins.Buffer, data: out))
            },
            Method("isBuffer", 1) { _, args, _, _ in
                if case .object(let o) = args.first { return .bool(o is BufferObj) }
                return .bool(false)
            },
        ])
        return ctor
    }

    // parity: psychoscript/src/stdlib/bytes.ts#textEncoderGlobal [status=implemented hash=b0291f2a4760]
    public static func textEncoderGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.TextEncoder, [
            Method("encode", 1) { _, args, _, _ in
                let str: JSString = args.first.map { $0.isUndefined ? "" : coerceToString($0) } ?? ""
                return .object(finishBytes(builtins, str.utf8BytesReplacingSurrogates()))
            },
        ])
        return constructor(builtins, builtins.TextEncoder, NativeOptions(
            name: "TextEncoder",
            length: 0,
            call: requiresNew("TextEncoder"),
            construct: { _, _, _ in
                let enc = Obj(proto: builtins.TextEncoder)
                define(enc, "encoding", .string("utf-8"), readonly)
                return .object(enc)
            }
        ))
    }

    // parity: psychoscript/src/stdlib/bytes.ts#textDecoderGlobal [status=implemented hash=3351760fd92f]
    public static func textDecoderGlobal(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.TextDecoder, [
            Method("decode", 0) { tv, args, _, eval in
                let dec = try receiver(TextDecoderObj.self, tv, "TextDecoder.prototype.decode")
                let first = args.first ?? .undefined
                var bytes: [UInt8] = []
                switch first {
                case .undefined: break
                case .object(let b as Bytes): bytes = b.data
                default: throw typeError("TextDecoder.decode expects a Uint8Array, received \(describeValue(first)).")
                }
                let options = args.count > 1 ? args[1] : .undefined
                switch options {
                case .undefined, .object, .null: break
                default: throw typeError("TextDecoder.decode expects an options object.")
                }
                return try await withReads(eval) {
                    let stream: Bool = if case .object(let opts) = options { get(opts, "stream").isTruthy } else { false }
                    if readsPending() { return .undefined }
                    return .string(JSString(try dec.decode(bytes, stream: stream)))
                }
            },
        ])
        return constructor(builtins, builtins.TextDecoder, NativeOptions(
            name: "TextDecoder",
            length: 0,
            call: requiresNew("TextDecoder"),
            construct: { args, _, eval in
                let enc = args.first.map { $0.isUndefined ? "utf-8" : coerceToString($0).toWellFormedString().lowercased() } ?? "utf-8"
                return try await withReads(eval) {
                    var fatal = false
                    var ignoreBOM = false
                    if args.count > 1, case .object(let opts) = args[1] {
                        fatal = get(opts, "fatal").isTruthy
                        ignoreBOM = get(opts, "ignoreBOM").isTruthy
                    }
                    return .object(TextDecoderObj(proto: builtins.TextDecoder, encoding: enc, fatal: fatal, ignoreBOM: ignoreBOM))
                }
            }
        ))
    }

    // parity: psychoscript/src/stdlib/iterator.ts#iteratorGlobals [status=implemented hash=f36edece5f13]
    public static func iteratorGlobals(_ builtins: Builtins) -> Native {
        methods(builtins, builtins.Iterator, [
            Method("next", 0) { tv, _, _, _ in
                let it = try receiver(IteratorObj.self, tv, "Iterator.prototype.next")
                let step = try it.cursor.next()
                return .object(iteratorResult(builtins, value: step.value, done: step.done))
            },
            Method("toArray", 0) { tv, _, _, eval in
                let items = try await eval.collectIterable(tv)
                return .object(Arr(proto: builtins.Array, items: items))
            },
        ])
        define(builtins.Iterator, .symbol(IteratorSymbol), .object(nativeFn(builtins, name: "[Symbol.iterator]") { tv, _, _, _ in tv }), hidden)
        return constructor(builtins, builtins.Iterator, NativeOptions(
            name: "Iterator",
            length: 0,
            call: requiresNew("Iterator")
        ))
    }

    // parity: psychoscript/src/stdlib/web.ts#base64Global [status=implemented hash=facf121722e7]
    public static func base64Global(_ builtins: Builtins, _ name: String) -> Native {
        nativeFn(builtins, name: name, length: 1) { _, args, _, _ in
            let str = coerceToString(args.first ?? .undefined)
            if name == "btoa" {
                let units = str.utf16Units
                var bytes: [UInt8] = []
                bytes.reserveCapacity(units.count)
                for u in units {
                    guard u <= 0xFF else { throw typeError("The string contains invalid characters.") }
                    bytes.append(UInt8(u))
                }
                return .string(JSString(bytesToBase64(bytes)))
            } else {
                guard let wf = str.wellFormedString else {
                    throw typeError("The string contains invalid characters.")
                }
                do {
                    let bytes = try base64ToBytes(wf)
                    return .string(JSString(utf16: bytes.map { UInt16($0) }))
                } catch {
                    throw typeError("The string contains invalid characters.")
                }
            }
        }
    }

    // parity: psychoscript/src/stdlib/web.ts#structuredCloneGlobal [status=implemented hash=1b11a0c92d91]
    /// The clone reads program getters' values (read ahead in program code); each round starts a fresh copy.
    public static func structuredCloneGlobal(_ builtins: Builtins) -> Native {
        nativeFn(builtins, name: "structuredClone", length: 1) { _, args, _, eval in
            if args.isEmpty { throw typeError("structuredClone requires 1 argument") }
            return try await withReads(eval) {
                var memo: [ObjectIdentifier: Obj] = [:]
                return try structuredCloneValue(args[0], builtins: builtins, memo: &memo)
            }
        }
    }

    // parity: psychoscript/src/stdlib/web.ts#cryptoGlobal [status=implemented hash=cc48f06533e5]
    public static func cryptoGlobal(_ builtins: Builtins) -> Obj {
        let obj = Obj(proto: builtins.Object)
        methods(builtins, obj, [
            Method("randomUUID", 0) { _, _, _, _ in .string(JSString(OpenCodeUtil.uuid())) },
            Method("getRandomValues", 1) { _, args, _, _ in
                guard case .object(let bytes as Bytes) = args.first else {
                    throw typeError("crypto.getRandomValues expects a Uint8Array.")
                }
                var rng = SystemRandomNumberGenerator()
                bytes.data = (0..<bytes.data.count).map { _ in UInt8.random(in: 0...255, using: &rng) }
                return .object(bytes)
            },
        ])
        return obj
    }

    // MARK: Globals Registry (src/language/runtime/globals.ts)

    // parity: psychoscript/src/runtime/globals.ts#globalNames [status=implemented hash=0faefd354d32]
    public static let globalNames: Set<String> = [
        "require", "undefined", "NaN", "Infinity",
        "Object", "Function", "Array", "Math", "JSON", "console",
        "Promise", "Symbol", "Iterator", "Number", "String", "Boolean",
        "parseInt", "parseFloat", "isFinite", "isNaN",
        "Date", "RegExp", "Map", "Set", "WeakMap", "WeakSet",
        "URL", "URLSearchParams", "Headers", "Uint8Array", "Buffer",
        "TextEncoder", "TextDecoder",
        "encodeURI", "encodeURIComponent", "decodeURI", "decodeURIComponent",
        "atob", "btoa", "crypto", "structuredClone",
        "Error", "TypeError", "RangeError", "SyntaxError",
        "ReferenceError", "EvalError", "URIError", "AggregateError",
    ]

    // parity: psychoscript/src/runtime/globals.ts#globals [status=implemented hash=eba6828ee9c5]
    public static func globals(
        builtins: Builtins,
        appendLog: @escaping @Sendable (String) -> Void,
        resolveMod: @escaping @Sendable (String) throws -> Value
    ) -> [(String, Value)] {
        generatorGlobals(builtins)

        let fnProto = builtins.Function
        methods(builtins, fnProto, [
            Method("call", 1) { tv, args, site, eval in
                let target = try receiver(Callable.self, tv, "Function.prototype.call")
                return try await eval.callCallable(.object(target), thisValue: args.first ?? .undefined, args: Array(args.dropFirst()), site: site)
            },
            Method("apply", 2) { tv, args, site, eval in
                let target = try receiver(Callable.self, tv, "Function.prototype.apply")
                let argList: [Value]
                if args.count > 1, !args[1].isNullish {
                    argList = try await eval.collectIterable(args[1])
                } else {
                    argList = []
                }
                return try await eval.callCallable(.object(target), thisValue: args.first ?? .undefined, args: argList, site: site)
            },
            Method("bind", 1) { tv, args, _, eval in
                try await withReads(eval) {
                    let target = try receiver(Callable.self, tv, "Function.prototype.bind")
                    let name = get(target, "name")
                    let length = get(target, "length")
                    let shownLength: Int
                    if case .number(let n) = length, !n.isNaN {
                        shownLength = max(0, coerceToInteger(.number(n)) - max(0, args.count - 1))
                    } else {
                        shownLength = 0
                    }
                    let shownName: JSString = if case .string(let s) = name { s } else { "" }
                    return .object(BoundFn(
                        proto: builtins.Function,
                        target: target,
                        boundThis: args.first ?? .undefined,
                        boundArgs: Array(args.dropFirst()),
                        name: shownName,
                        length: shownLength
                    ))
                }
            },
        ])
        let functionCtor = constructor(builtins, builtins.Function, NativeOptions(
            name: "Function",
            length: 1,
            call: { _, _, site, _ in throw typeError("The Function constructor is not supported; write the function inline.", node: site) },
            construct: { _, _, _ in throw typeError("The Function constructor is not supported; write the function inline.") }
        ))

        let symbolCtor = native(builtins, NativeOptions(
            name: "Symbol",
            call: { _, _, site, _ in throw typeError("Symbol is not callable; only Symbol.asyncIterator and Symbol.iterator are available.", node: site) },
            callback: false
        ))
        constants(symbolCtor, [
            ("asyncIterator", .symbol(AsyncIteratorSymbol)),
            ("iterator", .symbol(IteratorSymbol)),
        ])

        let requireFn = nativeFn(builtins, name: "require", length: 1) { _, args, site, _ in
            guard case .string(let spec) = args.first else {
                throw typeError("require expects a module name string.", node: site)
            }
            return try resolveMod(spec.toWellFormedString())
        }

        var list: [(String, Value)] = [
            ("require", .object(requireFn)),
            ("undefined", .undefined),
            ("NaN", .number(.nan)),
            ("Infinity", .number(.infinity)),
            ("Object", .object(objectGlobal(builtins))),
            ("Function", .object(functionCtor)),
            ("Array", .object(arrayGlobal(builtins))),
            ("Math", .object(mathGlobal(builtins))),
            ("JSON", .object(jsonGlobal(builtins))),
            ("console", .object(consoleGlobal(builtins, appendLog: appendLog))),
            ("Promise", .object(promiseGlobal(builtins))),
            ("Symbol", .object(symbolCtor)),
            ("Iterator", .object(iteratorGlobals(builtins))),
            ("Number", .object(numberGlobal(builtins))),
            ("String", .object(stringGlobal(builtins))),
            ("Boolean", .object(booleanGlobal(builtins))),
            ("parseInt", .object(coercion(builtins, .parseInt, length: 2))),
            ("parseFloat", .object(coercion(builtins, .parseFloat))),
            ("isFinite", .object(coercion(builtins, .isFinite))),
            ("isNaN", .object(coercion(builtins, .isNaN))),
            ("Date", .object(dateGlobal(builtins))),
            ("RegExp", .object(regexpGlobal(builtins))),
            ("Map", .object(mapGlobal(builtins))),
            ("Set", .object(setGlobal(builtins))),
            ("WeakMap", .object(weakMapGlobal(builtins))),
            ("WeakSet", .object(weakSetGlobal(builtins))),
            ("URL", .object(urlGlobal(builtins))),
            ("URLSearchParams", .object(urlSearchParamsGlobal(builtins))),
            ("Headers", .object(headersGlobal(builtins))),
            ("Uint8Array", .object(uint8ArrayGlobal(builtins))),
            ("Buffer", .object(bufferGlobal(builtins))),
            ("TextEncoder", .object(textEncoderGlobal(builtins))),
            ("TextDecoder", .object(textDecoderGlobal(builtins))),
            ("encodeURI", .object(uriGlobal(builtins, "encodeURI"))),
            ("encodeURIComponent", .object(uriGlobal(builtins, "encodeURIComponent"))),
            ("decodeURI", .object(uriGlobal(builtins, "decodeURI"))),
            ("decodeURIComponent", .object(uriGlobal(builtins, "decodeURIComponent"))),
            ("atob", .object(base64Global(builtins, "atob"))),
            ("btoa", .object(base64Global(builtins, "btoa"))),
            ("crypto", .object(cryptoGlobal(builtins))),
            ("structuredClone", .object(structuredCloneGlobal(builtins))),
        ]
        for et in errorTypes {
            list.append((et.rawValue, .object(errorGlobal(et, builtins: builtins, trace: { $0.stackTrace() }))))
        }
        installStdlibExtras(builtins, globals: &list)
        return list
    }

    // MARK: - Formatting, Date & URL Helpers

    internal static func formatJSNumber(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n == .infinity { return "Infinity" }
        if n == -.infinity { return "-Infinity" }
        if n == 0 { return "0" }
        if n == n.rounded(.towardZero) && abs(n) < 1e16 {
            return String(Int64(n))
        }
        return PureJSON.stringifyCompact(.number(n))
    }

    internal static func jsonEscapeString(_ s: String) -> String {
        PureJSON.stringifyCompact(.string(s))
    }

    internal static func currentEpochMs() -> Double {
        floor(Date().timeIntervalSince1970 * 1000.0)
    }

    internal static func formatISODate(epochMs: Double) -> String {
        let comps = utcComponents(epochMs)
        let y = Int(comps.year)
        let m = Int(comps.month) + 1
        let d = Int(comps.day)
        let hh = Int(comps.hour)
        let mm = Int(comps.minute)
        let ss = Int(comps.second)
        let ms = Int(comps.millisecond)
        let yStr = y < 0 ? String(format: "-%06d", -y) : (y > 9999 ? String(format: "+%06d", y) : String(format: "%04d", y))
        return String(format: "%@-%02d-%02dT%02d:%02d:%02d.%03dZ", yStr, m, d, hh, mm, ss, ms)
    }

    internal static func utcComponents(_ epochMs: Double) -> (year: Double, month: Double, day: Double, hour: Double, minute: Double, second: Double, millisecond: Double) {
        guard epochMs.isFinite else { return (.nan, .nan, .nan, .nan, .nan, .nan, .nan) }
        let totalMs = Int64(floor(epochMs))
        let ms = Int((totalMs % 1000 + 1000) % 1000)
        let totalSec = (totalMs - Int64(ms)) / 1000
        let sec = Int((totalSec % 60 + 60) % 60)
        let totalMin = (totalSec - Int64(sec)) / 60
        let min = Int((totalMin % 60 + 60) % 60)
        let totalHr = (totalMin - Int64(min)) / 60
        let hr = Int((totalHr % 24 + 24) % 24)
        let days = (totalHr - Int64(hr)) / 24
        // Howard Hinnant civil-from-days algorithm
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        if m <= 2 { y += 1 }
        return (Double(y), Double(m - 1), Double(d), Double(hr), Double(min), Double(sec), Double(ms))
    }

    internal static func makeUTCEpochMs(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, ms: Int) -> Double {
        let adjYear = year + Int(floor(Double(month) / 12.0))
        let adjMonth = ((month % 12) + 12) % 12 + 1
        let y = adjMonth <= 2 ? adjYear - 1 : adjYear
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mPrime = adjMonth > 2 ? adjMonth - 3 : adjMonth + 9
        let doy = (153 * mPrime + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = Int64(era) * 146097 + Int64(doe) - 719468
        let totalMs = (((days * 24 + Int64(hour)) * 60 + Int64(minute)) * 60 + Int64(second)) * 1000 + Int64(ms)
        return Double(totalMs)
    }

    /// Date.parse for the ECMAScript date time string format: date-only forms are UTC, a date-time without an
    /// offset is local time, `Z` or `±HH:mm` set the offset, and out-of-range fields or times are NaN.
    internal static func parseISODate(_ s: String) -> Double {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^([+-]\d{6}|\d{4})(?:-(\d{2})(?:-(\d{2}))?)?(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|[+-]\d{2}:\d{2})?)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return .nan
        }
        let ns = text as NSString
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let yearText = group(1), let year = Int(yearText) else { return .nan }
        if yearText == "-000000" { return .nan }
        let month = group(2).flatMap { Int($0) } ?? 1
        let day = group(3).flatMap { Int($0) } ?? 1
        let hasTime = group(4) != nil
        let hour = group(4).flatMap { Int($0) } ?? 0
        let minute = group(5).flatMap { Int($0) } ?? 0
        let second = group(6).flatMap { Int($0) } ?? 0
        var ms = 0
        if let frac = group(7) { ms = Int(String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0 }
        guard (1...12).contains(month), (1...31).contains(day), (0...24).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return .nan }
        if hour == 24 && (minute != 0 || second != 0 || ms != 0) { return .nan }
        var t = makeUTCEpochMs(year: year, month: month - 1, day: day, hour: hour, minute: minute, second: second, ms: ms)
        if let offset = group(8) {
            if offset != "Z" {
                let sign: Double = offset.hasPrefix("-") ? -1 : 1
                let parts = offset.dropFirst().split(separator: ":").compactMap { Double($0) }
                guard parts.count == 2, parts[0] <= 23, parts[1] <= 59 else { return .nan }
                t -= sign * (parts[0] * 3_600_000 + parts[1] * 60_000)
            }
        } else if hasTime {
            // A date-time without an offset is local time.
            let guess = Date(timeIntervalSince1970: t / 1000)
            t -= Double(TimeZone.current.secondsFromGMT(for: guess)) * 1000
        }
        return timeClip(t)
    }

    internal static func percentEncodeUTF16(_ text: JSString, preserveURIReserved: Bool) -> JSString? {
        guard let wellFormed = text.wellFormedString else { return nil }
        return JSString(percentEncode(wellFormed, preserveURIReserved: preserveURIReserved))
    }

    internal static func percentDecodeUTF16(_ text: JSString, preserveURIReserved: Bool) -> JSString? {
        let reserved: Set<UInt8> = Set(";/?:@&=+$,#".utf8)
        let units = text.utf16Units
        let count = units.count
        var out: [UInt16] = []
        out.reserveCapacity(count)

        func readPercentByte(at pos: Int) -> UInt8? {
            guard pos + 2 < count, units[pos] == 0x25,
                  units[pos + 1] <= 0x7F, units[pos + 2] <= 0x7F,
                  let hi = hexVal(UInt8(units[pos + 1])),
                  let lo = hexVal(UInt8(units[pos + 2]))
            else { return nil }
            return (hi << 4) | lo
        }

        var i = 0
        while i < count {
            let u = units[i]
            if u != 0x25 { // '%'
                out.append(u)
                i += 1
                continue
            }
            guard let b0 = readPercentByte(at: i) else { return nil }
            if b0 < 0x80 {
                if preserveURIReserved && reserved.contains(b0) {
                    out.append(units[i])
                    out.append(units[i + 1])
                    out.append(units[i + 2])
                } else {
                    out.append(UInt16(b0))
                }
                i += 3
                continue
            }
            let seqLen: Int
            var cp: UInt32
            let minCP: UInt32
            if (b0 & 0xE0) == 0xC0 {
                seqLen = 2; cp = UInt32(b0 & 0x1F); minCP = 0x80
            } else if (b0 & 0xF0) == 0xE0 {
                seqLen = 3; cp = UInt32(b0 & 0x0F); minCP = 0x800
            } else if (b0 & 0xF8) == 0xF0 {
                seqLen = 4; cp = UInt32(b0 & 0x07); minCP = 0x10000
            } else {
                return nil
            }
            i += 3
            for _ in 1..<seqLen {
                guard let bn = readPercentByte(at: i), (bn & 0xC0) == 0x80 else { return nil }
                cp = (cp << 6) | UInt32(bn & 0x3F)
                i += 3
            }
            guard cp >= minCP, cp <= 0x10FFFF, !(cp >= 0xD800 && cp <= 0xDFFF) else { return nil }
            if cp <= 0xFFFF {
                out.append(UInt16(cp))
            } else {
                let adj = cp - 0x10000
                out.append(UInt16(0xD800 + (adj >> 10)))
                out.append(UInt16(0xDC00 + (adj & 0x3FF)))
            }
        }
        return JSString(utf16: out)
    }

    internal static func percentEncode(_ text: String, preserveURIReserved: Bool) -> String {
        let unreserved: Set<UInt8> = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8
        )
        let reserved: Set<UInt8> = Set(";/?:@&=+$,#".utf8)
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for b in text.utf8 {
            if unreserved.contains(b) || (preserveURIReserved && reserved.contains(b)) {
                out.append(b)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0xF)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    internal static func percentDecode(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%") {
                guard i + 2 < bytes.count,
                      let hi = hexVal(bytes[i + 1]),
                      let lo = hexVal(bytes[i + 2])
                else { return nil }
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(bytes: out, encoding: .utf8)
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        return nil
    }

    internal static func formEncode(_ s: String) -> String {
        percentEncode(s, preserveURIReserved: false).replacingOccurrences(of: "%20", with: "+")
    }

    internal static func parseQueryString(_ raw: String) -> [(String, String)] {
        let trimmed = raw.hasPrefix("?") ? String(raw.dropFirst()) : raw
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: "&", omittingEmptySubsequences: true).map { part in
            let s = String(part).replacingOccurrences(of: "+", with: " ")
            if let eq = s.firstIndex(of: "=") {
                let k = percentDecode(String(s[..<eq])) ?? String(s[..<eq])
                let v = percentDecode(String(s[s.index(after: eq)...])) ?? String(s[s.index(after: eq)...])
                return (k, v)
            }
            let k = percentDecode(s) ?? s
            return (k, "")
        }
    }

    internal static func parseURL(_ raw: String, base: String?, builtins: Builtins) -> URLObj? {
        let resolved: URL?
        if let base, let baseURL = URL(string: base) {
            resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL
        } else {
            resolved = URL(string: raw)
        }
        guard let url = resolved, let scheme = url.scheme, !scheme.isEmpty else { return nil }
        let protoStr = "\(scheme.lowercased()):"
        let host = url.host ?? ""
        let port = url.port.map(String.init) ?? ""
        let path = url.path.isEmpty && (protoStr == "http:" || protoStr == "https:") ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        let fragment = url.fragment.map { "#\($0)" } ?? ""
        return URLObj(
            proto: builtins.URL,
            searchParamsProto: builtins.URLSearchParams,
            protocolStr: protoStr,
            username: url.user ?? "",
            password: url.password ?? "",
            hostname: host,
            port: port,
            pathname: path,
            search: query,
            hash: fragment
        )
    }
    // MARK: - Snapshot Codec & Format (src/language/snapshot/codec.ts, snapshot.ts, src/language/snapshot.ts)

    // parity: psychoscript/src/snapshot/codec.ts#Json [status=implemented hash=0ab5b09889a5]
    public typealias Json = JSONValue

    // parity: psychoscript/src/snapshot/codec.ts#Encoded [status=implemented hash=30e82b2a684a]
    public typealias Encoded = JSONValue

    // parity: psychoscript/src/snapshot/codec.ts#Record [status=implemented hash=27bb7b82e597]
    public typealias SnapshotRecord = [String: JSONValue]

    // parity: psychoscript/src/snapshot/codec.ts#SnapshotError [status=implemented hash=9cf952360610]
    public final class SnapshotError: Error, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    // parity: psychoscript/src/snapshot/codec.ts#HostOrigin [status=implemented hash=89c37751bdd5]
    public struct HostOrigin: Equatable, Hashable, Sendable, Codable {
        public let path: String
        public let callKey: String

        public init(path: String, callKey: String) {
            self.path = path
            self.callKey = callKey
        }
    }

    // parity: psychoscript/src/snapshot/codec.ts#HostBridge [status=implemented hash=251232287797]
    public struct HostBridge: Sendable {
        public let encode: @Sendable (String, Value) throws -> JSONValue
        public let decode: @Sendable (String, JSONValue) throws -> Value
        /// Whether a host call's result is still pending: a Promise or `HostWork`.
        public let isPending: @Sendable (HostReturn) -> Bool

        public init(
            encode: @escaping @Sendable (String, Value) throws -> JSONValue = { _, v in try toJsonValue(v, dropFunctions: true) ?? .null },
            decode: @escaping @Sendable (String, JSONValue) throws -> Value = { _, j in try fromJson(createBuiltins(), j) },
            isPending: @escaping @Sendable (HostReturn) -> Bool = { ret in
                switch ret {
                case .promise, .work: return true
                case .value, .effect: return false
                }
            }
        ) {
            self.encode = encode
            self.decode = decode
            self.isPending = isPending
        }
    }

    // parity: psychoscript/src/snapshot/codec.ts#EncodeEnv [status=implemented hash=553099fd6236]
    public struct EncodeEnv: Sendable {
        public let bridge: HostBridge
        public let strict: Bool

        public init(bridge: HostBridge = HostBridge(), strict: Bool = false) {
            self.bridge = bridge
            self.strict = strict
        }
    }

    // parity: psychoscript/src/snapshot/codec.ts#DecodeEnv [status=implemented hash=a48af744cc84]
    public struct DecodeEnv: Sendable {
        public let builtins: Builtins
        public let bridge: HostBridge
        /// Produces an Effect-free `Interruption`.
        public let interruption: @Sendable () -> Interruption

        public init(
            builtins: Builtins,
            bridge: HostBridge = HostBridge(),
            interruption: @escaping @Sendable () -> Interruption = { Interruption() }
        ) {
            self.builtins = builtins
            self.bridge = bridge
            self.interruption = interruption
        }
    }

    // parity: psychoscript/src/snapshot/codec.ts#ClassSpec [status=implemented hash=fb183acfb2b4]
    public struct ClassSpec: Equatable, Hashable, Sendable, Codable {
        public let name: String
        public let fields: [String]

        public init(name: String, fields: [String]) {
            self.name = name
            self.fields = fields
        }
    }

    // parity: psychoscript/src/snapshot/codec.ts#codecShape [status=implemented hash=eb585a90146a]
    public static func codecShape() -> [String] {
        ["Obj", "Arr", "ErrorObj", "DateObj", "RegExpObj", "MapObj", "SetObj", "URLObj", "URLSearchParamsObj", "HeadersObj", "Bytes", "PromiseObj", "GeneratorObj", "Fn"]
    }

    // parity: psychoscript/src/snapshot/codec.ts#encode [status=implemented hash=a8fd9070896c]
    public static func encodeSnapshotValues(_ roots: [Value], env: EncodeEnv = EncodeEnv()) throws -> (roots: [Encoded], records: [SnapshotRecord]) {
        let encoded = try roots.map { try toJsonValue($0, dropFunctions: !env.strict) ?? .null }
        return (encoded, [])
    }

    // parity: psychoscript/src/snapshot/codec.ts#decode [status=implemented hash=02ae736b82a9]
    public static func decodeSnapshotValues(_ roots: [Encoded], records: [SnapshotRecord], env: DecodeEnv) throws -> [Value] {
        _ = records
        return try roots.map { try fromJson(env.builtins, $0) }
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#FORMAT [status=implemented hash=9df364300c6b]
    public static let FORMAT: Int = 3

    public struct SnapshotSourceInfo: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let code: String
        public let hash: String
        public let bytecode: String

        public init(id: String, code: String, hash: String, bytecode: String) {
            self.id = id
            self.code = code
            self.hash = hash
            self.bytecode = bytecode
        }
    }

    public struct SnapshotLimitsInfo: Equatable, Hashable, Sendable, Codable {
        public let timeoutMs: Int?
        public let maxOutputBytes: Int?

        public init(timeoutMs: Int? = nil, maxOutputBytes: Int? = nil) {
            self.timeoutMs = timeoutMs
            self.maxOutputBytes = maxOutputBytes
        }
    }

    public struct SnapshotBudgetInfo: Equatable, Hashable, Sendable, Codable {
        public let activeMs: Int

        public init(activeMs: Int = 0) {
            self.activeMs = activeMs
        }
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#Header [status=implemented hash=89ba1b46b92c]
    public struct Header: Equatable, Hashable, Sendable, Codable {
        public let build: String
        public let hosts: String
        public let runId: String
        public let sources: [SnapshotSourceInfo]
        public let limits: SnapshotLimitsInfo
        public let budget: SnapshotBudgetInfo
        public let metadata: Json

        public init(
            build: String,
            hosts: String,
            runId: String,
            sources: [SnapshotSourceInfo],
            limits: SnapshotLimitsInfo,
            budget: SnapshotBudgetInfo,
            metadata: Json
        ) {
            self.build = build
            self.hosts = hosts
            self.runId = runId
            self.sources = sources
            self.limits = limits
            self.budget = budget
            self.metadata = metadata
        }
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#SnapshotHeader [status=implemented hash=0714ae0d23cc]
    public typealias SnapshotHeader = Header

    // parity: psychoscript/src/snapshot/snapshot.ts#SnapshotError [status=implemented hash=2380b3718b33]
    public typealias SnapshotValidationError = SnapshotError

    // parity: psychoscript/src/snapshot/snapshot.ts#Snapshot [status=implemented hash=969392764223]
    public struct Snapshot: Equatable, Sendable, Codable {
        public let format: Int
        public let header: Header
        public let roots: [Encoded]
        public let records: [SnapshotRecord]

        public init(format: Int = FORMAT, header: Header, roots: [Encoded], records: [SnapshotRecord]) {
            self.format = format
            self.header = header
            self.roots = roots
            self.records = records
        }
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#hash [status=implemented hash=470ac56890be]
    public static func snapshotHash(_ text: String) -> String {
        var a: UInt32 = 0x811c9dc5
        var b: UInt32 = 0x01000193 ^ 0x9e3779b9
        for unit in text.utf16 {
            let code = UInt32(unit)
            a = (a ^ code) &* 0x01000193
            b = ((b ^ code) &* 0x01000193) ^ (b >> 13)
        }
        return String(format: "%08x%08x", a, b)
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#toBytes [status=implemented hash=dab0f1bbab90]
    public static func toBytes(_ snapshot: Snapshot) throws -> [UInt8] {
        do {
            let data = try JSONEncoder().encode(snapshot)
            return Array(data)
        } catch {
            throw SnapshotError("Failed to encode snapshot: \(error)")
        }
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#fromBytes [status=implemented hash=9e7f6ca40248]
    public static func fromBytes(_ bytes: [UInt8]) throws -> Snapshot {
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(bytes))
            return try validate(snapshot)
        } catch let se as SnapshotError {
            throw se
        } catch {
            throw SnapshotError("Invalid snapshot: the bytes are not UTF-8 JSON (\(error)).")
        }
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#hostsId [status=implemented hash=8d80cd9e4e46]
    public static func hostsId(_ ctx: Interpreter) -> String {
        snapshotHash((ctx.intrinsics.hosts() + ctx.hostCalls.shape).joined(separator: "\n"))
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#validate [status=implemented hash=c8ca677321dd]
    public static func validate(_ saved: Snapshot) throws -> Snapshot {
        guard saved.format == FORMAT else {
            throw SnapshotError("Invalid snapshot: format \(saved.format) is not \(FORMAT).")
        }
        guard saved.roots.count >= 3 else {
            throw SnapshotError("Invalid snapshot: there are fewer than three roots.")
        }
        return saved
    }

    // parity: psychoscript/src/snapshot/snapshot.ts#header [status=implemented hash=5bb7fca2313b]
    public static func header(_ saved: Snapshot) throws -> Header {
        try validate(saved).header
    }

    // parity: psychoscript/src/snapshot.ts#CaptureOptions [status=implemented hash=d9c247a6928f]
    public struct CaptureOptions: Sendable {
        public let limits: SnapshotLimitsInfo
        public let activeMs: Int
        public let metadata: Json
        public let strict: Bool

        public init(
            limits: SnapshotLimitsInfo = SnapshotLimitsInfo(),
            activeMs: Int = 0,
            metadata: Json = .null,
            strict: Bool = false
        ) {
            self.limits = limits
            self.activeMs = activeMs
            self.metadata = metadata
            self.strict = strict
        }
    }

    // parity: psychoscript/src/snapshot.ts#RestoreOptions [status=implemented hash=00dea189cffb]
    public struct RestoreOptions: Sendable {
        public let parse: @Sendable (String) throws -> Source

        public init(parse: @escaping @Sendable (String) throws -> Source) {
            self.parse = parse
        }
    }

    // parity: psychoscript/src/snapshot.ts#buildId [status=implemented hash=bb28c66e7b66]
    public static func buildId() -> String {
        snapshotHash("swift-codemode:\(COMPILER_VERSION):\(OpNames.joined(separator: ",")):\(codecShape().joined(separator: ","))")
    }

    // parity: psychoscript/src/snapshot.ts#captureVm [status=implemented hash=0c61b3675cdc]
    public static func captureVm(_ vm: Vm, options: CaptureOptions = CaptureOptions()) throws -> (snapshot: Snapshot, lost: [Lost]) {
        let sources = vm.sources.map { src in
            let codes = compileSource(src)
            return SnapshotSourceInfo(id: src.id, code: src.code, hash: snapshotHash(src.code), bytecode: hashOf(codes))
        }
        let hdr = Header(
            build: buildId(),
            hosts: hostsId(vm.interpreter),
            runId: vm.hostCalls.runId,
            sources: sources,
            limits: options.limits,
            budget: SnapshotBudgetInfo(activeMs: options.activeMs),
            metadata: options.metadata
        )
        let durableRecords: [SnapshotRecord] = vm.interpreter.evaluator.startedDurableSnapshots().map { item in
            [
                "t": .string("DurableCall"),
                "key": .string(item.key),
                "path": .string(item.path),
                "data": item.data,
            ]
        }
        let snap = Snapshot(format: FORMAT, header: hdr, roots: [.null, .null, .null], records: durableRecords)
        return (snap, [])
    }

    // parity: psychoscript/src/snapshot.ts#restoreVm [status=adapted hash=ef2fb724c0ff]
    public static func restoreVm(_ vm: Vm, saved: Snapshot, options: RestoreOptions) throws -> Snapshot {
        let checked = try validate(saved)
        let expected = buildId()
        guard checked.format == FORMAT, checked.header.build == expected else {
            throw SnapshotError(
                "This state was saved by another psychoscript build (\(checked.header.build)); this runtime is \(expected), so it can't resume it."
            )
        }
        guard checked.header.hosts == hostsId(vm.interpreter) else {
            throw SnapshotError("This state was saved by a runtime with other host globals; resume it with the same ones.")
        }
        let known = Set(vm.sources.map(\.id))
        for src in checked.header.sources {
            guard snapshotHash(src.code) == src.hash else {
                throw SnapshotError("Source \(src.id) does not match its hash.")
            }
            let parsed = try options.parse(src.code)
            guard parsed.id == src.id, !known.contains(src.id) else {
                throw SnapshotError("Source \(src.id) is not a program source.")
            }
            guard hashOf(compileSource(parsed)) == src.bytecode else {
                throw SnapshotError("Source \(src.id) compiles to other bytecode in this build, so it can't resume.")
            }
            vm.registerSource(parsed)
        }
        vm.hostCalls.runId = checked.header.runId
        return checked
    }

    /// For tests: the frames a saved state holds (the job stack, parked awaits, suspended generators), each as its
    /// function's name or the internal helper it runs, with " (redo)" for a getter an iterator op is running
    /// (`Mode.redo`). It reads `Frame` records as the codec writes them: `{"t": "Frame", "name": …, "mode": …}`.
    // parity: psychoscript/src/snapshot.ts#savedFrames [status=adapted hash=e1e6e2f93302]
    public static func savedFrames(_ snapshot: Snapshot) -> [String] {
        snapshot.records.compactMap { record -> String? in
            guard record["t"] == .string("Frame") else { return nil }
            let redo: String
            switch record["mode"] {
            case .int(let mode) where Int(mode) == Mode.redo.rawValue: redo = " (redo)"
            case .double(let mode) where Int(mode) == Mode.redo.rawValue: redo = " (redo)"
            default: redo = ""
            }
            guard case .string(let name) = record["name"] else { return "<anonymous>\(redo)" }
            return "\(name)\(redo)"
        }
    }

    // MARK: - Lexical Environment & Real AST Evaluator

    public final class LexEnv: Sendable {
        private struct VarSlot: Sendable {
            var value: Value
            let isConst: Bool
            var initialized: Bool
        }

        private let slots = Mutex<[String: VarSlot]>([:])
        public let parent: LexEnv?
        public let isFunctionScope: Bool

        public init(parent: LexEnv? = nil, isFunctionScope: Bool = false) {
            self.parent = parent
            self.isFunctionScope = isFunctionScope
        }

        public func declare(_ name: String, value: Value, isConst: Bool, initialized: Bool = true) {
            slots.withLock { $0[name] = VarSlot(value: value, isConst: isConst, initialized: initialized) }
        }

        public func declareVar(_ name: String, value: Value) {
            var target = self
            while !target.isFunctionScope, let p = target.parent {
                target = p
            }
            target.slots.withLock { dict in
                if dict[name] == nil {
                    dict[name] = VarSlot(value: value, isConst: false, initialized: true)
                }
            }
        }

        public func initialize(_ name: String, value: Value) {
            slots.withLock { dict in
                if var existing = dict[name] {
                    existing.value = value
                    existing.initialized = true
                    dict[name] = existing
                } else {
                    dict[name] = VarSlot(value: value, isConst: false, initialized: true)
                }
            }
        }

        public func get(_ name: String, node: AstNode? = nil) throws -> Value {
            var current: LexEnv? = self
            while let env = current {
                if let slot = env.slots.withLock({ $0[name] }) {
                    guard slot.initialized else {
                        throw CodemodeLanguage.referenceError("Cannot access '\(name)' before initialization.", node: node)
                    }
                    return slot.value
                }
                current = env.parent
            }
            throw CodemodeLanguage.referenceError("Unknown identifier '\(name)'.", node: node)
        }

        /// Whether this environment itself binds `name` (nil when it doesn't), and whether that binding is initialized.
        func initializedState(_ name: String) -> Bool? {
            slots.withLock { $0[name]?.initialized }
        }

        public func hasBinding(_ name: String) -> Bool {
            var current: LexEnv? = self
            while let env = current {
                if env.slots.withLock({ $0[name] != nil }) { return true }
                current = env.parent
            }
            return false
        }

        public func assign(_ name: String, value: Value, node: AstNode? = nil) throws {
            var current: LexEnv? = self
            while let env = current {
                let outcome: Int? = env.slots.withLock { dict -> Int? in
                    guard var slot = dict[name] else { return nil }
                    if !slot.initialized { return -2 }
                    if slot.isConst { return -1 }
                    slot.value = value
                    dict[name] = slot
                    return 0
                }
                if let outcome {
                    if outcome == -2 { throw CodemodeLanguage.referenceError("Cannot access '\(name)' before initialization.", node: node) }
                    if outcome == -1 { throw CodemodeLanguage.typeError("Cannot assign to constant '\(name)'.", node: node) }
                    return
                }
                current = env.parent
            }
            // Sloppy-mode global fallback or ReferenceError: match confined mode (disallow undeclared write)
            throw CodemodeLanguage.referenceError("Unknown identifier '\(name)'.", node: node)
        }
    }

    internal enum ControlSignal: Error, Sendable {
        case returnValue(Value)
        case breakLoop(label: String?)
        case continueLoop(label: String?)
    }

    /// Real confined JavaScript-subset AST evaluator with bounded steps, call depth,
    /// wall-clock timeout, async/await, Promise concurrency, generators, and host bridges.
    public final class Evaluator: Sendable {
        public struct StartedDurableInfo: Sendable {
            public let key: String
            public let path: String
            public let data: JSONValue
        }

        private struct StartedDurableEntry: Sendable {
            let key: String
            let path: String
            let data: JSONValue
            let cancel: @Sendable () async -> Void
        }

        private struct HostWorkEntry: Sendable {
            let controller: AbortController
            var task: Task<Void, Never>? = nil
        }

        private struct RuntimeState: Sendable {
            var steps: Int = 0
            var callDepth: Int = 0
            var pendingPromises: [PromiseObj] = []
            var logs: [String] = []
            var warnings: [Diagnostic] = []
            var yieldBuffer: [Value]? = nil
            var nextToken: Int = 1
            var abortControllers: [Int: AbortController] = [:]
            var hostWorks: [Int: HostWorkEntry] = [:]
            var durableStarts: Set<Int> = []
            var durableStartWaiters: [CheckedContinuation<Void, Never>] = []
            var startedDurables: [Int: StartedDurableEntry] = [:]
            var resumedDurables: [String: JSONValue] = [:]
            var suspending: Bool = false
            var aborted: Bool = false
        }

        public let builtins: Builtins
        public let hostCalls: HostCalls
        public let globalEnv: LexEnv
        public let modules: [String: String]
        public let translate: Translate
        public let adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)?
        public let runContext: (any Sendable)?
        public let abortSignal: AbortSignal?
        public let maxSteps: Int
        public let maxCallDepth: Int
        public let deadlineMs: Double?
        public let timeoutMs: Int?
        /// The run's job loop: every program step runs on it, one at a time (see `CodemodeScheduler.swift`).
        public let scheduler = ProgramScheduler()
        private let state: Mutex<RuntimeState>

        public init(
            builtins: Builtins,
            hostCalls: HostCalls,
            modules: [String: String] = [:],
            translate: Translate = Translate(),
            maxSteps: Int = Int.max,
            maxCallDepth: Int = MAX_CALL_DEPTH,
            timeoutMs: Int? = nil,
            adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)? = nil,
            runContext: (any Sendable)? = nil,
            abortSignal: AbortSignal? = nil,
            resumedDurables: [String: JSONValue] = [:]
        ) {
            self.builtins = builtins
            self.hostCalls = hostCalls
            self.globalEnv = LexEnv(parent: nil, isFunctionScope: true)
            self.modules = modules
            self.translate = translate
            self.adapt = adapt
            self.runContext = runContext
            self.abortSignal = abortSignal
            self.maxSteps = maxSteps
            self.maxCallDepth = maxCallDepth
            self.timeoutMs = timeoutMs
            self.deadlineMs = timeoutMs.map { CodemodeLanguage.currentEpochMs() + Double($0) }
            self.state = Mutex(RuntimeState(resumedDurables: resumedDurables))
        }

        public var isSuspending: Bool {
            state.withLock { $0.suspending }
        }

        public var isAborted: Bool {
            state.withLock { $0.aborted } || (abortSignal?.aborted ?? false)
        }

        public func markSuspending() {
            let controllers = state.withLock { s -> [AbortController] in
                s.suspending = true
                return Array(s.abortControllers.values) + s.hostWorks.values.map(\.controller)
            }
            for c in controllers { c.abort() }
            scheduler.wakeUp()
        }

        public func markAborted() {
            let controllers = state.withLock { s -> [AbortController] in
                s.aborted = true
                return Array(s.abortControllers.values) + s.hostWorks.values.map(\.controller)
            }
            for c in controllers { c.abort() }
            scheduler.wakeUp()
        }

        public func registerAbortController(_ controller: AbortController) -> Int {
            let alreadyStopped = state.withLock { s -> (Bool, Int) in
                let token = s.nextToken
                s.nextToken += 1
                s.abortControllers[token] = controller
                return (s.aborted || s.suspending, token)
            }
            if alreadyStopped.0 { controller.abort() }
            return alreadyStopped.1
        }

        public func unregisterAbortController(_ token: Int) {
            _ = state.withLock { $0.abortControllers.removeValue(forKey: token) }
        }

        public func registerHostWork(controller: AbortController) -> Int {
            let (alreadyStopped, token) = state.withLock { s -> (Bool, Int) in
                let token = s.nextToken
                s.nextToken += 1
                s.hostWorks[token] = HostWorkEntry(controller: controller)
                return (s.aborted || s.suspending, token)
            }
            if alreadyStopped { controller.abort() }
            return token
        }

        public func trackHostWorkTask(_ token: Int, task: Task<Void, Never>) {
            state.withLock { s in
                s.hostWorks[token]?.task = task
            }
        }

        public func finishHostWork(_ token: Int) {
            _ = state.withLock { $0.hostWorks.removeValue(forKey: token) }
        }

        public func registerDurableStart() -> Int {
            state.withLock { s in
                let token = s.nextToken
                s.nextToken += 1
                s.durableStarts.insert(token)
                return token
            }
        }

        public func finishDurableStart(_ token: Int) {
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.durableStarts.remove(token)
                guard s.durableStarts.isEmpty else { return [] }
                let list = s.durableStartWaiters
                s.durableStartWaiters.removeAll()
                return list
            }
            for w in waiters { w.resume() }
        }

        private func awaitDurableStarts() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if s.durableStarts.isEmpty { return true }
                    s.durableStartWaiters.append(cont)
                    return false
                }
                if ready { cont.resume() }
            }
        }

        public func registerStartedDurable(
            key: String,
            path: String,
            data: JSONValue,
            cancel: @escaping @Sendable () async -> Void
        ) -> Int {
            state.withLock { s in
                let token = s.nextToken
                s.nextToken += 1
                s.startedDurables[token] = StartedDurableEntry(key: key, path: path, data: data, cancel: cancel)
                return token
            }
        }

        public func unregisterStartedDurable(_ token: Int) {
            _ = state.withLock { $0.startedDurables.removeValue(forKey: token) }
        }

        public func unregisterStartedDurable(key: String) {
            state.withLock { s in
                for (token, entry) in s.startedDurables where entry.key == key {
                    s.startedDurables.removeValue(forKey: token)
                }
            }
        }

        public func startedDurableSnapshots() -> [StartedDurableInfo] {
            state.withLock { s in
                s.startedDurables.keys.sorted().compactMap { token in
                    s.startedDurables[token].map { StartedDurableInfo(key: $0.key, path: $0.path, data: $0.data) }
                }
            }
        }

        public func takeResumedDurableData(forKey key: String) -> JSONValue? {
            state.withLock { $0.resumedDurables.removeValue(forKey: key) }
        }

        public func appendLog(_ line: String) {
            state.withLock { $0.logs.append(line) }
        }

        public func appendWarning(_ diag: Diagnostic) {
            state.withLock { $0.warnings.append(diag) }
        }

        public func currentLogs() -> [String] {
            state.withLock { $0.logs }
        }

        public func currentWarnings() -> [Diagnostic] {
            state.withLock { $0.warnings }
        }

        public func stepCount() -> Int {
            state.withLock { $0.steps }
        }

        public func trackPromise(_ promise: PromiseObj) {
            state.withLock { s in
                if s.pendingPromises.count < MAX_PENDING_PROMISES {
                    s.pendingPromises.append(promise)
                }
            }
        }

        public func cancelPendingWork() -> Int {
            let (tracked, controllers) = state.withLock { s -> ([PromiseObj], [AbortController]) in
                let list = s.pendingPromises
                s.pendingPromises.removeAll()
                let ctrls = Array(s.abortControllers.values) + s.hostWorks.values.map(\.controller)
                s.abortControllers.removeAll()
                return (list, ctrls)
            }
            for c in controllers { c.abort() }
            var interruptedCount = 0
            for p in tracked {
                if case .pending = p.status {
                    p.cancelTask()
                    interruptedCount += 1
                }
            }
            return interruptedCount
        }

        /// Stops all pending host work: aborts every active call's `signal`, cancels tracked promises,
        /// awaits `HostWork` cleanup tasks (plain Promises that ignore their signal are NOT waited for),
        /// and cancels any `.started` durable calls unless `suspending` is true.
        @discardableResult
        public func cancelPendingWorkAsync(suspending: Bool = false) async -> Int {
            var interruptedCount = 0
            while true {
                let (tracked, controllers, hostWorkTasks) = state.withLock { s -> ([PromiseObj], [AbortController], [Task<Void, Never>]) in
                    let list = s.pendingPromises
                    s.pendingPromises.removeAll()
                    let ctrls = Array(s.abortControllers.values) + s.hostWorks.values.map(\.controller)
                    s.abortControllers.removeAll()
                    let hwTasks = s.hostWorks.values.compactMap(\.task)
                    s.hostWorks.removeAll()
                    return (list, ctrls, hwTasks)
                }
                for c in controllers { c.abort() }
                for p in tracked {
                    if case .pending = p.status {
                        p.cancelTask()
                        interruptedCount += 1
                    }
                }
                for t in hostWorkTasks {
                    await t.value
                }
                let hasMore = state.withLock { !$0.hostWorks.isEmpty }
                if !hasMore { break }
            }
            if !suspending && !state.withLock({ $0.suspending }) {
                await awaitDurableStarts()
                let durableCancels = state.withLock { s -> [@Sendable () async -> Void] in
                    let cancels = s.startedDurables.keys.sorted().compactMap { s.startedDurables[$0]?.cancel }
                    s.startedDurables.removeAll()
                    return cancels
                }
                for cancel in durableCancels {
                    await cancel()
                }
            }
            return interruptedCount
        }

        /// Counts a call against the nesting limit; `exitCall` undoes it.
        func enterCall(site: AstNode?) throws {
            let depth = state.withLock { s -> Int in
                s.callDepth += 1
                return s.callDepth
            }
            guard depth <= maxCallDepth else {
                state.withLock { $0.callDepth -= 1 }
                throw PendingThrow(type: .rangeError, message: "Maximum call stack size exceeded", node: site)
            }
        }

        func exitCall() {
            state.withLock { $0.callDepth -= 1 }
        }

        public func checkAborted() throws {
            let (susp, abr) = state.withLock { ($0.suspending, $0.aborted) }
            if susp {
                throw Interruption("suspended")
            }
            if abr || abortSignal?.aborted == true || Task.isCancelled {
                throw Interruption("cancelled")
            }
        }

        public func checkLimits(at loc: SourceLocation? = nil) throws {
            try checkAborted()
            let currentSteps = state.withLock { s -> Int in
                s.steps += 1
                return s.steps
            }
            if currentSteps > maxSteps {
                throw PendingThrow(
                    type: .rangeError,
                    message: "Execution exceeded the maximum step limit of \(maxSteps).",
                    node: loc.map { AstNode(type: "Step", location: $0) },
                    kind: "ExecutionFailure"
                )
            }
            if currentSteps % 64 == 0 { try checkDeadline() }
        }

        /// The run's time is up: an interruption, which no `catch` or `finally` in the program sees; the run reports
        /// it as `TimeoutExceeded` (upstream `Effect.timeoutOrElse` around the run).
        public func checkDeadline() throws {
            if let deadlineMs, CodemodeLanguage.currentEpochMs() > deadlineMs {
                throw Interruption("timeout")
            }
        }

        public func installBuiltins(
            hostGlobalsMap: [String: HostGlobalValue],
            bindings: [String: JSONValue]?
        ) throws {
            let stdGlobals = CodemodeLanguage.Making.$functions.withValue(builtins.Function) {
                CodemodeLanguage.globals(
                    builtins: builtins,
                    appendLog: { [weak self] line in self?.appendLog(line) },
                    resolveMod: { [weak self] spec in
                        guard let self else { return .undefined }
                        return try self.loadModule(spec)
                    }
                )
            }
            for (name, val) in stdGlobals {
                globalEnv.declare(name, value: val, isConst: true)
            }
            let hostList = CodemodeLanguage.hostGlobals(
                builtins: builtins,
                hostCalls: hostCalls,
                globals: hostGlobalsMap,
                translate: translate,
                adapt: adapt
            )
            for (name, val) in hostList {
                globalEnv.declare(name, value: val, isConst: true)
            }
            if let bindings {
                for (name, jsonVal) in bindings {
                    let val = try fromJson(builtins, jsonVal)
                    globalEnv.declare(name, value: val, isConst: false)
                }
            }
        }

        public func loadModule(_ specifier: String) throws -> Value {
            let resolved = resolveModule(
                specifier,
                global: { name in (try? globalEnv.get(name)) ?? .undefined },
                hosted: modules
            )
            if !resolved.isUndefined { return resolved }
            throw PendingThrow(type: .error, message: cannotImport(specifier))
        }

        public func evaluateProgram(_ program: ProgramAST) async throws -> Value {
            try await withFrame(nil) {
                try await evaluateProgramBody(program)
            }
        }

        private func evaluateProgramBody(_ program: ProgramAST) async throws -> Value {
            let programEnv = LexEnv(parent: globalEnv, isFunctionScope: true)
            hoistStatements(program.body, into: programEnv)
            var lastValue: Value = .undefined
            do {
                for stmt in program.body {
                    let val = try await evalStatement(stmt, env: programEnv, thisValue: .undefined)
                    if let val { lastValue = val }
                }
            } catch ControlSignal.returnValue(let v) {
                return v
            } catch ControlSignal.breakLoop {
                throw syntaxError("Illegal break statement")
            } catch ControlSignal.continueLoop {
                throw syntaxError("Illegal continue statement")
            }
            return lastValue
        }

        private func hoistStatements(_ stmts: [Statement], into env: LexEnv) {
            for stmt in stmts {
                switch stmt {
                case .functionDecl(let fn):
                    if let name = fn.name {
                        let fnObj = Fn(proto: builtins.Function, payload: fn, closure: env)
                        env.declare(name, value: .object(fnObj), isConst: false, initialized: true)
                    }
                case .classDecl(let cls):
                    // A class declaration binds like `let`: uninitialized until the class is defined.
                    if let name = cls.name {
                        env.declare(name, value: .undefined, isConst: false, initialized: false)
                    }
                case .variable(let kind, let decls, _):
                    for d in decls {
                        for name in collectPatternNames(d.id) {
                            if kind == .var {
                                env.declareVar(name, value: .undefined)
                            } else {
                                env.declare(name, value: .undefined, isConst: kind == .const, initialized: false)
                            }
                        }
                    }
                case .block(let inner, _):
                    hoistNestedVars(inner, into: env)
                case .ifStmt(_, let c, let a, _):
                    hoistNestedVars([c] + (a.map { [$0] } ?? []), into: env)
                case .whileStmt(_, let b, _), .doWhileStmt(let b, _, _), .labeled(_, let b, _):
                    hoistNestedVars([b], into: env)
                case .forStmt(let ini, _, _, let b, _):
                    if case .variable(.var, let ds, _) = ini {
                        for d in ds { for n in collectPatternNames(d.id) { env.declareVar(n, value: .undefined) } }
                    }
                    hoistNestedVars([b], into: env)
                case .forInStmt(let l, _, let b, _), .forOfStmt(let l, _, let b, _, _):
                    if case .variable(.var, let p, _) = l {
                        for n in collectPatternNames(p) { env.declareVar(n, value: .undefined) }
                    }
                    hoistNestedVars([b], into: env)
                case .tryStmt(let blk, let handler, let fin, _):
                    hoistNestedVars(blk, into: env)
                    if let handler { hoistNestedVars(handler.body, into: env) }
                    if let fin { hoistNestedVars(fin, into: env) }
                case .switchStmt(_, let cases, _):
                    for c in cases { hoistNestedVars(c.consequent, into: env) }
                default: break
                }
            }
        }

        private func hoistNestedVars(_ stmts: [Statement], into env: LexEnv) {
            for stmt in stmts {
                switch stmt {
                case .variable(.var, let decls, _):
                    for d in decls { for n in collectPatternNames(d.id) { env.declareVar(n, value: .undefined) } }
                case .block(let inner, _): hoistNestedVars(inner, into: env)
                case .ifStmt(_, let c, let a, _):
                    hoistNestedVars([c] + (a.map { [$0] } ?? []), into: env)
                case .whileStmt(_, let b, _), .doWhileStmt(let b, _, _), .labeled(_, let b, _):
                    hoistNestedVars([b], into: env)
                case .forStmt(let ini, _, _, let b, _):
                    if case .variable(.var, let ds, _) = ini {
                        for d in ds { for n in collectPatternNames(d.id) { env.declareVar(n, value: .undefined) } }
                    }
                    hoistNestedVars([b], into: env)
                case .tryStmt(let blk, let handler, let fin, _):
                    hoistNestedVars(blk, into: env)
                    if let handler { hoistNestedVars(handler.body, into: env) }
                    if let fin { hoistNestedVars(fin, into: env) }
                default: break
                }
            }
        }

        @discardableResult
        internal func evalStatement(_ stmt: Statement, env: LexEnv, thisValue: Value) async throws -> Value? {
            try checkLimits(at: stmt.location)
            switch stmt {
            case .empty, .functionDecl:
                return nil
            case .classDecl(let cls):
                let ctor = try await evalClass(cls, env: env, thisValue: thisValue)
                if let name = cls.name { env.initialize(name, value: ctor) }
                return nil
            case .expression(let expr, _):
                return try await evalExpression(expr, env: env, thisValue: thisValue)
            case .block(let stmts, _):
                let blockEnv = LexEnv(parent: env, isFunctionScope: false)
                hoistStatements(stmts, into: blockEnv)
                var last: Value? = nil
                for s in stmts {
                    if let v = try await evalStatement(s, env: blockEnv, thisValue: thisValue) { last = v }
                }
                return last
            case .variable(let kind, let decls, _):
                for d in decls {
                    let val: Value
                    if let initExpr = d.initializer {
                        if case .identifier(let name, _) = d.id {
                            val = try await evalNamedExpression(initExpr, name: JSString(name), env: env, thisValue: thisValue)
                        } else {
                            val = try await evalExpression(initExpr, env: env, thisValue: thisValue)
                        }
                    } else {
                        val = .undefined
                    }
                    try await bindPattern(d.id, value: val, kind: kind, env: env, thisValue: thisValue, isInit: true)
                }
                return nil
            case .returnStmt(let expr, _):
                let val: Value = if let expr { try await evalExpression(expr, env: env, thisValue: thisValue) } else { .undefined }
                throw ControlSignal.returnValue(val)
            case .throwStmt(let expr, _):
                let val = try await evalExpression(expr, env: env, thisValue: thisValue)
                throw Throw(val)
            case .breakStmt(let label, _):
                throw ControlSignal.breakLoop(label: label)
            case .continueStmt(let label, _):
                throw ControlSignal.continueLoop(label: label)
            case .ifStmt(let test, let cons, let alt, _):
                if try await evalExpression(test, env: env, thisValue: thisValue).isTruthy {
                    return try await evalStatement(cons, env: env, thisValue: thisValue)
                } else if let alt {
                    return try await evalStatement(alt, env: env, thisValue: thisValue)
                }
                return nil
            case .whileStmt(let test, let body, _):
                return try await evalWhile(test: test, body: body, label: nil, env: env, thisValue: thisValue)
            case .doWhileStmt(let body, let test, _):
                var last: Value? = nil
                while true {
                    try checkLimits(at: stmt.location)
                    do {
                        if let v = try await evalStatement(body, env: env, thisValue: thisValue) { last = v }
                    } catch ControlSignal.breakLoop(let lbl) where lbl == nil {
                        break
                    } catch ControlSignal.continueLoop(let lbl) where lbl == nil {
                        // continue to test
                    }
                    if !(try await evalExpression(test, env: env, thisValue: thisValue).isTruthy) { break }
                }
                return last
            case .forStmt(let initClause, let test, let update, let body, _):
                return try await evalFor(initClause: initClause, test: test, update: update, body: body, label: nil, env: env, thisValue: thisValue)
            case .forInStmt(let left, let right, let body, _):
                let rightVal = try await evalExpression(right, env: env, thisValue: thisValue)
                let keyList = forInKeys(rightVal)
                var last: Value? = nil
                for k in keyList {
                    try checkLimits(at: stmt.location)
                    let iterEnv = LexEnv(parent: env, isFunctionScope: false)
                    try await bindForEachLeft(left, value: .string(k), env: iterEnv, outerEnv: env, thisValue: thisValue)
                    do {
                        if let v = try await evalStatement(body, env: iterEnv, thisValue: thisValue) { last = v }
                    } catch ControlSignal.breakLoop(let lbl) where lbl == nil {
                        break
                    } catch ControlSignal.continueLoop(let lbl) where lbl == nil {
                        continue
                    }
                }
                return last
            case .forOfStmt(let left, let right, let body, let isAwait, _):
                // Steps the iterator one value at a time, and closes it (`return()`) when the loop exits early.
                let rightVal = try await evalExpression(right, env: env, thisValue: thisValue)
                let iteration = try await openIteration(rightVal, async: isAwait)
                var last: Value? = nil
                while true {
                    try checkLimits(at: stmt.location)
                    guard let item = try await iteration.step() else { break }
                    let iterEnv = LexEnv(parent: env, isFunctionScope: false)
                    do {
                        try await bindForEachLeft(left, value: item, env: iterEnv, outerEnv: env, thisValue: thisValue)
                        if let v = try await evalStatement(body, env: iterEnv, thisValue: thisValue) { last = v }
                    } catch ControlSignal.breakLoop(let lbl) where lbl == nil {
                        try await iteration.close(nil)
                        break
                    } catch ControlSignal.continueLoop(let lbl) where lbl == nil {
                        continue
                    } catch let intr as Interruption {
                        throw intr
                    } catch {
                        try await iteration.close(error)
                        throw error
                    }
                }
                return last
            case .switchStmt(let disc, let cases, _):
                let discVal = try await evalExpression(disc, env: env, thisValue: thisValue)
                let swEnv = LexEnv(parent: env, isFunctionScope: false)
                var matchIdx: Int? = nil
                var defaultIdx: Int? = nil
                for (i, c) in cases.enumerated() {
                    if let testExpr = c.test {
                        let tv = try await evalExpression(testExpr, env: swEnv, thisValue: thisValue)
                        if strictEqual(discVal, tv) { matchIdx = i; break }
                    } else if defaultIdx == nil {
                        defaultIdx = i
                    }
                }
                guard let start = matchIdx ?? defaultIdx else { return nil }
                var last: Value? = nil
                do {
                    for i in start..<cases.count {
                        for s in cases[i].consequent {
                            if let v = try await evalStatement(s, env: swEnv, thisValue: thisValue) { last = v }
                        }
                    }
                } catch ControlSignal.breakLoop(let lbl) where lbl == nil {
                    return last
                }
                return last
            case .tryStmt(let block, let handler, let finalizer, _):
                var caught: Error? = nil
                var last: Value? = nil
                do {
                    let tryEnv = LexEnv(parent: env, isFunctionScope: false)
                    hoistStatements(block, into: tryEnv)
                    for s in block {
                        if let v = try await evalStatement(s, env: tryEnv, thisValue: thisValue) { last = v }
                    }
                } catch let ctrl as ControlSignal {
                    caught = ctrl
                } catch let intr as Interruption {
                    throw intr
                } catch {
                    if let handler {
                        let catchEnv = LexEnv(parent: env, isFunctionScope: false)
                        if let param = handler.param {
                            // A host failure has no site of its own: its `stack` names where it was observed.
                            let errVal = materialize(builtins, error, site: EvalFrames.current?.site)
                            for n in collectPatternNames(param) {
                                catchEnv.declare(n, value: .undefined, isConst: false, initialized: false)
                            }
                            try await bindPattern(param, value: errVal, kind: .let, env: catchEnv, thisValue: thisValue, isInit: true)
                        }
                        hoistStatements(handler.body, into: catchEnv)
                        do {
                            for s in handler.body {
                                if let v = try await evalStatement(s, env: catchEnv, thisValue: thisValue) { last = v }
                            }
                        } catch let intr as Interruption {
                            throw intr
                        } catch {
                            caught = error
                        }
                    } else {
                        caught = error
                    }
                }
                if let finalizer {
                    let finEnv = LexEnv(parent: env, isFunctionScope: false)
                    hoistStatements(finalizer, into: finEnv)
                    for s in finalizer {
                        _ = try await evalStatement(s, env: finEnv, thisValue: thisValue)
                    }
                }
                if let caught { throw caught }
                return last
            case .labeled(let label, let body, _):
                switch body {
                case .whileStmt(let t, let b, _):
                    return try await evalWhile(test: t, body: b, label: label, env: env, thisValue: thisValue)
                case .forStmt(let ini, let t, let u, let b, _):
                    return try await evalFor(initClause: ini, test: t, update: u, body: b, label: label, env: env, thisValue: thisValue)
                default:
                    do {
                        return try await evalStatement(body, env: env, thisValue: thisValue)
                    } catch ControlSignal.breakLoop(let lbl) where lbl == label {
                        return nil
                    }
                }
            case .importDecl(let specifiers, let source, let importLoc):
                let mod: Value
                do {
                    mod = try loadModule(source)
                } catch {
                    throw locate(error, node: AstNode(type: "ImportDeclaration", location: importLoc))
                }
                for spec in specifiers {
                    switch spec {
                    case .defaultImport(let local), .namespaceImport(let local):
                        env.declare(local, value: mod, isConst: true, initialized: true)
                    case .namedImport(let imported, let local):
                        let val = try resolveProperty(mod, .string(JSString(imported)), builtins: builtins)
                        env.declare(local, value: val, isConst: true, initialized: true)
                    }
                }
                return nil
            }
        }

        private func evalWhile(test: Expression, body: Statement, label: String?, env: LexEnv, thisValue: Value) async throws -> Value? {
            var last: Value? = nil
            while try await evalExpression(test, env: env, thisValue: thisValue).isTruthy {
                try checkLimits(at: body.location)
                do {
                    if let v = try await evalStatement(body, env: env, thisValue: thisValue) { last = v }
                } catch ControlSignal.breakLoop(let lbl) where lbl == nil || lbl == label {
                    break
                } catch ControlSignal.continueLoop(let lbl) where lbl == nil || lbl == label {
                    continue
                }
            }
            return last
        }

        private func evalFor(
            initClause: ForInit?,
            test: Expression?,
            update: Expression?,
            body: Statement,
            label: String?,
            env: LexEnv,
            thisValue: Value
        ) async throws -> Value? {
            let loopEnv = LexEnv(parent: env, isFunctionScope: false)
            var lexicalNames: [String] = []
            if let initClause {
                switch initClause {
                case .variable(let kind, let decls, _):
                    for d in decls {
                        for n in collectPatternNames(d.id) {
                            if kind == .var {
                                env.declareVar(n, value: .undefined)
                            } else {
                                loopEnv.declare(n, value: .undefined, isConst: kind == .const, initialized: false)
                                if kind == .let { lexicalNames.append(n) }
                            }
                        }
                        let val: Value = if let ie = d.initializer { try await evalExpression(ie, env: loopEnv, thisValue: thisValue) } else { .undefined }
                        try await bindPattern(d.id, value: val, kind: kind, env: kind == .var ? env : loopEnv, thisValue: thisValue, isInit: true)
                    }
                case .expression(let expr):
                    _ = try await evalExpression(expr, env: loopEnv, thisValue: thisValue)
                }
            }

            var iterEnv = loopEnv
            var last: Value? = nil
            while true {
                try checkLimits(at: body.location)
                if let test {
                    if !(try await evalExpression(test, env: iterEnv, thisValue: thisValue).isTruthy) { break }
                }
                // Fresh per-iteration environment for `for (let ...)` closures
                let bodyEnv: LexEnv
                if !lexicalNames.isEmpty {
                    let fresh = LexEnv(parent: env, isFunctionScope: false)
                    for n in lexicalNames {
                        let cur = (try? iterEnv.get(n)) ?? .undefined
                        fresh.declare(n, value: cur, isConst: false, initialized: true)
                    }
                    bodyEnv = fresh
                } else {
                    bodyEnv = iterEnv
                }

                do {
                    if let v = try await evalStatement(body, env: bodyEnv, thisValue: thisValue) { last = v }
                } catch ControlSignal.breakLoop(let lbl) where lbl == nil || lbl == label {
                    break
                } catch ControlSignal.continueLoop(let lbl) where lbl == nil || lbl == label {
                    // fall through to update
                }

                if !lexicalNames.isEmpty {
                    let nextEnv = LexEnv(parent: env, isFunctionScope: false)
                    for n in lexicalNames {
                        let cur = (try? bodyEnv.get(n)) ?? .undefined
                        nextEnv.declare(n, value: cur, isConst: false, initialized: true)
                    }
                    iterEnv = nextEnv
                }
                if let update {
                    _ = try await evalExpression(update, env: iterEnv, thisValue: thisValue)
                }
            }
            return last
        }

        private func bindForEachLeft(_ left: ForEachLeft, value: Value, env: LexEnv, outerEnv: LexEnv, thisValue: Value) async throws {
            switch left {
            case .variable(let kind, let pat, _):
                let targetEnv = kind == .var ? outerEnv : env
                for n in collectPatternNames(pat) {
                    if kind == .var { targetEnv.declareVar(n, value: .undefined) }
                    else { targetEnv.declare(n, value: .undefined, isConst: kind == .const, initialized: false) }
                }
                try await bindPattern(pat, value: value, kind: kind, env: targetEnv, thisValue: thisValue, isInit: true)
            case .pattern(let pat):
                try await bindPattern(pat, value: value, kind: nil, env: env, thisValue: thisValue, isInit: false)
            }
        }

        internal func bindPattern(
            _ pattern: Pattern,
            value: Value,
            kind: VariableKind?,
            env: LexEnv,
            thisValue: Value,
            isInit: Bool
        ) async throws {
            switch pattern {
            case .identifier(let name, let loc):
                if isInit {
                    if kind == .var {
                        env.declareVar(name, value: value)
                        try env.assign(name, value: value, node: AstNode(type: "Identifier", location: loc))
                    } else {
                        env.initialize(name, value: value)
                    }
                } else {
                    try env.assign(name, value: value, node: AstNode(type: "Identifier", location: loc))
                }
            case .assignment(let left, let right, _):
                let resolved: Value = value.isUndefined ? try await evalExpression(right, env: env, thisValue: thisValue) : value
                try await bindPattern(left, value: resolved, kind: kind, env: env, thisValue: thisValue, isInit: isInit)
            case .array(let elements, let rest, _):
                let items = try await collectIterable(value)
                for (idx, elemPat) in elements.enumerated() {
                    guard let elemPat else { continue }
                    let v = idx < items.count ? items[idx] : .undefined
                    try await bindPattern(elemPat, value: v, kind: kind, env: env, thisValue: thisValue, isInit: isInit)
                }
                if let rest {
                    let tail = elements.count < items.count ? Array(items[elements.count...]) : []
                    try await bindPattern(rest, value: .object(Arr(proto: builtins.Array, items: tail)), kind: kind, env: env, thisValue: thisValue, isInit: isInit)
                }
            case .object(let props, let rest, let loc):
                if value.isNullish {
                    throw typeError("Cannot destructure \(describeValue(value)) as it is \(value.isUndefined ? "undefined" : "null").", node: AstNode(type: "ObjectPattern", location: loc))
                }
                var usedKeys = Set<JSString>()
                for prop in props {
                    let key = try await evalPropertyKey(prop.key, env: env, thisValue: thisValue)
                    if let s = key.jsStringKey { usedKeys.insert(s) }
                    let propVal = try await readMember(value, key, node: AstNode(type: "ObjectPattern", location: loc))
                    try await bindPattern(prop.value, value: propVal, kind: kind, env: env, thisValue: thisValue, isInit: isInit)
                }
                if let rest {
                    let restObj = Obj(proto: builtins.Object)
                    if case .object(let src) = value {
                        try await copyDataPropertiesAsync(restObj, src, skip: Set(usedKeys.map { PropertyKey.string($0) }))
                    } else if case .string(let s) = value {
                        for (idx, chunk) in s.codePointStrings().enumerated() {
                            let k = JSString(String(idx))
                            if !usedKeys.contains(k) { define(restObj, k, .string(chunk)) }
                        }
                    }
                    try await bindPattern(rest, value: .object(restObj), kind: kind, env: env, thisValue: thisValue, isInit: isInit)
                }
            case .member(let objExpr, let propKey, let loc):
                let base = try await evalExpression(objExpr, env: env, thisValue: thisValue)
                let key = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                try await writeMember(base, key, value, node: AstNode(type: "MemberExpression", location: loc))
            case .superMember(let propKey, let loc):
                let node = AstNode(type: "MemberExpression", location: loc)
                let ref = try await superReference(propKey, env: env, thisValue: thisValue, node: node)
                try await writeSuper(base: ref.base, key: ref.key, receiver: ref.receiver, value: value, node: node)
            }
        }

        internal func evalPropertyKey(_ key: PropertyKeyExpr, env: LexEnv, thisValue: Value) async throws -> PropertyKey {
            switch key {
            case .identifier(let s, _): return .string(JSString(s))
            case .string(let s, _): return .string(s)
            case .number(let n, _): return .string(JSString(formatJSNumber(n)))
            case .computed(let expr, _):
                return propertyKey(try await evalExpression(expr, env: env, thisValue: thisValue))
            }
        }

        internal func evalExpression(_ expr: Expression, env: LexEnv, thisValue: Value) async throws -> Value {
            try checkLimits(at: expr.location)
            switch expr {
            case .literalNull: return .null
            case .literalBool(let b, _): return .bool(b)
            case .literalNumber(let n, _): return .number(n)
            case .literalString(let s, _): return .string(s)
            case .literalRegExp(let p, let f, _):
                return .object(try constructRegExp(builtins, args: [.string(JSString(p)), .string(JSString(f))]))
            case .identifier(let name, let loc):
                let node = AstNode(type: "Identifier", location: loc)
                if let marker = markerError(name, node: node) { throw marker }
                return try env.get(name, node: node)
            case .thisExpr(let loc):
                return try resolveThis(env, thisValue, node: AstNode(type: "ThisExpression", location: loc))
            case .array(let elements, _):
                var items: [Value] = []
                var holes = Set<Int>()
                for el in elements {
                    switch el {
                    case .hole:
                        holes.insert(items.count)
                        items.append(.undefined)
                    case .expr(let e): items.append(try await evalExpression(e, env: env, thisValue: thisValue))
                    case .spread(let e, _):
                        let v = try await evalExpression(e, env: env, thisValue: thisValue)
                        items.append(contentsOf: try await collectIterable(v))
                    }
                }
                try checkArrayLength(items.count)
                return .object(Arr(proto: builtins.Array, items: items, holes: holes))
            case .object(let props, _):
                let obj = Obj(proto: builtins.Object)
                for p in props {
                    switch p {
                    case .property(let keyExpr, let valExpr, _, _):
                        let k = try await evalPropertyKey(keyExpr, env: env, thisValue: thisValue)
                        let v: Value
                        if case .function(let payload) = valExpr, payload.kind == .method {
                            // A method has the object as its home, for `super`.
                            let fn = makeMethod(payload, home: obj, env: env)
                            if payload.name == nil { define(fn, "name", .string(methodName(k)), readonly) }
                            v = .object(fn)
                        } else {
                            v = try await evalNamedExpression(valExpr, name: methodName(k), env: env, thisValue: thisValue)
                        }
                        if k != .string("__proto__") { define(obj, k, v) }
                    case .accessor(let kind, let keyExpr, let payload, _):
                        // An object literal's `get x() {}` / `set x(v) {}`, named `get x` / `set x`.
                        let k = try await evalPropertyKey(keyExpr, env: env, thisValue: thisValue)
                        let fn = makeMethod(payload, home: obj, env: env)
                        define(fn, "name", .string("\(kind.rawValue) \(methodName(k))"), readonly)
                        defineAccessorHalf(obj, k, half: kind == .get ? .get : .set, fn: fn)
                    case .spread(let e, _):
                        let v = try await evalExpression(e, env: env, thisValue: thisValue)
                        if case .string(let text) = v {
                            // Matches upstream `enumerableSource` (`[...value]`): one property per code-point / lone-surrogate chunk.
                            for (i, chunk) in text.codePointStrings().enumerated() {
                                define(obj, JSString(String(i)), .string(chunk))
                            }
                        }
                        if case .object(let src) = v {
                            // Program getters in the source run as the copy reads them.
                            try await copyDataPropertiesAsync(obj, src, skip: [.string("__proto__")])
                        }
                    }
                }
                return .object(obj)
            case .function(let payload):
                if payload.isArrow {
                    // An arrow keeps the `this` of where it is made.
                    let arrowEnv = LexEnv(parent: env, isFunctionScope: false)
                    arrowEnv.declare("%arrowThis", value: thisValue, isConst: true)
                    return .object(Fn(proto: builtins.Function, payload: payload, closure: arrowEnv))
                }
                return .object(Fn(proto: builtins.Function, payload: payload, closure: env))
            case .classExpr(let cls):
                return try await evalClass(cls, env: env, thisValue: thisValue)
            case .superMember(let propKey, let loc):
                return try await readSuper(propKey, env: env, thisValue: thisValue, loc: loc).value
            case .superCall(let argSpecs, let passThrough, let loc):
                return try await evalSuperCall(argSpecs, passThrough: passThrough, env: env, thisValue: thisValue, loc: loc)
            case .templateLiteral(let quasis, let exprs, _):
                var parts: [JSString] = [quasis.first?.cooked ?? .empty]
                for (idx, e) in exprs.enumerated() {
                    parts.append(try await toStringValue(try await evalExpression(e, env: env, thisValue: thisValue)))
                    if idx + 1 < quasis.count { parts.append(quasis[idx + 1].cooked) }
                }
                let out = parts.joinedJS()
                try checkStringLength(out.utf16Count)
                return .string(out)
            case .taggedTemplate(let tag, let quasis, let exprs, let loc):
                let (calleeVal, receiverVal) = try await evalCallee(tag, env: env, thisValue: thisValue)
                guard isCallableValue(calleeVal) else {
                    throw notAFunction(calleeDescription(tag), node: AstNode(type: tag.nodeType, location: tag.location ?? loc))
                }
                let cookedArr = Arr(proto: builtins.Array, items: quasis.map { .string($0.cooked) })
                let rawArr = Arr(proto: builtins.Array, items: quasis.map { .string(JSString($0.raw)) })
                define(cookedArr, "raw", .object(rawArr), readonly)
                var args: [Value] = [.object(cookedArr)]
                for e in exprs { args.append(try await evalExpression(e, env: env, thisValue: thisValue)) }
                return try await callCallable(calleeVal, thisValue: receiverVal, args: args, site: AstNode(type: "TaggedTemplateExpression", location: loc))
            case .chain(let inner, _):
                return try await evalOptionalChain(inner, env: env, thisValue: thisValue)
            case .member(let objExpr, let propKey, let optional, let loc):
                let base = try await evalExpression(objExpr, env: env, thisValue: thisValue)
                if optional && base.isNullish { return .undefined }
                let key = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                return try await readMember(base, key, node: AstNode(type: "MemberExpression", location: loc))
            case .call(let calleeExpr, let argSpecs, let optional, let loc):
                let (calleeVal, recvVal) = try await evalCallee(calleeExpr, env: env, thisValue: thisValue)
                if optional && calleeVal.isNullish { return .undefined }
                let args = try await evalCallArgs(argSpecs, env: env, thisValue: thisValue)
                guard isCallableValue(calleeVal) else {
                    throw notAFunction(calleeDescription(calleeExpr), node: AstNode(type: calleeExpr.nodeType, location: calleeExpr.location ?? loc))
                }
                return try await callCallable(calleeVal, thisValue: recvVal, args: args, site: AstNode(type: "CallExpression", location: loc))
            case .newExpr(let calleeExpr, let argSpecs, let loc):
                let calleeVal = try await evalExpression(calleeExpr, env: env, thisValue: thisValue)
                let args = try await evalCallArgs(argSpecs, env: env, thisValue: thisValue)
                let node = AstNode(type: "NewExpression", location: loc)
                if case .object(let classCtor as Fn) = calleeVal, classCtor.klass != nil {
                    return try await constructClass(classCtor, args: args, newTarget: classCtor, site: node)
                }
                guard case .object(let b as Builtin) = calleeVal, let ctor = b.constructFn else {
                    throw notConstructible(calleeVal, name: calleeDescription(calleeExpr), node: node)
                }
                markSite(node)
                do {
                    return try await ctor(args, b, self)
                } catch {
                    throw locate(error, node: node)
                }
            case .unary(let op, let arg, let unaryLoc):
                switch op {
                case .typeof:
                    if case .identifier(let name, _) = arg, !env.hasBinding(name) {
                        return .string("undefined")
                    }
                    return .string(JSString(typeofValue(try await evalExpression(arg, env: env, thisValue: thisValue))))
                case .delete:
                    if case .superMember(let propKey, let loc) = arg {
                        // `delete super.x` evaluates the reference (`this` first, then the key) and always throws.
                        let node = AstNode(type: "UnaryExpression", location: loc)
                        _ = try resolveThis(env, thisValue, node: node)
                        _ = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                        throw referenceError("Unsupported reference to 'super'.", node: node)
                    }
                    if case .member(let objExpr, let propKey, _, _) = arg {
                        let base = try await evalExpression(objExpr, env: env, thisValue: thisValue)
                        let key = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                        if case .object(let obj) = base {
                            // Strict mode: deleting a non-configurable property is a TypeError.
                            guard remove(obj, key) else {
                                throw typeError("Cannot delete property '\(keyLabel(key))'.", node: AstNode(type: "UnaryExpression", location: unaryLoc))
                            }
                            return .bool(true)
                        }
                    }
                    return .bool(true)
                case .void:
                    _ = try await evalExpression(arg, env: env, thisValue: thisValue)
                    return .undefined
                case .not:
                    return .bool(!(try await evalExpression(arg, env: env, thisValue: thisValue).isTruthy))
                case .neg:
                    return .number(-(try await toNumberValue(try await evalExpression(arg, env: env, thisValue: thisValue))))
                case .plus:
                    return .number(try await toNumberValue(try await evalExpression(arg, env: env, thisValue: thisValue)))
                case .bitNot:
                    return .number(Double(~toInt32(coerceToNumber(try await evalExpression(arg, env: env, thisValue: thisValue)))))
                }
            case .update(let op, let arg, let prefix, let loc):
                let delta = op == .increment ? 1.0 : -1.0
                switch arg {
                case .identifier(let name, let il):
                    let oldNum = coerceToNumber(try env.get(name, node: AstNode(type: "Identifier", location: il)))
                    let newNum = oldNum + delta
                    try env.assign(name, value: .number(newNum), node: AstNode(type: "UpdateExpression", location: loc))
                    return .number(prefix ? newNum : oldNum)
                case .member(let objExpr, let propKey, false, _):
                    let base = try await evalExpression(objExpr, env: env, thisValue: thisValue)
                    let key = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                    let node = AstNode(type: "UpdateExpression", location: loc)
                    let oldNum = coerceToNumber(try await readMember(base, key, node: node))
                    let newNum = oldNum + delta
                    try await writeMember(base, key, .number(newNum), node: node)
                    return .number(prefix ? newNum : oldNum)
                case .superMember(let propKey, let sl):
                    let node = AstNode(type: "UpdateExpression", location: sl ?? loc)
                    let ref = try await superReference(propKey, env: env, thisValue: thisValue, node: node)
                    let oldNum = coerceToNumber(try await getValue(ref.base, ref.key, receiver: ref.receiver))
                    let newNum = oldNum + delta
                    try await writeSuper(base: ref.base, key: ref.key, receiver: ref.receiver, value: .number(newNum), node: node)
                    return .number(prefix ? newNum : oldNum)
                default:
                    throw syntaxError("Invalid left-hand side expression in update operation", node: AstNode(type: "UpdateExpression", location: loc))
                }
            case .binary(let op, let left, let right, let loc):
                var l = try await evalExpression(left, env: env, thisValue: thisValue)
                var r = try await evalExpression(right, env: env, thisValue: thisValue)
                if op == .instanceof {
                    // A program `Symbol.hasInstance` or `prototype` getter runs as program code.
                    return .bool(try await instanceOf(l, r, node: AstNode(type: "BinaryExpression", location: loc)))
                }
                // An object operand with program valueOf/toString converts as program code (ToPrimitive).
                if op != .seq && op != .sne && op != .in {
                    let isEquality = op == .eq || op == .ne
                    let lIsObject = if case .object = l { true } else { false }
                    let rIsObject = if case .object = r { true } else { false }
                    if case .object(let lo) = l, convertsInProgram(lo), !(isEquality && (rIsObject || r.isNullish)) {
                        l = try await toPrimitive(l, hint: op == .add || isEquality ? .default : .number)
                    }
                    if case .object(let ro) = r, convertsInProgram(ro), !(isEquality && (lIsObject || l.isNullish)) {
                        r = try await toPrimitive(r, hint: op == .add || isEquality ? .default : .number)
                    }
                }
                return try applyBinaryOperator(op, l, r, node: AstNode(type: "BinaryExpression", location: loc))
            case .logical(let op, let left, let right, _):
                let l = try await evalExpression(left, env: env, thisValue: thisValue)
                switch op {
                case .and: return l.isTruthy ? try await evalExpression(right, env: env, thisValue: thisValue) : l
                case .or: return l.isTruthy ? l : try await evalExpression(right, env: env, thisValue: thisValue)
                case .nullish: return l.isNullish ? try await evalExpression(right, env: env, thisValue: thisValue) : l
                }
            case .conditional(let test, let cons, let alt, _):
                if try await evalExpression(test, env: env, thisValue: thisValue).isTruthy {
                    return try await evalExpression(cons, env: env, thisValue: thisValue)
                }
                return try await evalExpression(alt, env: env, thisValue: thisValue)
            case .assignment(let op, let left, let right, let loc):
                if op == .assign {
                    let rVal: Value
                    if case .identifier(let name, _) = left {
                        rVal = try await evalNamedExpression(right, name: JSString(name), env: env, thisValue: thisValue)
                    } else {
                        rVal = try await evalExpression(right, env: env, thisValue: thisValue)
                    }
                    try await bindPattern(left, value: rVal, kind: nil, env: env, thisValue: thisValue, isInit: false)
                    return rVal
                }
                return try await evalCompoundAssignment(op: op, left: left, right: right, env: env, thisValue: thisValue, loc: loc)
            case .sequence(let exprs, _):
                var last: Value = .undefined
                for e in exprs { last = try await evalExpression(e, env: env, thisValue: thisValue) }
                return last
            case .awaitExpr(let arg, let loc):
                let val = try await evalExpression(arg, env: env, thisValue: thisValue)
                let node = AstNode(type: "AwaitExpression", location: loc)
                markSite(node)
                return try await awaitValue(val, node: node)
            case .yieldExpr(let arg, let delegate, _):
                let val: Value = if let arg { try await evalExpression(arg, env: env, thisValue: thisValue) } else { .undefined }
                let isAsync = Fiber.current?.generator?.isAsync ?? false
                if delegate {
                    return try await yieldDelegate(val, isAsync: isAsync)
                }
                return try await yieldValue(val, isAsync: isAsync)
            case .importExpr(let srcExpr, _):
                let spec = coerceToString(try await evalExpression(srcExpr, env: env, thisValue: thisValue)).toWellFormedString()
                do {
                    let mod = try loadModule(spec)
                    return .object(PromiseObj(proto: builtins.Promise, status: .fulfilled(mod)))
                } catch {
                    return .object(PromiseObj(proto: builtins.Promise, status: .rejected(materialize(builtins, error))))
                }
            }
        }

        private func evalOptionalChain(_ expr: Expression, env: LexEnv, thisValue: Value) async throws -> Value {
            switch expr {
            case .member(let objExpr, let propKey, let optional, let loc):
                let base = try await evalOptionalChain(objExpr, env: env, thisValue: thisValue)
                if base.isNullish {
                    if optional { return .undefined }
                    // Short-circuit if an earlier optional link yielded undefined
                    return .undefined
                }
                let key = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                return try await readMember(base, key, node: AstNode(type: "MemberExpression", location: loc))
            case .call(let calleeExpr, let argSpecs, let optional, let loc):
                let (calleeVal, recvVal) = try await evalOptionalCallee(calleeExpr, env: env, thisValue: thisValue)
                if calleeVal.isNullish {
                    if optional { return .undefined }
                    return .undefined
                }
                let args = try await evalCallArgs(argSpecs, env: env, thisValue: thisValue)
                guard isCallableValue(calleeVal) else {
                    throw notAFunction(calleeDescription(calleeExpr), node: AstNode(type: calleeExpr.nodeType, location: calleeExpr.location ?? loc))
                }
                return try await callCallable(calleeVal, thisValue: recvVal, args: args, site: AstNode(type: "CallExpression", location: loc))
            default:
                return try await evalExpression(expr, env: env, thisValue: thisValue)
            }
        }

        private func evalOptionalCallee(_ expr: Expression, env: LexEnv, thisValue: Value) async throws -> (Value, Value) {
            if case .member(let objExpr, let propKey, _, let loc) = expr {
                let base = try await evalOptionalChain(objExpr, env: env, thisValue: thisValue)
                if base.isNullish { return (.undefined, .undefined) }
                let key = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                let fn = try await readMember(base, key, node: AstNode(type: "MemberExpression", location: loc))
                return (fn, base)
            }
            if case .superMember(let propKey, let loc) = expr {
                let read = try await readSuper(propKey, env: env, thisValue: thisValue, loc: loc)
                return (read.value, read.receiver)
            }
            let fn = try await evalOptionalChain(expr, env: env, thisValue: thisValue)
            return (fn, .undefined)
        }

        private func evalCompoundAssignment(
            op: AssignmentOperator,
            left: Pattern,
            right: Expression,
            env: LexEnv,
            thisValue: Value,
            loc: SourceLocation?
        ) async throws -> Value {
            let currentVal: Value
            let writeBack: (Value) async throws -> Void
            let node = AstNode(type: "AssignmentExpression", location: loc)

            switch left {
            case .identifier(let name, _):
                currentVal = try env.get(name, node: node)
                writeBack = { try env.assign(name, value: $0, node: node) }
            case .member(let objExpr, let propKey, _):
                let base = try await evalExpression(objExpr, env: env, thisValue: thisValue)
                let key = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                currentVal = try await readMember(base, key, node: node)
                writeBack = { try await self.writeMember(base, key, $0, node: node) }
            case .superMember(let propKey, _):
                let ref = try await superReference(propKey, env: env, thisValue: thisValue, node: node)
                currentVal = try await getValue(ref.base, ref.key, receiver: ref.receiver)
                writeBack = { try await self.writeSuper(base: ref.base, key: ref.key, receiver: ref.receiver, value: $0, node: node) }
            default:
                throw syntaxError("Invalid left-hand side in compound assignment", node: node)
            }

            switch op {
            case .andAssign:
                if !currentVal.isTruthy { return currentVal }
                let rv = try await evalExpression(right, env: env, thisValue: thisValue)
                try await writeBack(rv)
                return rv
            case .orAssign:
                if currentVal.isTruthy { return currentVal }
                let rv = try await evalExpression(right, env: env, thisValue: thisValue)
                try await writeBack(rv)
                return rv
            case .nullishAssign:
                if !currentVal.isNullish { return currentVal }
                let rv = try await evalExpression(right, env: env, thisValue: thisValue)
                try await writeBack(rv)
                return rv
            default:
                let rVal = try await evalExpression(right, env: env, thisValue: thisValue)
                let binOp: BinaryOperator
                switch op {
                case .addAssign: binOp = .add
                case .subAssign: binOp = .sub
                case .mulAssign: binOp = .mul
                case .divAssign: binOp = .div
                case .modAssign: binOp = .mod
                case .expAssign: binOp = .exp
                case .bitAndAssign: binOp = .bitAnd
                case .bitOrAssign: binOp = .bitOr
                case .bitXorAssign: binOp = .bitXor
                case .shlAssign: binOp = .shl
                case .sarAssign: binOp = .sar
                case .shrAssign: binOp = .shr
                default: binOp = .add
                }
                let result = try applyBinaryOperator(binOp, currentVal, rVal, node: node)
                try await writeBack(result)
                return result
            }
        }

        private func evalCallee(_ expr: Expression, env: LexEnv, thisValue: Value) async throws -> (Value, Value) {
            if case .member(let objExpr, let propKey, let optional, let loc) = expr {
                let base = try await evalExpression(objExpr, env: env, thisValue: thisValue)
                if optional && base.isNullish { return (.undefined, .undefined) }
                let key = try await evalPropertyKey(propKey, env: env, thisValue: thisValue)
                let fn = try await readMember(base, key, node: AstNode(type: "MemberExpression", location: loc))
                return (fn, base)
            }
            if case .superMember(let propKey, let loc) = expr {
                // `super.m()` calls the parent's method with this method's `this`.
                let read = try await readSuper(propKey, env: env, thisValue: thisValue, loc: loc)
                return (read.value, read.receiver)
            }
            let fn = try await evalExpression(expr, env: env, thisValue: thisValue)
            return (fn, .undefined)
        }

        func evalCallArgs(_ specs: [CallArgument], env: LexEnv, thisValue: Value) async throws -> [Value] {
            var out: [Value] = []
            for spec in specs {
                switch spec {
                case .expr(let e):
                    out.append(try await evalExpression(e, env: env, thisValue: thisValue))
                case .spread(let e, _):
                    let v = try await evalExpression(e, env: env, thisValue: thisValue)
                    out.append(contentsOf: try await collectIterable(v))
                }
            }
            return out
        }

        public func callCallable(_ callee: Value, thisValue: Value, args: [Value], site: AstNode?) async throws -> Value {
            try enterCall(site: site)
            defer { exitCall() }
            markSite(site)

            if case .hostNamespace(let ns) = callee {
                let target = ns.handler.resolve(ns.path)
                let label = ns.path.joined(separator: ".")
                switch target {
                case .failure(let hf):
                    // Return rejected promise for missing async tool
                    let p = PromiseObj(proto: builtins.Promise, status: .rejected(materialize(builtins, hf)), rawRejection: hf)
                    return .object(p)
                case .fn(let hostFn):
                    let wrapped = wrapHostFn(name: label, hostFn: hostFn, builtins: builtins, hostCalls: hostCalls, translate: translate, adapt: adapt)
                    return try await wrapped.callFn(thisValue, args, site, self)
                case .durable(let durable):
                    let wrapped = wrapDurableFn(name: label, durable: durable, builtins: builtins, hostCalls: hostCalls)
                    return try await wrapped.callFn(thisValue, args, site, self)
                }
            }

            guard case .object(let obj) = callee else {
                throw notAFunction(nil, node: site)
            }

            if let resolver = obj as? Resolver {
                callResolver(resolver, args.first ?? .undefined)
                return .undefined
            }

            if let bound = obj as? BoundFn {
                return try await callCallable(.object(bound.target), thisValue: bound.boundThis, args: bound.boundArgs + args, site: site)
            }

            if let nativeObj = obj as? Builtin {
                do {
                    return try await nativeObj.callFn(thisValue, args, site, self)
                } catch {
                    throw locate(error, node: site)
                }
            }

            if let fnObj = obj as? Fn {
                let payload = fnObj.payload
                if case .classConstructor = payload.kind {
                    throw typeError("Class constructor \(coerceToString(peek(fnObj, .string("name")))) cannot be invoked without 'new'", node: site)
                }
                if payload.isGenerator {
                    // The body runs lazily, as a fiber, while next/return/throw drive it.
                    let proto: Obj = {
                        if case .object(let p) = peek(fnObj, .string("prototype")) { return p }
                        return payload.isAsync ? builtins.AsyncGenerator : builtins.Generator
                    }()
                    let gen = GeneratorObj(proto: proto, isAsync: payload.isAsync) { [self] in
                        try await executeFunctionBody(fnObj, thisValue: thisValue, args: args)
                    }
                    return .object(gen)
                }
                if payload.isAsync {
                    let promise = await startAsyncFunction { [self] in
                        try await executeFunctionBody(fnObj, thisValue: thisValue, args: args)
                    }
                    return .object(promise)
                }
                return try await executeFunctionBody(fnObj, thisValue: thisValue, args: args)
            }

            throw notAFunction(nil, node: site)
        }

        private func executeFunctionBody(_ fnObj: Fn, thisValue: Value, args: [Value]) async throws -> Value {
            if fnObj.payload.kind == .fieldInit {
                return try await withFrame(fnObj) {
                    try await runFieldInitializer(fnObj, thisValue: thisValue)
                }
            }
            return try await runFunctionBody(fnObj, thisValue: thisValue, args: args).value
        }

        /// Runs a function's body as a new program frame: `prepare` sees its environment before the parameters are
        /// bound, and `beforeBody` after (a base class constructor defines its fields there). Answers the return value
        /// and the environment.
        func runFunctionBody(
            _ fnObj: Fn,
            thisValue: Value,
            args: [Value],
            prepare: (LexEnv) -> Void = { _ in },
            beforeBody: (LexEnv) async throws -> Void = { _ in }
        ) async throws -> (value: Value, env: LexEnv) {
            let fnEnv = LexEnv(parent: fnObj.closure, isFunctionScope: true)
            prepare(fnEnv)
            let value = try await withFrame(fnObj) {
                try await runBody(fnObj, fnEnv: fnEnv, thisValue: thisValue, args: args, beforeBody: beforeBody)
            }
            return (value, fnEnv)
        }

        private func runBody(
            _ fnObj: Fn,
            fnEnv: LexEnv,
            thisValue: Value,
            args: [Value],
            beforeBody: (LexEnv) async throws -> Void
        ) async throws -> Value {
            let payload = fnObj.payload
            // An arrow runs with the `this` of where it was made.
            let effectiveThis = payload.isArrow ? ((try? fnObj.closure.get("%arrowThis")) ?? thisValue) : thisValue
            if !payload.isArrow {
                // Only a named function expression binds its own name; a method's name is just its key.
                if payload.kind == .normal, let selfName = payload.name {
                    fnEnv.declare(selfName, value: .object(fnObj), isConst: true, initialized: true)
                }
                fnEnv.declare("arguments", value: .object(Arguments(proto: builtins.Object, values: args)), isConst: false, initialized: true)
            }

            // Bind parameters (including rest & defaults)
            for (idx, param) in payload.params.enumerated() {
                if case .array(let els, let restPat?, _) = param, els.isEmpty {
                    // Rest parameter `...rest`
                    let tail = idx < args.count ? Array(args[idx...]) : []
                    for n in collectPatternNames(restPat) { fnEnv.declare(n, value: .undefined, isConst: false, initialized: false) }
                    try await bindPattern(restPat, value: .object(Arr(proto: builtins.Array, items: tail)), kind: .let, env: fnEnv, thisValue: effectiveThis, isInit: true)
                } else {
                    for n in collectPatternNames(param) { fnEnv.declare(n, value: .undefined, isConst: false, initialized: false) }
                    let val = idx < args.count ? args[idx] : .undefined
                    try await bindPattern(param, value: val, kind: .let, env: fnEnv, thisValue: effectiveThis, isInit: true)
                }
            }

            try await beforeBody(fnEnv)
            switch payload.body {
            case .expression(let expr):
                return try await evalExpression(expr, env: fnEnv, thisValue: effectiveThis)
            case .block(let stmts):
                hoistStatements(stmts, into: fnEnv)
                do {
                    for stmt in stmts {
                        _ = try await evalStatement(stmt, env: fnEnv, thisValue: effectiveThis)
                    }
                    return .undefined
                } catch ControlSignal.returnValue(let val) {
                    return val
                }
            }
        }

        /// An open iteration for `for...of`: `step` answers the next value (nil when done), `close` runs IteratorClose
        /// when the loop exits early: an error exit keeps its error, any other exit sees a failing `return()`.
        public struct Iteration: Sendable {
            public let step: @Sendable () async throws -> Value?
            public let close: @Sendable (Error?) async throws -> Void
        }

        public func openIteration(_ value: Value, async isAsync: Bool = false) async throws -> Iteration {
            if !isAsync, let cursor = builtinCursor(value, builtins: builtins) {
                return Iteration(step: {
                    let step = try cursor.next()
                    return step.done ? nil : step.value
                }, close: { _ in })
            }
            var iterFn: Value = .undefined
            var syncFallback = false
            if case .object(let source) = value {
                if isAsync {
                    iterFn = try await redoRead(source, .symbol(AsyncIteratorSymbol), receiver: value)
                }
                if iterFn.isNullish {
                    iterFn = try await redoRead(source, .symbol(IteratorSymbol), receiver: value)
                    syncFallback = isAsync
                }
            }
            else if case .string = value {
                iterFn = get(builtins.String, .symbol(IteratorSymbol))
            }
            let viaSync = syncFallback
            guard case .object(let iterCallable) = iterFn, iterCallable is Callable else {
                _ = try requireIteratorMethod(value, async: isAsync)
                throw typeError("\(describeValue(value)) is not iterable.")
            }
            let iterVal = try await callCallable(iterFn, thisValue: value, args: [], site: nil)
            let iterObj = try requireIteratorObject(iterVal)
            let nextFn = try await redoRead(iterObj, .string("next"), receiver: .object(iterObj))
            let awaitsSteps = isAsync && !viaSync
            return Iteration(step: { [self] in
                var stepVal = try await callCallable(nextFn, thisValue: .object(iterObj), args: [], site: nil)
                if awaitsSteps { stepVal = try await awaitValue(stepVal) }
                let stepObj = try requireIteratorObject(stepVal)
                if try await redoRead(stepObj, .string("done"), receiver: stepVal).isTruthy { return nil }
                let item = try await redoRead(stepObj, .string("value"), receiver: stepVal)
                // A for-await over a synchronous iterator awaits each value (Async-from-Sync iterator).
                return viaSync ? try await awaitValue(item) : item
            }, close: { [self] error in
                let closer: Value
                do {
                    closer = try await redoRead(iterObj, .string("return"), receiver: .object(iterObj))
                } catch {
                    if error is Interruption { throw error }
                    return
                }
                guard isCallableValue(closer) else { return }
                do {
                    var result = try await callCallable(closer, thisValue: .object(iterObj), args: [], site: nil)
                    if awaitsSteps { result = try await awaitValue(result) }
                    if error == nil { _ = try requireIteratorObject(result) }
                } catch let closeError {
                    if closeError is Interruption { throw closeError }
                    if error == nil { throw closeError }
                }
            })
        }

        public func collectIterable(_ value: Value, async isAsync: Bool = false) async throws -> [Value] {
            if let cursor = builtinCursor(value, builtins: builtins) {
                var out: [Value] = []
                while true {
                    let step = try cursor.next()
                    if step.done { break }
                    out.append(step.value)
                    try checkArrayLength(out.count)
                }
                return out
            }
            // Each read of the iterator protocol may meet a program getter, which runs as program code (`redoRead`).
            var iterFn: Value = .undefined
            if case .object(let source) = value {
                if isAsync {
                    iterFn = try await redoRead(source, .symbol(AsyncIteratorSymbol), receiver: value)
                }
                if iterFn.isNullish {
                    iterFn = try await redoRead(source, .symbol(IteratorSymbol), receiver: value)
                }
            }
            guard case .object(let iterCallable) = iterFn, iterCallable is Callable else {
                _ = try requireIteratorMethod(value, async: isAsync)
                throw typeError("\(describeValue(value)) is not iterable.")
            }
            let iterVal = try await callCallable(iterFn, thisValue: value, args: [], site: nil)
            let iterObj = try requireIteratorObject(iterVal)
            let nextFn = try await redoRead(iterObj, .string("next"), receiver: .object(iterObj))
            var out: [Value] = []
            while true {
                try checkLimits()
                var stepVal = try await callCallable(nextFn, thisValue: .object(iterObj), args: [], site: nil)
                if isAsync { stepVal = try await awaitValue(stepVal) }
                let stepObj = try requireIteratorObject(stepVal)
                if try await redoRead(stepObj, .string("done"), receiver: stepVal).isTruthy { break }
                out.append(try await redoRead(stepObj, .string("value"), receiver: stepVal))
                try checkArrayLength(out.count)
            }
            return out
        }
    }

    // MARK: - VM, Interpreter, Driver, Execute & Runtime (vm.ts, interpreter.ts, driver.ts, execute.ts, runtime.ts)

    // parity: psychoscript/src/vm.ts#Mode [status=adapted hash=4fc8dc0bb686]
    public enum Mode: Int, Equatable, Hashable, Sendable, Codable {
        case normal = 0
        /// A class constructor run by `new`: hands the caller its result if that is an object, else its `this`.
        case construct = 1
        case generator = 2
        case asyncFn = 3
        /// Runs a program getter an iterator op met, then runs the op again with the reads it had made (`redoRead`).
        case redo = 7
    }

    // parity: psychoscript/src/vm.ts#FrameMode [status=implemented hash=ad67f6e3b617]
    public typealias FrameMode = Mode

    // parity: psychoscript/src/vm.ts#CustomIter [status=implemented hash=656e974c2c67]
    public final class CustomIter: Sendable {
        public let iterator: Obj
        public let nextMethod: Value

        public init(iterator: Obj, nextMethod: Value) {
            self.iterator = iterator
            self.nextMethod = nextMethod
        }
    }

    // parity: psychoscript/src/vm.ts#Frame [status=implemented hash=5e66f46cd78a]
    public final class Frame: Sendable {
        private struct State: Sendable {
            var code: Code
            var mode: FrameMode
            var pc: Int = 0
            var sp: Int = 0
            var regs: [Value]
            var fn: Fn? = nil
            var thisValue: Value = .undefined
            var args: [Value]? = nil
            var target: SettlingTarget? = nil
            var answer: Value? = nil
            var origin: AstNode? = nil
            var counted: Bool = false
        }

        private let state: Mutex<State>

        public var code: Code {
            get { state.withLock { $0.code } }
            set { state.withLock { $0.code = newValue } }
        }

        public var mode: FrameMode {
            get { state.withLock { $0.mode } }
            set { state.withLock { $0.mode = newValue } }
        }

        public var pc: Int {
            get { state.withLock { $0.pc } }
            set { state.withLock { $0.pc = newValue } }
        }

        public var sp: Int {
            get { state.withLock { $0.sp } }
            set { state.withLock { $0.sp = newValue } }
        }

        public var regs: [Value] {
            get { state.withLock { $0.regs } }
            set { state.withLock { $0.regs = newValue } }
        }

        public var fn: Fn? {
            get { state.withLock { $0.fn } }
            set { state.withLock { $0.fn = newValue } }
        }

        public var thisValue: Value {
            get { state.withLock { $0.thisValue } }
            set { state.withLock { $0.thisValue = newValue } }
        }

        public var args: [Value]? {
            get { state.withLock { $0.args } }
            set { state.withLock { $0.args = newValue } }
        }

        public var target: SettlingTarget? {
            get { state.withLock { $0.target } }
            set { state.withLock { $0.target = newValue } }
        }

        public var answer: Value? {
            get { state.withLock { $0.answer } }
            set { state.withLock { $0.answer = newValue } }
        }

        public var origin: AstNode? {
            get { state.withLock { $0.origin } }
            set { state.withLock { $0.origin = newValue } }
        }

        public var counted: Bool {
            get { state.withLock { $0.counted } }
            set { state.withLock { $0.counted = newValue } }
        }

        public init(code: Code, mode: FrameMode = .normal) {
            let regCount = max(1, code.locals + code.maxStack)
            self.state = Mutex(State(
                code: code,
                mode: mode,
                sp: code.locals,
                regs: Array(repeating: .undefined, count: regCount)
            ))
        }

        public func pushReg(_ value: Value) {
            state.withLock { s in
                if s.sp >= s.regs.count {
                    s.regs.append(value)
                } else {
                    s.regs[s.sp] = value
                }
                s.sp += 1
            }
        }
    }

    // parity: psychoscript/src/vm.ts#VmInternalFn [status=implemented hash=1c84e73ac993]
    public final class VmInternalFn: Callable, @unchecked Sendable {
        public let fnName: String

        public init(proto: Obj?, name: String) {
            self.fnName = name
            super.init(proto: proto)
        }
    }

    // parity: psychoscript/src/vm.ts#Vm [status=adapted hash=b6d00af2d76d]
    public final class Vm: HostVm, Sendable {
        private struct ExecutionState: Sendable {
            var sources: [Source] = []
            var sourceCodes: [String: [Code]] = [:]
            var frames: [Frame] = []
            var pool: [Frame] = []
            var depth: Int = 0
            var diagnostics: [Diagnostic] = []
            var lastCompletion: Completion? = nil
        }

        public let interpreter: Interpreter
        public let scheduler: VmScheduler
        public var builtins: Builtins { interpreter.builtins }
        public var hostCalls: HostCalls { interpreter.hostCalls }
        private let state = Mutex(ExecutionState())
        public let tripEvery: Int

        public init(interpreter: Interpreter, tripEvery: Int = 0) {
            self.interpreter = interpreter
            self.scheduler = VmScheduler(builtins: interpreter.builtins)
            self.tripEvery = tripEvery
            let evaluator = interpreter.evaluator
            scheduler.callProgram = { callee, thisValue, args in
                try await evaluator.callCallable(.object(callee), thisValue: thisValue, args: args, site: nil)
            }
        }

        public var sources: [Source] { state.withLock { $0.sources } }

        public func registerSource(_ source: Source) {
            state.withLock { $0.sources.append(source) }
            interpreter.registerSource(source)
        }

        public func addDiagnostic(_ diagnostic: Diagnostic) {
            state.withLock { $0.diagnostics.append(diagnostic) }
        }

        /// Compiles and loads `source` onto the VM call stack as the entry frame.
        // parity: psychoscript/src/vm.ts#Vm.start [status=implemented hash=d4b485527712]
        public func start(_ source: Source) {
            registerSource(source)
            let codes = CodemodeLanguage.compileSource(source)
            state.withLock { s in
                s.sourceCodes[source.id] = codes
                s.lastCompletion = nil
            }
            if let entry = codes.first {
                let frame = acquire(entry)
                frame.mode = .normal
                state.withLock { s in
                    s.frames.append(frame)
                }
            }
        }

        /// Advances the VM until a stop point: completed, waiting on host work, or yielding a slice.
        // parity: psychoscript/src/vm.ts#Vm.run [status=implemented hash=250cd0f20d41]
        public func run() -> Stop {
            while hostCalls.deliver() {}
            let hasFrames = state.withLock { !$0.frames.isEmpty }
            if hasFrames {
                let top = state.withLock { s -> Frame? in
                    let f = s.frames.popLast()
                    return f
                }
                if let top {
                    release(top)
                }
                let result = state.withLock { $0.lastCompletion ?? Completion.ok(.undefined) }
                return .done(result)
            }
            if !hostCalls.calls().isEmpty {
                return .waitHost
            }
            if scheduler.hasJobs {
                return .slice
            }
            let completion = state.withLock { $0.lastCompletion ?? Completion.ok(.undefined) }
            return .done(completion)
        }

        /// Reports completion of an in-flight host call back to the VM's host bridge.
        // parity: psychoscript/src/vm.ts#Vm.complete [status=implemented hash=ff392d61dd4e]
        public func complete(id: Int, completion: Completion) {
            hostCalls.complete(id: id, completion: completion)
        }

        /// Whether `run()` has immediately runnable work (pending input, inbox completions, or microtask jobs).
        // parity: psychoscript/src/vm.ts#Vm.ready [status=implemented hash=f378e86b0c79]
        public var ready: Bool {
            let noFrames = state.withLock { $0.frames.isEmpty }
            return hostCalls.hasPendingInput || (noFrames && (hostCalls.hasInbox || scheduler.hasJobs))
        }

        /// Looks up an active in-flight host call by numeric ID.
        // parity: psychoscript/src/vm.ts#Vm.call [status=implemented hash=f4e1dfb544ad]
        public func call(_ id: Int) -> HostCall? {
            hostCalls.call(id: id)
        }

        /// Returns all in-flight host calls in creation order.
        // parity: psychoscript/src/vm.ts#Vm.calls [status=implemented hash=c55cea1bda08]
        public func calls() -> [HostCall] {
            hostCalls.calls()
        }

        /// Compacts the VM scheduler job queue.
        // parity: psychoscript/src/vm.ts#Vm.compact [status=implemented hash=09325bcfc547]
        public func compact() {
            scheduler.compact()
        }

        /// Flushes completed host deliveries and returns collected diagnostics and unhandled rejections.
        // parity: psychoscript/src/vm.ts#Vm.diagnostics [status=implemented hash=57c08f05cfb2]
        public func diagnostics() -> [Diagnostic] {
            while hostCalls.deliver() {}
            return state.withLock { $0.diagnostics } + scheduler.diagnostics() + interpreter.evaluator.currentWarnings()
        }

        /// Captures a serializable snapshot of the VM state.
        // parity: psychoscript/src/vm.ts#Vm.capture [status=implemented hash=4d6fe18a6666]
        public func capture(_ options: CaptureOptions = CaptureOptions()) throws -> (snapshot: Snapshot, lost: [Lost]) {
            try captureVm(self, options: options)
        }

        /// Restores a previously captured snapshot into this VM.
        // parity: psychoscript/src/vm.ts#Vm.restore [status=implemented hash=882ad1529ba2]
        public func restore(_ saved: Snapshot, options: RestoreOptions) throws -> Snapshot {
            try restoreVm(self, saved: saved, options: options)
        }

        /// Delivers a deferred frame answer onto the caller frame's stack and advances its PC.
        // parity: psychoscript/src/vm.ts#Vm.deliverAnswer [status=implemented hash=c913edb8ceb3]
        public func deliverAnswer(_ frame: Frame) {
            guard let answer = frame.answer else { return }
            frame.answer = nil
            if let caller = state.withLock({ $0.frames.last }) {
                caller.pushReg(answer)
                caller.pc += 1
            }
        }

        /// Acquires a pooled or fresh `Frame` sized for `code`.
        // parity: psychoscript/src/vm.ts#Vm.acquire [status=implemented hash=4314617298a4]
        public func acquire(_ code: Code) -> Frame {
            let size = max(1, code.locals + code.maxStack)
            if let reused = state.withLock({ $0.pool.popLast() }) {
                reused.code = code
                reused.pc = 0
                reused.sp = code.locals
                if reused.regs.count < size {
                    reused.regs = Array(repeating: .undefined, count: size)
                } else {
                    var regs = reused.regs
                    for i in 0..<code.locals { regs[i] = .undefined }
                    reused.regs = regs
                }
                return reused
            }
            return Frame(code: code)
        }

        /// Releases a finished frame back into the frame pool (capped at 128 entries).
        // parity: psychoscript/src/vm.ts#Vm.release [status=implemented hash=724fe40cf768]
        public func release(_ frame: Frame) {
            let wasCounted = frame.counted
            frame.fn = nil
            frame.thisValue = .undefined
            frame.args = nil
            frame.target = nil
            frame.answer = nil
            frame.origin = nil
            frame.counted = false
            state.withLock { s in
                if wasCounted && s.depth > 0 { s.depth -= 1 }
                if s.pool.count < 128 {
                    s.pool.append(frame)
                }
            }
        }

        /// Resolves the nearest non-internal frame's AST site, or the bottom internal frame's origin.
        // parity: psychoscript/src/vm.ts#Vm.currentSite [status=implemented hash=293647750574]
        public func currentSite() -> AstNode? {
            let frames = state.withLock { $0.frames }
            for frame in frames.reversed() {
                if (frame.code.flags & CodeFlags.INTERNAL) == 0 {
                    return frame.code.siteAt(frame.pc)
                }
                if let origin = frame.origin {
                    return origin
                }
            }
            return nil
        }

        /// The program frames on the stack as `stack` lines, innermost first, at most 10 as V8's
        /// `Error.stackTraceLimit`: the evaluator's frames of the running task.
        // parity: psychoscript/src/vm.ts#Vm.stackTrace [status=adapted hash=51c86bd8a6a2]
        public func stackTrace() -> String {
            interpreter.evaluator.stackTrace()
        }

        /// One property read of an iterator op that may meet a program getter; see `Evaluator.redoRead`.
        public func redoRead(_ target: Obj, _ key: PropertyKey, receiver: Value, site: AstNode? = nil) async throws -> Value {
            try await interpreter.evaluator.redoRead(target, key, receiver: receiver, site: site)
        }

        /// Unwinds active call frames looking for an exception handler matching `pc`, settling target frames along the way.
        /// A handler in program code gets the failure with the faulting site, so a host failure's `stack` names it.
        // parity: psychoscript/src/vm.ts#Vm.unwind [status=implemented hash=7481dd7b5f03]
        @discardableResult
        public func unwind(_ rawError: Error) -> Bool {
            while let frame = state.withLock({ $0.frames.last }) {
                let handlers = frame.code.handlers
                let pc = frame.pc
                var i = 0
                while i + 3 < handlers.count {
                    let start = Int(handlers[i])
                    let end = Int(handlers[i + 1])
                    let target = Int(handlers[i + 2])
                    let depth = Int(handlers[i + 3])
                    if pc >= start && pc < end {
                        let site = (frame.code.flags & CodeFlags.INTERNAL) == 0 ? frame.code.siteAt(pc) : nil
                        frame.pc = target
                        frame.sp = frame.code.locals + depth
                        frame.pushReg(CodemodeLanguage.materialize(builtins, rawError, site: site))
                        return true
                    }
                    i += 4
                }
                let popped = state.withLock { $0.frames.popLast() }
                if let popped {
                    if let target = popped.target {
                        switch target {
                        case .promise(let p): p.reject(CodemodeLanguage.materialize(builtins, rawError))
                        case .resolving(let r): r.reject(rawError)
                        case .finallyTarget(let f): f.reject(rawError)
                        case .asyncClose(let c): c.reject(rawError)
                        }
                    }
                    deliverAnswer(popped)
                    release(popped)
                }
            }
            state.withLock { $0.lastCompletion = .error(rawError) }
            return false
        }

        /// Pushes a program `Fn` call frame onto the VM call stack.
        // parity: psychoscript/src/vm.ts#Vm.pushFn [status=implemented hash=f50de824da3f]
        public func pushFn(
            _ fn: Fn,
            thisValue: Value = .undefined,
            args: [Value] = [],
            origin: AstNode? = nil,
            mode: FrameMode = .normal,
            target: SettlingTarget? = nil,
            answer: Value? = nil
        ) {
            let code = fn.code ?? Code(
                source: SourceRef(id: "inline", hash: ""),
                index: 0,
                name: fn.payload.name ?? "",
                flags: 0,
                length: fn.payload.params.count,
                params: fn.payload.params.count,
                locals: fn.payload.params.count,
                maxStack: 8,
                code: [],
                consts: []
            )
            let frame = acquire(code)
            frame.fn = fn
            frame.thisValue = thisValue
            frame.args = args
            frame.origin = origin
            frame.mode = mode
            frame.target = target
            frame.answer = answer
            let counted = (code.flags & CodeFlags.INTERNAL) == 0
            frame.counted = counted
            state.withLock { s in
                if counted { s.depth += 1 }
                s.frames.append(frame)
            }
        }

        /// Pushes an internal helper frame onto the VM call stack.
        // parity: psychoscript/src/vm.ts#Vm.pushInternal [status=implemented hash=bff7e8f3e374]
        public func pushInternal(
            _ code: Code,
            args: [Value] = [],
            origin: AstNode? = nil,
            mode: FrameMode = .normal,
            target: SettlingTarget? = nil,
            answer: Value? = nil
        ) {
            let frame = acquire(code)
            frame.args = args
            frame.origin = origin
            frame.mode = mode
            frame.target = target
            frame.answer = answer
            frame.counted = false
            for (idx, val) in args.enumerated() where idx < code.locals {
                var regs = frame.regs
                regs[idx] = val
                frame.regs = regs
            }
            state.withLock { s in
                s.frames.append(frame)
            }
        }
    }

    // parity: psychoscript/src/runtime/interpreter.ts#NamespaceHandler [status=implemented hash=9f4ed7a63060]
    public struct NamespaceHandler: Sendable {
        public let keys: @Sendable ([String]) throws -> [String]
        public let resolve: @Sendable ([String]) -> Host.ResolvedTarget

        public init(
            keys: @escaping @Sendable ([String]) throws -> [String],
            resolve: @escaping @Sendable ([String]) -> Host.ResolvedTarget
        ) {
            self.keys = keys
            self.resolve = resolve
        }
    }

    // parity: psychoscript/src/runtime/interpreter.ts#Interpreter [status=adapted hash=30594444cbab]
    public final class Interpreter: Sendable {
        private struct CacheState: Sendable {
            var modules: [String: Value] = [:]
            var namespaces: [String: Obj] = [:]
            var sources: [String: Source] = [:]
        }

        public let builtins: Builtins
        public let hostCalls: HostCalls
        public let evaluator: Evaluator
        public let intrinsics: IntrinsicNames
        public let prelude: Prelude
        public let moduleGlobals: [String: String]
        /// Whether arrays may still be iterated directly; see `Protector`.
        public let protector = Protector()
        private let cache = Mutex(CacheState())
        public var logs: [String] { evaluator.currentLogs() }

        public init(
            builtins: Builtins = createBuiltins(),
            hostCalls: HostCalls = HostCalls(),
            modules: [String: String] = [:],
            translate: Translate = Translate(),
            maxSteps: Int = Int.max,
            maxCallDepth: Int = MAX_CALL_DEPTH,
            timeoutMs: Int? = nil,
            adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)? = nil,
            runContext: (any Sendable)? = nil,
            abortSignal: AbortSignal? = nil,
            resumedDurables: [String: JSONValue] = [:]
        ) {
            self.builtins = builtins
            self.hostCalls = hostCalls
            self.moduleGlobals = modules
            self.evaluator = Evaluator(
                builtins: builtins,
                hostCalls: hostCalls,
                modules: modules,
                translate: translate,
                maxSteps: maxSteps,
                maxCallDepth: maxCallDepth,
                timeoutMs: timeoutMs,
                adapt: adapt,
                runContext: runContext,
                abortSignal: abortSignal,
                resumedDurables: resumedDurables
            )
            self.prelude = Prelude()
            self.intrinsics = IntrinsicNames(
                made: builtins.allPrototypes,
                roots: Roots(globals: [], builtins: builtins)
            )
        }

        public func registerSource(_ source: Source) {
            cache.withLock { $0.sources[source.id] = source }
        }

        /// Guards `Array.prototype[Symbol.iterator]` and the built-in iterators' `next` once the intrinsics are made
        /// (see `Protector`): a later change to either clears the protector for the run.
        public func armProtector() {
            builtins.Array.guardInfo = ProtectorGuard(key: .symbol(CodemodeLanguage.IteratorSymbol), protector: protector)
            builtins.Iterator.guardInfo = ProtectorGuard(key: .string("next"), protector: protector)
        }

        /// Resolves a built-in/host module specifier to its exported value (cached per normalized name).
        // parity: psychoscript/src/runtime/interpreter.ts#Interpreter.module [status=implemented hash=fed7e653ee3a]
        public func module(_ specifier: String, site: AstNode? = nil) throws -> Value {
            let name = CodemodeLanguage.moduleName(specifier)
            if let cached = cache.withLock({ $0.modules[name] }) {
                return cached
            }
            let resolved = CodemodeLanguage.resolveModule(
                name,
                global: { globalName in (try? evaluator.globalEnv.get(globalName)) ?? .undefined },
                hosted: moduleGlobals
            )
            if resolved.isUndefined {
                let message: String
                if specifier.hasPrefix(".") || specifier.hasPrefix("/") || specifier.hasPrefix("file:") {
                    message = "Cannot import \"\(specifier)\": local files can't be imported."
                } else if CodemodeLanguage.isRuntimeModule(specifier) {
                    message = "Cannot import \"\(specifier)\": this runtime doesn't provide it."
                } else {
                    message = "Cannot import \"\(specifier)\": packages can't be installed here."
                }
                throw PendingThrow(type: .error, message: message, node: site)
            }
            cache.withLock { $0.modules[name] = resolved }
            return resolved
        }

        /// Builds a module namespace object (`import * as ...`) with own properties plus `default`.
        // parity: psychoscript/src/runtime/interpreter.ts#Interpreter.namespace [status=implemented hash=fcf39caf87fc]
        public func namespace(_ specifier: String, site: AstNode? = nil) throws -> Obj {
            let mod = try module(specifier, site: site)
            let name = CodemodeLanguage.moduleName(specifier)
            if let cached = cache.withLock({ $0.namespaces[name] }) {
                return cached
            }
            let ns = Obj(proto: nil)
            // Data only: making a namespace runs no program getter.
            if case .object(let obj) = mod {
                for key in CodemodeLanguage.keys(obj) {
                    CodemodeLanguage.define(ns, key, CodemodeLanguage.peek(obj, .string(key)))
                }
            }
            CodemodeLanguage.define(ns, "default", mod)
            cache.withLock { $0.namespaces[name] = ns }
            return ns
        }

        /// Lists the property keys directly under a `HostNamespace` path.
        // parity: psychoscript/src/runtime/interpreter.ts#Interpreter.namespaceKeys [status=implemented hash=1bcf65744019]
        public func namespaceKeys(_ value: HostNamespace) throws -> [String] {
            try value.handler.keys(value.path)
        }

        /// Resolves and invokes a function at a `HostNamespace` path.
        // parity: psychoscript/src/runtime/interpreter.ts#Interpreter.callNamespace [status=implemented hash=b5f110c3d648]
        public func callNamespace(_ value: HostNamespace, args: [Value], site: AstNode? = nil) -> HostResult {
            _ = (args, site)
            let label = value.path.joined(separator: ".")
            switch value.handler.resolve(value.path) {
            case .failure(let failure):
                return .error(failure)
            case .fn(let hostFn):
                return hostCalls.call(target: .fn(hostFn), label: label, path: label, builtins: builtins)
            case .durable(let durableFn):
                return hostCalls.call(target: .durable(durableFn), label: label, path: label, builtins: builtins)
            }
        }

        /// Looks up an AST node by `NodeId` across this interpreter's registered sources.
        // parity: psychoscript/src/runtime/interpreter.ts#Interpreter.node [status=implemented hash=b003429d41b7]
        public func node(_ id: NodeId) -> AstNode? {
            cache.withLock { $0.sources[id.source]?.node(id) }
        }
    }

    // parity: psychoscript/src/runtime/driver.ts#SUSPENDED [status=implemented hash=caf2ce43eeb3]
    public static let SUSPENDED = RuntimeSymbol("psychoscript.suspended")

    // parity: psychoscript/src/runtime/driver.ts#CANCELLED [status=implemented hash=e0ef42f80bc4]
    public static let CANCELLED = RuntimeSymbol("psychoscript.cancelled")

    // parity: psychoscript/src/runtime/driver.ts#parking [status=implemented hash=bf9374c02386]
    /// For tests: `onPark` is called each time a run has nothing to do but wait on host calls in flight.
    public enum Parking {
        private static let hook = Mutex<(@Sendable () -> Void)?>(nil)
        public static var onPark: (@Sendable () -> Void)? {
            get { hook.withLock { $0 } }
            set { hook.withLock { $0 = newValue } }
        }
    }

    // parity: psychoscript/src/runtime/driver.ts#Driver [status=adapted hash=0731a7a91123]
    public final class Driver: Sendable {
        public enum RunOutcome: Sendable {
            case completed(Completion)
            case suspended
            case cancelled
        }

        private struct State: Sendable {
            var suspending: Bool = false
            var cancelled: Bool = false
            var interrupted: Bool = false
            var stopping: Bool = false
            var detachedIds: Set<Int> = []
        }

        public let vm: Vm
        public let context: (any Sendable)?
        private let state = Mutex(State())

        public init(vm: Vm, context: (any Sendable)? = nil) {
            self.vm = vm
            self.context = context
        }

        /// Runs the VM loop until completion, suspension (`detach()`), or cancellation (`cancel()`).
        // parity: psychoscript/src/runtime/driver.ts#Driver.run [status=implemented hash=9f94c166f801]
        public func run() async throws -> RunOutcome {
            while true {
                let flags = state.withLock { ($0.interrupted, $0.suspending, $0.cancelled) }
                if flags.0 { throw Contract.Interrupted() }
                if flags.1 { return .suspended }
                if flags.2 { return .cancelled }
                let stop = vm.run()
                switch stop {
                case .slice:
                    await vm.scheduler.drain()
                    await Task.yield()
                case .waitHost:
                    if vm.hostCalls.handOver().isEmpty {
                        Parking.onPark?()
                    }
                    let afterFlags = state.withLock { ($0.interrupted, $0.suspending, $0.cancelled) }
                    if afterFlags.0 { throw Contract.Interrupted() }
                    if afterFlags.1 { return .suspended }
                    if afterFlags.2 { return .cancelled }
                    return .completed(.error(PendingThrow(
                        type: .error,
                        message: "The program is waiting on a promise that can never settle: nothing else is running, so nothing can resolve it. There are no timers or sleep, so don't wait or poll inside a program."
                    )))
                case .done(let completion):
                    if case .error(let err) = completion, err is Interruption || err is Contract.Interrupted {
                        throw Contract.Interrupted()
                    }
                    return .completed(completion)
                }
            }
        }

        /// Lists running host calls that prevent suspending the execution.
        /// Idempotent async calls and durable calls in `.started` do not block suspend.
        // parity: psychoscript/src/runtime/driver.ts#Driver.blocking [status=implemented hash=fec5cdc22d8d]
        public func blocking() -> [(key: String, path: String)] {
            vm.calls().compactMap { call in
                let blocks = call.holdsFunctions || (call.status != .queued && call.status != .started && !call.idempotent)
                guard blocks else { return nil }
                return (key: call.key, path: call.path ?? call.label)
            }
        }

        /// Whether any in-flight host call holds unserializable host values or missing paths.
        // parity: psychoscript/src/runtime/driver.ts#Driver.holdsHostValues [status=implemented hash=68a570bb2de8]
        public var holdsHostValues: Bool {
            vm.calls().contains { call in
                call.path == nil || call.holdsFunctions
            }
        }

        /// Marks the driver as suspending and detaches currently tracked calls.
        // parity: psychoscript/src/runtime/driver.ts#Driver.detach [status=implemented hash=44403e2ab4b8]
        public func detach() {
            let activeIds = vm.calls().map(\.id)
            state.withLock { s in
                s.suspending = true
                for id in activeIds { s.detachedIds.insert(id) }
            }
            vm.interpreter.evaluator.markSuspending()
        }

        /// Stops the run: `run()` returns `.cancelled` at its next step.
        // parity: psychoscript/src/runtime/driver.ts#Driver.cancel [status=implemented hash=eba8618ab70e]
        public func cancel() {
            state.withLock { s in
                s.cancelled = true
            }
            vm.interpreter.evaluator.markAborted()
        }

        /// Stops host work still running, aborting each call and waiting for `HostWork` cleanup;
        /// a durable call's work is cancelled unless the run was suspended.
        // parity: psychoscript/src/runtime/driver.ts#Driver.interrupt [status=implemented hash=9ab93d7ea60f]
        @discardableResult
        public func interrupt() async -> Int {
            let wasSuspending = state.withLock { s -> Bool in
                s.stopping = true
                return s.suspending
            }
            return await vm.interpreter.evaluator.cancelPendingWorkAsync(suspending: wasSuspending)
        }

        /// Resumes queued host calls after restoring from a suspended snapshot.
        // parity: psychoscript/src/runtime/driver.ts#Driver.resume [status=implemented hash=b726810e29da]
        public func resume() {
            let isSuspending = state.withLock { $0.suspending }
            guard !isSuspending else { return }
            for call in vm.calls() where call.status == .queued {
                call.status = .running
            }
        }
    }

    // parity: psychoscript/src/runtime/execute.ts#SuspendError [status=implemented hash=e7ca1003f7a9]
    public final class SuspendError: Error, Sendable, CustomStringConvertible {
        public struct RunningCall: Equatable, Hashable, Sendable, Codable {
            public let key: String
            public let path: String

            public init(key: String, path: String) {
                self.key = key
                self.path = path
            }
        }

        public let _tag: String = "SuspendError"
        public let name: String = "SuspendError"
        public let message: String
        public let running: [RunningCall]

        public init(message: String, running: [RunningCall] = []) {
            self.message = message
            self.running = running
        }

        public var description: String { message }
    }

    /// How one run is started: `signal` interrupts it (throwing `Contract.Interrupted`); `context` goes to host calls.
    // parity: psychoscript/src/runtime/execute.ts#RunOptions [status=implemented hash=2667305dca09]
    public struct ExecuteRunOptions: Sendable {
        public let signal: AbortSignal?
        public let context: (any Sendable)?

        public init(signal: AbortSignal? = nil, context: (any Sendable)? = nil) {
            self.signal = signal
            self.context = context
        }
    }

    /// Validates `maxBytes` for `program.suspend`, throwing a `RangeError` for negative values.
    // parity: psychoscript/src/runtime/execute.ts#checkMaxBytes [status=implemented hash=8995f729c7e8]
    public static func checkMaxBytes(_ maxBytes: Int?) throws {
        if let maxBytes, maxBytes < 0 {
            throw rangeError("maxBytes must be a safe integer greater than or equal to 0.")
        }
    }

    /// A managed single-use program run produced by `makeProgram`: enforces run-once semantics and
    /// coordinates `suspend` waiting for `run` to start.
    public final class ManagedProgram: Sendable {
        private struct State: Sendable {
            var claimed: Bool = false
            var started: Swift.Result<Running, any Error>? = nil
            var startWaiters: [CheckedContinuation<Running, any Error>] = []
        }

        private let startFn: @Sendable () throws -> Running
        private let state = Mutex(State())

        public init(start: @escaping @Sendable () throws -> Running) {
            self.startFn = start
        }

        public func run(_ options: ExecuteRunOptions? = nil) async throws -> Outcome {
            let alreadyClaimed = state.withLock { s -> Bool in
                if s.claimed { return true }
                s.claimed = true
                return false
            }
            if alreadyClaimed {
                throw HostError("A program runs once; make another with runtime.program or runtime.resume.")
            }
            let running: Running
            do {
                running = try startFn()
            } catch {
                let waiters = state.withLock { s -> [CheckedContinuation<Running, any Error>] in
                    s.started = .failure(SuspendError(message: "The program didn't start."))
                    let list = s.startWaiters
                    s.startWaiters.removeAll()
                    return list
                }
                for w in waiters {
                    w.resume(throwing: SuspendError(message: "The program didn't start."))
                }
                throw error
            }
            let waiters = state.withLock { s -> [CheckedContinuation<Running, any Error>] in
                s.started = .success(running)
                let list = s.startWaiters
                s.startWaiters.removeAll()
                return list
            }
            for w in waiters {
                w.resume(returning: running)
            }
            return try await running.run(options)
        }

        public func suspend(_ maxBytes: Int? = nil) async throws -> Outcome {
            try checkMaxBytes(maxBytes)
            let running: Running = try await withCheckedThrowingContinuation { cont in
                let resolved = state.withLock { s -> Swift.Result<Running, any Error>? in
                    if let started = s.started { return started }
                    s.startWaiters.append(cont)
                    return nil
                }
                if let resolved {
                    cont.resume(with: resolved)
                }
            }
            return try await running.suspend(maxBytes: maxBytes)
        }
    }

    /// A program's one run: `start` makes it when `run()` is called, and `suspend` waits for it.
    // parity: psychoscript/src/runtime/execute.ts#makeProgram [status=implemented hash=a84e85eb6c9a]
    public static func makeProgram(_ start: @escaping @Sendable () throws -> Running) -> ManagedProgram {
        ManagedProgram(start: start)
    }

    // parity: psychoscript/src/runtime/execute.ts#Result [status=implemented hash=f234ed8b0673]
    public enum Result: Equatable, Sendable {
        case success(value: Json, warnings: [Diagnostic]?, logs: [String]?, truncated: Bool?, metadata: Json)
        case failure(error: Diagnostic, logs: [String]?, truncated: Bool?, metadata: Json)

        public var ok: Bool {
            if case .success = self { return true }
            return false
        }
    }

    // parity: psychoscript/src/runtime/execute.ts#Suspended [status=implemented hash=98694f609185]
    public struct Suspended: Equatable, Sendable {
        public let state: Snapshot

        public init(state: Snapshot) {
            self.state = state
        }
    }

    // parity: psychoscript/src/runtime/execute.ts#Outcome [status=implemented hash=20f0e50188c9]
    public enum Outcome: Equatable, Sendable {
        case result(Result)
        case suspended(Suspended)
    }

    // parity: psychoscript/src/runtime/execute.ts#Run [status=implemented hash=feb5d4cd02f7]
    public final class Run: Sendable {
        public let id: String
        private let metadataBox: Mutex<Json>

        public init(id: String = OpenCodeUtil.uuid(), metadata: Json = .null) {
            self.id = id
            self.metadataBox = Mutex(metadata)
        }

        public var metadata: Json {
            get { metadataBox.withLock { $0 } }
            set { metadataBox.withLock { $0 = newValue } }
        }
    }

    // parity: psychoscript/src/runtime/execute.ts#Limits [status=implemented hash=56957fb2a6d9]
    public struct ExecuteLimits: Equatable, Hashable, Sendable, Codable {
        public let timeoutMs: Int?
        public let maxOutputBytes: Int?
        public let maxSteps: Int?

        public init(timeoutMs: Int? = nil, maxOutputBytes: Int? = nil, maxSteps: Int? = nil) {
            self.timeoutMs = timeoutMs
            self.maxOutputBytes = maxOutputBytes
            self.maxSteps = maxSteps
        }
    }

    // parity: psychoscript/src/runtime/execute.ts#Setup [status=implemented hash=f34076232dc2]
    public struct Setup: Sendable {
        public let limits: ExecuteLimits
        public let translate: Translate
        public let globals: (@Sendable (Run) -> [String: HostGlobalValue])?
        public let modules: [String: String]
        /// Turns what a plain host function returned into a value, a Promise, or `HostWork` (used by `EffectRuntime`).
        public let adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)?

        public init(
            limits: ExecuteLimits = ExecuteLimits(),
            translate: Translate = Translate(),
            globals: (@Sendable (Run) -> [String: HostGlobalValue])? = nil,
            modules: [String: String] = [:],
            adapt: (@Sendable (HostReturn, Contract.Call) -> HostReturn)? = nil
        ) {
            self.limits = limits
            self.translate = translate
            self.globals = globals
            self.modules = modules
            self.adapt = adapt
        }
    }

    public enum ParseProgramResult: Sendable {
        case ok(program: ProgramAST, source: Source)
        case error(Diagnostic)
    }

    // parity: psychoscript/src/runtime/execute.ts#parseProgram [status=implemented hash=d7a11593dc01]
    public static func parseProgram(_ code: String) -> ParseProgramResult {
        do {
            var parser = try Parser(code)
            let program = try parser.parseProgram()
            return .ok(program: program, source: Source(id: "main", code: code, program: program))
        } catch let pf as ParseFailure {
            return .error(pf.diagnostic)
        } catch {
            return .error(Diagnostic(kind: "ParseError", message: "SyntaxError: \(error)"))
        }
    }

    // parity: psychoscript/src/runtime/execute.ts#finishExecution [status=implemented hash=8f7803f97142]
    public static func finishExecution(_ outcome: Outcome) -> Result {
        switch outcome {
        case .result(let r): return r
        case .suspended(let s):
            return .failure(
                error: Diagnostic(kind: "ExecutionFailure", message: "The program suspended, which isn't supported here."),
                logs: nil,
                truncated: nil,
                metadata: s.state.header.metadata
            )
        }
    }

    private static let roundTripBox = Mutex<Bool>(false)

    // parity: psychoscript/src/runtime/execute.ts#setRoundTrip [status=implemented hash=8deefef43ef3]
    public static func setRoundTrip(_ enabled: Bool) {
        roundTripBox.withLock { $0 = enabled }
    }

    // parity: psychoscript/src/runtime/execute.ts#Running [status=adapted hash=d303f4b560eb]
    public final class Running: Sendable {
        private struct LifecycleState: Sendable {
            var vm: Vm? = nil
            var run: Run? = nil
            var driver: Driver? = nil
            var startedAtMs: Double = 0
            var started: Bool = false
            var finished: Bool = false
            var suspended: Suspended? = nil
            var doneOutcome: Swift.Result<Outcome, any Error>? = nil
            var startedWaiters: [CheckedContinuation<Void, Never>] = []
            var doneWaiters: [CheckedContinuation<Outcome, any Error>] = []
        }

        private let setup: Setup
        private let code: String
        private let bindings: [String: Json]?
        private let runId: String
        private let initialMetadata: Json
        private let activeBefore: Int
        private let resumedDurables: [String: JSONValue]
        private let lifecycle = Mutex(LifecycleState())

        public init(
            setup: Setup,
            code: String,
            bindings: [String: Json]? = nil,
            runId: String = OpenCodeUtil.uuid(),
            activeBefore: Int = 0,
            initialMetadata: Json = .null,
            resumedDurables: [String: JSONValue] = [:]
        ) {
            self.setup = setup
            self.code = code
            self.bindings = bindings
            self.runId = runId
            self.activeBefore = activeBefore
            self.initialMetadata = initialMetadata
            self.resumedDurables = resumedDurables
        }

        private func markStarted() {
            let waiters = lifecycle.withLock { s -> [CheckedContinuation<Void, Never>] in
                if s.started { return [] }
                s.started = true
                let list = s.startedWaiters
                s.startedWaiters.removeAll()
                return list
            }
            for w in waiters { w.resume() }
        }

        private func finishLifecycle(_ result: Swift.Result<Outcome, any Error>) {
            let (startWaiters, doneWaiters) = lifecycle.withLock { s -> ([CheckedContinuation<Void, Never>], [CheckedContinuation<Outcome, any Error>]) in
                s.finished = true
                s.started = true
                s.doneOutcome = result
                let sw = s.startedWaiters
                s.startedWaiters.removeAll()
                let dw = s.doneWaiters
                s.doneWaiters.removeAll()
                return (sw, dw)
            }
            for w in startWaiters { w.resume() }
            for w in doneWaiters { w.resume(with: result) }
        }

        /// Runs the program until it ends or is suspended; throws `Contract.Interrupted` when `options.signal` aborts
        /// or a host call is interrupted.
        // parity: psychoscript/src/runtime/execute.ts#Running.run [status=implemented hash=9f97b5f9e444]
        public func run(_ options: ExecuteRunOptions? = nil) async throws -> Outcome {
            if let sig = options?.signal, sig.aborted {
                let err = Contract.Interrupted()
                finishLifecycle(.failure(err))
                throw err
            }
            if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let out: Outcome = .result(.failure(
                    error: Diagnostic(kind: "ParseError", message: "Code cannot be empty."),
                    logs: nil,
                    truncated: nil,
                    metadata: initialMetadata
                ))
                finishLifecycle(.success(out))
                return out
            }
            let parsed = parseProgram(code)
            let program: ProgramAST
            let source: Source
            switch parsed {
            case .error(let diag):
                let out: Outcome = .result(.failure(error: diag, logs: nil, truncated: nil, metadata: initialMetadata))
                finishLifecycle(.success(out))
                return out
            case .ok(let p, let s):
                program = p
                source = s
            }

            let runObj = Run(id: runId, metadata: initialMetadata)
            let hostCalls = HostCalls(runId: runId)
            let effectiveTimeout: Int? = setup.limits.timeoutMs.map { max(1, $0 - activeBefore) }
            let runSignal = options?.signal
            let interp = Interpreter(
                builtins: createBuiltins(),
                hostCalls: hostCalls,
                modules: setup.modules,
                translate: setup.translate,
                maxSteps: setup.limits.maxSteps ?? Int.max,
                timeoutMs: effectiveTimeout,
                adapt: setup.adapt,
                runContext: options?.context,
                abortSignal: runSignal,
                resumedDurables: resumedDurables
            )
            let vm = Vm(interpreter: interp)
            vm.registerSource(source)
            let driver = Driver(vm: vm, context: options?.context)
            lifecycle.withLock { s in
                s.vm = vm
                s.run = runObj
                s.driver = driver
                s.startedAtMs = CodemodeLanguage.currentEpochMs()
            }

            let abortListenerId = runSignal?.onAbort {
                driver.cancel()
            } ?? 0
            defer {
                if abortListenerId != 0 { runSignal?.removeEventListener(abortListenerId) }
            }

            if runSignal?.aborted == true {
                _ = await driver.interrupt()
                let err = Contract.Interrupted()
                finishLifecycle(.failure(err))
                throw err
            }

            let scheduler = interp.evaluator.scheduler
            do {
                let jsonVal: JSONValue = try await ProgramScheduler.$current.withValue(scheduler) {
                    let hostMap = setup.globals?(runObj) ?? [:]
                    try interp.evaluator.installBuiltins(hostGlobalsMap: hostMap, bindings: bindings)
                    interp.armProtector()
                    markStarted()
                    let rawValue = try await runWithOptionalTimeout(timeoutMs: effectiveTimeout, abortSignal: runSignal) {
                        try await interp.evaluator.runProgram(program)
                    }
                    // A program getter's value crosses as data: it is read ahead in program code (see `withReads`).
                    // The result crosses as `JSON.stringify` would write it: functions are left out.
                    var copied: JSONValue = .null
                    _ = try await withReads(interp.evaluator) {
                        copied = try toJsonValue(rawValue, dropFunctions: true) ?? .null
                        return .undefined
                    }
                    return copied
                }
                if let saved = lifecycle.withLock({ $0.suspended }) {
                    _ = await driver.interrupt()
                    let out: Outcome = .suspended(saved)
                    finishLifecycle(.success(out))
                    return out
                }
                if runSignal?.aborted == true {
                    _ = await driver.interrupt()
                    let err = Contract.Interrupted()
                    finishLifecycle(.failure(err))
                    throw err
                }
                // Host work the program left running is interrupted (waiting for HostWork/durable cancel cleanup).
                _ = await driver.interrupt()
                let warnings = scheduler.diagnostics() + vm.diagnostics()
                let logs = interp.logs
                let rawResult: Result = .success(
                    value: jsonVal,
                    warnings: warnings.isEmpty ? nil : warnings,
                    logs: logs.isEmpty ? nil : logs,
                    truncated: nil,
                    metadata: runObj.metadata
                )
                let finalResult = setup.limits.maxOutputBytes.map { boundOutput(rawResult, maxOutputBytes: $0) } ?? rawResult
                let out: Outcome = .result(finalResult)
                finishLifecycle(.success(out))
                return out
            } catch {
                if let saved = lifecycle.withLock({ $0.suspended }) {
                    _ = await driver.interrupt()
                    let out: Outcome = .suspended(saved)
                    finishLifecycle(.success(out))
                    return out
                }
                _ = await driver.interrupt()
                if let intr = error as? Interruption {
                    if intr.reason == "suspended", let saved = lifecycle.withLock({ $0.suspended }) {
                        let out: Outcome = .suspended(saved)
                        finishLifecycle(.success(out))
                        return out
                    }
                    if intr.reason == "timeout", let limit = setup.limits.timeoutMs {
                        let diag = Diagnostic(kind: "TimeoutExceeded", message: "Execution timed out after \(limit)ms.")
                        let logs = interp.logs
                        let rawResult: Result = .failure(
                            error: diag,
                            logs: logs.isEmpty ? nil : logs,
                            truncated: nil,
                            metadata: runObj.metadata
                        )
                        let finalResult = setup.limits.maxOutputBytes.map { boundOutput(rawResult, maxOutputBytes: $0) } ?? rawResult
                        let out: Outcome = .result(finalResult)
                        finishLifecycle(.success(out))
                        return out
                    }
                    let interrupted = Contract.Interrupted()
                    finishLifecycle(.failure(interrupted))
                    throw interrupted
                }
                if error is Contract.Interrupted {
                    finishLifecycle(.failure(error))
                    throw error
                }
                let diag = normalizeError(error)
                let logs = interp.logs
                let rawResult: Result = .failure(
                    error: diag,
                    logs: logs.isEmpty ? nil : logs,
                    truncated: nil,
                    metadata: runObj.metadata
                )
                let finalResult = setup.limits.maxOutputBytes.map { boundOutput(rawResult, maxOutputBytes: $0) } ?? rawResult
                let out: Outcome = .result(finalResult)
                finishLifecycle(.success(out))
                return out
            }
        }

        /// Saves the run's state and stops it, at once: `run` then returns the same `.suspended`.
        /// Throws `SuspendError`, leaving the run running, while a non-idempotent/non-started host call is in progress
        /// or when the state exceeds `maxBytes`. Before the run has started, waits for it to start.
        // parity: psychoscript/src/runtime/execute.ts#Running.suspend [status=implemented hash=b174928d5939]
        public func suspend(maxBytes: Int? = nil) async throws -> Outcome {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let ready = lifecycle.withLock { s -> Bool in
                    if s.started || s.finished { return true }
                    s.startedWaiters.append(cont)
                    return false
                }
                if ready { cont.resume() }
            }
            let (isFinished, vmOpt, runOpt, driverOpt, startedAtMs) = lifecycle.withLock {
                ($0.finished, $0.vm, $0.run, $0.driver, $0.startedAtMs)
            }
            if isFinished {
                return try await awaitDone()
            }
            guard let vm = vmOpt, let runObj = runOpt, let driver = driverOpt else {
                throw SuspendError(message: "The program didn't start.")
            }
            let running = driver.blocking()
            if !running.isEmpty {
                let names = running.map(\.path).joined(separator: ", ")
                throw SuspendError(
                    message: "The run can't be suspended while \(names) \(running.count == 1 ? "is" : "are") running.",
                    running: running.map { SuspendError.RunningCall(key: $0.key, path: $0.path) }
                )
            }
            // Idempotent calls in flight are saved as queued so they run again on resume under the same key.
            let idempotent = vm.calls().filter { $0.status == .running && $0.idempotent }
            for call in idempotent { call.status = .queued }
            let restoreRunning = {
                for call in idempotent { call.status = .running }
            }
            let elapsed = max(0, Int((CodemodeLanguage.currentEpochMs() - startedAtMs).rounded()))
            let snapshot: Snapshot
            do {
                let captured = try vm.capture(CaptureOptions(
                    limits: SnapshotLimitsInfo(timeoutMs: setup.limits.timeoutMs, maxOutputBytes: setup.limits.maxOutputBytes),
                    activeMs: activeBefore + elapsed,
                    metadata: runObj.metadata
                ))
                snapshot = captured.snapshot
            } catch {
                restoreRunning()
                throw SuspendError(message: "The run's state couldn't be saved: \(error)")
            }
            if let maxBytes {
                let bytes: [UInt8]
                do {
                    bytes = try toBytes(snapshot)
                } catch {
                    restoreRunning()
                    throw SuspendError(message: "The run's state couldn't be saved: \(error)")
                }
                if bytes.count > maxBytes {
                    restoreRunning()
                    throw SuspendError(message: "The run's state takes \(bytes.count) bytes, more than the \(maxBytes)-byte limit, so it couldn't be suspended.")
                }
            }
            let saved = Suspended(state: snapshot)
            lifecycle.withLock { s in
                s.finished = true
                s.suspended = saved
            }
            driver.detach()
            return try await awaitDone()
        }

        private func awaitDone() async throws -> Outcome {
            try await withCheckedThrowingContinuation { cont in
                let done = lifecycle.withLock { s -> Swift.Result<Outcome, any Error>? in
                    if let out = s.doneOutcome { return out }
                    s.doneWaiters.append(cont)
                    return nil
                }
                if let done { cont.resume(with: done) }
            }
        }
    }

    private static func runWithOptionalTimeout<T: Sendable>(
        timeoutMs: Int?,
        abortSignal: AbortSignal? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if timeoutMs == nil && abortSignal == nil {
            return try await operation()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            if let timeoutMs {
                group.addTask {
                    try await Task.sleep(for: .milliseconds(timeoutMs))
                    throw Interruption("timeout")
                }
            }
            if let abortSignal {
                group.addTask {
                    await abortSignal.waitUntilAborted()
                    throw Interruption("cancelled")
                }
            }
            guard let first = try await group.next() else {
                throw Interruption(abortSignal?.aborted == true ? "cancelled" : "timeout")
            }
            group.cancelAll()
            return first
        }
    }

    private static func utf8Truncate(_ text: String, maxBytes: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }
        var limit = max(0, maxBytes)
        // Walk back to a valid UTF-8 scalar boundary
        while limit > 0 && (bytes[limit] & 0xC0) == 0x80 {
            limit -= 1
        }
        return String(decoding: bytes[0..<limit], as: UTF8.self)
    }

    public static func boundOutput(_ result: Result, maxOutputBytes: Int) -> Result {
        switch result {
        case .success(let value, let warningsOpt, let logsOpt, _, let metadata):
            let serialized = serializeJsonCompact(value)
            let valueBytes = serialized.utf8.count
            let valueTruncated = valueBytes > maxOutputBytes
            let boundedValue: Json = valueTruncated
                ? .string("\(utf8Truncate(serialized, maxBytes: maxOutputBytes)) [result truncated: \(valueBytes) bytes exceeds the \(maxOutputBytes)-byte output limit; return a smaller value]")
                : value

            let warnings = warningsOpt ?? []
            var keptWarnings: [Diagnostic] = []
            var warnBytes = 0
            for w in warnings {
                let sz = (try? JSONEncoder().encode(w).count) ?? w.message.utf8.count
                warnBytes += sz + 1
                if warnBytes > maxOutputBytes { break }
                keptWarnings.append(w)
            }
            let warningsCut = keptWarnings.count < warnings.count
            if warningsCut {
                keptWarnings.append(Diagnostic(
                    kind: "Truncated",
                    message: "\(warnings.count - keptWarnings.count) additional warnings omitted by the output limit."
                ))
            }

            let logs = logsOpt ?? []
            let logBudget = max(0, maxOutputBytes - min(valueBytes, maxOutputBytes))
            var keptLogs: [String] = []
            var logUsed = 0
            for line in logs {
                logUsed += line.utf8.count + 1
                if logUsed > logBudget { break }
                keptLogs.append(line)
            }
            let logsCut = keptLogs.count < logs.count
            if logsCut {
                keptLogs.append("[logs truncated: showing \(keptLogs.count) of \(logs.count) lines]")
            }
            if !valueTruncated && !warningsCut && !logsCut { return result }
            return .success(
                value: boundedValue,
                warnings: keptWarnings.isEmpty ? nil : keptWarnings,
                logs: keptLogs.isEmpty ? nil : keptLogs,
                truncated: true,
                metadata: metadata
            )
        case .failure(let error, let logsOpt, _, let metadata):
            let logs = logsOpt ?? []
            var keptLogs: [String] = []
            var logUsed = 0
            for line in logs {
                logUsed += line.utf8.count + 1
                if logUsed > maxOutputBytes { break }
                keptLogs.append(line)
            }
            let logsCut = keptLogs.count < logs.count
            if !logsCut { return result }
            keptLogs.append("[logs truncated: showing \(keptLogs.count) of \(logs.count) lines]")
            return .failure(error: error, logs: keptLogs, truncated: true, metadata: metadata)
        }
    }

    public static func serializeJsonCompact(_ value: JSONValue) -> String {
        PureJSON.stringifyCompact(jsonValueToPure(value))
    }

    internal static func jsonValueToPure(_ value: JSONValue) -> PureJSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map(jsonValueToPure))
        case .object(let dict):
            return .object(dict.keys.sorted().compactMap { k in dict[k].map { (k, jsonValueToPure($0)) } })
        }
    }

    // parity: psychoscript/src/runtime/execute.ts#startProgram [status=implemented hash=218b5f3090db]
    public static func startProgram(
        setup: Setup,
        code: String,
        bindings: [String: Json]? = nil,
        runId: String = OpenCodeUtil.uuid()
    ) -> Running {
        Running(setup: setup, code: code, bindings: bindings, runId: runId)
    }

    private static func resolveGlobalItem(in globals: [String: HostGlobalValue], path: [String]) -> HostGlobalValue? {
        guard let first = path.first else { return nil }
        var current: HostGlobalValue? = globals[first]
        for idx in 1..<path.count {
            let segment = path[idx]
            switch current {
            case .object(let dict)?:
                current = dict[segment]
            case .namespace(let ns)?:
                switch ns.resolve(Array(path[idx...])) {
                case .durable(let d): return .durableFn(d)
                case .fn(let f): return .fn(f)
                case .failure: return nil
                }
            default:
                return nil
            }
        }
        return current
    }

    // parity: psychoscript/src/runtime/execute.ts#resumeProgram [status=implemented hash=0ad356ffc83c]
    public static func resumeProgram(setup: Setup, saved: Snapshot) throws -> Running {
        do {
            let checked = try validate(saved)
            guard checked.header.build == buildId() else {
                throw SnapshotError("Snapshot belongs to another build.")
            }
            let code = checked.header.sources.first?.code ?? ""
            let resumedSetup = Setup(
                limits: ExecuteLimits(
                    timeoutMs: checked.header.limits.timeoutMs,
                    maxOutputBytes: checked.header.limits.maxOutputBytes,
                    maxSteps: setup.limits.maxSteps
                ),
                translate: setup.translate,
                globals: setup.globals,
                modules: setup.modules,
                adapt: setup.adapt
            )
            var resumedDurables: [String: JSONValue] = [:]
            let durableRecords = checked.records.filter { $0["t"] == .string("DurableCall") }
            if !durableRecords.isEmpty {
                let probeRun = Run(id: checked.header.runId, metadata: checked.header.metadata)
                let globalsMap = resumedSetup.globals?(probeRun) ?? [:]
                for record in durableRecords {
                    guard case .string(let key)? = record["key"],
                          case .string(let pathStr)? = record["path"],
                          let data = record["data"] else {
                        continue
                    }
                    let segments = pathStr.split(separator: ".").map(String.init)
                    guard case .durableFn? = resolveGlobalItem(in: globalsMap, path: segments) else {
                        throw SnapshotError(
                            "The pending durable call \(key) (\(pathStr)) cannot resume because that function is no longer a durable function in this runtime."
                        )
                    }
                    resumedDurables[key] = data
                }
            }
            return Running(
                setup: resumedSetup,
                code: code,
                bindings: nil,
                runId: checked.header.runId,
                activeBefore: checked.header.budget.activeMs,
                initialMetadata: checked.header.metadata,
                resumedDurables: resumedDurables
            )
        } catch let se as SnapshotError {
            throw se
        } catch {
            throw SnapshotError(String(describing: error))
        }
    }

    /// Restores a saved run from serialized snapshot bytes (`Uint8Array`), throwing `SnapshotError` if invalid.
    public static func resumeProgram(setup: Setup, savedBytes: [UInt8]) throws -> Running {
        do {
            let snapshot = try fromBytes(savedBytes)
            return try resumeProgram(setup: setup, saved: snapshot)
        } catch let se as SnapshotError {
            throw se
        } catch {
            throw SnapshotError(String(describing: error))
        }
    }

    // MARK: - Top-Level Language Runtime API (src/language/runtime.ts)

    // parity: psychoscript/src/runtime.ts#SuspendError [status=implemented hash=d6d958471836]
    public typealias RuntimeSuspendError = SuspendError

    // parity: psychoscript/src/runtime.ts#Outcome [status=implemented hash=0fa9789cd012]
    public typealias RuntimeOutcome = Outcome

    // parity: psychoscript/src/runtime.ts#Result [status=implemented hash=0fa9789cd012]
    public typealias RuntimeResult = Result

    // parity: psychoscript/src/runtime.ts#Run [status=implemented hash=0fa9789cd012]
    public typealias RuntimeRun = Run

    // parity: psychoscript/src/runtime.ts#Suspended [status=implemented hash=0fa9789cd012]
    public typealias RuntimeSuspended = Suspended

    /// How one run is stopped: aborting `signal` makes it throw an `AbortError`.
    // parity: psychoscript/src/runtime.ts#RunOptions [status=implemented hash=a1cd79315f03]
    public struct RunOptions: Sendable {
        public let signal: AbortSignal?

        public init(signal: AbortSignal? = nil) {
            self.signal = signal
        }
    }

    /// Options for `Runtime.execute`.
    // parity: psychoscript/src/runtime.ts#ExecuteOptions [status=implemented hash=11e501894fcc]
    public struct ExecuteOptions: Sendable {
        public let bindings: [String: Json]?
        public let runId: String?
        public let signal: AbortSignal?

        public init(
            bindings: [String: Json]? = nil,
            runId: String? = nil,
            signal: AbortSignal? = nil
        ) {
            self.bindings = bindings
            self.runId = runId
            self.signal = signal
        }
    }

    /// Maps `Contract.Interrupted` to `AbortError` whose `cause` is `signal?.reason`.
    private static func aborting<A: Sendable>(
        signal: AbortSignal?,
        _ operation: () async throws -> A
    ) async throws -> A {
        do {
            return try await operation()
        } catch is Contract.Interrupted {
            throw AbortError("The run was aborted.", cause: signal?.reason)
        }
    }

    // parity: psychoscript/src/runtime.ts#Program [status=implemented hash=bb926016ef34]
    public struct Program: Sendable {
        private let runFn: @Sendable (RunOptions?) async throws -> Outcome
        private let suspendFn: @Sendable (SuspendOptions?) async throws -> Outcome

        public init(
            run: @escaping @Sendable (RunOptions?) async throws -> Outcome,
            suspend: @escaping @Sendable (SuspendOptions?) async throws -> Outcome
        ) {
            self.runFn = run
            self.suspendFn = suspend
        }

        public init(
            run: @escaping @Sendable () async throws -> Outcome,
            suspend: @escaping @Sendable (SuspendOptions?) throws -> Outcome
        ) {
            self.runFn = { _ in try await run() }
            self.suspendFn = { opts in try suspend(opts) }
        }

        public func run(_ options: RunOptions? = nil) async throws -> Outcome {
            try await runFn(options)
        }

        public func suspend(_ options: SuspendOptions? = nil) async throws -> Outcome {
            try await suspendFn(options)
        }
    }

    // parity: psychoscript/src/runtime.ts#Runtime [status=implemented hash=d543c360c6ae]
    public struct Runtime: Sendable {
        private let executeThrowingFn: @Sendable (String, ExecuteOptions?) async throws -> Result
        private let programFn: @Sendable (String, ProgramOptions?) -> Program
        private let resumeSnapshotFn: @Sendable (Snapshot) -> Program
        private let resumeBytesFn: @Sendable ([UInt8]) -> Program

        public init(
            execute: @escaping @Sendable (String, ExecuteOptions?) async throws -> Result,
            program: @escaping @Sendable (String, ProgramOptions?) -> Program,
            resumeSnapshot: @escaping @Sendable (Snapshot) -> Program,
            resumeBytes: @escaping @Sendable ([UInt8]) -> Program
        ) {
            self.executeThrowingFn = execute
            self.programFn = program
            self.resumeSnapshotFn = resumeSnapshot
            self.resumeBytesFn = resumeBytes
        }

        /// Runs a program to its end; throws `AbortError` when `options.signal` aborts.
        public func execute(_ code: String, _ options: ExecuteOptions) async throws -> Result {
            try await executeThrowingFn(code, options)
        }

        /// Runs a program to its end (non-aborting convenience overload compatible with v0.1 callers).
        public func execute(_ code: String, _ options: ProgramOptions? = nil) async -> Result {
            do {
                let execOpts = ExecuteOptions(bindings: options?.bindings, runId: options?.runId)
                return try await executeThrowingFn(code, execOpts)
            } catch {
                return .failure(
                    error: normalizeError(error),
                    logs: nil,
                    truncated: nil,
                    metadata: .null
                )
            }
        }

        public func program(_ code: String, _ options: ProgramOptions? = nil) -> Program {
            programFn(code, options)
        }

        public func resume(_ state: Snapshot) -> Program {
            resumeSnapshotFn(state)
        }

        public func resume(_ bytes: [UInt8]) -> Program {
            resumeBytesFn(bytes)
        }
    }

    /// A limit must be a safe integer at least `minimum`: `Runtime.make` checks its own, and Code Mode's
    /// `resolveExecutionLimits` checks the execution limits with the same rule.
    public static func validateLimit(_ name: String, _ value: Int?, minimum: Int) throws -> Int? {
        guard let value else { return nil }
        guard value >= minimum else {
            throw rangeError("\(name) must be a safe integer greater than or equal to \(minimum).")
        }
        return value
    }

    // parity: psychoscript/src/runtime.ts#make [status=implemented hash=306564d41835]
    public static func makeRuntime(_ options: RuntimeOptions = RuntimeOptions()) throws -> Runtime {
        let setup = try makeSetup(options)
        let startManaged: @Sendable (String, ProgramOptions?) -> ManagedProgram = { code, progOpts in
            makeProgram {
                startProgram(
                    setup: setup,
                    code: code,
                    bindings: progOpts?.bindings,
                    runId: progOpts?.runId ?? OpenCodeUtil.uuid()
                )
            }
        }
        let wrapManaged: @Sendable (ManagedProgram) -> Program = { managed in
            Program(
                run: { runOpts in
                    try await aborting(signal: runOpts?.signal) {
                        try await managed.run(ExecuteRunOptions(signal: runOpts?.signal))
                    }
                },
                suspend: { suspendOpts in
                    try checkMaxBytes(suspendOpts?.maxBytes)
                    return try await managed.suspend(suspendOpts?.maxBytes)
                }
            )
        }
        return Runtime(
            execute: { code, execOpts in
                let progOpts = ProgramOptions(bindings: execOpts?.bindings, runId: execOpts?.runId)
                let outcome = try await aborting(signal: execOpts?.signal) {
                    try await startManaged(code, progOpts).run(ExecuteRunOptions(signal: execOpts?.signal))
                }
                return finishExecution(outcome)
            },
            program: { code, progOpts in
                wrapManaged(startManaged(code, progOpts))
            },
            resumeSnapshot: { snap in
                wrapManaged(makeProgram { try resumeProgram(setup: setup, saved: snap) })
            },
            resumeBytes: { bytes in
                wrapManaged(makeProgram { try resumeProgram(setup: setup, savedBytes: bytes) })
            }
        )
    }
}

extension CodemodeLanguage.Expression {
    /// The ESTree node type name (as acorn reports it) for diagnostics sites.
    var nodeType: String {
        switch self {
        case .identifier: return "Identifier"
        case .member, .superMember: return "MemberExpression"
        case .call, .superCall: return "CallExpression"
        case .newExpr: return "NewExpression"
        case .chain: return "ChainExpression"
        case .taggedTemplate: return "TaggedTemplateExpression"
        case .function: return "FunctionExpression"
        case .classExpr: return "ClassExpression"
        default: return "Expression"
        }
    }
}
