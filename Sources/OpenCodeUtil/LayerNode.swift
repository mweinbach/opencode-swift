import Synchronization

/// Pure-Swift dependency-graph & layer composition runtime mirroring `packages/util/src/effect/layer-node.ts`.
///
/// Supports tagged scopes (`global`, `location`, etc.), node overrides (`replace`),
/// cycle detection, unbound-node validation, shared vs local memoized acquisition,
/// and `Teardown.track` release tracking on scope teardown.
public enum LayerNode {
    // parity: util/src/effect/layer-node.ts#Tag [status=implemented hash=8e62f218abd0]
    public struct Tag: Equatable, Hashable, Sendable, CustomStringConvertible {
        public let name: String

        public init(_ name: String) {
            self.name = name
        }

        public var description: String { name }
    }

    /// Runtime error thrown during layer graph compilation or acquisition.
    // parity: util/src/effect/layer-node.ts#Error [status=implemented hash=34259b4a382b]
    public struct GraphError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Type-erased service map built by a compiled layer graph.
    // parity: util/src/effect/layer-node.ts#Output [status=implemented hash=1ea5dcf9f491]
    public struct Output: Sendable {
        private let services: [String: any Sendable]

        public init(_ services: [String: any Sendable] = [:]) {
            self.services = services
        }

        public func get<T: Sendable>(_ key: String, as type: T.Type = T.self) -> T? {
            services[key] as? T
        }

        public func merging(_ other: Output) -> Output {
            var merged = services
            for (k, v) in other.services {
                merged[k] = v
            }
            return Output(merged)
        }
    }

    /// Scoped resource container tracking release finalizers in LIFO order.
    public final class ResourceScope: Sendable {
        private let finalizers = Mutex<[@Sendable () async -> Void]>([])

        public init() {}

        public func addFinalizer(_ finalizer: @escaping @Sendable () async -> Void) {
            finalizers.withLock { $0.append(finalizer) }
        }

        public func close() async {
            let list = finalizers.withLock { current -> [@Sendable () async -> Void] in
                let copy = current
                current.removeAll()
                return copy
            }
            for finalizer in list.reversed() {
                await finalizer()
            }
        }
    }

    /// Memoization cache preserving singleton acquisition per node identity within a build scope.
    public final class MemoMap: Sendable {
        private let cache = Mutex<[ObjectIdentifier: Output]>([:])

        public init() {}

        public func get(_ id: ObjectIdentifier) -> Output? {
            cache.withLock { $0[id] }
        }

        public func set(_ id: ObjectIdentifier, output: Output) {
            cache.withLock { $0[id] = output }
        }
    }

    /// Executable layer builder taking resolved dependencies and a resource scope.
    public final class ExecutableLayer: Sendable {
        public let build: @Sendable (Output, ResourceScope) async throws -> Output

        public init(_ build: @escaping @Sendable (Output, ResourceScope) async throws -> Output) {
            self.build = build
        }

        public static func succeed<T: Sendable>(key: String, value: T) -> ExecutableLayer {
            ExecutableLayer { _, _ in Output([key: value]) }
        }

        public static let empty = ExecutableLayer { _, _ in Output() }
    }

    internal enum Definition: Sendable {
        case group(name: String, dependencies: [Graph])
        case unbound(name: String)
        case layer(name: String, implementation: ExecutableLayer, dependencies: [Graph])

        var name: String {
            switch self {
            case .group(let name, _), .unbound(let name), .layer(let name, _, _):
                return name
            }
        }
    }

    // parity: util/src/effect/layer-node.ts#Graph [status=implemented hash=2732d68c582b]
    public class Graph: @unchecked Sendable {
        internal let definition: Definition

        internal init(definition: Definition) {
            self.definition = definition
        }

        public var name: String { definition.name }
    }

    // parity: util/src/effect/layer-node.ts#Node [status=implemented hash=84d6239b8866]
    public class Node: Graph, @unchecked Sendable {
        public let tag: Tag?

        internal init(definition: Definition, tag: Tag?) {
            self.tag = tag
            super.init(definition: definition)
        }

        /// Replaces this node across the entire graph without acquiring its original wiring.
        public func replace(with target: Node) throws -> Replacement {
            if target.tag != self.tag {
                throw GraphError("Cannot replace \(name) across tags")
            }
            return Replacement(source: self, target: target)
        }

        public func replace(with layer: ExecutableLayer) -> Replacement {
            let provider = Provider(
                name: name,
                implementation: layer,
                dependencies: [],
                tag: tag
            )
            return Replacement(source: self, target: provider)
        }
    }

