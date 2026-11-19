// Pure Swift 6 port of keymap/src/services/conditions.ts and shared keymap condition primitives.

public typealias KeyMatch = String

/// Pure-Swift dynamic value supporting JavaScript `Object.is` equality semantics
/// (including `NaN == NaN`, `+0.0 != -0.0`, and distinct `undefined` vs `null`).
public enum KeymapValue: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    case undefined
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([KeymapValue])
    case object([String: KeymapValue])

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .int(value)
    }

    public init(floatLiteral value: Double) {
        self = .double(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(nilLiteral: ()) {
        self = .null
    }

    public init(arrayLiteral elements: KeymapValue...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, KeymapValue)...) {
        var dict: [String: KeymapValue] = [:]
        dict.reserveCapacity(elements.count)
        for (k, v) in elements {
            dict[k] = v
        }
        self = .object(dict)
    }

    /// String conversion matching JavaScript `String(value)` for primitives.
    public var stringDescription: String {
        switch self {
        case .undefined:
            return "undefined"
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            if d.isNaN { return "NaN" }
            if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
            if d == 0 { return "0" }
            if d.rounded(.towardZero) == d, let i = Int(exactly: d) {
                return String(i)
            }
            return String(d)
        case .string(let s):
            return s
        case .array(let items):
            return items.map(\.stringDescription).joined(separator: ",")
        case .object:
            return "[object Object]"
        }
    }
}

extension KeymapValue: Equatable {
    public static func == (lhs: KeymapValue, rhs: KeymapValue) -> Bool {
        switch (lhs, rhs) {
        case (.undefined, .undefined), (.null, .null):
            return true
        case (.bool(let l), .bool(let r)):
            return l == r
        case (.int(let l), .int(let r)):
            return l == r
        case (.double(let l), .double(let r)):
            if l.isNaN && r.isNaN {
                return true
            }
            return l.bitPattern == r.bitPattern
        case (.string(let l), .string(let r)):
            return l == r
        case (.array(let l), .array(let r)):
            return l == r
        case (.object(let l), .object(let r)):
            return l == r
        default:
            return false
        }
    }
}

extension KeymapValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .undefined:
            hasher.combine(0)
        case .null:
            hasher.combine(1)
        case .bool(let b):
            hasher.combine(2)
            hasher.combine(b)
        case .int(let i):
            hasher.combine(3)
            hasher.combine(i)
        case .double(let d):
            hasher.combine(4)
            if d.isNaN {
                hasher.combine(UInt64(0x7ff8_0000_0000_0000))
            } else {
                hasher.combine(d.bitPattern)
            }
        case .string(let s):
            hasher.combine(5)
            hasher.combine(s)
        case .array(let arr):
            hasher.combine(6)
            hasher.combine(arr)
        case .object(let obj):
            hasher.combine(7)
            for key in obj.keys.sorted() {
                hasher.combine(key)
                hasher.combine(obj[key])
            }
        }
    }
}

public typealias EventData = [String: KeymapValue]
public typealias Attributes = [String: KeymapValue]

public protocol KeymapEvent: Sendable {
    var name: String { get }
    var ctrl: Bool { get }
    var shift: Bool { get }
    var meta: Bool { get }
    var `super`: Bool? { get }
    var hyper: Bool? { get }
    var propagationStopped: Bool { get }
    func preventDefault()
    func stopPropagation()
}

/// Concrete `KeymapEvent` implementation for headless use and testing.
public final class BasicKeymapEvent: KeymapEvent, @unchecked Sendable {
    public let name: String
    public let ctrl: Bool
    public let shift: Bool
    public let meta: Bool
    public let `super`: Bool?
    public let hyper: Bool?
    public private(set) var defaultPrevented: Bool = false
    public private(set) var propagationStopped: Bool = false

    public init(
        name: String,
        ctrl: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        super isSuper: Bool? = nil,
        hyper: Bool? = nil
    ) {
        self.name = name
        self.ctrl = ctrl
        self.shift = shift
        self.meta = meta
        self.`super` = isSuper
        self.hyper = hyper
    }

