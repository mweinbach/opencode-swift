// Pure Swift 6 port of keymap/src/services/values.ts.

private let KEYMAP_VALUE_DEPTH_MAX = 16
// Compiled data nests the checked data a few levels deeper; the bound only stops cycles a compile hook made.
private let KEYMAP_COMPILED_DEPTH_MAX = 32

/// Error protocol providing a human-readable message without importing `Foundation`.
public protocol KeymapDescribedError: Error, Sendable {
    var errorMessage: String { get }
}

/// Marker protocol for promise/thenable values in pure Swift.
public protocol PromiseLike: Sendable {}

/// Options controlling `snapshotDataValue`.
public struct SnapshotDataOptions: Equatable, Hashable, Sendable {
    public let deep: Bool
    public let freeze: Bool
    public let preserveNonPlainObjects: Bool

    public init(
        deep: Bool = false,
        freeze: Bool = false,
        preserveNonPlainObjects: Bool = false
    ) {
        self.deep = deep
        self.freeze = freeze
        self.preserveNonPlainObjects = preserveNonPlainObjects
    }
}

/// Stable reference wrapper that forwards to its current `target`, allowing kept layers to
/// swap closures or values in place without breaking caller references.
public final class Forwarder<T: Sendable>: @unchecked Sendable {
    public var target: T

    public init(_ target: T) {
        self.target = target
    }
}

/// Tracks caller-supplied or compile-hook-supplied reference objects that compare by identity.
public final class ExternalObjectRegistry: @unchecked Sendable {
    private var objectIDs: Set<ObjectIdentifier> = []

    public init() {}

    public func add(_ object: AnyObject) {
        objectIDs.insert(ObjectIdentifier(object))
    }

    public func contains(_ object: AnyObject) -> Bool {
        objectIDs.contains(ObjectIdentifier(object))
    }

    public var count: Int {
        objectIDs.count
    }

    public var isEmpty: Bool {
        objectIDs.isEmpty
    }
}

/// Represents a retarget/update move produced while comparing compiled layer data.
public struct CompiledDataMove: Sendable {
    public let key: String
    public let apply: @Sendable () -> Void

    public init(key: String, apply: @escaping @Sendable () -> Void) {
        self.key = key
        self.apply = apply
    }
}

private enum ExternalScope {
    @TaskLocal static var current: ExternalObjectRegistry?
}

/// JavaScript `Object.is` comparison for `KeymapValue`.
public func objectIs(_ lhs: KeymapValue, _ rhs: KeymapValue) -> Bool {
    lhs == rhs
}

/// JavaScript `Object.is` comparison for `Double` (`NaN == NaN`, `+0.0 != -0.0`).
public func objectIs(_ lhs: Double, _ rhs: Double) -> Bool {
    if lhs.isNaN && rhs.isNaN {
        return true
    }
    return lhs.bitPattern == rhs.bitPattern
}

// parity: keymap/src/services/values.ts#isPlainData [status=implemented hash=5285a0b9180d]
public func isPlainData(_ value: KeymapValue, identityKey: String? = nil) -> Bool {
    checkPlainData(value, identityKey: identityKey, depth: 0)
}

private func checkPlainData(_ value: KeymapValue, identityKey: String?, depth: Int) -> Bool {
    switch value {
    case .undefined, .null, .bool, .int, .double, .string:
        return true
    case .array(let items):
        if depth >= KEYMAP_VALUE_DEPTH_MAX {
            return false
        }
        for item in items {
            if !checkPlainData(item, identityKey: nil, depth: depth + 1) {
                return false
            }
        }
        return true
    case .object(let dict):
        if depth >= KEYMAP_VALUE_DEPTH_MAX {
            return false
        }
        for (key, entry) in dict {
            if key == "__proto__" {
                return false
            }
            if depth == 0 && key == identityKey {
                continue
            }
            if !checkPlainData(entry, identityKey: nil, depth: depth + 1) {
                return false
            }
        }
        return true
    }
}

// parity: keymap/src/services/values.ts#createForwarder [status=implemented hash=ec85a3759f41]
public func createForwarder<T: Sendable>(_ target: T) -> Forwarder<T> {
    Forwarder(target)
}

// parity: keymap/src/services/values.ts#collectExternal [status=implemented hash=b77fa0ab06e9]
public func collectExternal<T>(
    _ objects: ExternalObjectRegistry,
    _ compile: () throws -> T
) rethrows -> T {
    try ExternalScope.$current.withValue(objects) {
        try compile()
    }
}

