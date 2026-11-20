import OpenCodeSchema

/// Program-code member access for the confined evaluator: [[Get]] and [[Set]] that run program getters and setters.
/// Ports the callers of `psychoscript/src/runtime/operations.ts#accessProperty` / `#assignToReference` and the VM's
/// read-ahead of program getters (`Prefetch`, see `CodemodeLanguage.withReads`).
extension CodemodeLanguage.Evaluator {
    /// Reads `base[key]` the way a member expression does: a program getter on the chain runs with `base` as `this`,
    /// and reading a property an un-awaited promise lacks is an error.
    public func readMember(_ base: CodemodeLanguage.Value, _ key: CodemodeLanguage.PropertyKey, node: CodemodeLanguage.AstNode? = nil) async throws -> CodemodeLanguage.Value {
        try await readThrough(base, key, node: node, checkPromise: true)
    }

    /// Writes `base[key] = value` the way an assignment does: a program setter on the chain runs with `base` as `this`.
    public func writeMember(_ base: CodemodeLanguage.Value, _ key: CodemodeLanguage.PropertyKey, _ value: CodemodeLanguage.Value, node: CodemodeLanguage.AstNode? = nil) async throws {
        if let setter = try CodemodeLanguage.assignToReference(base, key, value, node: node) {
            _ = try await callCallable(.object(setter), thisValue: base, args: [value], site: node)
        }
    }

    /// [[Get]] on an object that runs a program getter it reaches.
    public func getValue(_ obj: CodemodeLanguage.Obj, _ key: CodemodeLanguage.PropertyKey, receiver: CodemodeLanguage.Value? = nil, node: CodemodeLanguage.AstNode? = nil) async throws -> CodemodeLanguage.Value {
        let thisValue = receiver ?? .object(obj)
        switch try CodemodeLanguage.accessProperty(obj, key, node: node, receiver: thisValue) {
        case .value(let value): return value
        case .getter(let call):
            return try await callCallable(.object(call.getter), thisValue: thisValue, args: [], site: node)
        }
    }

    /// `lhs instanceof rhs`, running a program `prototype` getter first.
    public func instanceOf(_ lhs: CodemodeLanguage.Value, _ rhs: CodemodeLanguage.Value, node: CodemodeLanguage.AstNode? = nil) async throws -> Bool {
        switch try CodemodeLanguage.instanceofValue(lhs, rhs, node: node) {
        case .result(let answer): return answer
        case .getter(let call):
            let proto = try await callCallable(.object(call.getter), thisValue: rhs, args: [], site: node)
            return try CodemodeLanguage.hasInstance(lhs, proto, node: node)
        }
    }

    /// CopyDataProperties for spread and rest: a source with program getters is read key by key in program code, each
    /// key's enumerability checked as it is visited.
    public func copyDataPropertiesAsync(_ target: CodemodeLanguage.Obj, _ source: CodemodeLanguage.Obj, skip: Set<CodemodeLanguage.PropertyKey> = []) async throws {
        guard source.hasProgramAccessors else {
            CodemodeLanguage.copyDataProperties(target, source, skip: skip)
            return
        }
        for key in CodemodeLanguage.enumerableCopyKeys(source) where !skip.contains(key) {
            guard CodemodeLanguage.own(source, key)?.enumerable == true else { continue }
            CodemodeLanguage.define(target, key, try await getValue(source, key))
        }
    }

    /// Carries out a `Prefetch`: reads each (receiver, key) pair in program code, for `withReads` to record.
    func runPrefetch(_ prefetch: CodemodeLanguage.Prefetch) async throws -> [(CodemodeLanguage.Value, CodemodeLanguage.PropertyKey, CodemodeLanguage.Value)] {
        var out: [(CodemodeLanguage.Value, CodemodeLanguage.PropertyKey, CodemodeLanguage.Value)] = []
        var at = 0
        let reads = prefetch.reads
        while at + 1 < reads.count {
            let receiver = reads[at]
            let key = CodemodeLanguage.propertyKey(reads[at + 1])
            out.append((receiver, key, try await readThrough(receiver, key, node: nil, checkPromise: false)))
            at += 2
        }
        return out
    }

    private func readThrough(_ base: CodemodeLanguage.Value, _ key: CodemodeLanguage.PropertyKey, node: CodemodeLanguage.AstNode?, checkPromise: Bool) async throws -> CodemodeLanguage.Value {
        let reference = try CodemodeLanguage.resolveReference(base, key, builtins: builtins, node: node)
        switch reference {
        case .namespace(let ns): return .hostNamespace(ns)
        case .value(let value): return value
        case .member(let target, let key, let receiver):
            if checkPromise { try CodemodeLanguage.requirePromiseProperty(reference, node: node) }
            return try await getValue(target, key, receiver: receiver, node: node)
        }
    }
}