    public func preventDefault() {
        defaultPrevented = true
    }

    public func stopPropagation() {
        propagationStopped = true
    }
}

public struct KeymapDiagnosticEvent: Equatable, Sendable {
    public let code: String
    public let message: String
    public let detail: String?

    public init(code: String, message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }
}

/// Lightweight notification & batching coordinator shared by keymap services.
public final class KeymapNotifier: @unchecked Sendable {
    public static let maxStateChangeFlushIterations = 1000

    public private(set) var errors: [KeymapDiagnosticEvent] = []
    public private(set) var warnings: [KeymapDiagnosticEvent] = []
    public private(set) var derivedVersion: Int = 0
    public private(set) var cacheVersion: Int = 0

    private var stateEventListeners: [@Sendable () -> Void] = []
    private var stateChangeListeners: [@Sendable () -> Void] = []
    private var errorHandler: (@Sendable (KeymapDiagnosticEvent) -> Void)?
    private var warningHandler: (@Sendable (KeymapDiagnosticEvent) -> Void)?
    private var usedWarningKeys: Set<String> = []
    private var stateChangeDepth: Int = 0
    private var stateChangePending: Bool = false
    private var flushingStateChange: Bool = false

    public init(
        onError: (@Sendable (KeymapDiagnosticEvent) -> Void)? = nil,
        onWarning: (@Sendable (KeymapDiagnosticEvent) -> Void)? = nil
    ) {
        self.errorHandler = onError
        self.warningHandler = onWarning
    }

    public func onStateEvent(_ listener: @escaping @Sendable () -> Void) {
        stateEventListeners.append(listener)
    }

    public func onStateChange(_ listener: @escaping @Sendable () -> Void) {
        stateChangeListeners.append(listener)
    }

    public func runWithStateChangeBatch<T>(_ body: () throws -> T) rethrows -> T {
        stateChangeDepth += 1
        defer {
            stateChangeDepth -= 1
            if stateChangeDepth == 0 {
                flushStateChange()
            }
        }
        return try body()
    }

    public func queueStateChange(invalidateCaches: Bool = true) {
        derivedVersion += 1
        if invalidateCaches {
            cacheVersion += 1
        }
        stateChangePending = true
        if stateChangeDepth == 0 && !flushingStateChange {
            flushStateChange()
        }
    }

    public func emitError(_ code: String, error: (any Error)? = nil, detail: String? = nil, message: String) {
        let resolvedDetail = detail ?? error.map { String(describing: $0) }
        let event = KeymapDiagnosticEvent(code: code, message: message, detail: resolvedDetail)
        errors.append(event)
        errorHandler?(event)
    }

    public func emitWarning(_ code: String, detail: String? = nil, message: String) {
        let event = KeymapDiagnosticEvent(code: code, message: message, detail: detail)
        warnings.append(event)
        warningHandler?(event)
    }

    public func warnOnce(key: String, code: String, detail: String? = nil, message: String) {
        if usedWarningKeys.contains(key) {
            return
        }
        usedWarningKeys.insert(key)
        emitWarning(code, detail: detail, message: message)
    }

    private func flushStateChange() {
        if !stateChangePending || stateChangeDepth > 0 || flushingStateChange {
            return
        }
        flushingStateChange = true
        defer { flushingStateChange = false }

        var iterations = 0
        while stateChangePending && stateChangeDepth == 0 {
            if iterations >= Self.maxStateChangeFlushIterations {
                stateChangePending = false
                emitError(
                    "state-change-feedback-loop",
                    detail: "\(Self.maxStateChangeFlushIterations)",
                    message:
                        "[Keymap] Possible infinite state listener feedback loop detected after \(Self.maxStateChangeFlushIterations) iterations; pending state notifications were dropped"
                )
                break
            }
            iterations += 1
            stateChangePending = false
            for listener in stateEventListeners {
                listener()
            }
            for listener in stateChangeListeners {
                listener()
            }
        }
    }
}