// parity: keymap/src/services/values.ts#markSupplied [status=implemented hash=195724698534]
public func markSupplied(_ value: Any?) {
    guard let current = ExternalScope.current, let value else {
        return
    }
    if let object = value as AnyObject? {
        // Only track reference types (classes); value types bridge to boxed objects in some contexts,
        // so check `type(of: value) is AnyClass`.
        if type(of: value) is AnyClass {
            current.add(object)
        }
    }
}

// parity: keymap/src/services/values.ts#markExternal [status=implemented hash=da9c8f13bb29]
public func markExternal(_ value: Any?, depth: Int = 0) {
    guard let current = ExternalScope.current, let value else {
        return
    }

    if type(of: value) is AnyClass {
        let object = value as AnyObject
        if current.contains(object) {
            return
        }
        current.add(object)
        return
    }

    if depth >= KEYMAP_VALUE_DEPTH_MAX {
        return
    }

    if let array = value as? [Any] {
        for element in array {
            markExternal(element, depth: depth + 1)
        }
    } else if let dict = value as? [String: Any] {
        for (_, entry) in dict {
            markExternal(entry, depth: depth + 1)
        }
    }
}

// parity: keymap/src/services/values.ts#sameCompiledData [status=implemented hash=9a5ba0a59d7e]
public func sameCompiledData(
    _ left: KeymapValue,
    _ right: KeymapValue,
    external: ExternalObjectRegistry = ExternalObjectRegistry(),
    moves: inout [CompiledDataMove],
    depth: Int = 0
) -> Bool {
    if objectIs(left, right) {
        if case .array = left, depth >= KEYMAP_COMPILED_DEPTH_MAX {
            return false
        }
        if case .object = left, depth >= KEYMAP_COMPILED_DEPTH_MAX {
            return false
        }
        return true
    }

    switch (left, right) {
    case (.array(let lhs), .array(let rhs)):
        if depth >= KEYMAP_COMPILED_DEPTH_MAX || lhs.count != rhs.count {
            return false
        }
        for index in 0..<lhs.count {
            if !sameCompiledData(lhs[index], rhs[index], external: external, moves: &moves, depth: depth + 1) {
                return false
            }
        }
        return true

    case (.object(let lhs), .object(let rhs)):
        if depth >= KEYMAP_COMPILED_DEPTH_MAX || lhs.count != rhs.count {
            return false
        }
        for (key, leftValue) in lhs {
            guard let rightValue = rhs[key] else {
                return false
            }
            if !sameCompiledData(leftValue, rightValue, external: external, moves: &moves, depth: depth + 1) {
                return false
            }
        }
        return true

    default:
        return false
    }
}

/// Overload comparing two `Forwarder` instances and recording a retarget move in `moves`.
public func sameCompiledData<T: Sendable>(
    _ left: Forwarder<T>,
    _ right: Forwarder<T>,
    key: String = "target",
    external: ExternalObjectRegistry = ExternalObjectRegistry(),
    moves: inout [CompiledDataMove]
) -> Bool {
    if left === right {
        return true
    }
    if external.contains(left) || external.contains(right) {
        return false
    }
    let nextTarget = right.target
    moves.append(
        CompiledDataMove(key: key) {
            left.target = nextTarget
        }
    )
    return true
}

// parity: keymap/src/services/values.ts#getErrorMessage [status=implemented hash=c51bc64d3ef6]
public func getErrorMessage(_ error: (any Error)?, fallback: String) -> String {
    guard let error else {
        return fallback
    }
    if let described = error as? any KeymapDescribedError, !described.errorMessage.isEmpty {
        return described.errorMessage
    }
    if let convertible = error as? any CustomStringConvertible, !convertible.description.isEmpty {
        return convertible.description
    }
    return fallback
}

// parity: keymap/src/services/values.ts#isPromiseLike [status=implemented hash=bfb497be3a5b]
public func isPromiseLike(_ value: Any?) -> Bool {
    value is any PromiseLike
}

// parity: keymap/src/services/values.ts#snapshotDataValue [status=implemented hash=6ba433834726]
public func snapshotDataValue(
    _ value: KeymapValue,
    options: SnapshotDataOptions = SnapshotDataOptions()
) -> KeymapValue {
    let deep = options.deep

    switch value {
    case .array(let items):
        if deep {
            return .array(items.map { snapshotDataValue($0, options: options) })
        }
        return .array(Array(items))

    case .object(let dict):
        var cloned: [String: KeymapValue] = [:]
        cloned.reserveCapacity(dict.count)
        for (key, entry) in dict {
            cloned[key] = deep ? snapshotDataValue(entry, options: options) : entry
        }
        return .object(cloned)

    case .undefined, .null, .bool, .int, .double, .string:
        return value
    }
}
