import Synchronization

// Value copies across the program boundary (structured clone, host-call arguments), ported from psychoscript
// `src/stdlib/web.ts#structuredCloneGlobal` and `src/runtime/extensions.ts` (`toHost`).
extension CodemodeLanguage {
    /// HTML structured clone over the program's data kinds: shared references survive through the memo; prototypes and
    /// frozen state do not. Without a DOMException, DataCloneError is a TypeError carrying that prefix.
    // Upstream: psychoscript/src/stdlib/web.ts#structuredCloneGlobal (implemented).
    static func structuredCloneValue(_ value: Value, builtins: Builtins, memo: inout [ObjectIdentifier: Obj]) throws -> Value {
        switch value {
        case .symbol, .hostNamespace:
            throw typeError("DataCloneError: \(describeValue(value)) could not be cloned.")
        case .object(let obj):
            if let seen = memo[ObjectIdentifier(obj)] { return .object(seen) }
            func remember<T: Obj>(_ copy: T) -> T {
                memo[ObjectIdentifier(obj)] = copy
                return copy
            }
            if let map = obj as? MapObj {
                let copy = remember(MapObj(proto: builtins.Map))
                for (k, v) in map.table.liveEntries() {
                    copy.table.set(try structuredCloneValue(k, builtins: builtins, memo: &memo), try structuredCloneValue(v, builtins: builtins, memo: &memo))
                }
                return .object(copy)
            }
            if let set = obj as? SetObj {
                let copy = remember(SetObj(proto: builtins.Set))
                for k in set.table.liveKeys() { copy.table.add(try structuredCloneValue(k, builtins: builtins, memo: &memo)) }
                return .object(copy)
            }
            if let date = obj as? DateObj { return .object(remember(DateObj(proto: builtins.Date, epochMs: date.epochMs))) }
            if let rx = obj as? RegExpObj { return .object(remember(RegExpObj(proto: builtins.RegExp, pattern: rx.pattern, flags: rx.flags))) }
            if let bytes = obj as? Bytes { return .object(remember(Bytes(proto: builtins.Uint8Array, data: bytes.data))) }
            if let err = obj as? ErrorObj {
                let name = get(err, "name")
                let message = get(err, "message")
                let proto: Obj = if case .string(let n) = name, let type = ErrorType(rawValue: n) { builtins.errorProto(type) } else { builtins.Error }
                let copy = remember(createErrorValue(proto, message: message.isUndefined ? nil : coerceToString(message)))
                if case .string(let stack) = getOwn(err, "stack") { define(copy, "stack", .string(stack), hidden) }
                if hasOwn(err, "cause") { define(copy, "cause", try structuredCloneValue(getOwn(err, "cause"), builtins: builtins, memo: &memo), hidden) }
                return .object(copy)
            }
            if obj is Callable || obj is PromiseObj || obj is GeneratorObj || obj is WeakMapObj || obj is WeakSetObj || !(type(of: obj) == Obj.self || obj is Arr) {
                throw typeError("DataCloneError: \(describeValue(value)) could not be cloned.")
            }
            if let arr = obj as? Arr {
                let copy = remember(Arr(proto: builtins.Array, items: []))
                var items: [Value] = []
                items.reserveCapacity(arr.items.count)
                for item in arr.items { items.append(try structuredCloneValue(item, builtins: builtins, memo: &memo)) }
                copy.items = items
                return .object(copy)
            }
            let copy = remember(Obj(proto: builtins.Object))
            for (k, v) in entries(obj) { define(copy, k, try structuredCloneValue(v, builtins: builtins, memo: &memo)) }
            return .object(copy)
        default:
            return value
        }
    }