public enum KeymapConditionError: Error, Equatable, Sendable {
    case invalidMatcher(source: String)
    case conflictingRequirement(name: String, source: String)
    case conflictingAttribute(name: String, source: String)
    case cannotPublishAttributes(source: String)
}

/// Boolean source with subscription-based invalidation.
public struct ReactiveMatcher: Sendable {
    public let get: @Sendable () throws -> Bool
    public let subscribe: @Sendable (@escaping @Sendable () -> Void) throws -> (@Sendable () -> Void)

    public init(
        get: @escaping @Sendable () throws -> Bool,
        subscribe: @escaping @Sendable (@escaping @Sendable () -> Void) throws -> (@Sendable () -> Void)
    ) {
        self.get = get
        self.subscribe = subscribe
    }
}

public enum MatcherInput: Sendable {
    case predicate(@Sendable () throws -> Bool)
    case reactive(ReactiveMatcher)
}

/// Runtime condition matcher attached to a layer, command, or binding.
public final class RuntimeMatcher: @unchecked Sendable {
    public let source: String
    public let match: @Sendable () throws -> Bool
    public let subscribe: (@Sendable (@escaping @Sendable () -> Void) throws -> (@Sendable () -> Void))?
    public var dispose: (@Sendable () throws -> Void)?

    public init(
        source: String,
        match: @escaping @Sendable () throws -> Bool,
        subscribe: (@Sendable (@escaping @Sendable () -> Void) throws -> (@Sendable () -> Void))? = nil,
        dispose: (@Sendable () throws -> Void)? = nil
    ) {
        self.source = source
        self.match = match
        self.subscribe = subscribe
        self.dispose = dispose
    }
}

public struct KeymapRequirement: Equatable, Hashable, Sendable {
    public let name: String
    public let value: KeymapValue

    public init(name: String, value: KeymapValue) {
        self.name = name
        self.value = value
    }
}

/// Any record (layer, binding, or command) that carries context requirements and runtime matchers.
public protocol RuntimeMatchable: AnyObject, Sendable {
    var requires: [KeymapRequirement] { get }
    var matchers: [RuntimeMatcher] { get }
}

/// Logical combinator helpers for composing runtime matchers.
public enum ConditionCombinators {
    public static func allOf(_ matchers: [RuntimeMatcher], source: String = "allOf") -> RuntimeMatcher {
        RuntimeMatcher(source: source) {
            for matcher in matchers {
                if try !matcher.match() {
                    return false
                }
            }
            return true
        }
    }

    public static func anyOf(_ matchers: [RuntimeMatcher], source: String = "anyOf") -> RuntimeMatcher {
        RuntimeMatcher(source: source) {
            for matcher in matchers {
                if try matcher.match() {
                    return true
                }
            }
            return false
        }
    }

    public static func not(_ matcher: RuntimeMatcher, source: String? = nil) -> RuntimeMatcher {
        RuntimeMatcher(source: source ?? "not(\(matcher.source))") {
            try !matcher.match()
        }
    }
}

// parity: keymap/src/services/conditions.ts#ConditionService [status=implemented hash=bd2c682b3030]
public protocol ConditionService: AnyObject, Sendable {
    func buildRuntimeMatcher(_ matcher: MatcherInput, source: String) -> RuntimeMatcher
    func matchesConditions(_ target: any RuntimeMatchable) -> Bool
    /// The results of a target with matchers read since the last `state` event: bit 1 false, bit 2 true.
    func seenResults(_ target: any RuntimeMatchable) -> Int
}

/// Concrete implementation of `ConditionService` tracking per-epoch matcher evaluations.
public final class DefaultConditionService: ConditionService, @unchecked Sendable {
    private let readData: @Sendable () -> EventData
    private let notify: KeymapNotifier
    private var seen: [ObjectIdentifier: Int] = [:]
    private var epoch: Int = 0

    public init(
        readData: @escaping @Sendable () -> EventData,
        notify: KeymapNotifier
    ) {
        self.readData = readData
        self.notify = notify
        notify.onStateEvent { [weak self] in
            self?.epoch += 1
        }
    }