    // parity: util/src/effect/layer-node.ts#Provider [status=implemented hash=7353ae6282b4]
    public final class Provider: Node, @unchecked Sendable {
        internal init(name: String, implementation: ExecutableLayer, dependencies: [Graph], tag: Tag?) {
            super.init(
                definition: .layer(name: name, implementation: implementation, dependencies: dependencies),
                tag: tag
            )
        }

        /// Decorates this provider's implementation while preserving its dependency wiring and tag.
        public func mapLayer(_ transform: (ExecutableLayer) -> ExecutableLayer) throws -> Provider {
            guard case .layer(let name, let impl, let deps) = definition else {
                throw GraphError("Cannot map unbound layer node: \(self.name)")
            }
            return Provider(name: name, implementation: transform(impl), dependencies: deps, tag: tag)
        }
    }

    // parity: util/src/effect/layer-node.ts#Replacement [status=implemented hash=79caf3ce9c88]
    public struct Replacement: Sendable {
        public let source: Node
        public let target: Node

        internal init(source: Node, target: Node) {
            self.source = source
            self.target = target
        }
    }

    // parity: util/src/effect/layer-node.ts#Replacements [status=implemented hash=a116f8f6132b]
    public typealias Replacements = [Replacement]

    // parity: util/src/effect/layer-node.ts#TagConfig [status=implemented hash=e366ddd6e71c]
    public typealias TagConfig = [String: [String]]

    // parity: util/src/effect/layer-node.ts#TagMaker [status=implemented hash=d3cbddbc7f3a]
    public typealias TagMaker = @Sendable (String, ExecutableLayer, [Graph]) -> Provider

    // parity: util/src/effect/layer-node.ts#Tags [status=implemented hash=9912ce945ee5]
    public struct Tags: Sendable {
        public let values: [String: Tag]
        public let allowedDependencies: TagConfig

        public init(values: [String: Tag], allowedDependencies: TagConfig) {
            self.values = values
            self.allowedDependencies = allowedDependencies
        }

        public func make(_ name: String) -> TagMaker {
            let tag = values[name] ?? Tag(name)
            return { nodeName, layer, deps in
                Provider(name: nodeName, implementation: layer, dependencies: deps, tag: tag)
            }
        }
    }

    // parity: util/src/effect/layer-node.ts#tags [status=implemented hash=ecd4d6c1127f]
    public static func tags(_ config: TagConfig) -> Tags {
        var map: [String: Tag] = [:]
        for key in config.keys {
            map[key] = Tag(key)
        }
        return Tags(values: map, allowedDependencies: config)
    }

    // parity: util/src/effect/layer-node.ts#make [status=implemented hash=07e39af681a3]
    public static func make(
        name: String,
        layer: ExecutableLayer,
        deps: [Graph] = [],
        tag: Tag? = nil
    ) -> Provider {
        Provider(name: name, implementation: layer, dependencies: deps, tag: tag)
    }

    // parity: util/src/effect/layer-node.ts#unbound [status=implemented hash=d9a8d440429d]
    public static func unbound(name: String, tag: Tag) -> Node {
        Node(definition: .unbound(name: name), tag: tag)
    }

    // parity: util/src/effect/layer-node.ts#group [status=implemented hash=7e5140a68a62]
    public static func group(_ dependencies: [Graph]) -> Graph {
        Graph(definition: .group(name: "group", dependencies: dependencies))
    }

    // parity: util/src/effect/layer-node.ts#CompileOptions [status=implemented hash=4af29e4ccd53]
    public struct CompileOptions: Sendable {
        public let replacements: Replacements
        public let shared: Tag?

        public init(replacements: Replacements = [], shared: Tag? = nil) {
            self.replacements = replacements
            self.shared = shared
        }
    }

    /// Compiled, validated layer plan ready to build against a `MemoMap` and `ResourceScope`.
    public struct CompiledGraph: Sendable {
        private let roots: [ResolvedNode]
        private let shared: Tag?

        internal init(roots: [ResolvedNode], shared: Tag?) {
            self.roots = roots
            self.shared = shared
        }

        public func build(memoMap: MemoMap = MemoMap(), scope: ResourceScope = ResourceScope()) async throws -> Output {
            let local = (shared == nil) ? memoMap : MemoMap()
            var combined = Output()
            for root in roots {
                let out = try await buildNode(root, sharedMemo: memoMap, localMemo: local, scope: scope)
                combined = combined.merging(out)
            }
            return combined
        }