    /// A host call's argument as the host receives it: a copy, so neither side sees the other's later changes
    /// (upstream `toHost`). A program function is dropped (`translate.functions == .drop`; nil here) or fails the
    /// call; a promise is awaited (`translate.promises == .await`) or fails it; values nest at most 32 deep.
    // Upstream: psychoscript/src/runtime/extensions.ts#toHost (adapted).
    static func copyToHost(
        _ value: Value,
        label: String,
        depth: Int,
        translate: Translate,
        takesFunctions: Bool,
        ancestors: inout Set<ObjectIdentifier>,
        builtins: Builtins,
        eval: Evaluator
    ) async throws -> Value? {
        if depth > MAX_VALUE_DEPTH {
            throw typeError("\(label) exceeds the maximum value depth of \(MAX_VALUE_DEPTH).")
        }
        guard case .object(let obj) = value else {
            if case .symbol = value { throw typeError("\(label) contains \(describeValue(value)), which cannot be passed to the host.") }
            return value
        }
        if obj is Callable {
            if takesFunctions { return value }
            if translate.functions == .drop { return nil }
            throw typeError("\(label) contains \(describeValue(value)), which cannot be passed to the host.")
        }
        let key = ObjectIdentifier(obj)
        if ancestors.contains(key) { throw typeError("\(label) contains a circular value.") }
        if let promise = obj as? PromiseObj {
            guard translate.promises == .await else {
                throw typeError("\(label) contains \(describeValue(value)), which cannot be passed to the host.")
            }
            let settled = try await eval.awaitValue(.object(promise))
            ancestors.insert(key)
            defer { ancestors.remove(key) }
            return try await copyToHost(settled, label: label, depth: depth + 1, translate: translate, takesFunctions: takesFunctions, ancestors: &ancestors, builtins: builtins, eval: eval)
        }
        ancestors.insert(key)
        defer { ancestors.remove(key) }
        func next(_ item: Value) async throws -> Value? {
            try await copyToHost(item, label: label, depth: depth + 1, translate: translate, takesFunctions: takesFunctions, ancestors: &ancestors, builtins: builtins, eval: eval)
        }
        if let arr = obj as? Arr {
            var items: [Value] = []
            items.reserveCapacity(arr.items.count)
            for item in arr.items { items.append(try await next(item) ?? .null) }
            return .object(Arr(proto: builtins.Array, items: items))
        }
        if let map = obj as? MapObj {
            let copy = MapObj(proto: builtins.Map)
            for (k, v) in map.table.liveEntries() { copy.table.set(try await next(k) ?? .undefined, try await next(v) ?? .undefined) }
            return .object(copy)
        }
        if let set = obj as? SetObj {
            let copy = SetObj(proto: builtins.Set)
            for k in set.table.liveKeys() { copy.table.add(try await next(k) ?? .undefined) }
            return .object(copy)
        }
        if let date = obj as? DateObj { return .object(DateObj(proto: builtins.Date, epochMs: date.epochMs)) }
        if let bytes = obj as? Bytes { return .object(Bytes(proto: builtins.Uint8Array, data: bytes.data)) }
        if let err = obj as? ErrorObj {
            let name = coerceToString(get(err, "name"))
            let message = get(err, "message")
            let proto: Obj = if let type = ErrorType(rawValue: name) { builtins.errorProto(type) } else { builtins.Error }
            let copy = createErrorValue(proto, message: message.isUndefined ? "" : coerceToString(message))
            for (k, v) in entries(err) where k != "stack" {
                if let item = try await next(v) { define(copy, k, item) }
            }
            return .object(copy)
        }
        guard type(of: obj) == Obj.self else { return value }
        let copy = Obj(proto: builtins.Object)
        for (k, v) in entries(obj) where k != "__proto__" {
            if let item = try await next(v) { define(copy, k, item) }
        }
        return .object(copy)
    }
}

// MARK: - Unsupported syntax at run time

extension CodemodeLanguage {
    /// Upstream compiles unsupported syntax (and BigInt literals) to an error thrown where the construct runs, so a
    /// program fails only if it reaches it. The parser stands such a construct in with an identifier carrying this
    /// marker, which the evaluator turns into the error (`markerError`).
    static let bigIntMarker = "%bigint"
    static let unsupportedMarkerPrefix = "%unsupported:"

    struct BigIntLiteralMarker: Error {}

    // Upstream: psychoscript/src/compiler/compile.ts#emitUnsupported (adapted).
    static func unsupportedThrow(_ kindName: String, at loc: SourceLocation) -> Expression {
        unsupportedThrow(message: "Syntax '\(kindName)' is not supported. \(supportedSyntaxMessage)", at: loc)
    }

    static func unsupportedThrow(message: String, at loc: SourceLocation) -> Expression {
        .identifier(name: unsupportedMarkerPrefix + message, loc: loc)
    }

    /// The error a marker identifier stands for, or nil for an ordinary name.
    static func markerError(_ name: String, node: AstNode?) -> PendingThrow? {
        guard name.first == "%" else { return nil }
        if name == bigIntMarker {
            return PendingThrow(type: .typeError, message: "BigInt literals are not supported.", node: node)
        }
        if name.hasPrefix(unsupportedMarkerPrefix) {
            return PendingThrow(
                type: .syntaxError,
                message: String(name.dropFirst(unsupportedMarkerPrefix.count)),
                node: node,
                kind: "UnsupportedSyntax",
                suggestions: [supportedSyntaxMessage]
            )
        }
        return nil
    }
}

extension CodemodeLanguage {
    /// Why `specifier` can't be loaded, split so the error names the kind of import that failed.
    // Upstream: psychoscript/src/runtime/interpreter.ts#cannotImport (implemented).
    static func cannotImport(_ specifier: String) -> String {
        if specifier.hasPrefix(".") || specifier.hasPrefix("/") || specifier.hasPrefix("file:") {
            return "Cannot import \"\(specifier)\": local files can't be imported."
        }
        if isRuntimeModule(specifier) { return "Cannot import \"\(specifier)\": this runtime doesn't provide it." }
        return "Cannot import \"\(specifier)\": packages can't be installed here."
    }
}

extension CodemodeLanguage {
    /// `String(symbol)`: upstream's two symbols are host symbols described `psychoscript.iterator` and
    /// `psychoscript.async-iterator` (`src/runtime/model.ts`).
    static func symbolString(_ sym: RuntimeSymbol) -> String {
        if sym == IteratorSymbol { return "Symbol(psychoscript.iterator)" }
        if sym == AsyncIteratorSymbol { return "Symbol(psychoscript.async-iterator)" }
        return "Symbol(\(sym.description))"
    }
}