    public func seenResults(_ target: any RuntimeMatchable) -> Int {
        let key = ObjectIdentifier(target)
        let entry = seen[key] ?? 0
        return (entry - (entry % 4)) == epoch * 4 ? (entry % 4) : 0
    }

    public func buildRuntimeMatcher(_ matcher: MatcherInput, source: String) -> RuntimeMatcher {
        switch matcher {
        case .predicate(let fn):
            return RuntimeMatcher(source: source, match: fn)
        case .reactive(let reactive):
            return RuntimeMatcher(
                source: source,
                match: { try reactive.get() },
                subscribe: { onChange in try reactive.subscribe(onChange) }
            )
        }
    }

    public func matchesConditions(_ target: any RuntimeMatchable) -> Bool {
        if target.requires.isEmpty && target.matchers.isEmpty {
            return true
        }
        let result = matchRequirements(target.requires) && matchesRuntimeMatchers(target)
        if !target.matchers.isEmpty {
            let key = ObjectIdentifier(target)
            let previous = seenResults(target)
            seen[key] = epoch * 4 + (previous | (result ? 2 : 1))
        }
        return result
    }

    private func matchesRuntimeMatcher(_ matcher: RuntimeMatcher) -> Bool {
        do {
            return try matcher.match()
        } catch {
            notify.emitError(
                "runtime-matcher-error",
                error: error,
                message: "[Keymap] Error evaluating runtime matcher from \(matcher.source):"
            )
            return false
        }
    }

    private func matchesRuntimeMatchers(_ target: any RuntimeMatchable) -> Bool {
        let matchers = target.matchers
        if matchers.isEmpty {
            return true
        }
        if matchers.count == 1 {
            return matchesRuntimeMatcher(matchers[0])
        }
        for matcher in matchers {
            if !matchesRuntimeMatcher(matcher) {
                return false
            }
        }
        return true
    }

    private func matchRequirements(_ requires: [KeymapRequirement]) -> Bool {
        if requires.isEmpty {
            return true
        }
        let data = readData()
        for requirement in requires {
            let current = data[requirement.name] ?? .undefined
            if current != requirement.value {
                return false
            }
        }
        return true
    }
}

// parity: keymap/src/services/conditions.ts#createConditionService [status=implemented hash=1c5047088d2b]
public func createConditionService(
    readData: @escaping @Sendable () -> EventData,
    notify: KeymapNotifier
) -> any ConditionService {
    DefaultConditionService(readData: readData, notify: notify)
}

// MARK: - Field Compiler Invariants

// parity: keymap/src/services/primitives/field-invariants.ts#mergeRequirement [status=implemented hash=a7822b407b8f]
public func mergeRequirement(
    into target: inout EventData,
    name: String,
    value: KeymapValue,
    source: String
) throws(KeymapConditionError) {
    if let existing = target[name], existing != value {
        throw .conflictingRequirement(name: name, source: source)
    }
    target[name] = value
}

// parity: keymap/src/services/primitives/field-invariants.ts#mergeAttribute [status=implemented hash=f8b077291f8a]
public func mergeAttribute(
    into target: inout Attributes,
    name: String,
    value: KeymapValue,
    source: String
) throws(KeymapConditionError) {
    if let existing = target[name], existing != value {
        throw .conflictingAttribute(name: name, source: source)
    }
    target[name] = value
}

/// Mutable compiler context passed to custom binding, layer, and command field compilers.
public final class FieldCompilerContext: @unchecked Sendable {
    private let source: String
    private let conditions: any ConditionService
    private let requireHandler: (String, KeymapValue, String) throws(KeymapConditionError) -> Void
    private let attrHandler: ((String, KeymapValue, String) throws(KeymapConditionError) -> Void)?
    private let appendMatcher: (RuntimeMatcher) -> Void

    internal init(
        source: String,
        conditions: any ConditionService,
        requireHandler: @escaping (String, KeymapValue, String) throws(KeymapConditionError) -> Void,
        attrHandler: ((String, KeymapValue, String) throws(KeymapConditionError) -> Void)?,
        appendMatcher: @escaping (RuntimeMatcher) -> Void
    ) {
        self.source = source
        self.conditions = conditions
        self.requireHandler = requireHandler
        self.attrHandler = attrHandler
        self.appendMatcher = appendMatcher
    }