        private func buildNode(
            _ node: ResolvedNode,
            sharedMemo: MemoMap,
            localMemo: MemoMap,
            scope: ResourceScope
        ) async throws -> Output {
            let memo = node.shared ? sharedMemo : localMemo
            let key = ObjectIdentifier(node)
            if let cached = memo.get(key) {
                return cached
            }
            var depOutput = Output()
            for dep in node.dependencies {
                let out = try await buildNode(dep, sharedMemo: sharedMemo, localMemo: localMemo, scope: scope)
                depOutput = depOutput.merging(out)
            }
            // Bracket release with Teardown.track just like upstream `trackRelease`.
            let settleBox = Mutex<(@Sendable () -> Void)?>(nil)
            scope.addFinalizer {
                if let settle = settleBox.withLock({ $0 }) {
                    settle()
                }
            }
            let built = try await node.implementation.build(depOutput, scope)
            let nodeName = node.name
            scope.addFinalizer {
                let settle = Teardown.track("layer \(nodeName) releasing")
                settleBox.withLock { $0 = settle }
            }
            memo.set(key, output: built)
            return built
        }
    }

    internal final class ResolvedNode: Sendable {
        let name: String
        let implementation: ExecutableLayer
        let dependencies: [ResolvedNode]
        let shared: Bool

        init(name: String, implementation: ExecutableLayer, dependencies: [ResolvedNode], shared: Bool) {
            self.name = name
            self.implementation = implementation
            self.dependencies = dependencies
            self.shared = shared
        }
    }

    /// Resolves replacements, validates acyclicity and bindings, and compiles `root` into an executable graph.
    // parity: util/src/effect/layer-node.ts#compile [status=implemented hash=399d4ae52c74]
    public static func compile(_ root: Graph, options: CompileOptions = CompileOptions()) throws -> CompiledGraph {
        let shared = options.shared
        var replacementMap: [ObjectIdentifier: Node] = [:]
        for item in options.replacements {
            replacementMap[ObjectIdentifier(item.source)] = item.target
        }

        var sharedCache: [ObjectIdentifier: [ResolvedNode]] = [:]
        var localCache: [ObjectIdentifier: [ResolvedNode]] = [:]
        var sharedDefs: [ObjectIdentifier: ResolvedNode] = [:]
        var localDefs: [ObjectIdentifier: ResolvedNode] = [:]
        var stack: [Graph] = []

        func resolve(_ graph: Graph, inherited: Bool = false) throws -> [ResolvedNode] {
            let graphID = ObjectIdentifier(graph)
            let isShared = inherited || (shared != nil && (graph as? Node)?.tag == shared)
            if isShared, let cached = sharedCache[graphID] { return cached }
            if !isShared, let cached = localCache[graphID] { return cached }

            if let cycleIdx = stack.firstIndex(where: { ObjectIdentifier($0) == graphID }) {
                let cycleNames = (stack[cycleIdx...] + [graph]).map(\.name).joined(separator: " -> ")
                throw GraphError("Cycle detected in layer graph: \(cycleNames)")
            }

            stack.append(graph)
            defer { stack.removeLast() }

            let result: [ResolvedNode]
            if let replacement = replacementMap[graphID], ObjectIdentifier(replacement) != graphID {
                result = try resolve(replacement, inherited: isShared)
            } else {
                switch graph.definition {
                case .group(_, let dependencies):
                    result = try dependencies.flatMap { try resolve($0, inherited: isShared) }
                case .unbound(let name):
                    throw GraphError("Unbound layer node: \(name)")
                case .layer(let name, let implementation, let dependencies):
                    let resolvedDeps = try dependencies.flatMap { try resolve($0, inherited: isShared) }
                    let implID = ObjectIdentifier(implementation)
                    let existing = isShared ? sharedDefs[implID] : localDefs[implID]
                    if let existing {
                        let sameCount = existing.dependencies.count == resolvedDeps.count
                        let sameDeps = sameCount && zip(existing.dependencies, resolvedDeps).allSatisfy {
                            ObjectIdentifier($0) == ObjectIdentifier($1)
                        }
                        if !sameDeps {
                            throw GraphError(
                                "Layer \(name) is wired to different dependencies; use a distinct implementation Layer"
                            )
                        }
                        result = [existing]
                    } else {
                        let node = ResolvedNode(
                            name: name,
                            implementation: implementation,
                            dependencies: resolvedDeps,
                            shared: isShared
                        )
                        if isShared {
                            sharedDefs[implID] = node
                        } else {
                            localDefs[implID] = node
                        }
                        result = [node]
                    }
                }
            }

            if isShared {
                sharedCache[graphID] = result
            } else {
                localCache[graphID] = result
            }
            return result
        }

        let roots = try resolve(root)
        return CompiledGraph(roots: roots, shared: shared)
    }
}