    public func require(_ name: String, _ value: KeymapValue) throws(KeymapConditionError) {
        try requireHandler(name, value, source)
    }

    public func attr(_ name: String, _ value: KeymapValue) throws(KeymapConditionError) {
        guard let attrHandler else {
            throw .cannotPublishAttributes(source: source)
        }
        try attrHandler(name, value, source)
    }

    public func activeWhen(_ matcher: MatcherInput) {
        appendMatcher(conditions.buildRuntimeMatcher(matcher, source: source))
    }

    public func activeWhen(_ predicate: @escaping @Sendable () throws -> Bool) {
        activeWhen(.predicate(predicate))
    }

    public func activeWhen(_ reactive: ReactiveMatcher) {
        activeWhen(.reactive(reactive))
    }
}

/// Shared mutable accumulator used while compiling fields on a binding, layer, or command.
public final class FieldAccumulator: @unchecked Sendable {
    public var requirements: EventData = [:]
    public var requirementOrder: [String] = []
    public var attrs: Attributes = [:]
    public var matchers: [RuntimeMatcher] = []
    public let allowsAttributes: Bool

    public init(allowsAttributes: Bool = true) {
        self.allowsAttributes = allowsAttributes
    }

    public var orderedRequirements: [KeymapRequirement] {
        requirementOrder.compactMap { name in
            requirements[name].map { KeymapRequirement(name: name, value: $0) }
        }
    }
}

// parity: keymap/src/services/primitives/field-invariants.ts#createFieldCompilerContext [status=implemented hash=c49beb2335f5]
public func createFieldCompilerContext(
    fieldName: String,
    conditions: any ConditionService,
    accumulator: FieldAccumulator
) -> FieldCompilerContext {
    let source = "field \(fieldName)"
    return FieldCompilerContext(
        source: source,
        conditions: conditions,
        requireHandler: { name, value, src throws(KeymapConditionError) in
            let existed = accumulator.requirements[name] != nil
            try mergeRequirement(into: &accumulator.requirements, name: name, value: value, source: src)
            if !existed {
                accumulator.requirementOrder.append(name)
            }
        },
        attrHandler: accumulator.allowsAttributes
            ? { name, value, src throws(KeymapConditionError) in
                try mergeAttribute(into: &accumulator.attrs, name: name, value: value, source: src)
            }
            : nil,
        appendMatcher: { matcher in
            accumulator.matchers.append(matcher)
        }
    )
}

public typealias FieldCompiler = @Sendable (KeymapValue, FieldCompilerContext) throws -> Void

// MARK: - Internal Shared Helpers

internal func keymapTrimWhitespace(_ value: String) -> String {
    let scalars = value.unicodeScalars
    var start = scalars.startIndex
    var end = scalars.endIndex
    func isWS(_ s: Unicode.Scalar) -> Bool {
        s.value == 0x20 || s.value == 0x09 || s.value == 0x0A || s.value == 0x0B || s.value == 0x0C
            || s.value == 0x0D || s.value == 0xA0 || s.value == 0xFEFF
    }
    while start < end && isWS(scalars[start]) {
        start = scalars.index(after: start)
    }
    while end > start {
        let prev = scalars.index(before: end)
        if isWS(scalars[prev]) {
            end = prev
        } else {
            break
        }
    }
    return String(scalars[start..<end])
}

internal func keymapContainsWhitespace(_ value: String) -> Bool {
    for scalar in value.unicodeScalars {
        if scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0B
            || scalar.value == 0x0C || scalar.value == 0x0D || scalar.value == 0xA0 || scalar.value == 0xFEFF
        {
            return true
        }
    }
    return false
}

public extension NormalizedKeyStroke {
    var asStrokeInput: KeyStrokeInput {
        KeyStrokeInput(
            name: name,
            ctrl: ctrl,
            shift: shift,
            meta: meta,
            super: `super`,
            hyper: hyper
        )
    }
}
