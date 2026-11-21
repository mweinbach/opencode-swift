// Pure-Swift native subsystem parity bridges for OpenTUICore (Workstream 3b).
// Covers all 201 unmapped symbols across 11 upstream `packages/native` Zig modules:
// - src/text-buffer.zig (19), src/text-buffer-view.zig (19), src/edit-buffer.zig (7),
//   src/editor-view.zig (3), src/rope.zig (1), src/syntax-style.zig (4),
// - src/audio.zig (58), src/image.zig (37), src/terminal-image.zig (18),
//   src/video.zig (8), src/native-span-feed.zig (27).
// Pure Swift 6 — zero OS or Foundation imports.

import Synchronization

// MARK: - Top-level Namespace

public enum NativeSubsystemsCoreB: Sendable {}

// MARK: - 1. native/src/syntax-style.zig (4 unmapped symbols)

public enum NativeZigSyntaxStyle: Sendable {
    // parity: native/src/syntax-style.zig#id_limit [status=implemented hash=7271e969fb8a]
    public static let idLimit: UInt32 = 0x8000_0000

    // parity: native/src/syntax-style.zig#RGBA [status=implemented hash=7137f217292d]
    public typealias RGBA = OpenTUICore.RGBA

    // parity: native/src/syntax-style.zig#StyleDefinition [status=implemented hash=8b376591d82c]
    public struct StyleDefinition: Equatable, Hashable, Sendable, Codable {
        public var fg: RGBA?
        public var bg: RGBA?
        public var attributes: UInt32
        public var suppliedAttributes: UInt8

        public init(
            fg: RGBA? = nil,
            bg: RGBA? = nil,
            attributes: UInt32 = TextAttributes.none,
            suppliedAttributes: UInt8 = 0xFF
        ) {
            self.fg = fg
            self.bg = bg
            self.attributes = attributes
            self.suppliedAttributes = suppliedAttributes
        }

        public init(from core: OpenTUICore.StyleDefinition) {
            self.fg = core.fg
            self.bg = core.bg
            var attrs: UInt32 = TextAttributes.none
            var supplied: UInt8 = 0
            if let b = core.bold {
                supplied |= UInt8(TextAttributes.bold & 0xFF)
                if b { attrs |= TextAttributes.bold }
            }
            if let i = core.italic {
                supplied |= UInt8(TextAttributes.italic & 0xFF)
                if i { attrs |= TextAttributes.italic }
            }
            if let u = core.underline {
                supplied |= UInt8(TextAttributes.underline & 0xFF)
                if u { attrs |= TextAttributes.underline }
            }
            if let d = core.dim {
                supplied |= UInt8(TextAttributes.dim & 0xFF)
                if d { attrs |= TextAttributes.dim }
            }
            if let s = core.strikethrough {
                supplied |= UInt8(TextAttributes.strikethrough & 0xFF)
                if s { attrs |= TextAttributes.strikethrough }
            }
            self.attributes = attrs
            self.suppliedAttributes = supplied == 0 ? 0xFF : supplied
        }

        public func toCore() -> OpenTUICore.StyleDefinition {
            let mask = UInt32(suppliedAttributes)
            return OpenTUICore.StyleDefinition(
                fg: fg,
                bg: bg,
                bold: (mask & TextAttributes.bold) != 0 ? (attributes & TextAttributes.bold) != 0 : nil,
                italic: (mask & TextAttributes.italic) != 0 ? (attributes & TextAttributes.italic) != 0 : nil,
                underline: (mask & TextAttributes.underline) != 0 ? (attributes & TextAttributes.underline) != 0 : nil,
                dim: (mask & TextAttributes.dim) != 0 ? (attributes & TextAttributes.dim) != 0 : nil,
                strikethrough: (mask & TextAttributes.strikethrough) != 0 ? (attributes & TextAttributes.strikethrough) != 0 : nil
            )
        }
    }

    // parity: native/src/syntax-style.zig#Borrower [status=implemented hash=2a396152eea4]
    public final class Borrower: @unchecked Sendable {
        public enum Dependent: Equatable, Hashable, Sendable {
            case none
            case text(UInt64)
            case edit(UInt64)
            case sceneText(UInt64)
        }

        public private(set) weak var style: SyntaxStyle?
        public var dependent: Dependent
        public private(set) var changes: UInt32 = 0

        public init(dependent: Dependent = .none) {
            self.dependent = dependent
        }

        // parity: native/src/syntax-style.zig#Borrower.bind [status=implemented hash=c1d66a78fc00]
        public func bind(_ newStyle: SyntaxStyle?) {
            if style === newStyle { return }
            if let old = style {
                old.detachBorrower(self)
            }
            style = newStyle
            if let newStyle {
                newStyle.attachBorrower(self)
            }
            changes &+= 1
        }

        internal func unbindFromDestroyedStyle() {
            style = nil
            changes &+= 1
        }

        internal func notifyStyleChanged() {
            changes &+= 1
        }
    }

    // parity: native/src/syntax-style.zig#SyntaxStyle [status=implemented hash=915731df8c12]
    public final class SyntaxStyle: @unchecked Sendable {
        public let core: OpenTUICore.SyntaxStyle
        private let state: Mutex<State>

        private struct State: @unchecked Sendable {
            var definitionsById: [UInt32: StyleDefinition] = [:]
            var groupSetCache: [UInt32: StyleDefinition] = [:]
            var borrowers: [ObjectIdentifier: Borrower] = [:]
        }

        // parity: native/src/syntax-style.zig#SyntaxStyle.init [status=implemented hash=c831c44596af]
        public init(core: OpenTUICore.SyntaxStyle = OpenTUICore.SyntaxStyle.create()) {
            self.core = core
            self.state = Mutex(State())
        }

        // parity: native/src/syntax-style.zig#SyntaxStyle.deinit [status=implemented hash=493309c91c34]
        deinit {
            let detached = state.withLock { s -> [Borrower] in
                let list = Array(s.borrowers.values)
                s.borrowers.removeAll(keepingCapacity: false)
                s.groupSetCache.removeAll(keepingCapacity: false)
                s.definitionsById.removeAll(keepingCapacity: false)
                return list
            }
            for borrower in detached {
                borrower.unbindFromDestroyedStyle()
            }
        }

        // parity: native/src/syntax-style.zig#SyntaxStyle.registerStyleDefinition [status=implemented hash=5ec5064865f6]
        @discardableResult
        public func registerStyleDefinition(name: String, definition: StyleDefinition) -> UInt32 {
            let id = core.registerStyle(name, definition.toCore())
            state.withLock { s in
                s.definitionsById[id] = definition
                s.groupSetCache.removeAll(keepingCapacity: true)
                for borrower in s.borrowers.values {
                    borrower.notifyStyleChanged()
                }
            }
            return id
        }

        /// Composes highlight group set `id` against this style, caching the result until the next registration.
        // parity: native/src/syntax-style.zig#SyntaxStyle.resolveGroupSet [status=implemented hash=8907d0af1382]
        public func resolveGroupSet(sets: NativeHighlightLayers.GroupSets, id: UInt32) -> StyleDefinition {
            precondition(id != 0 && id <= sets.count)
            if let cached = state.withLock({ $0.groupSetCache[id] }) {
                return cached
            }
            let composed = NativeHighlightLayers.compose(style: self, sets: sets, id: id)
            state.withLock { $0.groupSetCache[id] = composed }
            return composed
        }

        // parity: native/src/syntax-style.zig#SyntaxStyle.registerStyle [status=implemented hash=73c208c59ee3]
        @discardableResult
        public func registerStyle(name: String, fg: RGBA?, bg: RGBA?, attributes: UInt32) -> UInt32 {
            registerStyleDefinition(
                name: name,
                definition: StyleDefinition(fg: fg, bg: bg, attributes: attributes)
            )
        }

        // parity: native/src/syntax-style.zig#SyntaxStyle.resolveById [status=implemented hash=bb713f43d543]
        public func resolveById(_ id: UInt32) -> StyleDefinition? {
            if let cached = state.withLock({ $0.definitionsById[id] }) {
                return cached
            }
            return core.resolveById(id).map(StyleDefinition.init(from:))
        }

        // parity: native/src/syntax-style.zig#SyntaxStyle.resolveByName [status=implemented hash=ced86d817f41]
        public func resolveByName(_ name: String) -> UInt32? {
            core.resolveStyleId(name)
        }

        // parity: native/src/syntax-style.zig#SyntaxStyle.getStyleByName [status=implemented hash=2f188107c358]
        public func getStyleByName(_ name: String) -> StyleDefinition? {
            guard let id = resolveByName(name) else { return nil }
            return resolveById(id)
        }

        // parity: native/src/syntax-style.zig#SyntaxStyle.getStyleCount [status=implemented hash=9d681e21b34b]
        public func getStyleCount() -> Int {
            core.getStyleCount()
        }

        internal func attachBorrower(_ borrower: Borrower) {
            state.withLock { $0.borrowers[ObjectIdentifier(borrower)] = borrower }
        }

        internal func detachBorrower(_ borrower: Borrower) {
            _ = state.withLock { $0.borrowers.removeValue(forKey: ObjectIdentifier(borrower)) }
        }
    }
}

// MARK: - 2. native/src/rope.zig (66 symbols)

public enum NativeZigRope: Sendable {
    public enum SplitError: Error, Equatable, Hashable, Sendable {
        case outOfBounds
        case outOfMemory
    }

    // parity: native/src/rope.zig#Rope [status=adapted hash=6990c64f2482]
    public struct Rope<Element: Sendable>: Sendable {
        public static var maxImbalance: Int { 7 }

        public struct Config: Equatable, Hashable, Sendable {
            public var maxUndoDepth: Int?
            public init(maxUndoDepth: Int? = nil) { self.maxUndoDepth = maxUndoDepth }
        }

        public struct Metrics: Equatable, Hashable, Sendable {
            public var count: UInt32
            public var depth: UInt32
            public var weightValue: UInt32

            public init(count: UInt32 = 0, depth: UInt32 = 1, weight: UInt32 = 0) {
                self.count = count
                self.depth = depth
                self.weightValue = weight
            }

            // parity: native/src/rope.zig#Rope.Metrics.add [status=implemented hash=8101b8c83a85]
            public mutating func add(_ other: Metrics) {
                count &+= other.count
                depth = max(depth, other.depth)
                weightValue &+= other.weightValue
            }

            // parity: native/src/rope.zig#Rope.Metrics.weight [status=implemented hash=c6530269d88e]
            public func weight() -> UInt32 {
                weightValue
            }
        }

        public struct Position: Equatable, Hashable, Sendable {
            public var leafIndex: UInt32
            public var weight: UInt32

            public init(leafIndex: UInt32, weight: UInt32) {
                self.leafIndex = leafIndex
                self.weight = weight
            }
        }

        public struct WeightFindResult: Sendable {
            public var leaf: Element
            public var startWeight: UInt32
            public var leafIndex: UInt32

            public init(leaf: Element, startWeight: UInt32, leafIndex: UInt32) {
                self.leaf = leaf
                self.startWeight = startWeight
                self.leafIndex = leafIndex
            }
        }

        public struct KeyFindResult: Sendable {
            public var leaf: Element
            public var startKey: UInt32
            public var leafIndex: UInt32

            public init(leaf: Element, startKey: UInt32, leafIndex: UInt32) {
                self.leaf = leaf
                self.startKey = startKey
                self.leafIndex = leafIndex
            }
        }

        public struct JoinSpan: Equatable, Hashable, Sendable {
            public var start: UInt32
            public var end: UInt32

            public init(start: UInt32 = 0, end: UInt32 = 0) {
                self.start = start
                self.end = end
            }
        }

        public enum Side: Equatable, Hashable, Sendable {
            case left
            case right
        }

        public typealias SplitError = NativeZigRope.SplitError

        public final class Node: @unchecked Sendable {
            public enum Storage: Sendable {
                case leaf(data: Element, metrics: Metrics)
                case branch(left: Node, right: Node, totalMetrics: Metrics)
            }

            public struct WalkerResult: Sendable {
                public var keepWalking: Bool
                public var error: (any Error)?

                public init(keepWalking: Bool = true, error: (any Error)? = nil) {
                    self.keepWalking = keepWalking
                    self.error = error
                }
            }

            public struct LeafSplitResult: Sendable {
                public var left: Element
                public var right: Element

                public init(left: Element, right: Element) {
                    self.left = left
                    self.right = right
                }
            }

            public struct LeafSplitFn: Sendable {
                private let splitImpl: @Sendable (Element, UInt32) throws(SplitError) -> LeafSplitResult

                public init(_ split: @escaping @Sendable (Element, UInt32) throws(SplitError) -> LeafSplitResult) {
                    self.splitImpl = split
                }

                // parity: native/src/rope.zig#Rope.Node.LeafSplitFn.call [status=implemented hash=8900d9aafbfd]
                public func call(leaf: Element, weight: UInt32) throws(SplitError) -> LeafSplitResult {
                    try splitImpl(leaf, weight)
                }
            }

            public enum Bias: Equatable, Hashable, Sendable {
                case left
                case right
            }

            public let storage: Storage

            public init(_ storage: Storage) {
                self.storage = storage
            }

            // parity: native/src/rope.zig#Rope.Node.metrics [status=implemented hash=cc312888aa9e]
            public func metrics() -> Metrics {
                switch storage {
                case .branch(_, _, let total): total
                case .leaf(_, let m): m
                }
            }

            // parity: native/src/rope.zig#Rope.Node.depth [status=implemented hash=77207b7c22b8]
            public func depth() -> UInt32 {
                metrics().depth
            }

            // parity: native/src/rope.zig#Rope.Node.count [status=implemented hash=3bf8c7455c18]
            public func count() -> UInt32 {
                metrics().count
            }

            // parity: native/src/rope.zig#Rope.Node.is_balanced [status=implemented hash=3d09456a40e4]
            public func isBalanced() -> Bool {
                switch storage {
                case .leaf:
                    return true
                case .branch(let left, let right, _):
                    let ld = Int(left.depth())
                    let rd = Int(right.depth())
                    return abs(ld - rd) <= Rope.maxImbalance
                }
            }

            // parity: native/src/rope.zig#Rope.Node.is_empty [status=implemented hash=a2a422c0f636]
            public func isEmpty() -> Bool {
                count() == 0
            }

            // parity: native/src/rope.zig#Rope.Node.is_sentinel [status=implemented hash=0a1ec545c78e]
            public func isSentinel(emptyLeaf: Node) -> Bool {
                self === emptyLeaf
            }

            // parity: native/src/rope.zig#Rope.Node.init_branch [status=implemented hash=fc4f7a5c916f]
            public static func initBranch(left: Node, right: Node) -> Storage {
                var total = Metrics(count: 0, depth: 0, weight: 0)
                total.add(left.metrics())
                total.add(right.metrics())
                total.depth &+= 1
                return .branch(left: left, right: right, totalMetrics: total)
            }

            // parity: native/src/rope.zig#Rope.Node.new_branch [status=implemented hash=40b78785977d]
            public static func newBranch(left: Node, right: Node) -> Node {
                Node(initBranch(left: left, right: right))
            }

            // parity: native/src/rope.zig#Rope.Node.new_leaf [status=implemented hash=273fa959e1ad]
            public static func newLeaf(_ data: Element, weight: UInt32 = 1) -> Node {
                Node(.leaf(data: data, metrics: Metrics(count: 1, depth: 1, weight: weight)))
            }

            // parity: native/src/rope.zig#Rope.Node.get [status=implemented hash=7e86ac5f8d80]
            public func get(_ index: UInt32) -> Element? {
                switch storage {
                case .branch(let left, let right, _):
                    let leftCount = left.count()
                    if index < leftCount {
                        return left.get(index)
                    }
                    return right.get(index - leftCount)
                case .leaf(let data, let m):
                    return (m.count > 0 && index == 0) ? data : nil
                }
            }

            // parity: native/src/rope.zig#Rope.Node.walk [status=implemented hash=5e9a633eee0b]
            @discardableResult
            public func walk(
                currentIndex: inout UInt32,
                _ visit: (Element, UInt32) -> WalkerResult
            ) -> WalkerResult {
                switch storage {
                case .branch(let left, let right, _):
                    let leftRes = left.walk(currentIndex: &currentIndex, visit)
                    if !leftRes.keepWalking || leftRes.error != nil { return leftRes }
                    return right.walk(currentIndex: &currentIndex, visit)
                case .leaf(let data, let m):
                    guard m.count > 0 else { return WalkerResult() }
                    let idx = currentIndex
                    currentIndex &+= 1
                    return visit(data, idx)
                }
            }

            // parity: native/src/rope.zig#Rope.Node.walk_from [status=implemented hash=f43198493521]
            @discardableResult
            public func walkFrom(
                startIndex: UInt32,
                _ visit: (Element, UInt32) -> WalkerResult
            ) -> WalkerResult {
                var current: UInt32 = 0
                return walk(currentIndex: &current) { elem, idx in
                    if idx < startIndex { return WalkerResult(keepWalking: true) }
                    return visit(elem, idx)
                }
            }

            private func collectLeaves(into out: inout [Node]) {
                switch storage {
                case .branch(let left, let right, _):
                    left.collectLeaves(into: &out)
                    right.collectLeaves(into: &out)
                case .leaf(_, let m):
                    if m.count > 0 { out.append(self) }
                }
            }

            fileprivate static func mergeLeaves(_ leaves: ArraySlice<Node>) -> Node? {
                guard !leaves.isEmpty else { return nil }
                if leaves.count == 1 { return leaves[leaves.startIndex] }
                let mid = leaves.startIndex + leaves.count / 2
                guard let left = mergeLeaves(leaves[leaves.startIndex..<mid]),
                      let right = mergeLeaves(leaves[mid..<leaves.endIndex])
                else { return nil }
                return newBranch(left: left, right: right)
            }

            // parity: native/src/rope.zig#Rope.Node.rebalance [status=implemented hash=862479aea519]
            public func rebalance() -> Node {
                if isBalanced() { return self }
                var leaves: [Node] = []
                leaves.reserveCapacity(Int(count()))
                collectLeaves(into: &leaves)
                return Self.mergeLeaves(leaves[...]) ?? self
            }

            // parity: native/src/rope.zig#Rope.Node.split_at [status=implemented hash=ec47b96e5d65]
            public static func splitAt(
                _ node: Node,
                index: UInt32,
                emptyLeaf: Node
            ) -> (left: Node, right: Node) {
                if index == 0 { return (emptyLeaf, node) }
                if index >= node.count() { return (node, emptyLeaf) }
                switch node.storage {
                case .leaf:
                    return (node, emptyLeaf)
                case .branch(let left, let right, _):
                    let leftCount = left.count()
                    if index < leftCount {
                        let sub = splitAt(left, index: index, emptyLeaf: emptyLeaf)
                        return (sub.left, joinBalanced(left: sub.right, right: right))
                    } else if index > leftCount {
                        let sub = splitAt(right, index: index - leftCount, emptyLeaf: emptyLeaf)
                        return (joinBalanced(left: left, right: sub.left), sub.right)
                    } else {
                        return (left, right)
                    }
                }
            }

            // parity: native/src/rope.zig#Rope.Node.join_balanced [status=implemented hash=843e9477e018]
            public static func joinBalanced(left: Node, right: Node) -> Node {
                let leftCount = left.count()
                let rightCount = right.count()
                if leftCount == 0 { return right }
                if rightCount == 0 { return left }

                let maxSide = ((leftCount &+ rightCount) &* 3) / 4
                if leftCount <= maxSide && rightCount <= maxSide {
                    return newBranch(left: left, right: right)
                }
                if leftCount > rightCount &* 3 {
                    if case .branch(let ll, let lr, _) = left.storage {
                        let newRight = joinBalanced(left: lr, right: right)
                        if newRight.count() > ll.count() &* 3,
                           case .branch(let nrl, let nrr, _) = newRight.storage
                        {
                            let newLeft = joinBalanced(left: ll, right: nrl)
                            return newBranch(left: newLeft, right: nrr)
                        }
                        return newBranch(left: ll, right: newRight)
                    }
                    return newBranch(left: left, right: right)
                }
                if case .branch(let rl, let rr, _) = right.storage {
                    let newLeft = joinBalanced(left: left, right: rl)
                    if newLeft.count() > rr.count() &* 3,
                       case .branch(let nll, let nlr, _) = newLeft.storage
                    {
                        let newRight = joinBalanced(left: nlr, right: rr)
                        return newBranch(left: nll, right: newRight)
                    }
                    return newBranch(left: newLeft, right: rr)
                }
                return newBranch(left: left, right: right)
            }

            // parity: native/src/rope.zig#Rope.Node.split_at_weight [status=implemented hash=d4d9519af8a7]
            public static func splitAtWeight(
                _ node: Node,
                targetWeight: UInt32,
                bias: Bias?,
                emptyLeaf: Node,
                splitLeafFn: LeafSplitFn,
                weightOf: (Element) -> UInt32 = { _ in 1 },
                isVoid: ((Element) -> Bool)? = nil
            ) throws(SplitError) -> (left: Node, right: Node) {
                switch node.storage {
                case .leaf(let data, let m):
                    let leafWeight = m.weight()
                    // Under a left bias, a leaf whose split may leave an empty piece decides what lies at
                    // weight 0 (zero-width text), as inside it.
                    if targetWeight == 0 && (bias != .left || (leafWeight > 0 && isVoid == nil)) {
                        return (emptyLeaf, node)
                    } else if targetWeight >= leafWeight {
                        return (node, emptyLeaf)
                    }

                    let splitRes = try splitLeafFn.call(leaf: data, weight: targetWeight)
                    // An empty left piece, as when a wide grapheme straddles the weight or ASCII starts
                    // at weight 0, leaves no leaf that would sit between the leaves a join must see.
                    if let isVoid {
                        assert(!isVoid(splitRes.right))
                        if isVoid(splitRes.left) {
                            return (emptyLeaf, node)
                        }
                    }
                    let leftNode = Node.newLeaf(splitRes.left, weight: weightOf(splitRes.left))
                    let rightNode = Node.newLeaf(splitRes.right, weight: weightOf(splitRes.right))
                    return (leftNode, rightNode)
                case .branch(let left, let right, _):
                    let leftWeight = left.metrics().weight()
                    if targetWeight < leftWeight || (targetWeight == leftWeight && bias == .right) {
                        let sub = try splitAtWeight(
                            left,
                            targetWeight: targetWeight,
                            bias: bias,
                            emptyLeaf: emptyLeaf,
                            splitLeafFn: splitLeafFn,
                            weightOf: weightOf,
                            isVoid: isVoid
                        )
                        return (sub.left, joinBalanced(left: sub.right, right: right))
                    } else if targetWeight > leftWeight || bias == .left {
                        let sub = try splitAtWeight(
                            right,
                            targetWeight: targetWeight - leftWeight,
                            bias: bias,
                            emptyLeaf: emptyLeaf,
                            splitLeafFn: splitLeafFn,
                            weightOf: weightOf,
                            isVoid: isVoid
                        )
                        return (joinBalanced(left: left, right: sub.left), sub.right)
                    } else {
                        return (left, right)
                    }
                }
            }
        }

        public struct UndoSnapshot: Sendable {
            public let items: [Element]
            public let meta: [UInt8]
        }

        public let config: Config
        public let weightOf: @Sendable (Element) -> UInt32
        private var items: [Element]
        private var undoStack: [UndoSnapshot] = []
        private var redoStack: [UndoSnapshot] = []
        private var generation: UInt64 = 0

        // parity: native/src/rope.zig#Rope.init [status=implemented hash=0bad28d89959]
        public init() {
            self.config = Config()
            self.weightOf = { _ in 1 }
            self.items = []
        }

        // parity: native/src/rope.zig#Rope.initWithConfig [status=implemented hash=b3f8a0edcf07]
        public init(config: Config, weightOf: @escaping @Sendable (Element) -> UInt32 = { _ in 1 }) {
            self.config = config
            self.weightOf = weightOf
            self.items = []
        }

        public init(
            items: [Element],
            config: Config = Config(),
            weightOf: @escaping @Sendable (Element) -> UInt32 = { _ in 1 }
        ) {
            self.config = config
            self.weightOf = weightOf
            self.items = items
        }

        // parity: native/src/rope.zig#Rope.from_item [status=implemented hash=a8a56ff8a3e0]
        public static func fromItem(_ data: Element) -> Rope<Element> {
            fromItemWithConfig(data, config: Config())
        }

        // parity: native/src/rope.zig#Rope.from_itemWithConfig [status=implemented hash=506f104d5f20]
        public static func fromItemWithConfig(
            _ data: Element,
            config: Config,
            weightOf: @escaping @Sendable (Element) -> UInt32 = { _ in 1 }
        ) -> Rope<Element> {
            Rope(items: [data], config: config, weightOf: weightOf)
        }

        // parity: native/src/rope.zig#Rope.from_slice [status=implemented hash=afd061da6278]
        public static func fromSlice(_ items: [Element]) -> Rope<Element> {
            fromSliceWithConfig(items, config: Config())
        }

        // parity: native/src/rope.zig#Rope.from_sliceWithConfig [status=implemented hash=03d99e698c15]
        public static func fromSliceWithConfig(
            _ items: [Element],
            config: Config,
            weightOf: @escaping @Sendable (Element) -> UInt32 = { _ in 1 }
        ) -> Rope<Element> {
            Rope(items: items, config: config, weightOf: weightOf)
        }

        /// Builds a balanced `Node` tree reflecting the rope's current leaf sequence.
        public func buildTree() -> Node? {
            let leaves = items.map { Node.newLeaf($0, weight: weightOf($0)) }
            return Node.mergeLeaves(leaves[...])
        }

        // parity: native/src/rope.zig#Rope.count [status=implemented hash=24484ebd9d3a]
        public var count: UInt32 { UInt32(items.count) }
        public var isEmpty: Bool { items.isEmpty }

        // parity: native/src/rope.zig#Rope.metricsGeneration [status=implemented hash=4ad71a602404]
        public var metricsGeneration: UInt64 { generation }

        // parity: native/src/rope.zig#Rope.setMetricsGeneration [status=implemented hash=cbed7c3976c6]
        public mutating func setMetricsGeneration(_ generation: UInt64) {
            self.generation = generation
        }

        // parity: native/src/rope.zig#Rope.remeasure [status=implemented hash=3bdc630e0adb]
        public mutating func remeasure() {
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.get [status=implemented hash=9ae398aa712e]
        public func get(_ index: UInt32) -> Element? {
            let idx = Int(index)
            guard idx >= 0 && idx < items.count else { return nil }
            return items[idx]
        }

        // parity: native/src/rope.zig#Rope.walk [status=implemented hash=a3750560ba0f]
        public func walk(_ visit: (Element, UInt32) -> Node.WalkerResult) {
            for (idx, elem) in items.enumerated() {
                let res = visit(elem, UInt32(idx))
                if !res.keepWalking || res.error != nil { break }
            }
        }

        // parity: native/src/rope.zig#Rope.walk_from [status=implemented hash=5012eaefa1e1]
        public func walkFrom(startIndex: UInt32, _ visit: (Element, UInt32) -> Node.WalkerResult) {
            let start = Int(startIndex)
            guard start < items.count else { return }
            for idx in start..<items.count {
                let res = visit(items[idx], UInt32(idx))
                if !res.keepWalking || res.error != nil { break }
            }
        }

        // parity: native/src/rope.zig#Rope.rebalance [status=implemented hash=ca2c808d7809]
        public mutating func rebalance() {
            if let tree = buildTree() {
                _ = tree.rebalance()
            }
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.insert [status=implemented hash=40cb5fcae3c6]
        public mutating func insert(_ element: Element, at index: UInt32) {
            let clamped = min(max(0, Int(index)), items.count)
            items.insert(element, at: clamped)
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.append [status=implemented hash=8f7ab610ceaa]
        public mutating func append(_ element: Element) {
            items.append(element)
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.prepend [status=implemented hash=c8bef5f72d55]
        public mutating func prepend(_ element: Element) {
            items.insert(element, at: 0)
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.delete [status=implemented hash=37f057b9a312]
        public mutating func delete(at index: UInt32) {
            let idx = Int(index)
            guard idx >= 0 && idx < items.count else { return }
            items.remove(at: idx)
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.replace [status=implemented hash=268c7b285b0d]
        public mutating func replace(at index: UInt32, with element: Element) {
            let idx = Int(index)
            guard idx >= 0 && idx < items.count else { return }
            items[idx] = element
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.delete_range [status=implemented hash=807b7db91c05]
        public mutating func deleteRange(start: UInt32, end: UInt32) {
            let lo = min(max(0, Int(start)), items.count)
            let hi = min(max(lo, Int(end)), items.count)
            items.removeSubrange(lo..<hi)
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.insert_slice [status=implemented hash=19cbb242e7f5]
        public mutating func insertSlice(_ slice: [Element], at index: UInt32) {
            let clamped = min(max(0, Int(index)), items.count)
            items.insert(contentsOf: slice, at: clamped)
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.concat [status=implemented hash=af1e502b157a]
        public mutating func concat(_ other: Rope<Element>) {
            items.append(contentsOf: other.items)
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.split [status=implemented hash=3bac9afe3105]
        public mutating func split(at index: UInt32) -> Rope<Element> {
            let clamped = min(max(0, Int(index)), items.count)
            let rightItems = Array(items[clamped...])
            items.removeSubrange(clamped...)
            generation &+= 1
            return Rope<Element>(items: rightItems, config: config, weightOf: weightOf)
        }

        // parity: native/src/rope.zig#Rope.slice [status=implemented hash=46e6b49da4d2]
        public func slice(start: UInt32, end: UInt32) -> [Element] {
            let lo = min(max(0, Int(start)), items.count)
            let hi = min(max(lo, Int(end)), items.count)
            return Array(items[lo..<hi])
        }

        // parity: native/src/rope.zig#Rope.to_array [status=implemented hash=4242003a5381]
        public func toArray() -> [Element] { items }

        // parity: native/src/rope.zig#Rope.toText [status=adapted hash=ffb396248a9a]
        public func toText(render: (Element) -> String = { String(describing: $0) }) -> [UInt8] {
            var out: [UInt8] = []
            for item in items {
                out.append(contentsOf: render(item).utf8)
            }
            return out
        }

        // parity: native/src/rope.zig#Rope.totalWeight [status=implemented hash=8546001e6608]
        public func totalWeight() -> UInt32 {
            var total: UInt32 = 0
            for item in items {
                total &+= weightOf(item)
            }
            return total
        }

        // parity: native/src/rope.zig#Rope.splitByWeight [status=implemented hash=bac72ddec25d]
        public mutating func splitByWeight(
            _ weight: UInt32,
            bias: Node.Bias? = nil,
            splitLeafFn: Node.LeafSplitFn,
            isVoid: ((Element) -> Bool)? = nil
        ) throws(SplitError) -> Rope<Element> {
            guard let first = items.first, let tree = buildTree() else {
                return Rope<Element>(items: [], config: config, weightOf: weightOf)
            }
            let emptyLeaf = Node(.leaf(data: first, metrics: Metrics(count: 0, depth: 1, weight: 0)))
            let parts = try Node.splitAtWeight(
                tree,
                targetWeight: weight,
                bias: bias,
                emptyLeaf: emptyLeaf,
                splitLeafFn: splitLeafFn,
                weightOf: weightOf,
                isVoid: isVoid
            )
            var leftItems: [Element] = []
            var rightItems: [Element] = []
            var idx: UInt32 = 0
            parts.left.walk(currentIndex: &idx) { elem, _ in
                leftItems.append(elem)
                return Node.WalkerResult(keepWalking: true)
            }
            idx = 0
            parts.right.walk(currentIndex: &idx) { elem, _ in
                rightItems.append(elem)
                return Node.WalkerResult(keepWalking: true)
            }
            items = leftItems
            generation &+= 1
            return Rope<Element>(items: rightItems, config: config, weightOf: weightOf)
        }

        // parity: native/src/rope.zig#Rope.replaceRangeByWeight [status=implemented hash=922c62c83f71]
        @discardableResult
        public mutating func replaceRangeByWeight(
            start: UInt32,
            end: UInt32,
            startBias: Node.Bias = .left,
            endBias: Node.Bias = .right,
            replacement: [Element],
            splitLeafFn: Node.LeafSplitFn,
            isVoid: ((Element) -> Bool)? = nil
        ) throws(SplitError) -> JoinSpan {
            let lo = min(start, end)
            let hi = max(start, end)
            var afterStart = try splitByWeight(lo, bias: startBias, splitLeafFn: splitLeafFn, isVoid: isVoid)
            let tail = try afterStart.splitByWeight(hi - lo, bias: endBias, splitLeafFn: splitLeafFn, isVoid: isVoid)
            let joinStart = totalWeight()
            items.append(contentsOf: replacement)
            let joinEnd = totalWeight()
            items.append(contentsOf: tail.toArray())
            generation &+= 1
            return JoinSpan(start: joinStart, end: joinEnd)
        }

        // parity: native/src/rope.zig#Rope.insertSliceByWeight [status=implemented hash=6082082fb9a1]
        @discardableResult
        public mutating func insertSliceByWeight(
            weight: UInt32,
            bias: Node.Bias = .right,
            elements: [Element],
            splitLeafFn: Node.LeafSplitFn,
            isVoid: ((Element) -> Bool)? = nil
        ) throws(SplitError) -> JoinSpan {
            if elements.isEmpty {
                return JoinSpan(start: weight, end: weight)
            }
            let tail = try splitByWeight(weight, bias: bias, splitLeafFn: splitLeafFn, isVoid: isVoid)
            let joinStart = totalWeight()
            items.append(contentsOf: elements)
            let joinEnd = totalWeight()
            items.append(contentsOf: tail.toArray())
            generation &+= 1
            return JoinSpan(start: joinStart, end: joinEnd)
        }

        // parity: native/src/rope.zig#Rope.findByWeight [status=implemented hash=08a808fd04a7]
        public func findByWeight(_ target: UInt32) -> WeightFindResult? {
            var acc: UInt32 = 0
            for (idx, item) in items.enumerated() {
                let w = weightOf(item)
                if target < acc &+ w || (w == 0 && target == acc) {
                    return WeightFindResult(leaf: item, startWeight: acc, leafIndex: UInt32(idx))
                }
                acc &+= w
            }
            return nil
        }

        // parity: native/src/rope.zig#Rope.seekCount [status=implemented hash=bd7f9932e41b]
        public func seekCount(counted: (Element) -> UInt32, target n: UInt32) -> Position? {
            var countAcc: UInt32 = 0
            var weightAcc: UInt32 = 0
            for (idx, item) in items.enumerated() {
                let c = counted(item)
                if n < countAcc &+ c {
                    return Position(leafIndex: UInt32(idx), weight: weightAcc)
                }
                countAcc &+= c
                weightAcc &+= weightOf(item)
            }
            return nil
        }

        // parity: native/src/rope.zig#Rope.seekCountSum [status=implemented hash=a2f603fd0950]
        public func seekCountSum(
            counted: (Element) -> UInt32,
            summed: (Element) -> UInt32,
            target n: UInt32
        ) -> (leafIndex: UInt32, sum: UInt32)? {
            var countAcc: UInt32 = 0
            var sumAcc: UInt32 = 0
            for (idx, item) in items.enumerated() {
                let c = counted(item)
                if n < countAcc &+ c {
                    return (UInt32(idx), sumAcc)
                }
                countAcc &+= c
                sumAcc &+= summed(item)
            }
            return nil
        }

        // parity: native/src/rope.zig#Rope.seekKey [status=implemented hash=f94df45abf18]
        public func seekKey(key: (Element) -> UInt32, target: UInt32) -> KeyFindResult? {
            var acc: UInt32 = 0
            for (idx, item) in items.enumerated() {
                let k = key(item)
                if target < acc &+ k {
                    return KeyFindResult(leaf: item, startKey: acc, leafIndex: UInt32(idx))
                }
                acc &+= k
            }
            return nil
        }

        // parity: native/src/rope.zig#Rope.countThrough [status=implemented hash=96d48acfee8d]
        public func countThrough(
            key: (Element) -> UInt32,
            counted: (Element) -> UInt32,
            target: UInt32
        ) -> UInt32 {
            var keyAcc: UInt32 = 0
            var countAcc: UInt32 = 0
            for item in items {
                let k = key(item)
                if keyAcc &+ k > target { break }
                keyAcc &+= k
                countAcc &+= counted(item)
            }
            return countAcc
        }

        // parity: native/src/rope.zig#Rope.sharedLeaves [status=implemented hash=4c91240d7249]
        public func sharedLeaves(with other: Node, side: Side, limit: UInt32) -> UInt32? where Element: Equatable {
            var otherItems: [Element] = []
            var idx: UInt32 = 0
            other.walk(currentIndex: &idx) { elem, _ in
                otherItems.append(elem)
                return Node.WalkerResult(keepWalking: true)
            }
            let maxCheck = min(Int(limit), min(items.count, otherItems.count))
            var matched: UInt32 = 0
            switch side {
            case .left:
                for i in 0..<maxCheck {
                    if items[i] != otherItems[i] { break }
                    matched += 1
                }
            case .right:
                for i in 0..<maxCheck {
                    if items[items.count - 1 - i] != otherItems[otherItems.count - 1 - i] { break }
                    matched += 1
                }
            }
            return matched
        }

        // parity: native/src/rope.zig#Rope.store_undo [status=implemented hash=2b23c2bf62ef]
        public mutating func storeUndo(meta: [UInt8] = []) {
            undoStack.append(UndoSnapshot(items: items, meta: meta))
            if let limit = config.maxUndoDepth, limit > 0, undoStack.count > limit {
                undoStack.removeFirst(undoStack.count - limit)
            }
            redoStack.removeAll()
        }

        // parity: native/src/rope.zig#Rope.undo [status=implemented hash=2c8be2f2fc1f]
        public mutating func undo(currentMeta: [UInt8] = []) -> [UInt8]? {
            guard let prev = undoStack.popLast() else { return nil }
            redoStack.append(UndoSnapshot(items: items, meta: currentMeta))
            items = prev.items
            generation &+= 1
            return prev.meta
        }

        // parity: native/src/rope.zig#Rope.redo [status=implemented hash=2cd9c50bcd6b]
        public mutating func redo() -> [UInt8]? {
            guard let next = redoStack.popLast() else { return nil }
            undoStack.append(UndoSnapshot(items: items, meta: next.meta))
            items = next.items
            generation &+= 1
            return next.meta
        }

        // parity: native/src/rope.zig#Rope.can_undo [status=implemented hash=300e6f209f4f]
        public var canUndo: Bool { !undoStack.isEmpty }
        // parity: native/src/rope.zig#Rope.can_redo [status=implemented hash=bf7406f36b37]
        public var canRedo: Bool { !redoStack.isEmpty }
        // parity: native/src/rope.zig#Rope.hasHistory [status=implemented hash=1a09e5864cff]
        public var hasHistory: Bool { canUndo || canRedo }

        // parity: native/src/rope.zig#Rope.clear_history [status=implemented hash=dbefec210717]
        public mutating func clearHistory() {
            undoStack.removeAll()
            redoStack.removeAll()
        }

        // parity: native/src/rope.zig#Rope.clear [status=implemented hash=0e577d4cabf0]
        public mutating func clear() {
            items.removeAll()
            generation &+= 1
        }

        // parity: native/src/rope.zig#Rope.clearWithUndo [status=implemented hash=e464c75ee283]
        public mutating func clearWithUndo(meta: [UInt8]? = nil) {
            storeUndo(meta: meta ?? [])
            clear()
        }

        // parity: native/src/rope.zig#Rope.setSegments [status=implemented hash=0df1072587e2]
        public mutating func setSegments(_ newItems: [Element]) {
            items = newItems
            generation &+= 1
        }
    }

    /// Bridges directly to the core UTF-8/UTF-16 string `OpenTUICore.Rope`.
    public static func makeStringRope(_ text: String = "") -> OpenTUICore.Rope {
        OpenTUICore.Rope(text)
    }
}

// MARK: - 3. native/src/text-buffer.zig (19 unmapped symbols)

public enum NativeZigTextBuffer: Sendable {
    // parity: native/src/text-buffer.zig#TextChunk [status=implemented hash=c444b44a0083]
    public typealias TextChunk = OpenTUICore.TextChunk

    // parity: native/src/text-buffer.zig#MemRegistry [status=implemented hash=93ad34159a97]
    public final class MemRegistry: @unchecked Sendable {
        private var buffers: [UInt8: [UInt8]] = [:]
        private var nextId: UInt8 = 1

        public init() {}

        @discardableResult
        public func register(_ data: [UInt8], owned: Bool = true) -> UInt8 {
            _ = owned
            let id = nextId
            nextId = nextId == UInt8.max ? 1 : nextId &+ 1
            buffers[id] = data
            return id
        }

        public func replace(id: UInt8, data: [UInt8], owned: Bool = true) {
            _ = owned
            buffers[id] = data
        }

        public func get(_ id: UInt8) -> [UInt8]? {
            buffers[id]
        }

        public func clear() {
            buffers.removeAll()
            nextId = 1
        }

        public var count: Int { buffers.count }
    }

    // parity: native/src/text-buffer.zig#RGBA [status=implemented hash=239ff532e761]
    public typealias RGBA = OpenTUICore.RGBA

    // parity: native/src/text-buffer.zig#TextSelection [status=implemented hash=96f47201893e]
    public typealias TextSelection = OpenTUICore.TextSelection

    // parity: native/src/text-buffer.zig#TextBufferError [status=implemented hash=f09bedff43f5]
    public enum TextBufferError: Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case invalidMemId
        case invalidRange
        case textLimit
        case objectLimit
    }

    // parity: native/src/text-buffer.zig#Highlight [status=implemented hash=9bdbf140ff9b]
    public typealias Highlight = OpenTUICore.Highlight

    // parity: native/src/text-buffer.zig#StyleSpan [status=implemented hash=bae3a27577d7]
    public struct StyleSpan: Equatable, Hashable, Sendable {
        public var startCol: UInt32
        public var endCol: UInt32
        public var styleId: UInt32

        public init(startCol: UInt32, endCol: UInt32, styleId: UInt32) {
            self.startCol = startCol
            self.endCol = endCol
            self.styleId = styleId
        }
    }

    // parity: native/src/text-buffer.zig#WrapMode [status=implemented hash=a19ad2be691e]
    public typealias WrapMode = OpenTUICore.TextWrapMode

    // parity: native/src/text-buffer.zig#RenderClusterInfo [status=implemented hash=ee994972e6a8]
    public struct RenderClusterInfo: Equatable, Hashable, Sendable {
        public var byteOffset: UInt32
        public var byteLength: UInt32
        public var widthCols: UInt8

        public init(byteOffset: UInt32, byteLength: UInt32, widthCols: UInt8) {
            self.byteOffset = byteOffset
            self.byteLength = byteLength
            self.widthCols = widthCols
        }
    }

    // parity: native/src/text-buffer.zig#SyntaxStyle [status=implemented hash=fb2fef6d4e63]
    public typealias SyntaxStyle = NativeZigSyntaxStyle.SyntaxStyle

    // parity: native/src/text-buffer.zig#StyleDefinition [status=implemented hash=d5e2f336959a]
    public typealias StyleDefinition = NativeZigSyntaxStyle.StyleDefinition

    // parity: native/src/text-buffer.zig#no_style [status=implemented hash=5ef3d2fdf42a]
    public static let noStyle = StyleDefinition(fg: nil, bg: nil, attributes: 0, suppliedAttributes: 0)

    // parity: native/src/text-buffer.zig#run_style_flag [status=implemented hash=0ee2079cce34]
    public static let runStyleFlag: UInt32 = NativeZigSyntaxStyle.idLimit

    // parity: native/src/text-buffer.zig#RunStyles [status=implemented hash=f9b2c1e3edd3]
    public struct RunStyles: Equatable, Sendable {
        public private(set) var styles: [StyleDefinition] = []
        private var indexByStyle: [StyleDefinition: UInt32] = [:]

        public init() {}

        public mutating func intern(_ style: StyleDefinition) -> UInt32 {
            if let existing = indexByStyle[style] {
                return existing
            }
            let idx = UInt32(styles.count)
            styles.append(style)
            indexByStyle[style] = idx
            return idx
        }

        public func resolve(_ index: UInt32) -> StyleDefinition? {
            let i = Int(index)
            guard i >= 0 && i < styles.count else { return nil }
            return styles[i]
        }

        public mutating func clear() {
            styles.removeAll()
            indexByStyle.removeAll()
        }
    }

    // parity: native/src/text-buffer.zig#OwnedStyledChunk [status=implemented hash=5babe7cd8825]
    public struct OwnedStyledChunk: Equatable, Hashable, Sendable {
        public var byteCount: UInt32
        public var style: StyleDefinition

        public init(byteCount: UInt32, style: StyleDefinition = StyleDefinition()) {
            self.byteCount = byteCount
            self.style = style
        }
    }

    // parity: native/src/text-buffer.zig#LayerRun [status=implemented hash=afca73b5c46c]
    public struct LayerRun: Equatable, Hashable, Sendable {
        public var startByte: UInt32
        public var endByte: UInt32
        public var groupSetId: UInt32
        public var priority: UInt8

        public init(startByte: UInt32, endByte: UInt32, groupSetId: UInt32, priority: UInt8 = 0) {
            self.startByte = startByte
            self.endByte = endByte
            self.groupSetId = groupSetId
            self.priority = priority
        }
    }

    // parity: native/src/text-buffer.zig#LineSpans [status=implemented hash=9c21f2798572]
    public struct LineSpans: Equatable, Hashable, Sendable {
        public var spans: [StyleSpan]
        public var generation: UInt64
        public var styleChanges: UInt32?

        public init(spans: [StyleSpan] = [], generation: UInt64 = 0, styleChanges: UInt32? = nil) {
            self.spans = spans
            self.generation = generation
            self.styleChanges = styleChanges
        }
    }

    // parity: native/src/text-buffer.zig#LineMark [status=implemented hash=12889566c475]
    public struct LineMark: Equatable, Hashable, Sendable {
        public var mark: NativeEditMark
        public var colStart: UInt32
        public var colEnd: UInt32

        public init(mark: NativeEditMark, colStart: UInt32, colEnd: UInt32) {
            self.mark = mark
            self.colStart = colStart
            self.colEnd = colEnd
        }
    }

    // parity: native/src/text-buffer.zig#UnifiedTextBuffer [status=implemented hash=1ca10fe52d65]
    public final class UnifiedTextBuffer: @unchecked Sendable {
        public struct Defaults: Equatable, Hashable, Sendable {
            public var fg: RGBA?
            public var bg: RGBA?
            public var attributes: UInt32?

            public init(fg: RGBA? = nil, bg: RGBA? = nil, attributes: UInt32? = nil) {
                self.fg = fg
                self.bg = bg
                self.attributes = attributes
            }
        }

        public struct InitOptions: Equatable, Hashable, Sendable {
            public var widthMethod: TextWidthMethod
            public var tabWidth: UInt8
            public var controlDisplay: ControlDisplay

            public init(
                widthMethod: TextWidthMethod = .unicode,
                tabWidth: UInt8 = 2,
                controlDisplay: ControlDisplay = .hidden
            ) {
                self.widthMethod = widthMethod
                self.tabWidth = tabWidth
                self.controlDisplay = controlDisplay
            }
        }

        public struct PreparedOwnedStyledText: @unchecked Sendable {
            public let target: UnifiedTextBuffer
            public private(set) var textBytes: [UInt8]?
            public private(set) var chunks: [OwnedStyledChunk]
            public private(set) var preferredMemId: UInt8?

            public init(
                target: UnifiedTextBuffer,
                textBytes: [UInt8],
                chunks: [OwnedStyledChunk],
                preferredMemId: UInt8? = nil
            ) {
                self.target = target
                self.textBytes = textBytes
                self.chunks = chunks
                self.preferredMemId = preferredMemId
            }

            // parity: native/src/text-buffer.zig#UnifiedTextBuffer.PreparedOwnedStyledText.deinit [status=implemented hash=aba9dcbfea0b]
            public mutating func deinitPrepared() {
                textBytes = nil
                chunks.removeAll(keepingCapacity: false)
                preferredMemId = nil
            }

            // parity: native/src/text-buffer.zig#UnifiedTextBuffer.PreparedOwnedStyledText.commit [status=implemented hash=b259b2dae518]
            @discardableResult
            public mutating func commit() -> UInt8 {
                guard let bytes = textBytes else { return preferredMemId ?? 0 }
                textBytes = nil
                let memId: UInt8
                if let preferred = preferredMemId {
                    target.memRegistry.replace(id: preferred, data: bytes, owned: true)
                    memId = preferred
                } else {
                    memId = target.memRegistry.register(bytes, owned: true)
                }
                target.core.setText(String(decoding: bytes, as: UTF8.self))
                target.runStyles.clear()
                var offset: UInt32 = 0
                for chunk in chunks {
                    let styleIdx = target.runStyles.intern(chunk.style)
                    let end = offset &+ chunk.byteCount
                    if chunk.byteCount > 0 {
                        target.core.addHighlightByCharRange(
                            Highlight(
                                start: Int(offset),
                                end: Int(end),
                                styleId: NativeZigTextBuffer.runStyleFlag | styleIdx
                            )
                        )
                    }
                    offset = end
                }
                chunks.removeAll(keepingCapacity: false)
                target.markViewsDirty()
                return memId
            }
        }

        public let core: OpenTUICore.TextBuffer
        public let memRegistry: MemRegistry
        public private(set) var syntaxStyle: SyntaxStyle?
        public private(set) var contentEpoch: UInt64 = 0
        public private(set) var runStyles: RunStyles = RunStyles()
        public var controlDisplayMode: ControlDisplay = .hidden
        public var storageRetired: Bool = false
        private var dirtyViews: [UInt32: Bool] = [:]
        private var nextViewId: UInt32 = 1
        private var layersById: [UInt32: [LayerRun]] = [:]
        private var editMarks: [NativeEditMarks.Mark] = []
        private var undoSnapshots: [(text: String, meta: [UInt8])] = []
        private var redoSnapshots: [(text: String, meta: [UInt8])] = []
        private var layoutCache = NativeTextSegment.ChunkLayoutCache()
        private var segmentMemRegistry = NativeMemRegistry()

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.init [status=implemented hash=f3b093b8aa0d]
        public convenience init(widthMethod: TextWidthMethod = .unicode) {
            self.init(options: InitOptions(widthMethod: widthMethod))
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.initWithOptions [status=implemented hash=254c7fe5d73e]
        public init(options: InitOptions) {
            self.core = OpenTUICore.TextBuffer(
                widthMethod: options.widthMethod,
                tabWidth: Int(Self.effectiveTabWidth(options.tabWidth))
            )
            self.memRegistry = MemRegistry()
            self.controlDisplayMode = options.controlDisplay
        }

        public init(wrapping core: OpenTUICore.TextBuffer) {
            self.core = core
            self.memRegistry = MemRegistry()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.deinit [status=implemented hash=bdeb3d91e35c]
        deinit {
            retireStorage()
        }

        private static func toWidthMethod(_ m: TextWidthMethod) -> WidthMethod {
            switch m {
            case .wcwidth: return .wcwidth
            case .unicode: return .unicode
            case .unicodeWide: return .unicodeWide
            }
        }

        private static func fromWidthMethod(_ m: WidthMethod) -> TextWidthMethod {
            switch m {
            case .wcwidth: return .wcwidth
            case .unicode, .noZWJ: return .unicode
            case .unicodeWide: return .unicodeWide
            }
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.defaults [status=implemented hash=2e7e3d7ec07f]
        public func defaults() -> Defaults {
            Defaults(fg: core.defaultFg, bg: core.defaultBg, attributes: core.defaultAttributes)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.memRegistry [status=implemented hash=77b8a9c05848]
        public func getMemRegistry() -> MemRegistry {
            memRegistry
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.widthMethod [status=implemented hash=99111495747b]
        public func widthMethod() -> WidthMethod {
            Self.toWidthMethod(core.widthMethod)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.tabWidth [status=implemented hash=5e3e6988b2e2]
        public func tabWidth() -> UInt8 {
            UInt8(clamping: core.getTabWidth())
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.controlDisplay [status=implemented hash=c2004b09fbf8]
        public func controlDisplay() -> ControlDisplay {
            controlDisplayMode
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getAllocator [status=adapted hash=55dbe696ae2f]
        public func getAllocator() -> Int {
            retainedStorageBytes()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.rope [status=implemented hash=9c76297c4c7d]
        public func rope() -> OpenTUICore.Rope {
            core.rope
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.undo [status=implemented hash=3246311de135]
        public func undo(currentMeta: [UInt8] = []) -> [UInt8]? {
            guard let prev = undoSnapshots.popLast() else { return nil }
            redoSnapshots.append((core.getPlainText(), currentMeta))
            core.setText(prev.text)
            markViewsDirty()
            return prev.meta
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.redo [status=implemented hash=73a4325bf48a]
        public func redo() -> [UInt8]? {
            guard let next = redoSnapshots.popLast() else { return nil }
            undoSnapshots.append((core.getPlainText(), next.meta))
            core.setText(next.text)
            markViewsDirty()
            return next.meta
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.lineWidthAt [status=implemented hash=3cf980c167fe]
        public func lineWidthAt(row: UInt32) -> UInt32 {
            let line = core.getLine(Int(row))
            return calculateTextWidth(line, tabWidth: tabWidth(), controlDisplay: controlDisplayMode, widthMethod: widthMethod())
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.lineWidthColsMax [status=implemented hash=2500420b0cdc]
        public func lineWidthColsMax() -> UInt32 {
            let lines = core.getLineCount()
            var maxW: UInt32 = 0
            for r in 0..<lines {
                maxW = max(maxW, lineWidthAt(row: UInt32(r)))
            }
            return maxW
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getGraphemeWidthAt [status=implemented hash=7f2e9da2ff42]
        public func getGraphemeWidthAt(row: UInt32, col: UInt32) -> UInt32 {
            let line = core.getLine(Int(row))
            let spans = segmentGraphemeClusters(
                Array(line.utf8),
                tabWidth: tabWidth(),
                controlDisplay: controlDisplayMode,
                widthMethod: widthMethod()
            )
            var cur: UInt32 = 0
            for span in spans {
                if cur == col || (col > cur && col < cur &+ span.width) {
                    return span.width
                }
                cur &+= span.width
            }
            return 0
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getPrevGraphemeWidth [status=implemented hash=655fc1207cf9]
        public func getPrevGraphemeWidth(row: UInt32, col: UInt32) -> UInt32 {
            guard col > 0 else { return 0 }
            let line = core.getLine(Int(row))
            let spans = segmentGraphemeClusters(
                Array(line.utf8),
                tabWidth: tabWidth(),
                controlDisplay: controlDisplayMode,
                widthMethod: widthMethod()
            )
            var cur: UInt32 = 0
            var prevWidth: UInt32 = 0
            for span in spans {
                if cur >= col { break }
                prevWidth = span.width
                cur &+= span.width
            }
            return prevWidth
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.textEndOffset [status=implemented hash=9a6fe94b99e2]
        public func textEndOffset() -> UInt32 {
            UInt32(max(0, core.documentCellLength))
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.graphemeBoundsAtOffset [status=implemented hash=8eb32f6322fe]
        public func graphemeBoundsAtOffset(_ offset: UInt32) -> (start: UInt32, end: UInt32)? {
            let endTotal = textEndOffset()
            guard offset < endTotal else { return nil }
            guard let pos = core.offsetToPosition(Int(offset)) else { return nil }
            let lineStart = UInt32(max(0, core.getLineStartOffset(pos.row)))
            let line = core.getLine(pos.row)
            let spans = segmentGraphemeClusters(
                Array(line.utf8),
                tabWidth: tabWidth(),
                controlDisplay: controlDisplayMode,
                widthMethod: widthMethod()
            )
            var cur = lineStart
            for span in spans {
                let next = cur &+ max(1, span.width)
                if offset >= cur && offset < next {
                    return (cur, next)
                }
                cur = next
            }
            return (offset, min(endTotal, offset &+ 1))
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.cursorUnitBoundsAtOffset [status=implemented hash=e4b1f20ea2fb]
        public func cursorUnitBoundsAtOffset(_ offset: UInt32) -> (start: UInt32, end: UInt32)? {
            graphemeBoundsAtOffset(offset)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getLayoutInfoFor [status=implemented hash=a9cf0177f552]
        public func getLayoutInfoFor(_ chunk: inout NativeTextSegment.TextChunk) -> ChunkLayoutInfo {
            chunk.getLayoutInfo(
                cache: layoutCache,
                memRegistry: segmentMemRegistry,
                tabWidth: tabWidth(),
                controlDisplay: controlDisplayMode,
                widthMethod: widthMethod()
            )
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getWordLayoutInfoFor [status=implemented hash=3c1279ed7d8e]
        public func getWordLayoutInfoFor(_ chunk: inout NativeTextSegment.TextChunk) -> NativeTextSegment.WordLayoutInfo {
            chunk.getWordLayoutInfo(
                cache: layoutCache,
                memRegistry: segmentMemRegistry,
                tabWidth: tabWidth(),
                controlDisplay: controlDisplayMode,
                widthMethod: widthMethod()
            )
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.walkLinesAndSegments [status=implemented hash=edf911f3783e]
        public func walkLinesAndSegments(_ visit: (_ lineIndex: Int, _ lineText: String) -> Bool) {
            let total = core.getLineCount()
            for row in 0..<total {
                if !visit(row, core.getLine(row)) { break }
            }
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.retireStorage [status=implemented hash=2778dbcd5e84]
        public func retireStorage() {
            storageRetired = true
            layoutCache.clear()
            memRegistry.clear()
            segmentMemRegistry.clear()
            runStyles.clear()
            layersById.removeAll(keepingCapacity: false)
            editMarks.removeAll(keepingCapacity: false)
            undoSnapshots.removeAll(keepingCapacity: false)
            redoSnapshots.removeAll(keepingCapacity: false)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.reinitStorage [status=implemented hash=a9d39f878193]
        public func reinitStorage(widthMethod newMethod: WidthMethod) {
            retireStorage()
            storageRetired = false
            core.reset()
            core.setWidthMethod(Self.fromWidthMethod(newMethod))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.retainedStorageBytes [status=implemented hash=315e3467de67]
        public func retainedStorageBytes() -> Int {
            core.byteSize + editMarks.count * MemoryLayout<NativeEditMarks.Mark>.stride
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.arenaStorageBytes [status=adapted hash=05c007dfa3ec]
        public static func arenaStorageBytes(for buffer: UnifiedTextBuffer) -> Int {
            buffer.retainedStorageBytes()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.registerView [status=implemented hash=5c1f84295ccf]
        public func registerView() -> UInt32 {
            let id = nextViewId
            nextViewId &+= 1
            dirtyViews[id] = true
            return id
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.unregisterView [status=implemented hash=e583c88b570a]
        public func unregisterView(_ viewId: UInt32) {
            dirtyViews.removeValue(forKey: viewId)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.isViewDirty [status=implemented hash=8242be604106]
        public func isViewDirty(_ viewId: UInt32) -> Bool {
            dirtyViews[viewId] ?? false
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.clearViewDirty [status=implemented hash=466963fa108d]
        public func clearViewDirty(_ viewId: UInt32) {
            if dirtyViews[viewId] != nil {
                dirtyViews[viewId] = false
            }
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getContentEpoch [status=implemented hash=c2928de8a206]
        public func getContentEpoch() -> UInt64 {
            contentEpoch
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.markViewsDirty [status=implemented hash=eb0e6032dbf7]
        public func markViewsDirty() {
            contentEpoch &+= 1
            for key in dirtyViews.keys {
                dirtyViews[key] = true
            }
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getLength [status=implemented hash=db33205fd33f]
        public func getLength() -> UInt32 {
            UInt32(max(0, core.length))
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.measureText [status=implemented hash=aefc6f364d4e]
        public func measureText(_ text: [UInt8]) -> UInt32 {
            calculateTextWidth(text, tabWidth: tabWidth(), controlDisplay: controlDisplayMode, widthMethod: widthMethod())
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setDefaultFg [status=implemented hash=6a49e4d5b7a8]
        public func setDefaultFg(_ fg: RGBA?) {
            core.setDefaultFg(fg)
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setDefaultBg [status=implemented hash=bc736ee5d887]
        public func setDefaultBg(_ bg: RGBA?) {
            core.setDefaultBg(bg)
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setDefaultAttributes [status=implemented hash=62e04ada76b6]
        public func setDefaultAttributes(_ attributes: UInt32?) {
            core.setDefaultAttributes(attributes)
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.resetDefaults [status=implemented hash=f8eb42eef41f]
        public func resetDefaults() {
            core.resetDefaults()
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setSyntaxStyle [status=implemented hash=1a15da46b5f3]
        public func setSyntaxStyle(_ style: SyntaxStyle?) {
            syntaxStyle = style
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getSyntaxStyle [status=implemented hash=980642ca3f3e]
        public func getSyntaxStyle() -> SyntaxStyle? {
            syntaxStyle
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.resolveStyle [status=implemented hash=cb5bf0048ff0]
        public func resolveStyle(_ id: UInt32) -> StyleDefinition? {
            if (id & NativeZigTextBuffer.runStyleFlag) != 0 {
                return runStyles.resolve(id & ~NativeZigTextBuffer.runStyleFlag)
            }
            return syntaxStyle?.resolveById(id)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setText [status=implemented hash=2258ed33aa5f]
        public func setText(_ text: String) {
            core.setText(text)
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.append [status=implemented hash=fe5518019643]
        public func append(_ text: String) {
            core.append(text)
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.appendWithOwnership [status=implemented hash=7635006abf49]
        public func appendWithOwnership(_ text: [UInt8], owned: Bool) {
            _ = memRegistry.register(text, owned: owned)
            core.append(String(decoding: text, as: UTF8.self))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.appendCopy [status=implemented hash=d56ed3d2a46f]
        public func appendCopy(_ text: [UInt8]) {
            appendWithOwnership(text, owned: true)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.flattenMemRegistry [status=implemented hash=d44f8c266c0e]
        public func flattenMemRegistry() {
            let flat = Array(core.getPlainText().utf8)
            memRegistry.clear()
            if !flat.isEmpty {
                _ = memRegistry.register(flat, owned: true)
            }
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.appendFromMemId [status=implemented hash=864a0c36a0cd]
        public func appendFromMemId(_ memId: UInt8) throws(TextBufferError) {
            guard let bytes = memRegistry.get(memId) else { throw .invalidMemId }
            core.append(String(decoding: bytes, as: UTF8.self))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.replaceTail [status=implemented hash=684898f9ca9b]
        public func replaceTail(from byteOffset: UInt32, bytes: [UInt8]) throws(TextBufferError) {
            let current = Array(core.getPlainText().utf8)
            guard Int(byteOffset) <= current.count else { throw .invalidRange }
            var updated = Array(current[0..<Int(byteOffset)])
            updated.append(contentsOf: bytes)
            core.setText(String(decoding: updated, as: UTF8.self))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setTextFromMemId [status=implemented hash=7ce05ce62adb]
        public func setTextFromMemId(_ memId: UInt8) throws(TextBufferError) {
            guard let bytes = memRegistry.get(memId) else { throw .invalidMemId }
            core.setText(String(decoding: bytes, as: UTF8.self))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setTextFromMemIdWithUndo [status=implemented hash=c4cf41a4133f]
        public func setTextFromMemIdWithUndo(_ memId: UInt8, meta: [UInt8]? = nil) throws(TextBufferError) {
            guard let bytes = memRegistry.get(memId) else { throw .invalidMemId }
            undoSnapshots.append((core.getPlainText(), meta ?? []))
            redoSnapshots.removeAll()
            core.setText(String(decoding: bytes, as: UTF8.self))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setTextFromMemRangeWithUndo [status=implemented hash=0cd86b0ea200]
        public func setTextFromMemRangeWithUndo(
            _ memId: UInt8,
            byteStart: UInt32,
            byteEnd: UInt32,
            meta: [UInt8]? = nil
        ) throws(TextBufferError) {
            guard let bytes = memRegistry.get(memId) else { throw .invalidMemId }
            guard byteStart <= byteEnd && Int(byteEnd) <= bytes.count else { throw .invalidRange }
            undoSnapshots.append((core.getPlainText(), meta ?? []))
            redoSnapshots.removeAll()
            let slice = Array(bytes[Int(byteStart)..<Int(byteEnd)])
            core.setText(String(decoding: slice, as: UTF8.self))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.replaceText [status=implemented hash=14afff59745b]
        @discardableResult
        public func replaceText(_ text: [UInt8], memId: UInt8? = nil, owned: Bool = true) -> UInt8 {
            let assignedId: UInt8
            if let existing = memId {
                memRegistry.replace(id: existing, data: text, owned: owned)
                assignedId = existing
            } else {
                assignedId = memRegistry.register(text, owned: owned)
            }
            core.setText(String(decoding: text, as: UTF8.self))
            markViewsDirty()
            return assignedId
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.replaceOwnedText [status=implemented hash=01bdb6ebf558]
        @discardableResult
        public func replaceOwnedText(_ text: [UInt8], memId: UInt8? = nil) -> UInt8 {
            replaceText(text, memId: memId, owned: true)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.prepareOwnedStyledText [status=implemented hash=78c1660760bf]
        public func prepareOwnedStyledText(
            text: [UInt8],
            chunks: [OwnedStyledChunk],
            preferredMemId: UInt8? = nil
        ) -> PreparedOwnedStyledText {
            PreparedOwnedStyledText(target: self, textBytes: text, chunks: chunks, preferredMemId: preferredMemId)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.replaceOwnedStyledText [status=implemented hash=e04912d0bdfe]
        @discardableResult
        public func replaceOwnedStyledText(
            text: [UInt8],
            chunks: [OwnedStyledChunk],
            preferredMemId: UInt8? = nil
        ) -> UInt8 {
            var prepared = prepareOwnedStyledText(text: text, chunks: chunks, preferredMemId: preferredMemId)
            return prepared.commit()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.createChunk [status=implemented hash=6c382232e0a0]
        public func createChunk(memId: UInt8, byteStart: UInt32, byteEnd: UInt32, bytes: [UInt8]) -> NativeTextSegment.TextChunk {
            let start = min(Int(byteStart), bytes.count)
            let end = min(max(start, Int(byteEnd)), bytes.count)
            let slice = Array(bytes[start..<end])
            let width = calculateTextWidth(slice, tabWidth: tabWidth(), controlDisplay: controlDisplayMode, widthMethod: widthMethod())
            var flags: UInt8 = 0
            if isAsciiOnly(slice) { flags |= NativeTextSegment.TextChunk.Flags.asciiOnly }
            if slice.contains(0x09) { flags |= NativeTextSegment.TextChunk.Flags.hasTab }
            return NativeTextSegment.TextChunk(
                memId: memId,
                byteStart: byteStart,
                byteEnd: byteEnd,
                widthCols: width,
                flags: flags
            )
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.textToSegments [status=implemented hash=c50a459f69e2]
        public func textToSegments(_ bytes: [UInt8], memId: UInt8) -> [NativeTextSegment.Segment] {
            var segments: [NativeTextSegment.Segment] = []
            var lineStart = 0
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x0A {
                    if i > lineStart {
                        segments.append(.text(createChunk(memId: memId, byteStart: UInt32(lineStart), byteEnd: UInt32(i), bytes: bytes)))
                    }
                    segments.append(.brk)
                    lineStart = i + 1
                }
                i += 1
            }
            if lineStart < bytes.count {
                segments.append(.text(createChunk(memId: memId, byteStart: UInt32(lineStart), byteEnd: UInt32(bytes.count), bytes: bytes)))
            }
            return segments
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.registerMemBuffer [status=implemented hash=17b35c36b52f]
        public func registerMemBuffer(_ data: [UInt8], owned: Bool = true) -> UInt8 {
            memRegistry.register(data, owned: owned)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.replaceMemBuffer [status=implemented hash=2483c68422f0]
        public func replaceMemBuffer(_ memId: UInt8, data: [UInt8], owned: Bool = true) {
            memRegistry.replace(id: memId, data: data, owned: owned)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.clearMemRegistry [status=implemented hash=a05bf6a0fa2a]
        public func clearMemRegistry() {
            memRegistry.clear()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getMemBuffer [status=implemented hash=607f1e25573f]
        public func getMemBuffer(_ memId: UInt8) -> [UInt8]? {
            memRegistry.get(memId)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.addLine [status=implemented hash=77c38ff0a76b]
        public func addLine(_ text: String) {
            if core.byteSize > 0 {
                core.append("\n" + text)
            } else {
                core.append(text)
            }
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getArenaAllocatedBytes [status=implemented hash=c909d9348973]
        public func getArenaAllocatedBytes() -> Int {
            retainedStorageBytes()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getPlainTextIntoBuffer [status=implemented hash=c8e19aac11dc]
        public func getPlainTextIntoBuffer(_ outBuffer: inout [UInt8]) -> Int {
            let bytes = Array(core.getPlainText().utf8)
            let count = min(bytes.count, outBuffer.count)
            for i in 0..<count { outBuffer[i] = bytes[i] }
            return count
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.addHighlight [status=implemented hash=07ffe2a8217b]
        public func addHighlight(lineIdx: Int, highlight: Highlight) {
            core.addHighlight(lineIdx: lineIdx, highlight: highlight)
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getLineHighlights [status=implemented hash=cb5bac31fa19]
        public func getLineHighlights(lineIdx: Int) -> [Highlight] {
            core.getLineHighlights(lineIdx)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getLineSpans [status=implemented hash=98cca153e835]
        public func getLineSpans(lineIdx: Int) -> LineSpans {
            let highlights = core.getLineHighlights(lineIdx)
            let spans = highlights.map {
                StyleSpan(startCol: UInt32(max(0, $0.start)), endCol: UInt32(max(0, $0.end)), styleId: $0.styleId)
            }
            return LineSpans(spans: spans, generation: contentEpoch)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.resolveSpan [status=implemented hash=e6407d84b604]
        public func resolveSpan(_ span: StyleSpan) -> StyleDefinition? {
            resolveStyle(span.styleId)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.marks [status=implemented hash=0b2c4b402650]
        public func marks() -> [NativeEditMarks.Mark] {
            editMarks
        }

        internal func setMarks(_ newMarks: [NativeEditMarks.Mark]) {
            editMarks = newMarks
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.internMarkStyle [status=implemented hash=8b1e789dbcb6]
        public func internMarkStyle(_ style: StyleDefinition) throws(TextBufferError) -> UInt32 {
            let idx = runStyles.intern(style)
            guard idx < NativeZigTextBuffer.runStyleFlag else { throw .objectLimit }
            return NativeZigTextBuffer.runStyleFlag | idx
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.lineMarks [status=implemented hash=f35adabc1bfa]
        public func lineMarks(row: UInt32) -> [LineMark] {
            let startByte = lineStartByte(row: row)
            let lineLen = UInt32(core.getLine(Int(row)).utf8.count)
            let endByte = startByte &+ lineLen
            var result: [LineMark] = []
            for m in editMarks where m.endByte > startByte && m.startByte < endByte {
                let s = max(m.startByte, startByte) - startByte
                let e = min(m.endByte, endByte) - startByte
                let converted = NativeEditMark(
                    id: m.id,
                    kind: m.kind,
                    atomic: m.atomic,
                    style: m.style,
                    priority: m.priority,
                    start: Int(m.startByte),
                    end: Int(m.endByte)
                )
                result.append(LineMark(mark: converted, colStart: s, colEnd: e))
            }
            return result
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setLayer [status=implemented hash=48950ab4793e]
        public func setLayer(layerId: UInt32, startByte: UInt32, endByte: UInt32, runs: [LayerRun]) {
            var spare: [LayerRun]? = nil
            setLayerWithSpare(layerId: layerId, startByte: startByte, endByte: endByte, runs: runs, spare: &spare)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.reserveLayer [status=implemented hash=4242f456aa1b]
        public func reserveLayer(layerId: UInt32, runCount: Int) -> [LayerRun] {
            var spare: [LayerRun] = []
            spare.reserveCapacity(max(runCount, layersById[layerId]?.count ?? 0))
            return spare
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.freeLayerSpare [status=implemented hash=249ba07fc481]
        public func freeLayerSpare(_ spare: inout [LayerRun]) {
            spare.removeAll(keepingCapacity: false)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setLayerWithSpare [status=implemented hash=6ea17160e79b]
        public func setLayerWithSpare(
            layerId: UInt32,
            startByte: UInt32,
            endByte: UInt32,
            runs: [LayerRun],
            spare: inout [LayerRun]?
        ) {
            _ = (startByte, endByte)
            if var reusable = spare {
                reusable.removeAll(keepingCapacity: true)
                reusable.append(contentsOf: runs)
                layersById[layerId] = reusable
                spare = nil
            } else {
                layersById[layerId] = runs
            }
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.assertLayerBoundaries [status=implemented hash=9a9ff73e7389]
        public func assertLayerBoundaries() {
            let totalBytes = getByteSize()
            for runs in layersById.values {
                var prevEnd: UInt32 = 0
                for r in runs {
                    precondition(r.startByte >= prevEnd && r.startByte <= r.endByte && r.endByte <= totalBytes)
                    prevEnd = r.endByte
                }
            }
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.assertMarks [status=implemented hash=af6d028f8589]
        public func assertMarks() {
            let totalBytes = getByteSize()
            for m in editMarks {
                precondition(m.startByte <= m.endByte && m.endByte <= totalBytes)
            }
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.byteOffsetAtWeight [status=implemented hash=de6fb9133099]
        public func byteOffsetAtWeight(_ weight: UInt32) -> UInt32 {
            byteAtCell(weight: weight, wholeGrapheme: false)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.byteAtCell [status=implemented hash=1b42fa5f10ba]
        public func byteAtCell(weight: UInt32, wholeGrapheme: Bool) -> UInt32 {
            let bytes = Array(core.getPlainText().utf8)
            var curWeight: UInt32 = 0
            var bytePos = 0
            let tw = tabWidth()
            let wm = widthMethod()
            while bytePos < bytes.count {
                if bytes[bytePos] == 0x0A {
                    if curWeight == weight {
                        return UInt32(bytePos)
                    }
                    curWeight &+= 1
                    bytePos += 1
                    continue
                }
                let lineEnd = bytes[bytePos...].firstIndex(of: 0x0A) ?? bytes.count
                let lineSlice = Array(bytes[bytePos..<lineEnd])
                let asciiOnly = isAsciiOnly(lineSlice)
                let lineWeight = calculateTextWidth(
                    lineSlice,
                    tabWidth: tw,
                    controlDisplay: controlDisplayMode,
                    isASCIIOnly: asciiOnly,
                    widthMethod: wm
                )
                if weight < curWeight &+ lineWeight {
                    let targetCol = weight - curWeight
                    let split = wholeGrapheme
                        ? findGraphemePosByWidth(
                            lineSlice,
                            maxColumns: targetCol,
                            tabWidth: tw,
                            controlDisplay: controlDisplayMode,
                            isASCIIOnly: asciiOnly,
                            includeStartBefore: false,
                            widthMethod: wm
                        )
                        : findPosByWidth(
                            lineSlice,
                            maxColumns: targetCol,
                            tabWidth: tw,
                            controlDisplay: controlDisplayMode,
                            isASCIIOnly: asciiOnly,
                            includeStartBefore: false,
                            widthMethod: wm
                        )
                    return UInt32(bytePos) &+ split.byteOffset
                }
                curWeight &+= lineWeight
                bytePos = lineEnd
            }
            return UInt32(bytes.count)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.convertUtf16 [status=implemented hash=756ec870dd2b]
        public func convertUtf16(index: UInt32, toByte: Bool) -> UInt32 {
            let text = core.getPlainText()
            if toByte {
                var u16: UInt32 = 0
                var u8: UInt32 = 0
                for scalar in text.unicodeScalars {
                    if u16 >= index { break }
                    u16 &+= UInt32(scalar.utf16.count)
                    u8 &+= UInt32(scalar.utf8.count)
                }
                return u8
            } else {
                var u8: UInt32 = 0
                var u16: UInt32 = 0
                for scalar in text.unicodeScalars {
                    if u8 >= index { break }
                    u8 &+= UInt32(scalar.utf8.count)
                    u16 &+= UInt32(scalar.utf16.count)
                }
                return u16
            }
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.weightAtByte [status=implemented hash=659971fe587b]
        public func weightAtByte(_ byte: UInt32, roundDown: Bool = true) -> UInt32 {
            let bytes = Array(core.getPlainText().utf8)
            let clamped = min(Int(byte), bytes.count)
            var curWeight: UInt32 = 0
            var pos = 0
            let tw = tabWidth()
            let wm = widthMethod()
            while pos < clamped {
                if bytes[pos] == 0x0A {
                    curWeight &+= 1
                    pos += 1
                    continue
                }
                let lineEnd = bytes[pos...].firstIndex(of: 0x0A) ?? bytes.count
                let lineSlice = Array(bytes[pos..<lineEnd])
                let spans = segmentGraphemeClusters(lineSlice, tabWidth: tw, controlDisplay: controlDisplayMode, widthMethod: wm)
                for span in spans {
                    let absStart = pos + span.byteStart
                    let absEnd = pos + span.byteEnd
                    if absStart >= clamped { return curWeight }
                    if absEnd > clamped {
                        return roundDown ? curWeight : (curWeight &+ span.width)
                    }
                    curWeight &+= span.width
                }
                pos = lineEnd
            }
            return curWeight
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.byteAtOffset [status=implemented hash=897ce2fe09ef]
        public func byteAtOffset(_ offset: UInt32) -> UInt32 {
            byteOffsetAtWeight(offset)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.lineStartByte [status=implemented hash=789f8e20b895]
        public func lineStartByte(row: UInt32) -> UInt32 {
            let bytes = Array(core.getPlainText().utf8)
            var curRow: UInt32 = 0
            var i = 0
            while i < bytes.count && curRow < row {
                if bytes[i] == 0x0A { curRow += 1 }
                i += 1
            }
            return UInt32(i)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.addHighlightByCoords [status=implemented hash=8a860bf3f7d6]
        public func addHighlightByCoords(
            startRow: Int,
            startCol: Int,
            endRow: Int,
            endCol: Int,
            styleId: UInt32,
            priority: Int? = nil,
            hlRef: Int? = nil
        ) {
            let startOff = core.positionToOffset(row: startRow, col: startCol)
            let endOff = core.positionToOffset(row: endRow, col: endCol)
            addHighlightByCharRange(Highlight(start: startOff, end: endOff, styleId: styleId, priority: priority, hlRef: hlRef))
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.addHighlightByCharRange [status=implemented hash=66f78f8e65ff]
        public func addHighlightByCharRange(_ highlight: Highlight) {
            core.addHighlightByCharRange(highlight)
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.removeHighlightsByRef [status=implemented hash=08f51bf01b49]
        public func removeHighlightsByRef(_ hlRef: UInt16) {
            core.removeHighlightsByRef(Int(hlRef))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.removeHighlightsByRefChecked [status=implemented hash=21a9f6f2ef7d]
        public func removeHighlightsByRefChecked(_ hlRef: UInt16) throws(TextBufferError) {
            guard !storageRetired else { throw .invalidRange }
            removeHighlightsByRef(hlRef)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.clearLineHighlights [status=implemented hash=1eb0344021f3]
        public func clearLineHighlights(_ lineIdx: Int) {
            core.clearLineHighlights(lineIdx)
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.clearAllHighlights [status=implemented hash=3b7d5be75d61]
        public func clearAllHighlights() {
            core.clearAllHighlights()
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getLineHighlightsSlice [status=implemented hash=53f0ea029695]
        public func getLineHighlightsSlice(_ lineIdx: Int) -> [Highlight] {
            core.getLineHighlights(lineIdx)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getHighlightCount [status=implemented hash=9f5588006c1f]
        public func getHighlightCount() -> UInt32 {
            UInt32(max(0, core.getHighlightCount()))
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.loadFile [status=adapted hash=3cce169f0bc7]
        public func loadFile(contents: [UInt8]) throws(TextBufferError) {
            guard isValidUtf8(contents) else { throw .invalidRange }
            setText(String(decoding: contents, as: UTF8.self))
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getTabWidth [status=implemented hash=093abcae5736]
        public func getTabWidth() -> UInt8 {
            UInt8(clamping: core.getTabWidth())
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setTabWidth [status=implemented hash=97d7e4f22355]
        public func setTabWidth(_ width: UInt8) {
            core.setTabWidth(Int(Self.effectiveTabWidth(width)))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.setWidthMethod [status=implemented hash=89648def2182]
        public func setWidthMethod(_ method: WidthMethod) {
            core.setWidthMethod(Self.fromWidthMethod(method))
            markViewsDirty()
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.byteAtOffsetUnder [status=implemented hash=d6d83314a961]
        public func byteAtOffsetUnder(offset: UInt32, method: WidthMethod) -> UInt32 {
            let saved = core.widthMethod
            core.setWidthMethod(Self.fromWidthMethod(method))
            let result = byteAtOffset(offset)
            core.setWidthMethod(saved)
            return result
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.effectiveTabWidth [status=implemented hash=e105e030e8c0]
        public static func effectiveTabWidth(_ width: UInt8) -> UInt8 {
            width == 0 ? 2 : width
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.checkTabWidth [status=implemented hash=cc855508081b]
        public func checkTabWidth(_ width: UInt8) throws(TextBufferError) {
            let eff = UInt64(Self.effectiveTabWidth(width))
            let tabCount = UInt64(core.getPlainText().utf8.filter { $0 == 0x09 }.count)
            if UInt64(core.byteSize) &+ tabCount &* eff > UInt64(UInt32.max) {
                throw .textLimit
            }
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.debugLogRope [status=implemented hash=ae43b26e936e]
        @discardableResult
        public func debugLogRope() -> String {
            "UnifiedTextBuffer(lines=\(getLineCount()), bytes=\(getByteSize()), epoch=\(contentEpoch))"
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getTextRange [status=implemented hash=96beb9393e06]
        public func getTextRange(startOffset: UInt32, endOffset: UInt32, into outBuffer: inout [UInt8]) -> Int {
            let text = core.getTextRange(startOffset: Int(startOffset), endOffset: Int(endOffset))
            let bytes = Array(text.utf8)
            let count = min(bytes.count, outBuffer.count)
            for i in 0..<count { outBuffer[i] = bytes[i] }
            return count
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.copyTextRange [status=implemented hash=1d6e30a93ac0]
        public func copyTextRange(startOffset: UInt32, endOffset: UInt32, into out: inout [UInt8]) throws(TextBufferError) -> UInt32 {
            guard startOffset <= endOffset else { throw .invalidRange }
            let text = core.getTextRange(startOffset: Int(startOffset), endOffset: Int(endOffset))
            let bytes = Array(text.utf8)
            guard bytes.count <= out.count else { throw .outOfMemory }
            for i in 0..<bytes.count { out[i] = bytes[i] }
            return UInt32(bytes.count)
        }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getTextRangeByCoords [status=implemented hash=d69a4bebefe1]
        public func getTextRangeByCoords(
            startRow: UInt32,
            startCol: UInt32,
            endRow: UInt32,
            endCol: UInt32,
            into outBuffer: inout [UInt8]
        ) -> Int {
            let text = core.getTextRangeByCoords(
                startRow: Int(startRow),
                startCol: Int(startCol),
                endRow: Int(endRow),
                endCol: Int(endCol)
            )
            let bytes = Array(text.utf8)
            let count = min(bytes.count, outBuffer.count)
            for i in 0..<count { outBuffer[i] = bytes[i] }
            return count
        }

        public func layerRuns(for layerId: UInt32) -> [LayerRun] {
            layersById[layerId] ?? []
        }

        public func getPlainText() -> String { core.getPlainText() }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getLineCount [status=implemented hash=801ce22f92fc]
        public func getLineCount() -> UInt32 { UInt32(core.getLineCount()) }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.lineCount [status=implemented hash=00811f9199a5]
        public func lineCount() -> UInt32 { getLineCount() }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.getByteSize [status=implemented hash=afe0a9d04e62]
        public func getByteSize() -> UInt32 { UInt32(core.getPlainText().utf8.count) }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.clear [status=implemented hash=8784e3a89dae]
        public func clear() { core.clear(); editMarks.removeAll(keepingCapacity: true); markViewsDirty() }

        // parity: native/src/text-buffer.zig#UnifiedTextBuffer.reset [status=implemented hash=bd96cb1ba22b]
        public func reset() { core.reset(); memRegistry.clear(); runStyles.clear(); layersById.removeAll(); editMarks.removeAll(); markViewsDirty() }
    }

    // parity: native/src/text-buffer.zig#TextBuffer [status=implemented hash=2f3517ac7b34]
    public typealias TextBuffer = UnifiedTextBuffer
}

// MARK: - 4. native/src/text-buffer-view.zig (19 unmapped symbols)

public enum NativeZigTextBufferView: Sendable {
    // parity: native/src/text-buffer-view.zig#WrapMode [status=implemented hash=c511ddc349a1]
    public typealias WrapMode = OpenTUICore.TextWrapMode

    // parity: native/src/text-buffer-view.zig#TextBufferViewError [status=implemented hash=d0acdb8c32ae]
    public enum TextBufferViewError: Error, Equatable, Hashable, Sendable {
        case outOfMemory
    }

    // parity: native/src/text-buffer-view.zig#SelectionStyle [status=implemented hash=045a2d08f11d]
    public struct SelectionStyle: Equatable, Hashable, Sendable {
        public var bgColor: RGBA?
        public var fgColor: RGBA?

        public init(bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
            self.bgColor = bgColor
            self.fgColor = fgColor
        }

        // parity: native/src/text-buffer-view.zig#SelectionStyle.rgb [status=implemented hash=5a2c852fdb1b]
        public static func rgb(bgColor: RGBA?, fgColor: RGBA?) -> SelectionStyle {
            SelectionStyle(bgColor: bgColor, fgColor: fgColor)
        }
    }

    // parity: native/src/text-buffer-view.zig#SelectionOccupancy [status=implemented hash=232e730aa0ef]
    public enum SelectionOccupancy: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case cell = 0
        case boundary = 1

        public var coreValue: OpenTUICore.SelectionOccupancy {
            switch self {
            case .cell: return .cell
            case .boundary: return .boundary
            }
        }

        public init(core: OpenTUICore.SelectionOccupancy) {
            self = core == .cell ? .cell : .boundary
        }
    }

    // parity: native/src/text-buffer-view.zig#SelectionBehavior [status=implemented hash=6d5c8c73191f]
    public enum SelectionBehavior: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case cell = 0
        case word = 1
        case line = 2
    }

    // parity: native/src/text-buffer-view.zig#SelectionRange [status=implemented hash=34ad40686ecd]
    public struct SelectionRange: Equatable, Hashable, Sendable {
        public var start: UInt32
        public var end: UInt32

        public init(start: UInt32, end: UInt32) {
            self.start = start
            self.end = end
        }

        public init(core: TextSelectionRange) {
            self.start = UInt32(max(0, core.start))
            self.end = UInt32(max(0, core.end))
        }
    }

    // parity: native/src/text-buffer-view.zig#Viewport [status=implemented hash=16772aff5b10]
    public struct Viewport: Equatable, Hashable, Sendable {
        public var x: UInt32
        public var y: UInt32
        public var width: UInt32
        public var height: UInt32

        public init(x: UInt32 = 0, y: UInt32 = 0, width: UInt32 = 0, height: UInt32 = 0) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    // parity: native/src/text-buffer-view.zig#LineInfo [status=implemented hash=016fa3f8927f]
    public struct LineInfo: Equatable, Hashable, Sendable {
        public var lineStartCols: [UInt32]
        public var lineWidthCols: [UInt32]
        public var lineSources: [UInt32]
        public var lineWraps: [UInt32]
        public var lineWidthColsMax: UInt32

        public init(
            lineStartCols: [UInt32] = [],
            lineWidthCols: [UInt32] = [],
            lineSources: [UInt32] = [],
            lineWraps: [UInt32] = [],
            lineWidthColsMax: UInt32 = 0
        ) {
            self.lineStartCols = lineStartCols
            self.lineWidthCols = lineWidthCols
            self.lineSources = lineSources
            self.lineWraps = lineWraps
            self.lineWidthColsMax = lineWidthColsMax
        }

        public init(core: OpenTUICore.LineInfo) {
            self.lineStartCols = core.lineStartCols.map { UInt32(max(0, $0)) }
            self.lineWidthCols = core.lineWidthCols.map { UInt32(max(0, $0)) }
            self.lineSources = core.lineSources.map { UInt32(max(0, $0)) }
            self.lineWraps = core.lineWraps.map { UInt32(max(0, $0)) }
            self.lineWidthColsMax = UInt32(max(0, core.lineWidthColsMax))
        }
    }

    // parity: native/src/text-buffer-view.zig#WrapInfo [status=implemented hash=8fe5a15e7d73]
    public struct WrapInfo: Equatable, Hashable, Sendable {
        public var lineFirstVLine: [UInt32]
        public var lineVLineCounts: [UInt32]

        public init(lineFirstVLine: [UInt32] = [], lineVLineCounts: [UInt32] = []) {
            self.lineFirstVLine = lineFirstVLine
            self.lineVLineCounts = lineVLineCounts
        }
    }

    // parity: native/src/text-buffer-view.zig#VirtualChunk [status=implemented hash=d403a0841eaa]
    public struct VirtualChunk: Equatable, Hashable, Sendable {
        public var text: String
        public var byteStartInChunk: UInt32
        public var byteLen: UInt32
        public var colStartInChunk: UInt32
        public var widthCols: UInt32

        public init(
            text: String = "",
            byteStartInChunk: UInt32 = 0,
            byteLen: UInt32 = 0,
            colStartInChunk: UInt32 = 0,
            widthCols: UInt32 = 0
        ) {
            self.text = text
            self.byteStartInChunk = byteStartInChunk
            self.byteLen = byteLen
            self.colStartInChunk = colStartInChunk
            self.widthCols = widthCols
        }
    }

    // parity: native/src/text-buffer-view.zig#VirtualLine [status=implemented hash=50dbffc43662]
    public struct VirtualLine: Equatable, Hashable, Sendable {
        public var chunks: [VirtualChunk]
        public var widthCols: UInt32
        public var documentCellOffset: UInt32
        public var sourceLine: Int
        public var sourceColStart: UInt32
        public var isTruncated: Bool
        public var ellipsisCol: UInt32
        public var truncationSuffixColStart: UInt32

        // parity: native/src/text-buffer-view.zig#VirtualLine.init [status=implemented hash=260e1aae8bd1]
        public init(
            chunks: [VirtualChunk] = [],
            widthCols: UInt32 = 0,
            documentCellOffset: UInt32 = 0,
            sourceLine: Int = 0,
            sourceColStart: UInt32 = 0,
            isTruncated: Bool = false,
            ellipsisCol: UInt32 = 0,
            truncationSuffixColStart: UInt32 = 0
        ) {
            self.chunks = chunks
            self.widthCols = widthCols
            self.documentCellOffset = documentCellOffset
            self.sourceLine = sourceLine
            self.sourceColStart = sourceColStart
            self.isTruncated = isTruncated
            self.ellipsisCol = ellipsisCol
            self.truncationSuffixColStart = truncationSuffixColStart
        }
    }

    // parity: native/src/text-buffer-view.zig#VirtualLineOutput [status=implemented hash=3ad0ebcd3fe4]
    public struct VirtualLineOutput: Equatable, Sendable {
        public var virtualLines: [VirtualLine]
        public var cachedLineStarts: [UInt32]
        public var cachedLineWidths: [UInt32]
        public var cachedLineSources: [UInt32]
        public var cachedLineWrapIndices: [UInt32]
        public var cachedLineFirstVLine: [UInt32]
        public var cachedLineVLineCounts: [UInt32]

        public init(
            virtualLines: [VirtualLine] = [],
            cachedLineStarts: [UInt32] = [],
            cachedLineWidths: [UInt32] = [],
            cachedLineSources: [UInt32] = [],
            cachedLineWrapIndices: [UInt32] = [],
            cachedLineFirstVLine: [UInt32] = [],
            cachedLineVLineCounts: [UInt32] = []
        ) {
            self.virtualLines = virtualLines
            self.cachedLineStarts = cachedLineStarts
            self.cachedLineWidths = cachedLineWidths
            self.cachedLineSources = cachedLineSources
            self.cachedLineWrapIndices = cachedLineWrapIndices
            self.cachedLineFirstVLine = cachedLineFirstVLine
            self.cachedLineVLineCounts = cachedLineVLineCounts
        }
    }

    // parity: native/src/text-buffer-view.zig#MeasureResult [status=implemented hash=b7520eccb145]
    public struct MeasureResult: Equatable, Hashable, Sendable {
        public var lineCount: UInt32
        public var widthColsMax: UInt32

        public init(lineCount: UInt32, widthColsMax: UInt32) {
            self.lineCount = lineCount
            self.widthColsMax = widthColsMax
        }

        public init(core: OpenTUICore.MeasureResult) {
            self.lineCount = UInt32(max(0, core.lineCount))
            self.widthColsMax = UInt32(max(0, core.widthColsMax))
        }
    }

    // parity: native/src/text-buffer-view.zig#VirtualLineSpanInfo [status=implemented hash=2078f412b793]
    public struct VirtualLineSpanInfo: Equatable, Hashable, Sendable {
        public var spans: [NativeZigTextBuffer.StyleSpan]
        public var sourceLine: Int
        public var sourceColStart: UInt32

        public init(spans: [NativeZigTextBuffer.StyleSpan] = [], sourceLine: Int = 0, sourceColStart: UInt32 = 0) {
            self.spans = spans
            self.sourceLine = sourceLine
            self.sourceColStart = sourceColStart
        }
    }

    // parity: native/src/text-buffer-view.zig#LocalSelection [status=implemented hash=76d97cee58d4]
    public struct LocalSelection: Equatable, Hashable, Sendable {
        public var anchorX: Int32
        public var anchorY: Int32
        public var focusX: Int32
        public var focusY: Int32
        public var isActive: Bool

        public init(anchorX: Int32 = 0, anchorY: Int32 = 0, focusX: Int32 = 0, focusY: Int32 = 0, isActive: Bool = false) {
            self.anchorX = anchorX
            self.anchorY = anchorY
            self.focusX = focusX
            self.focusY = focusY
            self.isActive = isActive
        }
    }

    // parity: native/src/text-buffer-view.zig#TextAlign [status=implemented hash=a1de0673a730]
    public enum TextAlign: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case left = 0
        case center = 1
        case right = 2

        public var coreValue: OpenTUICore.TextAlign {
            switch self {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
    }

    // parity: native/src/text-buffer-view.zig#alignmentPadCols [status=implemented hash=144917dde310]
    public static func alignmentPadCols(
        alignment: TextAlign,
        viewportWidth: UInt32,
        lineWidthCols: UInt32
    ) -> UInt32 {
        UInt32(
            max(
                0,
                OpenTUICore.alignmentPadCols(
                    alignment: alignment.coreValue,
                    viewportWidth: Int(viewportWidth),
                    lineWidthCols: Int(lineWidthCols)
                )
            )
        )
    }

    public struct CellGrapheme: Equatable, Hashable, Sendable {
        public var offset: UInt32
        public var widthCols: UInt32
        public var text: String

        public init(offset: UInt32, widthCols: UInt32, text: String) {
            self.offset = offset
            self.widthCols = widthCols
            self.text = text
        }
    }

    // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView [status=implemented hash=3dd658e1caad]
    public final class UnifiedTextBufferView: @unchecked Sendable {
        public private(set) var buffer: NativeZigTextBuffer.UnifiedTextBuffer
        public let originalBuffer: NativeZigTextBuffer.UnifiedTextBuffer
        public private(set) var core: OpenTUICore.TextBufferView
        public private(set) var localSelection: LocalSelection = LocalSelection()
        public private(set) var selectionStyle: SelectionStyle = SelectionStyle()
        public private(set) var viewport: Viewport = Viewport()
        public private(set) var hasViewport: Bool = false
        public private(set) var drawY: Int32 = 0
        public private(set) var storageRetired: Bool = false
        public private(set) var cachedOutput: VirtualLineOutput = VirtualLineOutput()
        private var registeredViewId: UInt32 = 0
        private var currentSelectionBehavior: SelectionBehavior = .cell

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.init [status=implemented hash=00171f79f889]
        public init(buffer: NativeZigTextBuffer.UnifiedTextBuffer) {
            self.buffer = buffer
            self.originalBuffer = buffer
            self.core = OpenTUICore.TextBufferView.create(buffer.core)
            self.registeredViewId = buffer.registerView()
        }

        public init(buffer: NativeZigTextBuffer.UnifiedTextBuffer, wrapping core: OpenTUICore.TextBufferView) {
            self.buffer = buffer
            self.originalBuffer = buffer
            self.core = core
            self.registeredViewId = buffer.registerView()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.deinit [status=implemented hash=15a2815d5326]
        deinit {
            retireStorage()
            buffer.unregisterView(registeredViewId)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.retireStorage [status=implemented hash=3f2e31ce1cb8]
        public func retireStorage() {
            storageRetired = true
            cachedOutput = VirtualLineOutput()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.reinitStorage [status=implemented hash=7f387c727087]
        public func reinitStorage() {
            storageRetired = false
            updateVirtualLines()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.retainedStorageBytes [status=implemented hash=54447c52b401]
        public func retainedStorageBytes() -> Int {
            cachedOutput.virtualLines.count * MemoryLayout<VirtualLine>.stride
                + cachedOutput.cachedLineStarts.count * MemoryLayout<UInt32>.stride * 4
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.prepare [status=implemented hash=db3acf00740b]
        public func prepare() {
            if needsPrepare() {
                updateVirtualLines()
                buffer.clearViewDirty(registeredViewId)
            }
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.needsPrepare [status=implemented hash=34fd6fb3616d]
        public func needsPrepare() -> Bool {
            buffer.isViewDirty(registeredViewId) || cachedOutput.virtualLines.isEmpty
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setWrapMode [status=implemented hash=f2d8bb34fdc8]
        public func setWrapMode(_ mode: WrapMode) {
            core.setWrapMode(mode)
            buffer.markViewsDirty()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setWrapWidth [status=implemented hash=93cd83baf9f8]
        public func setWrapWidth(_ width: UInt32?) {
            core.setWrapWidth(width.map(Int.init))
            buffer.markViewsDirty()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.layoutWrapWidth [status=implemented hash=cc3b9f3966c2]
        public func layoutWrapWidth() -> UInt32? {
            if let explicit = core.wrapWidth {
                return UInt32(max(0, explicit))
            }
            if hasViewport && viewport.width > 0 {
                return viewport.width
            }
            return nil
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setTextAlign [status=implemented hash=ca37cdeaa21a]
        public func setTextAlign(_ align: TextAlign) {
            core.setTextAlign(align.coreValue)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getTextAlign [status=implemented hash=47875760e599]
        public func getTextAlign() -> TextAlign {
            switch core.textAlign {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setDrawY [status=implemented hash=24a248f27764]
        public func setDrawY(_ y: Int32) {
            self.drawY = y
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getLineAlignmentPad [status=implemented hash=0e284596ae93]
        public func getLineAlignmentPad(vlineIdx: Int, lineWidthCols: UInt32) -> UInt32 {
            _ = vlineIdx
            let vpWidth = hasViewport ? viewport.width : (layoutWrapWidth() ?? lineWidthCols)
            return NativeZigTextBufferView.alignmentPadCols(
                alignment: getTextAlign(),
                viewportWidth: vpWidth,
                lineWidthCols: lineWidthCols
            )
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setFirstLineOffset [status=implemented hash=bc9def85ed6f]
        public func setFirstLineOffset(_ offset: UInt32) {
            core.setFirstLineOffset(Int(offset))
            buffer.markViewsDirty()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setTruncate [status=implemented hash=6207e8cf8feb]
        public func setTruncate(_ truncate: Bool) {
            core.setTruncate(truncate)
            buffer.markViewsDirty()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getTruncate [status=implemented hash=2d2765707697]
        public func getTruncate() -> Bool {
            core.truncate
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setTabIndicator [status=implemented hash=9cfd54dd6853]
        public func setTabIndicator(_ indicator: UInt32?) {
            if let cp = indicator {
                core.setTabIndicator(codePoint: cp)
            } else {
                core.setTabIndicator("")
            }
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getTabIndicator [status=implemented hash=2604693d8d6b]
        public func getTabIndicator() -> UInt32? {
            core.tabIndicator?.value
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setTabIndicatorColor [status=implemented hash=51bafc763020]
        public func setTabIndicatorColor(_ color: RGBA?) {
            if let color {
                core.setTabIndicatorColor(color)
            }
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getTabIndicatorColor [status=implemented hash=7ce7265706ae]
        public func getTabIndicatorColor() -> RGBA? {
            core.tabIndicatorColor
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setViewport [status=implemented hash=cb87b4997c3a]
        public func setViewport(_ vp: Viewport?) {
            if let vp {
                viewport = vp
                hasViewport = true
                core.setViewport(x: Int(vp.x), y: Int(vp.y), width: Int(vp.width), height: Int(vp.height))
            } else {
                viewport = Viewport()
                hasViewport = false
            }
            buffer.markViewsDirty()
        }

        public func setViewport(_ vp: Viewport) {
            setViewport(Optional(vp))
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getViewport [status=implemented hash=8e2a487def5a]
        public func getViewport() -> Viewport? {
            hasViewport ? viewport : nil
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setViewportSize [status=implemented hash=89160e2bd22a]
        public func setViewportSize(width: UInt32, height: UInt32) {
            viewport.width = width
            viewport.height = height
            hasViewport = true
            core.setViewportSize(width: Int(width), height: Int(height))
            buffer.markViewsDirty()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.updateVirtualLines [status=implemented hash=5e8890fc482f]
        public func updateVirtualLines() {
            cachedOutput = virtualLineOutput()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getVirtualLines [status=implemented hash=da7229320bd2]
        public func getVirtualLines() -> [VirtualLine] {
            prepare()
            return cachedOutput.virtualLines
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getCachedLineInfo [status=implemented hash=7cfa3d0e259a]
        public func getCachedLineInfo() -> LineInfo {
            prepare()
            return LineInfo(
                lineStartCols: cachedOutput.cachedLineStarts,
                lineWidthCols: cachedOutput.cachedLineWidths,
                lineSources: cachedOutput.cachedLineSources,
                lineWraps: cachedOutput.cachedLineWrapIndices,
                lineWidthColsMax: cachedOutput.cachedLineWidths.max() ?? 0
            )
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getLogicalLineInfo [status=implemented hash=855d3868e2ea]
        public func getLogicalLineInfo() -> LineInfo {
            let lineCount = Int(buffer.getLineCount())
            var starts: [UInt32] = []
            var widths: [UInt32] = []
            var sources: [UInt32] = []
            var wraps: [UInt32] = []
            var maxW: UInt32 = 0
            for r in 0..<lineCount {
                let w = buffer.lineWidthAt(row: UInt32(r))
                starts.append(0)
                widths.append(w)
                sources.append(UInt32(r))
                wraps.append(0)
                maxW = max(maxW, w)
            }
            return LineInfo(
                lineStartCols: starts,
                lineWidthCols: widths,
                lineSources: sources,
                lineWraps: wraps,
                lineWidthColsMax: maxW
            )
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getWrapInfo [status=implemented hash=1421f78d5704]
        public func getWrapInfo() -> WrapInfo {
            prepare()
            let logicalCount = Int(buffer.getLineCount())
            var firstVLine = Array<UInt32>(repeating: 0, count: logicalCount)
            var counts = Array<UInt32>(repeating: 0, count: logicalCount)
            for (vIdx, vline) in cachedOutput.virtualLines.enumerated() {
                let src = vline.sourceLine
                guard src >= 0 && src < logicalCount else { continue }
                if counts[src] == 0 {
                    firstVLine[src] = UInt32(vIdx)
                }
                counts[src] &+= 1
            }
            return WrapInfo(lineFirstVLine: firstVLine, lineVLineCounts: counts)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.findVisualLineIndex [status=implemented hash=98eba55c35a2]
        public func findVisualLineIndex(logicalRow: UInt32, logicalCol: UInt32) -> UInt32 {
            let vlines = getVirtualLines()
            var lastForRow: UInt32 = 0
            var foundRow = false
            for (idx, vline) in vlines.enumerated() {
                if vline.sourceLine == Int(logicalRow) {
                    foundRow = true
                    lastForRow = UInt32(idx)
                    let endCol = vline.sourceColStart &+ vline.widthCols
                    if logicalCol >= vline.sourceColStart && logicalCol <= endCol {
                        return UInt32(idx)
                    }
                } else if foundRow && vline.sourceLine > Int(logicalRow) {
                    break
                }
            }
            return lastForRow
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getPlainTextIntoBuffer [status=implemented hash=a6d04265a756]
        public func getPlainTextIntoBuffer(_ outBuffer: inout [UInt8]) -> Int {
            buffer.getPlainTextIntoBuffer(&outBuffer)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getArenaAllocatedBytes [status=implemented hash=0efbe3bc0017]
        public func getArenaAllocatedBytes() -> Int {
            retainedStorageBytes()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setSelection [status=implemented hash=c5a6c1bdeb05]
        public func setSelection(start: UInt32, end: UInt32, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
            setSelectionStyle(start: start, end: end, style: SelectionStyle(bgColor: bgColor, fgColor: fgColor))
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setSelectionStyle [status=implemented hash=f511c523577c]
        public func setSelectionStyle(start: UInt32, end: UInt32, style: SelectionStyle = SelectionStyle()) {
            selectionStyle = style
            core.setSelection(start: Int(start), end: Int(end), bgColor: style.bgColor, fgColor: style.fgColor)
        }

        public func setSelection(start: UInt32, end: UInt32, style: SelectionStyle) {
            setSelectionStyle(start: start, end: end, style: style)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.updateSelection [status=implemented hash=dac705b7c81d]
        public func updateSelection(end: UInt32, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
            updateSelectionStyle(end: end, style: SelectionStyle(bgColor: bgColor, fgColor: fgColor))
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.updateSelectionStyle [status=implemented hash=2e56016f5dda]
        public func updateSelectionStyle(end: UInt32, style: SelectionStyle) {
            selectionStyle = style
            core.updateSelection(end: Int(end), bgColor: style.bgColor, fgColor: style.fgColor)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setSelectionColors [status=implemented hash=08f84c937288]
        public func setSelectionColors(bgColor: RGBA?, fgColor: RGBA?) {
            selectionStyle = SelectionStyle(bgColor: bgColor, fgColor: fgColor)
            core.setSelectionColors(bgColor: bgColor, fgColor: fgColor)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.resetSelection [status=implemented hash=771383b95cd8]
        public func resetSelection() {
            core.resetSelection()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.followWidthMethod [status=implemented hash=a58997fe201d]
        public func followWidthMethod(buffer: NativeZigTextBuffer.UnifiedTextBuffer, method: WidthMethod) {
            buffer.setWidthMethod(method)
            updateVirtualLines()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setSelectionInclusiveStyle [status=implemented hash=79e04b2f96b4]
        public func setSelectionInclusiveStyle(start: UInt32, end: UInt32, style: SelectionStyle) {
            selectionStyle = style
            core.setSelectionInclusive(start: Int(start), end: Int(end), bgColor: style.bgColor, fgColor: style.fgColor)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getSelection [status=implemented hash=2ad59f2baea3]
        public func getSelection() -> SelectionRange? {
            core.getSelection().map(SelectionRange.init(core:))
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getTextBuffer [status=implemented hash=3b80f4850881]
        public func getTextBuffer() -> NativeZigTextBuffer.UnifiedTextBuffer {
            buffer
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.switchToBuffer [status=implemented hash=11989aba5571]
        public func switchToBuffer(_ newBuffer: NativeZigTextBuffer.UnifiedTextBuffer) {
            guard newBuffer !== buffer else { return }
            buffer.unregisterView(registeredViewId)
            buffer = newBuffer
            registeredViewId = newBuffer.registerView()
            let wrapMode = core.wrapMode
            let wrapWidth = core.wrapWidth
            let align = core.textAlign
            let truncate = core.truncate
            core = OpenTUICore.TextBufferView.create(newBuffer.core)
            core.setWrapMode(wrapMode)
            core.setWrapWidth(wrapWidth)
            core.setTextAlign(align)
            core.setTruncate(truncate)
            if hasViewport {
                core.setViewport(x: Int(viewport.x), y: Int(viewport.y), width: Int(viewport.width), height: Int(viewport.height))
            }
            updateVirtualLines()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.switchToOriginalBuffer [status=implemented hash=92c92592aeff]
        public func switchToOriginalBuffer() {
            switchToBuffer(originalBuffer)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setSelectionOccupancy [status=implemented hash=3239cc05e6ea]
        public func setSelectionOccupancy(_ occupancy: SelectionOccupancy) {
            core.setSelectionOccupancy(occupancy.coreValue)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getSelectionOccupancy [status=implemented hash=fb75127e015b]
        public func getSelectionOccupancy() -> SelectionOccupancy {
            SelectionOccupancy(core: core.getSelectionOccupancy())
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setLocalSelection [status=implemented hash=9d1b29516b58]
        @discardableResult
        public func setLocalSelection(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            bgColor: RGBA? = nil,
            fgColor: RGBA? = nil
        ) -> Bool {
            setLocalSelectionBehavior(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                bgColor: bgColor,
                fgColor: fgColor,
                behavior: .cell
            )
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setLocalSelectionBehavior [status=implemented hash=14c16e44c2fe]
        @discardableResult
        public func setLocalSelectionBehavior(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            bgColor: RGBA? = nil,
            fgColor: RGBA? = nil,
            behavior: SelectionBehavior
        ) -> Bool {
            setLocalSelectionStyle(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                style: SelectionStyle(bgColor: bgColor, fgColor: fgColor),
                behavior: behavior
            )
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.setLocalSelectionStyle [status=implemented hash=7ff4a5e335a7]
        @discardableResult
        public func setLocalSelectionStyle(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            style: SelectionStyle,
            behavior: SelectionBehavior = .cell
        ) -> Bool {
            localSelection = LocalSelection(anchorX: anchorX, anchorY: anchorY, focusX: focusX, focusY: focusY, isActive: true)
            selectionStyle = style
            currentSelectionBehavior = behavior
            let changed = core.setLocalSelection(
                anchorX: Int(anchorX),
                anchorY: Int(anchorY),
                focusX: Int(focusX),
                focusY: Int(focusY),
                bgColor: style.bgColor,
                fgColor: style.fgColor
            )
            if behavior == .word, let sel = getSelection() {
                if let expanded = selectWordBetween(from: sel.start, toward: sel.end) {
                    setSelectionStyle(start: expanded.start, end: expanded.end, style: style)
                }
            } else if behavior == .line, let sel = getSelection() {
                if let a = selectLine(offset: sel.start), let b = selectLine(offset: sel.end) {
                    setSelectionStyle(start: min(a.start, b.start), end: max(a.end, b.end), style: style)
                }
            }
            return changed
        }

        public func setLocalSelection(_ local: LocalSelection, style: SelectionStyle = SelectionStyle()) {
            localSelection = local
            selectionStyle = style
            if local.isActive {
                _ = setLocalSelectionStyle(
                    anchorX: local.anchorX,
                    anchorY: local.anchorY,
                    focusX: local.focusX,
                    focusY: local.focusY,
                    style: style,
                    behavior: .cell
                )
            } else {
                resetLocalSelection()
            }
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.updateLocalSelection [status=implemented hash=e6b95375df19]
        @discardableResult
        public func updateLocalSelection(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            bgColor: RGBA? = nil,
            fgColor: RGBA? = nil
        ) -> Bool {
            updateLocalSelectionBehavior(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                bgColor: bgColor,
                fgColor: fgColor,
                behavior: currentSelectionBehavior
            )
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.updateLocalSelectionBehavior [status=implemented hash=638cf3121cdf]
        @discardableResult
        public func updateLocalSelectionBehavior(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            bgColor: RGBA? = nil,
            fgColor: RGBA? = nil,
            behavior: SelectionBehavior
        ) -> Bool {
            updateLocalSelectionStyle(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                style: SelectionStyle(bgColor: bgColor, fgColor: fgColor),
                behavior: behavior
            )
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.updateLocalSelectionStyle [status=implemented hash=0bd1f9ddd29f]
        @discardableResult
        public func updateLocalSelectionStyle(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            style: SelectionStyle,
            behavior: SelectionBehavior = .cell
        ) -> Bool {
            setLocalSelectionStyle(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                style: style,
                behavior: behavior
            )
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.convertSelectionToCell [status=implemented hash=23ed45864321]
        @discardableResult
        public func convertSelectionToCell() -> Bool {
            guard currentSelectionBehavior != .cell else { return false }
            currentSelectionBehavior = .cell
            return true
        }

        private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
            s == "_" || s.properties.isAlphabetic || (s.value >= 0x30 && s.value <= 0x39)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.selectWord [status=implemented hash=f03a3737b8a5]
        public func selectWord(offset: UInt32) -> SelectionRange? {
            let text = buffer.getPlainText()
            guard !text.isEmpty else { return nil }
            let chars = Array(text)
            let idx = min(Int(offset), chars.count - 1)
            let isWord = chars[idx].unicodeScalars.first.map(Self.isWordScalar) ?? false
            var lo = idx
            while lo > 0 {
                let prevIsWord = chars[lo - 1].unicodeScalars.first.map(Self.isWordScalar) ?? false
                if prevIsWord != isWord { break }
                lo -= 1
            }
            var hi = idx + 1
            while hi < chars.count {
                let nextIsWord = chars[hi].unicodeScalars.first.map(Self.isWordScalar) ?? false
                if nextIsWord != isWord { break }
                hi += 1
            }
            return SelectionRange(start: UInt32(lo), end: UInt32(hi))
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.selectWordBetween [status=implemented hash=934535bd8f24]
        public func selectWordBetween(from: UInt32, toward: UInt32) -> SelectionRange? {
            guard let a = selectWord(offset: from) else { return nil }
            guard let b = selectWord(offset: toward) else { return a }
            return SelectionRange(start: min(a.start, b.start), end: max(a.end, b.end))
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.selectLine [status=implemented hash=7a47a9cf0227]
        public func selectLine(offset: UInt32) -> SelectionRange? {
            guard let pos = buffer.core.offsetToPosition(Int(offset)) else { return nil }
            let start = UInt32(max(0, buffer.core.getLineStartOffset(pos.row)))
            let width = buffer.lineWidthAt(row: UInt32(pos.row))
            return SelectionRange(start: start, end: start &+ width)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.resetLocalSelection [status=implemented hash=069eb22b6f51]
        public func resetLocalSelection() {
            localSelection = LocalSelection()
            currentSelectionBehavior = .cell
            core.resetLocalSelection()
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.graphemeAtCell [status=implemented hash=b62c09ee1807]
        public func graphemeAtCell(x: Int32, y: Int32) -> CellGrapheme? {
            let vlines = getVirtualLines()
            let row = Int(y) + Int(hasViewport ? viewport.y : 0)
            guard row >= 0 && row < vlines.count else { return nil }
            let vline = vlines[row]
            let lineText = vline.chunks.map(\.text).joined()
            let bytes = Array(lineText.utf8)
            let spans = segmentGraphemeClusters(
                bytes,
                tabWidth: buffer.tabWidth(),
                controlDisplay: buffer.controlDisplay(),
                widthMethod: buffer.widthMethod()
            )
            let targetCol = Int(x) + Int(hasViewport ? viewport.x : 0)
            guard targetCol >= 0 else { return nil }
            var col = 0
            for span in spans {
                let w = max(1, Int(span.width))
                if targetCol >= col && targetCol < col + w {
                    let gText = String(decoding: bytes[span.byteStart..<span.byteEnd], as: UTF8.self)
                    return CellGrapheme(
                        offset: vline.documentCellOffset &+ UInt32(col),
                        widthCols: UInt32(w),
                        text: gText
                    )
                }
                col += w
            }
            return nil
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.packSelectionInfo [status=implemented hash=e0e7994283cd]
        public func packSelectionInfo() -> UInt64 {
            guard let sel = getSelection() else { return 0xFFFF_FFFF_FFFF_FFFF }
            return (UInt64(sel.start) << 32) | UInt64(sel.end)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getSelectedTextIntoBuffer [status=implemented hash=4dcb2932642d]
        public func getSelectedTextIntoBuffer(_ outBuffer: inout [UInt8]) -> Int {
            let bytes = Array(core.getSelectedText().utf8)
            let count = min(bytes.count, outBuffer.count)
            for i in 0..<count { outBuffer[i] = bytes[i] }
            return count
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.copySelectedText [status=implemented hash=62fe624bc00f]
        public func copySelectedText(into out: inout [UInt8]) throws(NativeZigTextBuffer.TextBufferError) -> UInt32 {
            let bytes = Array(core.getSelectedText().utf8)
            guard bytes.count <= out.count else { throw .outOfMemory }
            for i in 0..<bytes.count { out[i] = bytes[i] }
            return UInt32(bytes.count)
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getVirtualLineSpans [status=implemented hash=030a133cac63]
        public func getVirtualLineSpans(vlineIdx: Int) throws(NativeZigTextBuffer.TextBufferError) -> VirtualLineSpanInfo {
            let vlines = getVirtualLines()
            guard vlineIdx >= 0 && vlineIdx < vlines.count else { throw .invalidRange }
            let vline = vlines[vlineIdx]
            let lineSpans = buffer.getLineSpans(lineIdx: vline.sourceLine)
            return VirtualLineSpanInfo(
                spans: lineSpans.spans,
                sourceLine: vline.sourceLine,
                sourceColStart: vline.sourceColStart
            )
        }

        public func getSelectedText() -> String { core.getSelectedText() }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.getVirtualLineCount [status=implemented hash=521e1a4fd778]
        public func getVirtualLineCount() -> UInt32 {
            UInt32(max(0, core.getVirtualLineCount()))
        }

        // parity: native/src/text-buffer-view.zig#UnifiedTextBufferView.measureForDimensions [status=implemented hash=ed579b2332b7]
        public func measureForDimensions(width: UInt32, height: UInt32) -> MeasureResult? {
            core.measureForDimensions(width: Int(width), height: Int(height)).map(MeasureResult.init(core:))
        }

        public func virtualLineOutput() -> VirtualLineOutput {
            let vlines = core.virtualLines()
            var out = VirtualLineOutput()
            var offset: UInt32 = 0
            for vline in vlines {
                let text = vline.text
                let widthCols = UInt32(max(0, vline.widthCols))
                let chunk = VirtualChunk(
                    text: text,
                    byteStartInChunk: 0,
                    byteLen: UInt32(text.utf8.count),
                    colStartInChunk: 0,
                    widthCols: widthCols
                )
                out.virtualLines.append(
                    VirtualLine(
                        chunks: [chunk],
                        widthCols: widthCols,
                        documentCellOffset: offset,
                        sourceLine: vline.sourceLine,
                        sourceColStart: UInt32(max(0, vline.sourceColStart))
                    )
                )
                out.cachedLineStarts.append(UInt32(max(0, vline.sourceColStart)))
                out.cachedLineWidths.append(widthCols)
                out.cachedLineSources.append(UInt32(max(0, vline.sourceLine)))
                out.cachedLineWrapIndices.append(UInt32(max(0, vline.wrapIndex)))
                offset &+= widthCols
            }
            return out
        }
    }

    // parity: native/src/text-buffer-view.zig#TextBufferView [status=implemented hash=f01d904771e4]
    public typealias TextBufferView = UnifiedTextBufferView
}

// MARK: - 5. native/src/edit-buffer.zig (7 unmapped symbols)

public enum NativeZigEditBuffer: Sendable {
    // parity: native/src/edit-buffer.zig#EditBufferError [status=implemented hash=9ec5d034115f]
    public enum EditBufferError: Error, Equatable, Hashable, Sendable {
        case outOfMemory
        case invalidCursor
    }

    // parity: native/src/edit-buffer.zig#EditBufferEvent [status=implemented hash=fd0ac816a5c6]
    public enum EditBufferEvent: Equatable, Hashable, Sendable {
        case cursorChanged
    }

    // parity: native/src/edit-buffer.zig#NativeEvent [status=implemented hash=f53b1be3e17b]
    public enum NativeEvent: Equatable, Hashable, Sendable {
        case cursorChanged
        case contentChanged
        case historyCursorChanged
    }

    // parity: native/src/edit-buffer.zig#NativeEventNotify [status=implemented hash=86298b25e33b]
    public struct NativeEventNotify: Sendable {
        public let callback: @Sendable (NativeEvent) -> Void

        public init(callback: @escaping @Sendable (NativeEvent) -> Void) {
            self.callback = callback
        }

        public func emit(_ event: NativeEvent) {
            callback(event)
        }
    }

    // parity: native/src/edit-buffer.zig#Cursor [status=implemented hash=504df6f03b75]
    public struct Cursor: Equatable, Hashable, Sendable {
        public var row: UInt32
        public var col: UInt32
        public var desiredCol: UInt32
        public var offset: UInt32

        public init(row: UInt32 = 0, col: UInt32 = 0, desiredCol: UInt32 = 0, offset: UInt32 = 0) {
            self.row = row
            self.col = col
            self.desiredCol = desiredCol
            self.offset = offset
        }

        public init(core: LogicalCursor) {
            self.row = UInt32(max(0, core.row))
            self.col = UInt32(max(0, core.col))
            self.desiredCol = UInt32(max(0, core.col))
            self.offset = UInt32(max(0, core.offset))
        }
    }

    // parity: native/src/edit-buffer.zig#Measure [status=implemented hash=4018b420df62]
    public struct Measure: Equatable, Hashable, Sendable {
        public var tabWidth: UInt8
        public var widthMethod: TextWidthMethod

        public init(tabWidth: UInt8 = 2, widthMethod: TextWidthMethod = .unicode) {
            self.tabWidth = tabWidth
            self.widthMethod = widthMethod
        }
    }

    // parity: native/src/edit-buffer.zig#EditBuffer [status=implemented hash=6ebf3e04b64c]
    public final class EditBuffer: @unchecked Sendable {
        public struct InitOptions: Equatable, Hashable, Sendable {
            public var widthMethod: TextWidthMethod
            public var tabWidth: UInt8
            public var id: UInt32

            public init(widthMethod: TextWidthMethod = .unicode, tabWidth: UInt8 = 2, id: UInt32 = 1) {
                self.widthMethod = widthMethod
                self.tabWidth = tabWidth
                self.id = id
            }
        }

        public struct MarkOptions: Equatable, Hashable, Sendable {
            public var kind: UInt32
            public var startByte: UInt32
            public var endByte: UInt32
            public var style: UInt32
            public var priority: UInt32
            public var atomic: Bool

            public init(
                kind: UInt32 = 0,
                startByte: UInt32,
                endByte: UInt32,
                style: UInt32 = 0,
                priority: UInt32 = 0,
                atomic: Bool = false
            ) {
                self.kind = kind
                self.startByte = startByte
                self.endByte = endByte
                self.style = style
                self.priority = priority
                self.atomic = atomic
            }
        }

        public enum Toward: UInt8, Equatable, Hashable, Sendable {
            case left = 0
            case right = 1
            case nearest = 2
        }

        public let core: OpenTUICore.EditBuffer
        public let textBuffer: NativeZigTextBuffer.UnifiedTextBuffer
        public var notify: NativeEventNotify?
        private var desiredColumn: UInt32 = 0
        private var nextMarkId: UInt32 = 1

        // parity: native/src/edit-buffer.zig#EditBuffer.init [status=implemented hash=41ede0f85081]
        public convenience init(widthMethod: TextWidthMethod = .unicode, tabWidth: UInt8 = 2, id: UInt32 = 1) {
            self.init(options: InitOptions(widthMethod: widthMethod, tabWidth: tabWidth, id: id))
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.initWithOptions [status=implemented hash=9ef8f7c4ec73]
        public init(options: InitOptions) {
            let core = OpenTUICore.EditBuffer(widthMethod: options.widthMethod, tabWidth: Int(options.tabWidth), id: options.id)
            self.core = core
            self.textBuffer = NativeZigTextBuffer.UnifiedTextBuffer(wrapping: core.textBuffer)
        }

        public init(wrapping core: OpenTUICore.EditBuffer) {
            self.core = core
            self.textBuffer = NativeZigTextBuffer.UnifiedTextBuffer(wrapping: core.textBuffer)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.deinit [status=implemented hash=bb2af65999dc]
        deinit {
            textBuffer.retireStorage()
            core.destroy()
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getTextBuffer [status=implemented hash=b39568ae635b]
        public func getTextBuffer() -> NativeZigTextBuffer.UnifiedTextBuffer {
            textBuffer
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getPrimaryCursor [status=implemented hash=37d040f57a26]
        public func getPrimaryCursor() -> Cursor {
            var cur = Cursor(core: core.getCursorPosition())
            cur.desiredCol = desiredColumn
            return cur
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.setTabWidth [status=implemented hash=76707d25c548]
        public func setTabWidth(_ width: UInt8) {
            core.setTabWidth(Int(NativeZigTextBuffer.UnifiedTextBuffer.effectiveTabWidth(width)))
            textBuffer.markViewsDirty()
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.setWidthMethod [status=implemented hash=fdb9e12f9f52]
        public func setWidthMethod(_ method: WidthMethod) {
            let old = remeasure(method: method)
            remapCursor(old: old)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.remeasure [status=implemented hash=6e31fc9ba665]
        public func remeasure(method: WidthMethod) -> Measure {
            let previous = measure()
            textBuffer.setWidthMethod(method)
            return previous
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.remapCursor [status=implemented hash=cf5e731a0d2f]
        public func remapCursor(old: Measure) {
            _ = old
            let pos = core.getCursorPosition()
            let snapped = snapColumn(row: UInt32(max(0, pos.row)), col: UInt32(max(0, pos.col)))
            core.setCursor(line: pos.row, col: Int(snapped))
            desiredColumn = snapped
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.setText [status=implemented hash=f3b63f9d14e3]
        public func setText(_ text: String) {
            core.setText(text)
            desiredColumn = 0
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.setTextOwned [status=implemented hash=377d12c1407c]
        @discardableResult
        public func setTextOwned(_ text: [UInt8], preferredId: UInt8? = nil) -> UInt8 {
            let memId = textBuffer.replaceOwnedText(text, memId: preferredId)
            core.setTextOwned(String(decoding: text, as: UTF8.self))
            desiredColumn = 0
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
            return memId
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.replaceText [status=implemented hash=22ea7e1d6b28]
        public func replaceText(_ text: String) {
            core.replaceText(text)
            desiredColumn = 0
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.insertText [status=implemented hash=e74a28334931]
        public func insertText(_ text: String) {
            core.insertText(text)
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.deleteRange [status=implemented hash=8806ee0f58d5]
        public func deleteRange(start: Cursor, end: Cursor) {
            core.deleteRange(
                startLine: Int(start.row),
                startCol: Int(start.col),
                endLine: Int(end.row),
                endCol: Int(end.col)
            )
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.replaceRange [status=implemented hash=e000f601bda2]
        public func replaceRange(start: Cursor, end: Cursor, replacement: String) {
            core.deleteRange(
                startLine: Int(start.row),
                startCol: Int(start.col),
                endLine: Int(end.row),
                endCol: Int(end.col)
            )
            core.setCursor(line: Int(start.row), col: Int(start.col))
            if !replacement.isEmpty {
                core.insertText(replacement)
            }
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.backspace [status=implemented hash=8926c26841bc]
        public func deleteBackward() {
            core.deleteBackward()
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.deleteForward [status=implemented hash=63f07e6716f3]
        public func deleteForward() {
            core.deleteForward()
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.moveLeft [status=implemented hash=b5de5d5f546d]
        public func moveLeft() {
            core.moveCursorLeft()
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getPrevCharBoundary [status=implemented hash=4cb9e46a8952]
        public func getPrevCharBoundary() -> Cursor {
            let pos = core.getCursorPosition()
            if pos.offset <= 0 { return Cursor(row: 0, col: 0, desiredCol: 0, offset: 0) }
            if pos.col > 0 {
                let prevW = textBuffer.getPrevGraphemeWidth(row: UInt32(pos.row), col: UInt32(pos.col))
                let newCol = UInt32(pos.col) - min(UInt32(pos.col), max(1, prevW))
                let newOff = UInt32(max(0, core.positionToOffset(row: pos.row, col: Int(newCol))))
                return Cursor(row: UInt32(pos.row), col: newCol, desiredCol: newCol, offset: newOff)
            }
            let prevRow = max(0, pos.row - 1)
            let prevRowW = textBuffer.lineWidthAt(row: UInt32(prevRow))
            let newOff = UInt32(max(0, core.positionToOffset(row: prevRow, col: Int(prevRowW))))
            return Cursor(row: UInt32(prevRow), col: prevRowW, desiredCol: prevRowW, offset: newOff)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.moveRight [status=implemented hash=e300840b4c30]
        public func moveRight() {
            core.moveCursorRight()
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.moveUp [status=implemented hash=233988897c84]
        public func moveUp() {
            core.moveCursorUp()
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.moveDown [status=implemented hash=6d96e89872d4]
        public func moveDown() {
            core.moveCursorDown()
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.snapColumn [status=implemented hash=87c7171de984]
        public func snapColumn(row: UInt32, col: UInt32) -> UInt32 {
            let lineW = textBuffer.lineWidthAt(row: row)
            if col >= lineW { return lineW }
            let line = core.textBuffer.getLine(Int(row))
            let spans = segmentGraphemeClusters(
                Array(line.utf8),
                tabWidth: textBuffer.tabWidth(),
                controlDisplay: textBuffer.controlDisplay(),
                widthMethod: textBuffer.widthMethod()
            )
            var cur: UInt32 = 0
            for span in spans {
                if span.width == 0 { continue }
                let next = cur &+ span.width
                if col < next { return cur }
                cur = next
            }
            return cur
        }

        /// Splits a text chunk at display-column `weight` matching `edit-buffer.zig#EditBuffer.splitChunkAtWeight`.
        /// At weight 0 only leading zero-width text goes left (short-circuited when `isASCIIOnly`).
        public func splitChunkAtWeight(
            _ bytes: [UInt8],
            weight: UInt32,
            isASCIIOnly: Bool? = nil
        ) -> (left: [UInt8], right: [UInt8]) {
            let ascii = isASCIIOnly ?? isAsciiOnly(bytes)
            let tw = textBuffer.tabWidth()
            let cd = textBuffer.controlDisplay()
            let wm = textBuffer.widthMethod()
            let chunkWeight = calculateTextWidth(bytes, tabWidth: tw, controlDisplay: cd, isASCIIOnly: ascii, widthMethod: wm)
            if weight == 0 && ascii {
                return ([], bytes)
            } else if weight >= chunkWeight {
                return (bytes, [])
            }
            let split = findPosByWidth(
                bytes,
                maxColumns: weight,
                tabWidth: tw,
                controlDisplay: cd,
                isASCIIOnly: ascii,
                includeStartBefore: false,
                widthMethod: wm
            )
            let idx = min(Int(split.byteOffset), bytes.count)
            return (Array(bytes[0..<idx]), Array(bytes[idx...]))
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.unsnappedColumn [status=implemented hash=d25e04c25f2e]
        public func unsnappedColumn() -> UInt32 {
            desiredColumn
        }

        public func newLine() {
            core.newLine()
            desiredColumn = 0
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.deleteLine [status=implemented hash=a937bc18689b]
        public func deleteLine() {
            core.deleteLine()
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            textBuffer.markViewsDirty()
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.gotoLine [status=implemented hash=321b5f1bbc53]
        public func gotoLine(_ line: UInt32) {
            core.gotoLine(Int(line))
            desiredColumn = 0
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.setCursor [status=implemented hash=7a968c403fb2]
        public func setCursor(row: UInt32, col: UInt32) {
            let snapped = snapColumn(row: row, col: col)
            core.setCursor(line: Int(row), col: Int(snapped))
            desiredColumn = snapped
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.setCursorByOffset [status=implemented hash=9b0103844223]
        public func setCursorByOffset(_ offset: UInt32) {
            core.setCursorByOffset(Int(offset))
            desiredColumn = UInt32(max(0, core.getCursorPosition().col))
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getCursorPosition [status=implemented hash=2c8a878ccc2e]
        public func getCursorPosition() -> (line: UInt32, visualCol: UInt32, offset: UInt32) {
            let pos = core.getCursorPosition()
            return (UInt32(max(0, pos.row)), UInt32(max(0, pos.col)), UInt32(max(0, pos.offset)))
        }

        public func getCursor() -> Cursor {
            getPrimaryCursor()
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.debugLogRope [status=implemented hash=73f25f295ff2]
        @discardableResult
        public func debugLogRope() -> String {
            core.debugLogRope()
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.undo [status=implemented hash=2f9665dab15a]
        public func undo() -> String? {
            let result = core.undo()
            if result != nil {
                textBuffer.markViewsDirty()
                notify?.emit(.contentChanged)
                notify?.emit(.historyCursorChanged)
            }
            return result
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.redo [status=implemented hash=64199150a6c9]
        public func redo() -> String? {
            let result = core.redo()
            if result != nil {
                textBuffer.markViewsDirty()
                notify?.emit(.contentChanged)
                notify?.emit(.historyCursorChanged)
            }
            return result
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.canUndo [status=implemented hash=54bb4c76ac71]
        public func canUndo() -> Bool { core.canUndo() }

        // parity: native/src/edit-buffer.zig#EditBuffer.canRedo [status=implemented hash=346350815e01]
        public func canRedo() -> Bool { core.canRedo() }

        // parity: native/src/edit-buffer.zig#EditBuffer.clearHistory [status=implemented hash=cc3b04a92ffe]
        public func clearHistory() { core.clearHistory() }

        // parity: native/src/edit-buffer.zig#EditBuffer.clear [status=implemented hash=fe3c5a3f5d24]
        public func clear() {
            core.clear()
            textBuffer.setMarks([])
            desiredColumn = 0
            notify?.emit(.contentChanged)
            notify?.emit(.cursorChanged)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.addMark [status=implemented hash=46348ba53c76]
        public func addMark(_ options: MarkOptions) throws(EditBufferError) -> UInt32 {
            let total = textBuffer.getByteSize()
            guard options.startByte <= options.endByte && options.endByte <= total else {
                throw .invalidCursor
            }
            var current = textBuffer.marks()
            guard current.count < NativeEditMarks.countMax else { throw .outOfMemory }
            let id = nextMarkId
            nextMarkId &+= 1
            let mark = NativeEditMarks.Mark(
                id: id,
                kind: options.kind,
                style: options.style,
                startByte: options.startByte,
                endByte: options.endByte,
                priority: options.priority,
                atomic: options.atomic
            )
            current.append(mark)
            textBuffer.setMarks(current)
            return id
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.removeMark [status=implemented hash=c512a3b99d48]
        @discardableResult
        public func removeMark(id: UInt32) -> Bool {
            var current = textBuffer.marks()
            guard let idx = current.firstIndex(where: { $0.id == id }) else { return false }
            current.remove(at: idx)
            textBuffer.setMarks(current)
            return true
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.clearMarks [status=implemented hash=b3430cbcd34d]
        public func clearMarks() {
            textBuffer.setMarks([])
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.markOffsets [status=implemented hash=7cd3749c98a7]
        public func markOffsets(_ mark: NativeEditMarks.Mark) -> (start: UInt32, end: UInt32) {
            (
                textBuffer.weightAtByte(mark.startByte, roundDown: true),
                textBuffer.weightAtByte(mark.endByte, roundDown: false)
            )
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.keepOutside [status=implemented hash=8c2db2340b42]
        public func keepOutside(toward: Toward) {
            let cur = getPrimaryCursor()
            for m in textBuffer.marks() where m.atomic {
                let bounds = markOffsets(m)
                if cur.offset > bounds.start && cur.offset < bounds.end {
                    let target: UInt32
                    switch toward {
                    case .left: target = bounds.start
                    case .right: target = bounds.end
                    case .nearest:
                        target = (cur.offset - bounds.start) <= (bounds.end - cur.offset) ? bounds.start : bounds.end
                    }
                    setCursorByOffset(target)
                    return
                }
            }
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.moveAtomic [status=implemented hash=8c9b45569eec]
        public func moveAtomic(right: Bool) {
            if right {
                moveRight()
                keepOutside(toward: .right)
            } else {
                moveLeft()
                keepOutside(toward: .left)
            }
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.setCursorByOffsetAtomic [status=implemented hash=8181d6741555]
        public func setCursorByOffsetAtomic(_ offset: UInt32) {
            setCursorByOffset(offset)
            keepOutside(toward: .nearest)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.leaveAtomic [status=implemented hash=0b7e121b9d2b]
        public func leaveAtomic(from previousOffset: UInt32, down: Bool) {
            let cur = getPrimaryCursor()
            for m in textBuffer.marks() where m.atomic {
                let bounds = markOffsets(m)
                if cur.offset > bounds.start && cur.offset < bounds.end {
                    let target = down ? bounds.end : bounds.start
                    if target == previousOffset {
                        setCursorByOffset(down ? bounds.start : bounds.end)
                    } else {
                        setCursorByOffset(target)
                    }
                    return
                }
            }
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.deleteAtomic [status=implemented hash=4e4030e526cc]
        public func deleteAtomic(forwardDelete: Bool) {
            let cur = getPrimaryCursor()
            for m in textBuffer.marks() where m.atomic {
                let bounds = markOffsets(m)
                let hits = forwardDelete
                    ? (cur.offset >= bounds.start && cur.offset < bounds.end)
                    : (cur.offset > bounds.start && cur.offset <= bounds.end)
                if hits {
                    if let sPos = core.offsetToPosition(Int(bounds.start)),
                       let ePos = core.offsetToPosition(Int(bounds.end))
                    {
                        deleteRange(
                            start: Cursor(row: UInt32(sPos.row), col: UInt32(sPos.col), offset: bounds.start),
                            end: Cursor(row: UInt32(ePos.row), col: UInt32(ePos.col), offset: bounds.end)
                        )
                        _ = removeMark(id: m.id)
                        return
                    }
                }
            }
            if forwardDelete {
                deleteForward()
            } else {
                deleteBackward()
            }
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getNextWordBoundary [status=implemented hash=e419c22e5b5a]
        public func getNextWordBoundary() -> Cursor {
            Cursor(core: core.getNextWordBoundary())
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getPrevWordBoundary [status=implemented hash=30b4827cd557]
        public func getPrevWordBoundary() -> Cursor {
            Cursor(core: core.getPrevWordBoundary())
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getEOL [status=implemented hash=b1bf5b48345a]
        public func getEOL() -> Cursor {
            Cursor(core: core.getEOL())
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getTextRange [status=implemented hash=9038bccd8647]
        public func getTextRange(startOffset: UInt32, endOffset: UInt32, into outBuffer: inout [UInt8]) -> Int {
            textBuffer.getTextRange(startOffset: startOffset, endOffset: endOffset, into: &outBuffer)
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getTextRangeByCoords [status=implemented hash=cc70aa7d4c3c]
        public func getTextRangeByCoords(
            startRow: UInt32,
            startCol: UInt32,
            endRow: UInt32,
            endCol: UInt32,
            into outBuffer: inout [UInt8]
        ) -> Int {
            textBuffer.getTextRangeByCoords(
                startRow: startRow,
                startCol: startCol,
                endRow: endRow,
                endCol: endCol,
                into: &outBuffer
            )
        }

        // parity: native/src/edit-buffer.zig#EditBuffer.getText [status=implemented hash=968020b6d43e]
        public func getText() -> String { core.getText() }
        public func getLineCount() -> UInt32 { UInt32(core.getLineCount()) }
        public func measure() -> Measure { Measure(tabWidth: UInt8(clamping: core.getTabWidth())) }
    }
}

// MARK: - 6. native/src/editor-view.zig (65 symbols)

public enum NativeZigEditorView: Sendable {
    // parity: native/src/editor-view.zig#EditorViewError [status=implemented hash=915a2125679d]
    public enum EditorViewError: Error, Equatable, Hashable, Sendable {
        case outOfMemory
    }

    // parity: native/src/editor-view.zig#VisualCursor [status=implemented hash=6c19d4b7507e]
    public struct VisualCursor: Equatable, Hashable, Sendable {
        public var visualRow: UInt32
        public var visualCol: UInt32
        public var logicalRow: UInt32
        public var logicalCol: UInt32
        public var offset: UInt32

        public init(
            visualRow: UInt32 = 0,
            visualCol: UInt32 = 0,
            logicalRow: UInt32 = 0,
            logicalCol: UInt32 = 0,
            offset: UInt32 = 0
        ) {
            self.visualRow = visualRow
            self.visualCol = visualCol
            self.logicalRow = logicalRow
            self.logicalCol = logicalCol
            self.offset = offset
        }

        public init(core: OpenTUICore.VisualCursor) {
            self.visualRow = UInt32(max(0, core.visualRow))
            self.visualCol = UInt32(max(0, core.visualCol))
            self.logicalRow = UInt32(max(0, core.logicalRow))
            self.logicalCol = UInt32(max(0, core.logicalCol))
            self.offset = UInt32(max(0, core.offset))
        }
    }

    // parity: native/src/editor-view.zig#EditorView [status=implemented hash=f27ae8a0398d]
    public final class EditorView: @unchecked Sendable {
        public let editBuffer: NativeZigEditBuffer.EditBuffer
        public let core: OpenTUICore.EditorView
        public let textBufferView: NativeZigTextBufferView.UnifiedTextBufferView
        public private(set) var selectionFollowCursor: Bool = false
        public private(set) var scrollMargin: Float = 0.2
        public private(set) var placeholderBuffer: NativeZigTextBuffer.UnifiedTextBuffer? = nil

        // parity: native/src/editor-view.zig#EditorView.init [status=implemented hash=85e554f7d416]
        public init(editBuffer: NativeZigEditBuffer.EditBuffer, viewportWidth: UInt32, viewportHeight: UInt32) {
            self.editBuffer = editBuffer
            let core = OpenTUICore.EditorView.create(
                editBuffer: editBuffer.core,
                viewportWidth: Int(viewportWidth),
                viewportHeight: Int(viewportHeight)
            )
            self.core = core
            self.textBufferView = NativeZigTextBufferView.UnifiedTextBufferView(
                buffer: editBuffer.textBuffer,
                wrapping: core.textBufferView
            )
        }

        // parity: native/src/editor-view.zig#EditorView.deinit [status=implemented hash=6df35e93a343]
        deinit {
            clearPlaceholder()
            core.destroy()
        }

        // parity: native/src/editor-view.zig#EditorView.settle [status=implemented hash=30d927fc754a]
        public func settle() {
            textBufferView.prepare()
            makeCursorVisible()
        }

        // parity: native/src/editor-view.zig#EditorView.setViewport [status=implemented hash=dbe9bf3e3f5d]
        public func setViewport(_ vp: NativeZigTextBufferView.Viewport?, moveCursor: Bool = true) {
            if let vp {
                core.setViewport(
                    x: Int(vp.x),
                    y: Int(vp.y),
                    width: Int(vp.width),
                    height: Int(vp.height),
                    moveCursor: moveCursor
                )
            }
            textBufferView.setViewport(vp)
        }

        // parity: native/src/editor-view.zig#EditorView.getViewport [status=implemented hash=14234c8e510a]
        public func getViewport() -> NativeZigTextBufferView.Viewport? {
            let vp = core.getViewport()
            return NativeZigTextBufferView.Viewport(
                x: UInt32(max(0, vp.offsetX)),
                y: UInt32(max(0, vp.offsetY)),
                width: UInt32(max(0, vp.width)),
                height: UInt32(max(0, vp.height))
            )
        }

        // parity: native/src/editor-view.zig#EditorView.makeCursorVisible [status=implemented hash=cf51f4da66d4]
        public func makeCursorVisible() {
            let vc = getVisualCursor()
            ensureCursorVisible(cursorLine: vc.visualRow)
        }

        // parity: native/src/editor-view.zig#EditorView.setScrollMargin [status=implemented hash=5351b9c55d72]
        public func setScrollMargin(_ margin: Float) {
            scrollMargin = max(0, min(0.5, margin))
            core.setScrollMargin(Double(scrollMargin))
        }

        // parity: native/src/editor-view.zig#EditorView.setSelectionFollowCursor [status=implemented hash=7b7198032df1]
        public func setSelectionFollowCursor(_ enabled: Bool) {
            selectionFollowCursor = enabled
        }

        // parity: native/src/editor-view.zig#EditorView.ensureCursorVisible [status=implemented hash=503920fbe0ab]
        public func ensureCursorVisible(cursorLine: UInt32) {
            let vp = core.getViewport()
            guard vp.height > 0 else { return }
            let margin = Int(Float(vp.height) * scrollMargin)
            let line = Int(cursorLine)
            var nextY = vp.offsetY
            if line < vp.offsetY + margin {
                nextY = max(0, line - margin)
            } else if line >= vp.offsetY + vp.height - margin {
                nextY = max(0, line - vp.height + margin + 1)
            }
            if nextY != vp.offsetY {
                core.setViewport(x: vp.offsetX, y: nextY, width: vp.width, height: vp.height, moveCursor: false)
            }
        }

        // parity: native/src/editor-view.zig#EditorView.updateCursorBeforeRender [status=implemented hash=22e271631145]
        public func updateCursorBeforeRender() -> VisualCursor? {
            settle()
            let vc = getVisualCursor()
            let vp = core.getViewport()
            guard vp.height > 0, Int(vc.visualRow) >= vp.offsetY, Int(vc.visualRow) < vp.offsetY + vp.height else {
                return nil
            }
            return vc
        }

        // parity: native/src/editor-view.zig#EditorView.getVirtualLines [status=implemented hash=3b290d058c21]
        public func getVirtualLines() -> [NativeZigTextBufferView.VirtualLine] {
            textBufferView.getVirtualLines()
        }

        // parity: native/src/editor-view.zig#EditorView.getCachedLineInfo [status=implemented hash=f97974a1056b]
        public func getCachedLineInfo() -> NativeZigTextBufferView.LineInfo {
            NativeZigTextBufferView.LineInfo(core: core.getLineInfo())
        }

        // parity: native/src/editor-view.zig#EditorView.getLogicalLineInfo [status=implemented hash=928e249edd6d]
        public func getLogicalLineInfo() -> NativeZigTextBufferView.LineInfo {
            NativeZigTextBufferView.LineInfo(core: core.getLogicalLineInfo())
        }

        // parity: native/src/editor-view.zig#EditorView.getTextBufferView [status=implemented hash=443913491c4e]
        public func getTextBufferView() -> NativeZigTextBufferView.UnifiedTextBufferView {
            textBufferView
        }

        // parity: native/src/editor-view.zig#EditorView.getTotalVirtualLineCount [status=implemented hash=3695896cb22a]
        public func getTotalVirtualLineCount() -> UInt32 { UInt32(max(0, core.getTotalVirtualLineCount())) }

        // parity: native/src/editor-view.zig#EditorView.getVirtualLineSpans [status=implemented hash=d8ab733e0f49]
        public func getVirtualLineSpans(vlineIdx: Int) throws(NativeZigTextBuffer.TextBufferError) -> NativeZigTextBufferView.VirtualLineSpanInfo {
            try textBufferView.getVirtualLineSpans(vlineIdx: vlineIdx)
        }

        // parity: native/src/editor-view.zig#EditorView.getTextAlign [status=implemented hash=77a0e09d81af]
        public func getTextAlign() -> NativeZigTextBufferView.TextAlign {
            textBufferView.getTextAlign()
        }

        // parity: native/src/editor-view.zig#EditorView.setDrawY [status=implemented hash=306e9c2c8dd4]
        public func setDrawY(_ y: Int32) {
            textBufferView.setDrawY(y)
        }

        // parity: native/src/editor-view.zig#EditorView.getLineAlignmentPad [status=implemented hash=5a78abd03f4f]
        public func getLineAlignmentPad(vlineIdx: Int, lineWidthCols: UInt32) -> UInt32 {
            textBufferView.getLineAlignmentPad(vlineIdx: vlineIdx, lineWidthCols: lineWidthCols)
        }

        // parity: native/src/editor-view.zig#EditorView.getTextBuffer [status=implemented hash=e10f1f077a86]
        public func getTextBuffer() -> NativeZigTextBuffer.UnifiedTextBuffer {
            editBuffer.textBuffer
        }

        // parity: native/src/editor-view.zig#EditorView.getSelection [status=implemented hash=b1465b35c7f7]
        public func getSelection() -> NativeZigTextBufferView.SelectionRange? {
            core.getSelection().map(NativeZigTextBufferView.SelectionRange.init(core:))
        }

        // parity: native/src/editor-view.zig#EditorView.setSelection [status=implemented hash=41ab53e812a6]
        public func setSelection(start: UInt32, end: UInt32, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
            core.setSelection(start: Int(start), end: Int(end), bgColor: bgColor, fgColor: fgColor)
        }

        // parity: native/src/editor-view.zig#EditorView.updateSelection [status=implemented hash=8956de6fe267]
        public func updateSelection(end: UInt32, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
            core.updateSelection(end: Int(end), bgColor: bgColor, fgColor: fgColor)
        }

        // parity: native/src/editor-view.zig#EditorView.setSelectionInclusive [status=implemented hash=2b09cd541c4e]
        public func setSelectionInclusive(start: UInt32, end: UInt32, bgColor: RGBA? = nil, fgColor: RGBA? = nil) {
            core.setSelectionInclusive(start: Int(start), end: Int(end), bgColor: bgColor, fgColor: fgColor)
        }

        // parity: native/src/editor-view.zig#EditorView.resetSelection [status=implemented hash=72ee1e471382]
        public func resetSelection() {
            core.resetSelection()
        }

        // parity: native/src/editor-view.zig#EditorView.setLocalSelection [status=implemented hash=e6d06c562eaf]
        @discardableResult
        public func setLocalSelection(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            bgColor: RGBA? = nil,
            fgColor: RGBA? = nil,
            updateCursor: Bool = true
        ) -> Bool {
            setLocalSelectionBehavior(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                bgColor: bgColor,
                fgColor: fgColor,
                updateCursor: updateCursor,
                behavior: .cell
            )
        }

        // parity: native/src/editor-view.zig#EditorView.setLocalSelectionBehavior [status=implemented hash=e4f237f12904]
        @discardableResult
        public func setLocalSelectionBehavior(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            bgColor: RGBA? = nil,
            fgColor: RGBA? = nil,
            updateCursor: Bool = true,
            behavior: NativeZigTextBufferView.SelectionBehavior
        ) -> Bool {
            let changed = textBufferView.setLocalSelectionBehavior(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                bgColor: bgColor,
                fgColor: fgColor,
                behavior: behavior
            )
            if updateCursor && selectionFollowCursor {
                syncCursorToSelectionFocus()
            }
            return changed
        }

        // parity: native/src/editor-view.zig#EditorView.updateLocalSelection [status=implemented hash=fc531e72bd62]
        @discardableResult
        public func updateLocalSelection(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            bgColor: RGBA? = nil,
            fgColor: RGBA? = nil,
            updateCursor: Bool = true
        ) -> Bool {
            updateLocalSelectionBehavior(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                bgColor: bgColor,
                fgColor: fgColor,
                updateCursor: updateCursor,
                behavior: .cell
            )
        }

        // parity: native/src/editor-view.zig#EditorView.updateLocalSelectionBehavior [status=implemented hash=03f5830b1c48]
        @discardableResult
        public func updateLocalSelectionBehavior(
            anchorX: Int32,
            anchorY: Int32,
            focusX: Int32,
            focusY: Int32,
            bgColor: RGBA? = nil,
            fgColor: RGBA? = nil,
            updateCursor: Bool = true,
            behavior: NativeZigTextBufferView.SelectionBehavior
        ) -> Bool {
            let changed = textBufferView.updateLocalSelectionBehavior(
                anchorX: anchorX,
                anchorY: anchorY,
                focusX: focusX,
                focusY: focusY,
                bgColor: bgColor,
                fgColor: fgColor,
                behavior: behavior
            )
            if updateCursor && selectionFollowCursor {
                syncCursorToSelectionFocus()
            }
            return changed
        }

        // parity: native/src/editor-view.zig#EditorView.convertSelectionToCell [status=implemented hash=d7e3adda7e1d]
        @discardableResult
        public func convertSelectionToCell() -> Bool {
            core.convertSelectionToCell()
        }

        // parity: native/src/editor-view.zig#EditorView.resetLocalSelection [status=implemented hash=97baf3af135a]
        public func resetLocalSelection() {
            core.resetLocalSelection()
        }

        // parity: native/src/editor-view.zig#EditorView.setSelectionOccupancy [status=implemented hash=94ad82b56eca]
        public func setSelectionOccupancy(_ occupancy: NativeZigTextBufferView.SelectionOccupancy) {
            core.setSelectionOccupancy(occupancy.coreValue)
        }

        // parity: native/src/editor-view.zig#EditorView.getSelectionOccupancy [status=implemented hash=50d1a6cca9ca]
        public func getSelectionOccupancy() -> NativeZigTextBufferView.SelectionOccupancy {
            NativeZigTextBufferView.SelectionOccupancy(core: core.getSelectionOccupancy())
        }

        // parity: native/src/editor-view.zig#EditorView.syncCursorToSelectionFocus [status=implemented hash=1b5afd56fb7f]
        public func syncCursorToSelectionFocus() {
            if let sel = getSelection() {
                setCursorByOffset(sel.end)
            }
        }

        // parity: native/src/editor-view.zig#EditorView.getSelectedTextIntoBuffer [status=implemented hash=b42c9293dc20]
        public func getSelectedTextIntoBuffer(_ outBuffer: inout [UInt8]) -> Int {
            textBufferView.getSelectedTextIntoBuffer(&outBuffer)
        }

        // parity: native/src/editor-view.zig#EditorView.packSelectionInfo [status=implemented hash=7a98cd9c019e]
        public func packSelectionInfo() -> UInt64 {
            textBufferView.packSelectionInfo()
        }

        // parity: native/src/editor-view.zig#EditorView.setViewportSize [status=implemented hash=34cb2499d41a]
        public func setViewportSize(width: UInt32, height: UInt32) {
            core.setViewportSize(width: Int(width), height: Int(height))
            textBufferView.setViewportSize(width: width, height: height)
        }

        // parity: native/src/editor-view.zig#EditorView.setWrapMode [status=implemented hash=d47084308075]
        public func setWrapMode(_ mode: TextWrapMode) {
            core.setWrapMode(mode)
        }

        // parity: native/src/editor-view.zig#EditorView.getPrimaryCursor [status=implemented hash=784d122b681f]
        public func getPrimaryCursor() -> NativeZigEditBuffer.Cursor {
            editBuffer.getPrimaryCursor()
        }

        // parity: native/src/editor-view.zig#EditorView.getEditBuffer [status=implemented hash=f248eab5099a]
        public func getEditBuffer() -> NativeZigEditBuffer.EditBuffer {
            editBuffer
        }

        // parity: native/src/editor-view.zig#EditorView.getVisualCursor [status=implemented hash=a09235c15700]
        public func getVisualCursor() -> VisualCursor {
            VisualCursor(core: core.getVisualCursor())
        }

        // parity: native/src/editor-view.zig#EditorView.logicalToVisualCursor [status=implemented hash=e739dfa148de]
        public func logicalToVisualCursor(logicalRow: UInt32, logicalCol: UInt32) -> VisualCursor {
            let vIdx = textBufferView.findVisualLineIndex(logicalRow: logicalRow, logicalCol: logicalCol)
            let vlines = textBufferView.getVirtualLines()
            let vCol: UInt32
            if Int(vIdx) < vlines.count {
                let startCol = vlines[Int(vIdx)].sourceColStart
                vCol = logicalCol >= startCol ? logicalCol - startCol : 0
            } else {
                vCol = logicalCol
            }
            let off = UInt32(max(0, editBuffer.core.positionToOffset(row: Int(logicalRow), col: Int(logicalCol))))
            return VisualCursor(
                visualRow: vIdx,
                visualCol: vCol,
                logicalRow: logicalRow,
                logicalCol: logicalCol,
                offset: off
            )
        }

        // parity: native/src/editor-view.zig#EditorView.visualToLogicalCursor [status=implemented hash=9422e827bb79]
        public func visualToLogicalCursor(visualRow: UInt32, visualCol: UInt32) -> VisualCursor? {
            let vlines = textBufferView.getVirtualLines()
            guard Int(visualRow) < vlines.count else { return nil }
            let vline = vlines[Int(visualRow)]
            let clampedVCol = min(visualCol, vline.widthCols)
            let logicalRow = UInt32(max(0, vline.sourceLine))
            let logicalCol = vline.sourceColStart &+ clampedVCol
            let off = UInt32(max(0, editBuffer.core.positionToOffset(row: Int(logicalRow), col: Int(logicalCol))))
            return VisualCursor(
                visualRow: visualRow,
                visualCol: clampedVCol,
                logicalRow: logicalRow,
                logicalCol: logicalCol,
                offset: off
            )
        }

        // parity: native/src/editor-view.zig#EditorView.moveUpVisual [status=implemented hash=134a8668664a]
        public func moveUpVisual() { core.moveUpVisual() }
        // parity: native/src/editor-view.zig#EditorView.moveDownVisual [status=implemented hash=bddbe849f550]
        public func moveDownVisual() { core.moveDownVisual() }
        // parity: native/src/editor-view.zig#EditorView.gotoVisualLineEnd [status=implemented hash=d66ae737b241]
        public func gotoVisualLineEnd() { core.gotoVisualLineEnd() }
        // parity: native/src/editor-view.zig#EditorView.setCursorByOffset [status=implemented hash=de54e7a2ff0d]
        public func setCursorByOffset(_ offset: UInt32) { core.setCursorByOffset(Int(offset)) }

        // parity: native/src/editor-view.zig#EditorView.getNextWordBoundary [status=implemented hash=e62aa82a0c11]
        public func getNextWordBoundary() -> VisualCursor {
            VisualCursor(core: core.getNextWordBoundary())
        }

        // parity: native/src/editor-view.zig#EditorView.getPrevWordBoundary [status=implemented hash=f729463ed60e]
        public func getPrevWordBoundary() -> VisualCursor {
            VisualCursor(core: core.getPrevWordBoundary())
        }

        // parity: native/src/editor-view.zig#EditorView.getEOL [status=implemented hash=f9e19723c3b4]
        public func getEOL() -> VisualCursor {
            VisualCursor(core: core.getEOL())
        }

        // parity: native/src/editor-view.zig#EditorView.getVisualSOL [status=implemented hash=8214a7010ea7]
        public func getVisualSOL() -> VisualCursor {
            VisualCursor(core: core.getVisualSOL())
        }

        // parity: native/src/editor-view.zig#EditorView.getVisualEOL [status=implemented hash=699211dca501]
        public func getVisualEOL() -> VisualCursor {
            VisualCursor(core: core.getVisualEOL())
        }

        // parity: native/src/editor-view.zig#EditorView.clearPlaceholder [status=implemented hash=63b292de48a7]
        public func clearPlaceholder() {
            placeholderBuffer = nil
            core.setPlaceholderStyledText([])
            textBufferView.switchToOriginalBuffer()
        }

        // parity: native/src/editor-view.zig#EditorView.setPlaceholderOwnedStyledText [status=implemented hash=87632bb4d2ee]
        public func setPlaceholderOwnedStyledText(
            text: [UInt8],
            chunks: [NativeZigTextBuffer.OwnedStyledChunk]
        ) {
            let ph = NativeZigTextBuffer.UnifiedTextBuffer(widthMethod: editBuffer.core.textBuffer.widthMethod)
            _ = ph.replaceOwnedStyledText(text: text, chunks: chunks)
            placeholderBuffer = ph
            let str = String(decoding: text, as: UTF8.self)
            var coreChunks: [TextChunk] = []
            var offset = 0
            let bytes = Array(str.utf8)
            for chunk in chunks {
                let end = min(bytes.count, offset + Int(chunk.byteCount))
                let sliceStr = String(decoding: bytes[offset..<end], as: UTF8.self)
                coreChunks.append(
                    TextChunk(
                        text: sliceStr,
                        fg: chunk.style.fg,
                        bg: chunk.style.bg,
                        attributes: chunk.style.attributes
                    )
                )
                offset = end
            }
            if coreChunks.isEmpty && !str.isEmpty {
                coreChunks.append(TextChunk(text: str))
            }
            core.setPlaceholderStyledText(coreChunks)
        }

        // parity: native/src/editor-view.zig#EditorView.followWidthMethod [status=implemented hash=d636a52b4f83]
        public func followWidthMethod(_ method: WidthMethod) {
            editBuffer.setWidthMethod(method)
            textBufferView.followWidthMethod(buffer: editBuffer.textBuffer, method: method)
        }

        // parity: native/src/editor-view.zig#EditorView.setTabIndicator [status=implemented hash=73936d035a7d]
        public func setTabIndicator(_ indicator: UInt32?) {
            textBufferView.setTabIndicator(indicator)
        }

        // parity: native/src/editor-view.zig#EditorView.getTabIndicator [status=implemented hash=2658202f0552]
        public func getTabIndicator() -> UInt32? {
            textBufferView.getTabIndicator()
        }

        // parity: native/src/editor-view.zig#EditorView.setTabIndicatorColor [status=implemented hash=5e5de1f45c78]
        public func setTabIndicatorColor(_ color: RGBA?) {
            textBufferView.setTabIndicatorColor(color)
        }

        // parity: native/src/editor-view.zig#EditorView.getTabIndicatorColor [status=implemented hash=94b62d77781c]
        public func getTabIndicatorColor() -> RGBA? {
            textBufferView.getTabIndicatorColor()
        }

        // parity: native/src/editor-view.zig#EditorView.getText [status=implemented hash=592eafd8a569]
        public func getText() -> String { core.getText() }
        public func getSelectedText() -> String { core.getSelectedText() }
        // parity: native/src/editor-view.zig#EditorView.deleteSelectedText [status=implemented hash=4eb65e4879ed]
        public func deleteSelectedText() { core.deleteSelectedText() }
        // parity: native/src/editor-view.zig#EditorView.replaceSelectedText [status=implemented hash=421a44808184]
        public func replaceSelectedText(_ text: String) { core.replaceSelectedText(text) }
        public func measureForDimensions(width: UInt32, height: UInt32) -> NativeZigTextBufferView.MeasureResult? {
            core.measureForDimensions(width: Int(width), height: Int(height)).map(NativeZigTextBufferView.MeasureResult.init(core:))
        }
    }
}

// MARK: - 7. native/src/audio.zig (58 unmapped symbols)

public enum NativeZigAudio: Sendable {
    // parity: native/src/audio.zig#max_voices [status=implemented hash=1cc40105778e]
    public static let maxVoices: Int = 32
    // parity: native/src/audio.zig#default_sample_rate [status=implemented hash=1cfb080384dc]
    public static let defaultSampleRate: UInt32 = 48_000
    // parity: native/src/audio.zig#default_playback_channels [status=implemented hash=b070441d138b]
    public static let defaultPlaybackChannels: UInt32 = 2
    // parity: native/src/audio.zig#max_capture_channels [status=implemented hash=da807203c85f]
    public static let maxCaptureChannels: UInt32 = 254
    // parity: native/src/audio.zig#default_stream_probe_bytes [status=implemented hash=8e7fd2710111]
    public static let defaultStreamProbeBytes: UInt32 = 1024 * 1024
    // parity: native/src/audio.zig#min_pcm_sample_rate [status=implemented hash=638ec9b58121]
    public static let minPcmSampleRate: UInt32 = 8_000
    // parity: native/src/audio.zig#max_pcm_sample_rate [status=implemented hash=d7b5142ce797]
    public static let maxPcmSampleRate: UInt32 = 192_000
    // parity: native/src/audio.zig#max_stream_pcm_capacity_frames [status=implemented hash=f6b80d373121]
    public static let maxStreamPcmCapacityFrames: UInt32 = (0x7FFF_FFFF - 63) / 8

    // parity: native/src/audio.zig#Status [status=implemented hash=95eae0d57358]
    public enum Status: Sendable {
        public static let ok: Int32 = 0
        public static let errInvalid: Int32 = -1
        public static let errNoSpace: Int32 = -2
        public static let errDecode: Int32 = -3
        public static let errNotFound: Int32 = -4
        public static let errDevice: Int32 = -5
    }

    // parity: native/src/audio.zig#CreateOptions [status=implemented hash=323c3a4414c7]
    public struct CreateOptions: Equatable, Hashable, Sendable {
        public var sampleRate: UInt32
        public var playbackChannels: UInt32

        public init(sampleRate: UInt32 = 48_000, playbackChannels: UInt32 = 2) {
            self.sampleRate = sampleRate
            self.playbackChannels = playbackChannels
        }
    }

    // parity: native/src/audio.zig#StartOptions [status=implemented hash=93b481a7ab24]
    public struct StartOptions: Equatable, Hashable, Sendable {
        public var periodSizeInFrames: UInt32
        public var periodSizeInMilliseconds: UInt32
        public var periods: UInt32
        public var performanceProfile: UInt8
        public var shareMode: UInt8
        public var noPreSilencedOutputBuffer: Bool
        public var noClip: Bool
        public var noDisableDenormals: Bool
        public var noFixedSizedCallback: Bool
        public var wasapiNoAutoConvertSrc: Bool
        public var wasapiNoDefaultQualitySrc: Bool
        public var alsaNoMmap: Bool
        public var alsaNoAutoFormat: Bool
        public var alsaNoAutoChannels: Bool
        public var alsaNoAutoResample: Bool

        public init(
            periodSizeInFrames: UInt32 = 0,
            periodSizeInMilliseconds: UInt32 = 0,
            periods: UInt32 = 0,
            performanceProfile: UInt8 = 0,
            shareMode: UInt8 = 0,
            noPreSilencedOutputBuffer: Bool = false,
            noClip: Bool = false,
            noDisableDenormals: Bool = false,
            noFixedSizedCallback: Bool = false,
            wasapiNoAutoConvertSrc: Bool = false,
            wasapiNoDefaultQualitySrc: Bool = false,
            alsaNoMmap: Bool = false,
            alsaNoAutoFormat: Bool = false,
            alsaNoAutoChannels: Bool = false,
            alsaNoAutoResample: Bool = false
        ) {
            self.periodSizeInFrames = periodSizeInFrames
            self.periodSizeInMilliseconds = periodSizeInMilliseconds
            self.periods = periods
            self.performanceProfile = performanceProfile
            self.shareMode = shareMode
            self.noPreSilencedOutputBuffer = noPreSilencedOutputBuffer
            self.noClip = noClip
            self.noDisableDenormals = noDisableDenormals
            self.noFixedSizedCallback = noFixedSizedCallback
            self.wasapiNoAutoConvertSrc = wasapiNoAutoConvertSrc
            self.wasapiNoDefaultQualitySrc = wasapiNoDefaultQualitySrc
            self.alsaNoMmap = alsaNoMmap
            self.alsaNoAutoFormat = alsaNoAutoFormat
            self.alsaNoAutoChannels = alsaNoAutoChannels
            self.alsaNoAutoResample = alsaNoAutoResample
        }

        public func toCore() -> AudioStartOptions {
            AudioStartOptions(
                periodSizeInFrames: periodSizeInFrames == 0 ? nil : Int(periodSizeInFrames),
                periodSizeInMilliseconds: periodSizeInMilliseconds == 0 ? nil : Int(periodSizeInMilliseconds),
                periods: periods == 0 ? nil : Int(periods),
                performanceProfile: Int(performanceProfile),
                shareMode: Int(shareMode),
                noPreSilencedOutputBuffer: noPreSilencedOutputBuffer,
                noClip: noClip,
                noDisableDenormals: noDisableDenormals,
                noFixedSizedCallback: noFixedSizedCallback,
                wasapiNoAutoConvertSrc: wasapiNoAutoConvertSrc,
                wasapiNoDefaultQualitySrc: wasapiNoDefaultQualitySrc,
                alsaNoMMap: alsaNoMmap,
                alsaNoAutoFormat: alsaNoAutoFormat,
                alsaNoAutoChannels: alsaNoAutoChannels,
                alsaNoAutoResample: alsaNoAutoResample
            )
        }
    }

    // parity: native/src/audio.zig#VoiceOptions [status=implemented hash=175b2bc8f7fe]
    public struct VoiceOptions: Equatable, Hashable, Sendable {
        public var volume: Float
        public var pan: Float
        public var loop: Bool
        public var groupId: UInt32

        public init(volume: Float = 1.0, pan: Float = 0.0, loop: Bool = false, groupId: UInt32 = 0) {
            self.volume = volume
            self.pan = pan
            self.loop = loop
            self.groupId = groupId
        }
    }

    // parity: native/src/audio.zig#StreamFormat [status=implemented hash=366784a50263]
    public enum StreamFormat: Sendable {
        public static let mp3: UInt32 = 1
        public static let flac: UInt32 = 2
        public static let pcm: UInt32 = 3
    }

    // parity: native/src/audio.zig#StreamOptions [status=implemented hash=2500058bd257]
    public struct StreamOptions: Equatable, Hashable, Sendable {
        public var capacityMs: UInt32
        public var startupMs: UInt32
        public var resumeMs: UInt32
        public var volume: Float
        public var pan: Float
        public var groupId: UInt32
        public var maxProbeBytes: UInt32
        public var format: UInt32
        public var sampleRate: UInt32
        public var channels: UInt32

        public init(
            capacityMs: UInt32 = 1000,
            startupMs: UInt32 = 100,
            resumeMs: UInt32 = 100,
            volume: Float = 1.0,
            pan: Float = 0.0,
            groupId: UInt32 = 0,
            maxProbeBytes: UInt32 = 1024 * 1024,
            format: UInt32 = StreamFormat.pcm,
            sampleRate: UInt32 = 48_000,
            channels: UInt32 = 2
        ) {
            self.capacityMs = capacityMs
            self.startupMs = startupMs
            self.resumeMs = resumeMs
            self.volume = volume
            self.pan = pan
            self.groupId = groupId
            self.maxProbeBytes = maxProbeBytes
            self.format = format
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    // parity: native/src/audio.zig#StreamState [status=implemented hash=9420c29d2489]
    public enum StreamState: Sendable {
        public static let initializing: UInt32 = 0
        public static let buffering: UInt32 = 1
        public static let playing: UInt32 = 2
        public static let ended: UInt32 = 3
        public static let failed: UInt32 = 4
        public static let cancelled: UInt32 = 5
        public static let reconnecting: UInt32 = 6
    }

    // parity: native/src/audio.zig#StreamStats [status=implemented hash=b4e12a2c88f5]
    public struct StreamStats: Equatable, Hashable, Sendable {
        public var bytesReceived: UInt64
        public var framesDecoded: UInt64
        public var framesPlayed: UInt64
        public var state: UInt32
        public var sampleRate: UInt32
        public var channels: UInt32
        public var bufferedFrames: UInt32
        public var capacityFrames: UInt32
        public var underruns: UInt32
        public var errorCode: Int32
        public var readyGeneration: UInt32

        public init(
            bytesReceived: UInt64 = 0,
            framesDecoded: UInt64 = 0,
            framesPlayed: UInt64 = 0,
            state: UInt32 = StreamState.initializing,
            sampleRate: UInt32 = 48_000,
            channels: UInt32 = 2,
            bufferedFrames: UInt32 = 0,
            capacityFrames: UInt32 = 0,
            underruns: UInt32 = 0,
            errorCode: Int32 = 0,
            readyGeneration: UInt32 = 0
        ) {
            self.bytesReceived = bytesReceived
            self.framesDecoded = framesDecoded
            self.framesPlayed = framesPlayed
            self.state = state
            self.sampleRate = sampleRate
            self.channels = channels
            self.bufferedFrames = bufferedFrames
            self.capacityFrames = capacityFrames
            self.underruns = underruns
            self.errorCode = errorCode
            self.readyGeneration = readyGeneration
        }
    }

    // parity: native/src/audio.zig#StreamCloseReason [status=implemented hash=53b25fc57734]
    public enum StreamCloseReason: Sendable {
        public static let preserveNativeTerminal: UInt32 = 0
        public static let transportError: UInt32 = 1
        public static let disposed: UInt32 = 2
    }

    // parity: native/src/audio.zig#Stats [status=implemented hash=f7f0c8cdc883]
    public struct Stats: Equatable, Sendable {
        public var soundsLoaded: UInt32
        public var voicesActive: UInt32
        public var framesMixed: UInt64
        public var lockMisses: UInt32
        public var lastPeak: Float
        public var lastRms: Float

        public init(
            soundsLoaded: UInt32 = 0,
            voicesActive: UInt32 = 0,
            framesMixed: UInt64 = 0,
            lockMisses: UInt32 = 0,
            lastPeak: Float = 0,
            lastRms: Float = 0
        ) {
            self.soundsLoaded = soundsLoaded
            self.voicesActive = voicesActive
            self.framesMixed = framesMixed
            self.lockMisses = lockMisses
            self.lastPeak = lastPeak
            self.lastRms = lastRms
        }
    }

    // parity: native/src/audio.zig#CaptureStats [status=implemented hash=60db1cd215f0]
    public struct CaptureStats: Equatable, Hashable, Sendable {
        public var framesReceived: UInt64
        public var framesRead: UInt64
        public var framesDropped: UInt64
        public var sampleRate: UInt32
        public var channels: UInt32
        public var bufferedFrames: UInt32
        public var capacityFrames: UInt32

        public init(
            framesReceived: UInt64 = 0,
            framesRead: UInt64 = 0,
            framesDropped: UInt64 = 0,
            sampleRate: UInt32 = 48_000,
            channels: UInt32 = 2,
            bufferedFrames: UInt32 = 0,
            capacityFrames: UInt32 = 0
        ) {
            self.framesReceived = framesReceived
            self.framesRead = framesRead
            self.framesDropped = framesDropped
            self.sampleRate = sampleRate
            self.channels = channels
            self.bufferedFrames = bufferedFrames
            self.capacityFrames = capacityFrames
        }
    }

    // parity: native/src/audio.zig#CaptureBuffer [status=implemented hash=8ab68451814e]
    public final class CaptureBuffer: @unchecked Sendable {
        public let sampleRate: UInt32
        public let channels: UInt32
        public let capacityFrames: UInt32
        private var ring: [Float]
        private var readPos: Int = 0
        private var writePos: Int = 0
        private var buffered: Int = 0
        private var framesReceived: UInt64 = 0
        private var framesRead: UInt64 = 0
        private var framesDropped: UInt64 = 0

        // parity: native/src/audio.zig#CaptureBuffer.create [status=implemented hash=7c17c45c568a]
        public init(sampleRate: UInt32, channels: UInt32, capacityFrames: UInt32) {
            self.sampleRate = max(1, sampleRate)
            self.channels = max(1, channels)
            self.capacityFrames = max(1, capacityFrames)
            self.ring = Array(repeating: 0, count: Int(self.capacityFrames) * Int(self.channels))
        }

        // parity: native/src/audio.zig#CaptureBuffer.destroy [status=implemented hash=960a61a50eb0]
        public func destroy() {
            ring.removeAll(keepingCapacity: false)
            readPos = 0
            writePos = 0
            buffered = 0
        }

        // parity: native/src/audio.zig#CaptureBuffer.write [status=implemented hash=320b3dfac17a]
        public func write(_ input: [Float], frameCount: UInt32) {
            let ch = Int(channels)
            let cap = Int(capacityFrames)
            let count = min(Int(frameCount), input.count / ch)
            framesReceived &+= UInt64(count)
            for f in 0..<count {
                if buffered >= cap {
                    readPos = (readPos + 1) % cap
                    buffered -= 1
                    framesDropped &+= 1
                }
                for c in 0..<ch {
                    ring[writePos * ch + c] = input[f * ch + c]
                }
                writePos = (writePos + 1) % cap
                buffered += 1
            }
        }

        // parity: native/src/audio.zig#CaptureBuffer.read [status=implemented hash=e09fdf558d2b]
        public func read(frameCount: UInt32) -> [Float] {
            let ch = Int(channels)
            let cap = Int(capacityFrames)
            let toRead = min(Int(frameCount), buffered)
            var out: [Float] = []
            out.reserveCapacity(toRead * ch)
            for _ in 0..<toRead {
                for c in 0..<ch {
                    out.append(ring[readPos * ch + c])
                }
                readPos = (readPos + 1) % cap
                buffered -= 1
            }
            framesRead &+= UInt64(toRead)
            return out
        }

        // parity: native/src/audio.zig#CaptureBuffer.snapshot [status=implemented hash=694c7075e8e8]
        public func snapshot() -> CaptureStats {
            CaptureStats(
                framesReceived: framesReceived,
                framesRead: framesRead,
                framesDropped: framesDropped,
                sampleRate: sampleRate,
                channels: channels,
                bufferedFrames: UInt32(buffered),
                capacityFrames: capacityFrames
            )
        }
    }

    internal struct StreamSlot: Sendable {
        var id: UInt32
        var options: StreamOptions
        var stats: StreamStats
        var volume: Float
        var pan: Float
        var groupId: UInt32
        var pcmQueue: [Float] = []
        var ended: Bool = false
    }

    // parity: native/src/audio.zig#Engine [status=implemented hash=fb71786dc4ed]
    public final class Engine: @unchecked Sendable {
        public let core: AudioEngine
        fileprivate var streams: [UInt32: StreamSlot] = [:]
        fileprivate var nextStreamId: UInt32 = 1
        fileprivate var voiceSlots: [UInt32] = []
        fileprivate var playbackDevices: [AudioPlaybackDevice] = []
        fileprivate var captureDevices: [AudioCaptureDevice] = []
        fileprivate var mixerSuspended: Bool = false
        fileprivate var disposed: Bool = false

        // parity: native/src/audio.zig#Engine.init [status=implemented hash=a2b3aa69666d]
        public init(options: CreateOptions = CreateOptions()) {
            self.core = AudioEngine(
                options: AudioSetupOptions(
                    autoStart: false,
                    sampleRate: Int(options.sampleRate),
                    playbackChannels: Int(options.playbackChannels)
                )
            )
            self.playbackDevices = core.listPlaybackDevices() ?? []
            self.captureDevices = core.listCaptureDevices() ?? []
        }

        // parity: native/src/audio.zig#Engine.deinit [status=implemented hash=00d5c7b25ff8]
        deinit {
            disposed = true
            streams.removeAll(keepingCapacity: false)
            voiceSlots.removeAll(keepingCapacity: false)
            core.dispose()
        }
    }

    // parity: native/src/audio.zig#create [status=implemented hash=4c0af1dff4de]
    public static func create(options: CreateOptions? = nil) -> Engine {
        Engine(options: options ?? CreateOptions())
    }

    // parity: native/src/audio.zig#destroy [status=implemented hash=d6b0bdd190ef]
    public static func destroy(_ engine: Engine) {
        engine.disposed = true
        engine.streams.removeAll()
        engine.voiceSlots.removeAll()
        engine.core.dispose()
    }

    // parity: native/src/audio.zig#refreshPlaybackDevices [status=implemented hash=6959fdb36fc3]
    public static func refreshPlaybackDevices(_ engine: Engine) -> Int32 {
        guard !engine.disposed else { return Status.errInvalid }
        engine.playbackDevices = engine.core.listPlaybackDevices() ?? []
        return Status.ok
    }

    // parity: native/src/audio.zig#getPlaybackDeviceCount [status=implemented hash=49845893fc5e]
    public static func getPlaybackDeviceCount(_ engine: Engine) -> UInt32 {
        UInt32(engine.playbackDevices.count)
    }

    // parity: native/src/audio.zig#getPlaybackDeviceName [status=implemented hash=3c88f2661fbf]
    public static func getPlaybackDeviceName(_ engine: Engine, index: UInt32) -> String? {
        let i = Int(index)
        guard i >= 0 && i < engine.playbackDevices.count else { return nil }
        return engine.playbackDevices[i].name
    }

    // parity: native/src/audio.zig#isPlaybackDeviceDefault [status=implemented hash=35709aec084c]
    public static func isPlaybackDeviceDefault(_ engine: Engine, index: UInt32) -> Bool {
        let i = Int(index)
        guard i >= 0 && i < engine.playbackDevices.count else { return false }
        return engine.playbackDevices[i].isDefault
    }

    // parity: native/src/audio.zig#selectPlaybackDevice [status=implemented hash=0d6f84df367b]
    public static func selectPlaybackDevice(_ engine: Engine, index: UInt32) -> Int32 {
        engine.core.selectPlaybackDevice(Int(index)) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#clearPlaybackDeviceSelection [status=implemented hash=0ad24f732556]
    public static func clearPlaybackDeviceSelection(_ engine: Engine) {
        engine.core.clearPlaybackDeviceSelection()
    }

    // parity: native/src/audio.zig#refreshCaptureDevices [status=implemented hash=0ecd17a4024c]
    public static func refreshCaptureDevices(_ engine: Engine) -> Int32 {
        guard !engine.disposed else { return Status.errInvalid }
        engine.captureDevices = engine.core.listCaptureDevices() ?? []
        return Status.ok
    }

    // parity: native/src/audio.zig#getCaptureDeviceCount [status=implemented hash=a4c1a1caeb99]
    public static func getCaptureDeviceCount(_ engine: Engine) -> UInt32 {
        UInt32(engine.captureDevices.count)
    }

    // parity: native/src/audio.zig#getCaptureDeviceName [status=implemented hash=77a0c32158ad]
    public static func getCaptureDeviceName(_ engine: Engine, index: UInt32) -> String? {
        let i = Int(index)
        guard i >= 0 && i < engine.captureDevices.count else { return nil }
        return engine.captureDevices[i].name
    }

    // parity: native/src/audio.zig#isCaptureDeviceDefault [status=implemented hash=f49cd7de25b5]
    public static func isCaptureDeviceDefault(_ engine: Engine, index: UInt32) -> Bool {
        let i = Int(index)
        guard i >= 0 && i < engine.captureDevices.count else { return false }
        return engine.captureDevices[i].isDefault
    }

    // parity: native/src/audio.zig#selectCaptureDevice [status=implemented hash=8cc60b8d20a4]
    public static func selectCaptureDevice(_ engine: Engine, index: UInt32) -> Int32 {
        engine.core.selectCaptureDevice(Int(index)) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#clearCaptureDeviceSelection [status=implemented hash=b50c6df0055b]
    public static func clearCaptureDeviceSelection(_ engine: Engine) {
        engine.core.clearCaptureDeviceSelection()
    }

    // parity: native/src/audio.zig#isCaptureRunning [status=implemented hash=9a3da8298f05]
    public static func isCaptureRunning(_ engine: Engine) -> Bool {
        engine.core.isCapturing()
    }

    // parity: native/src/audio.zig#startCapture [status=implemented hash=ed5afeb42dd4]
    public static func startCapture(
        _ engine: Engine,
        channels: UInt32 = 1,
        capacityFrames: UInt32 = 8192,
        options: StartOptions? = nil
    ) -> Int32 {
        let opts = AudioCaptureOptions(
            channels: Int(channels),
            capacityFrames: Int(capacityFrames),
            startOptions: options?.toCore()
        )
        return engine.core.startCapture(opts) ? Status.ok : Status.errDevice
    }

    // parity: native/src/audio.zig#stopCapture [status=implemented hash=1035cf6b0442]
    public static func stopCapture(_ engine: Engine) -> Int32 {
        engine.core.stopCapture() ? Status.ok : Status.errInvalid
    }

    // parity: native/src/audio.zig#readCapture [status=implemented hash=76e4bf07cd21]
    public static func readCapture(_ engine: Engine, frameCount: UInt32) -> (status: Int32, samples: [Float], framesRead: UInt32) {
        guard let result = engine.core.readCaptureFrames(Int(frameCount)) else {
            return (Status.errInvalid, [], 0)
        }
        return (Status.ok, result.frames, UInt32(max(0, result.framesRead)))
    }

    // parity: native/src/audio.zig#getCaptureStats [status=implemented hash=45bbdccfbd42]
    public static func getCaptureStats(_ engine: Engine) -> (status: Int32, stats: CaptureStats?) {
        guard let s = engine.core.getCaptureStats() else {
            return (Status.errInvalid, nil)
        }
        return (
            Status.ok,
            CaptureStats(
                framesReceived: s.framesReceived,
                framesRead: s.framesRead,
                framesDropped: s.framesDropped,
                sampleRate: UInt32(max(0, s.sampleRate)),
                channels: UInt32(max(0, s.channels)),
                bufferedFrames: UInt32(max(0, s.bufferedFrames)),
                capacityFrames: UInt32(max(0, s.capacityFrames))
            )
        )
    }

    // parity: native/src/audio.zig#start [status=implemented hash=fc8aaddbabec]
    public static func start(_ engine: Engine, options: StartOptions? = nil) -> Int32 {
        engine.mixerSuspended = false
        return engine.core.start(options?.toCore()) ? Status.ok : Status.errDevice
    }

    // parity: native/src/audio.zig#startMixer [status=implemented hash=e3a633a7ec12]
    public static func startMixer(_ engine: Engine) -> Int32 {
        engine.mixerSuspended = false
        return engine.core.startMixer() ? Status.ok : Status.errDevice
    }

    // parity: native/src/audio.zig#suspendMixer [status=implemented hash=13e7b2963fab]
    public static func suspendMixer(_ engine: Engine) {
        engine.mixerSuspended = true
    }

    // parity: native/src/audio.zig#stop [status=implemented hash=609d225427a2]
    public static func stop(_ engine: Engine) -> Int32 {
        engine.core.stop() ? Status.ok : Status.errInvalid
    }

    // parity: native/src/audio.zig#voiceSlotIndex [status=implemented hash=695e6ebaf311]
    public static func voiceSlotIndex(_ engine: Engine, voiceId: UInt32) -> Int? {
        engine.voiceSlots.firstIndex(of: voiceId)
    }

    // parity: native/src/audio.zig#createStream [status=implemented hash=917e77672d66]
    public static func createStream(_ engine: Engine, options: StreamOptions = StreamOptions()) -> (status: Int32, streamId: UInt32) {
        guard !engine.disposed else { return (Status.errInvalid, 0) }
        let id = engine.nextStreamId
        engine.nextStreamId &+= 1
        let sr = options.sampleRate > 0 ? options.sampleRate : UInt32(engine.core.sampleRate)
        let ch = options.channels > 0 ? options.channels : UInt32(engine.core.playbackChannels)
        let capFrames = max(1, UInt32((UInt64(sr) * UInt64(max(1, options.capacityMs))) / 1000))
        let stats = StreamStats(
            state: StreamState.buffering,
            sampleRate: sr,
            channels: ch,
            bufferedFrames: 0,
            capacityFrames: capFrames
        )
        engine.streams[id] = StreamSlot(
            id: id,
            options: options,
            stats: stats,
            volume: options.volume,
            pan: options.pan,
            groupId: options.groupId
        )
        return (Status.ok, id)
    }

    // parity: native/src/audio.zig#writeStream [status=implemented hash=01cae06c748b]
    public static func writeStream(_ engine: Engine, streamId: UInt32, data: [UInt8]) -> (status: Int32, written: Int) {
        guard var slot = engine.streams[streamId] else { return (Status.errNotFound, 0) }
        slot.stats.bytesReceived &+= UInt64(data.count)
        let ch = max(1, Int(slot.stats.channels))
        if slot.options.format == StreamFormat.pcm {
            let floats = PCMConverter.bytesLEToFloat32(data)
            slot.pcmQueue.append(contentsOf: floats)
            let frames = floats.count / ch
            slot.stats.framesDecoded &+= UInt64(frames)
            slot.stats.bufferedFrames = UInt32(slot.pcmQueue.count / ch)
            if slot.stats.bufferedFrames > 0 {
                slot.stats.state = StreamState.playing
            }
        } else if !data.isEmpty {
            slot.stats.state = StreamState.playing
        }
        engine.streams[streamId] = slot
        return (Status.ok, data.count)
    }

    // parity: native/src/audio.zig#endStream [status=implemented hash=0b9e16bff64b]
    public static func endStream(_ engine: Engine, streamId: UInt32) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.ended = true
        slot.stats.state = StreamState.ended
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#restartStream [status=implemented hash=bc71af500028]
    public static func restartStream(_ engine: Engine, streamId: UInt32) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.pcmQueue.removeAll()
        slot.ended = false
        slot.stats.bufferedFrames = 0
        slot.stats.state = StreamState.buffering
        slot.stats.readyGeneration &+= 1
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#setStreamVolume [status=implemented hash=cbf7f7bdce87]
    public static func setStreamVolume(_ engine: Engine, streamId: UInt32, volume: Float) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.volume = max(0, volume)
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#setStreamPan [status=implemented hash=f9cd419996de]
    public static func setStreamPan(_ engine: Engine, streamId: UInt32, pan: Float) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.pan = min(1, max(-1, pan))
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#setStreamGroup [status=implemented hash=9422f678d447]
    public static func setStreamGroup(_ engine: Engine, streamId: UInt32, groupId: UInt32) -> Int32 {
        guard var slot = engine.streams[streamId] else { return Status.errNotFound }
        slot.groupId = groupId
        engine.streams[streamId] = slot
        return Status.ok
    }

    // parity: native/src/audio.zig#getStreamStats [status=implemented hash=552d9f255987]
    public static func getStreamStats(_ engine: Engine, streamId: UInt32) -> (status: Int32, stats: StreamStats?) {
        guard let slot = engine.streams[streamId] else { return (Status.errNotFound, nil) }
        return (Status.ok, slot.stats)
    }

    // parity: native/src/audio.zig#closeStream [status=implemented hash=593dcc74733a]
    public static func closeStream(_ engine: Engine, streamId: UInt32, reason: UInt32 = StreamCloseReason.disposed) -> (status: Int32, finalStats: StreamStats?) {
        guard var slot = engine.streams.removeValue(forKey: streamId) else {
            return (Status.errNotFound, nil)
        }
        if reason == StreamCloseReason.transportError {
            slot.stats.state = StreamState.failed
        } else if reason == StreamCloseReason.disposed && slot.stats.state != StreamState.ended {
            slot.stats.state = StreamState.cancelled
        }
        return (Status.ok, slot.stats)
    }

    // parity: native/src/audio.zig#load [status=implemented hash=d9542d79e930]
    public static func load(_ engine: Engine, data: [UInt8]) -> (status: Int32, soundId: UInt32) {
        guard let sound = engine.core.loadSound(data) else {
            return (Status.errDecode, 0)
        }
        return (Status.ok, sound)
    }

    // parity: native/src/audio.zig#unload [status=implemented hash=4ff7e98d63e2]
    public static func unload(_ engine: Engine, soundId: UInt32) -> Int32 {
        engine.core.unloadSound(soundId) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#createGroup [status=implemented hash=19b14e44e6fb]
    public static func createGroup(_ engine: Engine, name: String) -> (status: Int32, groupId: UInt32) {
        guard let id = engine.core.group(name) else {
            return (Status.errInvalid, 0)
        }
        return (Status.ok, id)
    }

    // parity: native/src/audio.zig#play [status=implemented hash=d5ff4a953d31]
    public static func play(_ engine: Engine, soundId: UInt32, options: VoiceOptions = VoiceOptions()) -> (status: Int32, voiceId: UInt32) {
        let playOpts = AudioPlayOptions(
            volume: Double(options.volume),
            pan: Double(options.pan),
            loop: options.loop,
            groupId: options.groupId == 0 ? nil : options.groupId
        )
        guard let voice = engine.core.play(soundId, options: playOpts) else {
            return (Status.errNotFound, 0)
        }
        if !engine.voiceSlots.contains(voice) {
            engine.voiceSlots.append(voice)
        }
        return (Status.ok, voice)
    }

    // parity: native/src/audio.zig#stopVoice [status=implemented hash=2d24fd8c99cd]
    public static func stopVoice(_ engine: Engine, voiceId: UInt32) -> Int32 {
        engine.voiceSlots.removeAll { $0 == voiceId }
        return engine.core.stopVoice(voiceId) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#setVoiceGroup [status=implemented hash=63e25792b55e]
    public static func setVoiceGroup(_ engine: Engine, voiceId: UInt32, groupId: UInt32) -> Int32 {
        engine.core.setVoiceGroup(voiceId, group: groupId) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#setGroupVolume [status=implemented hash=d08702d7a838]
    public static func setGroupVolume(_ engine: Engine, groupId: UInt32, volume: Float) -> Int32 {
        engine.core.setGroupVolume(groupId, volume: Double(volume)) ? Status.ok : Status.errNotFound
    }

    // parity: native/src/audio.zig#setMasterVolume [status=implemented hash=dc888a8089ae]
    public static func setMasterVolume(_ engine: Engine, volume: Float) -> Int32 {
        engine.core.setMasterVolume(Double(volume)) ? Status.ok : Status.errInvalid
    }

    // parity: native/src/audio.zig#enableTap [status=implemented hash=02df1edd6f46]
    public static func enableTap(_ engine: Engine, enabled: Bool, capacityFrames: UInt32 = 8192) -> Int32 {
        let ok = enabled
            ? engine.core.enableTap(capacityFrames: Int(capacityFrames))
            : engine.core.disableTap()
        return ok ? Status.ok : Status.errInvalid
    }

    // parity: native/src/audio.zig#readTap [status=implemented hash=d658b438a863]
    public static func readTap(_ engine: Engine, frameCount: UInt32, channels: UInt8 = 2) -> (status: Int32, samples: [Float], framesRead: UInt32) {
        guard let result = engine.core.readTapFrames(Int(frameCount), channels: Int(channels)) else {
            return (Status.errInvalid, [], 0)
        }
        return (Status.ok, result.frames, UInt32(max(0, result.framesRead)))
    }

    // parity: native/src/audio.zig#mixToBuffer [status=implemented hash=8d7bfb474389]
    public static func mixToBuffer(_ engine: Engine, frameCount: UInt32, channels: UInt8 = 2) -> (status: Int32, samples: [Float]) {
        guard !engine.mixerSuspended else {
            return (Status.ok, Array(repeating: 0, count: Int(frameCount) * Int(channels)))
        }
        guard let mixed = engine.core.mixFrames(Int(frameCount), channels: Int(channels)) else {
            return (Status.errInvalid, [])
        }
        return (Status.ok, mixed)
    }

    // parity: native/src/audio.zig#getStats [status=implemented hash=c2167663b419]
    public static func getStats(_ engine: Engine) -> (status: Int32, stats: Stats?) {
        guard let s = engine.core.getStats() else {
            return (Status.errInvalid, nil)
        }
        return (
            Status.ok,
            Stats(
                soundsLoaded: UInt32(max(0, s.soundsLoaded)),
                voicesActive: UInt32(max(0, s.voicesActive)),
                framesMixed: s.framesMixed,
                lockMisses: UInt32(max(0, s.lockMisses)),
                lastPeak: s.lastPeak,
                lastRms: s.lastRms
            )
        )
    }
}

// MARK: - 8. native/src/image.zig (37 unmapped symbols)

public enum NativeZigImage: Sendable {
    // parity: native/src/image.zig#Status [status=implemented hash=dad504dad748]
    public enum Status: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case ok = 0
        case invalidHandle = 1
        case unsupportedFormat = 2
        case unsupportedColorSpace = 3
        case malformedInput = 4
        case dimensionLimit = 5
        case memoryLimit = 6
        case invalidArgument = 7
        case outOfMemory = 8
        case outputTooSmall = 9
        case internalError = 10
        case unsupportedFeature = 11
        case busy = 12
    }

    // parity: native/src/image.zig#Format [status=implemented hash=92be84a6cc6b]
    public enum Format: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case unknown = 0
        case png = 1
        case rawRgba = 2
        case jpeg = 3
        case webp = 4
        case gif = 5

        public init(core: ImageFormat) {
            switch core {
            case .png: self = .png
            case .rawRgba: self = .rawRgba
            case .jpeg: self = .jpeg
            case .webp: self = .webp
            case .gif: self = .gif
            case .bmp, .ppm: self = .unknown
            }
        }
    }

    // parity: native/src/image.zig#ColorStatus [status=implemented hash=51f06dffef29]
    public enum ColorStatus: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case assumedSRGB = 0
        case explicitSRGB = 1

        public init(core: ImageColorStatus) {
            self = core == .explicitSrgb ? .explicitSRGB : .assumedSRGB
        }
    }

    // parity: native/src/image.zig#PixelFormat [status=implemented hash=b5b34345f305]
    public enum PixelFormat: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case rgba8 = 0
        case bgra8 = 1

        public var coreValue: OpenTUICore.PixelFormat {
            self == .rgba8 ? .rgba8 : .bgra8
        }
    }

    // parity: native/src/image.zig#PixelAlpha [status=implemented hash=c6216317e90d]
    public enum PixelAlpha: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case straight = 0
        case opaque = 1

        public var coreValue: PixelAlphaMode {
            self == .straight ? .straight : .opaque
        }
    }

    // parity: native/src/image.zig#PixelImportOptions [status=implemented hash=0b22237ddcb6]
    public struct PixelImportOptions: Equatable, Hashable, Sendable {
        public var stride: UInt32
        public var format: PixelFormat
        public var alpha: PixelAlpha

        public init(stride: UInt32, format: PixelFormat = .rgba8, alpha: PixelAlpha = .straight) {
            self.stride = stride
            self.format = format
            self.alpha = alpha
        }
    }

    // parity: native/src/image.zig#Info [status=implemented hash=097aa3d6d3ed]
    public struct Info: Equatable, Hashable, Sendable {
        public var width: UInt32
        public var height: UInt32
        public var sourceWidth: UInt32
        public var sourceHeight: UInt32
        public var format: Format
        public var colorStatus: ColorStatus
        public var orientation: UInt32
        public var hasAlpha: UInt32

        public init(
            width: UInt32 = 0,
            height: UInt32 = 0,
            sourceWidth: UInt32 = 0,
            sourceHeight: UInt32 = 0,
            format: Format = .unknown,
            colorStatus: ColorStatus = .assumedSRGB,
            orientation: UInt32 = 1,
            hasAlpha: UInt32 = 0
        ) {
            self.width = width
            self.height = height
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.format = format
            self.colorStatus = colorStatus
            self.orientation = orientation
            self.hasAlpha = hasAlpha
        }

        public init(core: ImageInfo) {
            self.width = UInt32(max(0, core.width))
            self.height = UInt32(max(0, core.height))
            self.sourceWidth = UInt32(max(0, core.sourceWidth))
            self.sourceHeight = UInt32(max(0, core.sourceHeight))
            self.format = Format(core: core.format)
            self.colorStatus = ColorStatus(core: core.colorStatus)
            self.orientation = UInt32(max(1, core.orientation))
            self.hasAlpha = core.hasAlpha ? 1 : 0
        }
    }

    // parity: native/src/image.zig#Limits [status=implemented hash=13f36fc09a7f]
    public struct Limits: Equatable, Hashable, Sendable {
        public var maxEncodedBytes: UInt64
        public var maxWidth: UInt32
        public var maxHeight: UInt32
        public var maxPixels: UInt64
        public var maxDecodedBytes: UInt64

        public init(
            maxEncodedBytes: UInt64 = 64 * 1024 * 1024,
            maxWidth: UInt32 = 16_384,
            maxHeight: UInt32 = 16_384,
            maxPixels: UInt64 = 25_000_000,
            maxDecodedBytes: UInt64 = 100 * 1024 * 1024
        ) {
            self.maxEncodedBytes = maxEncodedBytes
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
            self.maxPixels = maxPixels
            self.maxDecodedBytes = maxDecodedBytes
        }
    }

    // parity: native/src/image.zig#ResizeFilter [status=implemented hash=6927b29c7123]
    public enum ResizeFilter: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case `default` = 0
        case area = 1
        case triangle = 2
        case cubicBSpline = 3
        case catmullRom = 4
        case mitchell = 5
        case nearest = 6

        public var coreValue: ResizeKernel {
            switch self {
            case .default: return .default
            case .area: return .area
            case .triangle: return .triangle
            case .cubicBSpline: return .cubicBspline
            case .catmullRom: return .catmullRom
            case .mitchell: return .mitchell
            case .nearest: return .nearest
            }
        }
    }

    // parity: native/src/image.zig#Transform [status=implemented hash=a9c6bd2e2e05]
    public enum Transform: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case rotate90 = 0
        case rotate180 = 1
        case rotate270 = 2
        case flip = 3
        case flop = 4
    }

    // parity: native/src/image.zig#Blend [status=implemented hash=44927f5d9646]
    public enum Blend: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case sourceOver = 0
        case source = 1
        case destinationOver = 2

        public var coreValue: BlendMode {
            switch self {
            case .sourceOver: return .sourceOver
            case .source: return .source
            case .destinationOver: return .destinationOver
            }
        }
    }

    // parity: native/src/image.zig#RenderProtocol [status=implemented hash=471e6d79a171]
    public enum RenderProtocol: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case auto = 0
        case kitty = 1
        case sixel = 2
        case blocks = 3
    }

    // parity: native/src/image.zig#Fit [status=implemented hash=734260e7966a]
    public enum Fit: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case fit = 0
        case cover = 1
        case fill = 2
    }

    // parity: native/src/image.zig#Region [status=implemented hash=734f9a8e3d62]
    public struct Region: Equatable, Hashable, Sendable {
        public var left: UInt32
        public var top: UInt32
        public var width: UInt32
        public var height: UInt32

        public init(left: UInt32 = 0, top: UInt32 = 0, width: UInt32, height: UInt32) {
            self.left = left
            self.top = top
            self.width = width
            self.height = height
        }

        // parity: native/src/image.zig#Region.inside [status=implemented hash=41d9946aa088]
        public static func inside(_ crop: Region?, width: UInt32, height: UInt32) -> Region? {
            guard let crop else { return nil }
            guard crop.width > 0, crop.height > 0 else { return nil }
            guard UInt64(crop.left) + UInt64(crop.width) <= UInt64(width),
                  UInt64(crop.top) + UInt64(crop.height) <= UInt64(height)
            else {
                return nil
            }
            return crop
        }
    }

    // parity: native/src/image.zig#Image [status=implemented hash=e245061cd318]
    public final class Image: @unchecked Sendable {
        public private(set) var core: NativeImage
        public var ownerContextId: UInt64 = 0
        public var renderId: UInt32 = 0
        public private(set) var refCount: UInt32 = 1
        private var cachedEncodedPng: [UInt8]? = nil

        public init(core: NativeImage) {
            self.core = core
        }

        // parity: native/src/image.zig#Image.width [status=implemented hash=90c58632d1f4]
        public var width: UInt32 { UInt32(max(0, core.width)) }
        // parity: native/src/image.zig#Image.height [status=implemented hash=26e312c718d3]
        public var height: UInt32 { UInt32(max(0, core.height)) }
        public var pixels: [UInt8] { core.rgbaBytes }

        // parity: native/src/image.zig#Image.retain [status=implemented hash=cf25aaf3c3f3]
        public func retain() { refCount &+= 1 }

        // parity: native/src/image.zig#Image.deinit [status=implemented hash=79f168461998]
        public func release() {
            if refCount > 1 {
                refCount -= 1
            } else {
                refCount = 0
                cachedEncodedPng = nil
                core.dispose()
            }
        }

        // parity: native/src/image.zig#Image.info [status=implemented hash=a18f81a306a0]
        public func info() -> Info {
            if let coreInfo = try? core.info() {
                return Info(core: coreInfo)
            }
            return Info(width: width, height: height, sourceWidth: width, sourceHeight: height, format: .rawRgba, hasAlpha: 1)
        }

        // parity: native/src/image.zig#Image.discardEncoded [status=implemented hash=28ca334d83bb]
        public func discardEncoded() {
            cachedEncodedPng = nil
        }

        // parity: native/src/image.zig#Image.clone [status=implemented hash=6cc843b9242a]
        public func clone() throws(ImageError) -> Image {
            Image(core: try core.clone())
        }

        // parity: native/src/image.zig#Image.cloneOwned [status=implemented hash=7f08ebd097a7]
        public func cloneOwned(ownerContextId owner: UInt64 = 0) throws(ImageError) -> Image {
            let copy = try clone()
            copy.ownerContextId = owner
            return copy
        }

        // parity: native/src/image.zig#Image.ensurePixels [status=implemented hash=454e1cb2a7f0]
        public func ensurePixels() throws(ImageError) -> [UInt8] {
            guard !core.isDisposed else {
                throw ImageError(code: .invalidHandle, message: "Image has been disposed")
            }
            return core.rgbaBytes
        }

        // parity: native/src/image.zig#Image.ensureEncodedPng [status=implemented hash=480f37df5bf8]
        public func ensureEncodedPng() throws(ImageError) -> [UInt8] {
            if let cached = cachedEncodedPng {
                return cached
            }
            let encoded = try core.encodePNG()
            cachedEncodedPng = encoded
            return encoded
        }

        internal func replaceCore(_ newCore: NativeImage) {
            self.core = newCore
            self.cachedEncodedPng = nil
        }
    }

    // parity: native/src/image.zig#dimensionsWithinLimits [status=implemented hash=1553b7c2c598]
    public static func dimensionsWithinLimits(width: UInt32, height: UInt32, limits: Limits = Limits()) -> Bool {
        guard width > 0 && height > 0 else { return false }
        guard width <= limits.maxWidth && height <= limits.maxHeight else { return false }
        let pixels = UInt64(width) * UInt64(height)
        guard pixels <= limits.maxPixels else { return false }
        return pixels * 4 <= limits.maxDecodedBytes
    }

    // parity: native/src/image.zig#statusFromError [status=implemented hash=c7c97f6d2d90]
    public static func statusFromError(_ error: any Error) -> Status {
        if let imgErr = error as? ImageError {
            switch imgErr.code {
            case .invalidHandle: return .invalidHandle
            case .unsupportedFormat: return .unsupportedFormat
            case .unsupportedColorSpace: return .unsupportedColorSpace
            case .malformedData: return .malformedInput
            case .dimensionLimit: return .dimensionLimit
            case .memoryLimit: return .memoryLimit
            case .invalidArgument: return .invalidArgument
            case .outOfMemory: return .outOfMemory
            case .outputTooSmall: return .outputTooSmall
            case .internalError: return .internalError
            case .unsupportedFeature: return .unsupportedFeature
            case .busy: return .busy
            }
        }
        return .internalError
    }

    // parity: native/src/image.zig#errorFromStatus [status=implemented hash=d2085e9e9ac3]
    public static func errorFromStatus(_ status: Status) throws(ImageError) {
        switch status {
        case .ok: return
        case .invalidHandle: throw ImageError(code: .invalidHandle, message: "invalid image handle")
        case .unsupportedFormat: throw ImageError(code: .unsupportedFormat, message: "unsupported image format")
        case .unsupportedColorSpace: throw ImageError(code: .unsupportedColorSpace, message: "unsupported color space")
        case .malformedInput: throw ImageError(code: .malformedData, message: "malformed image data")
        case .dimensionLimit: throw ImageError(code: .dimensionLimit, message: "image dimension limit exceeded")
        case .memoryLimit: throw ImageError(code: .memoryLimit, message: "image memory limit exceeded")
        case .invalidArgument: throw ImageError(code: .invalidArgument, message: "invalid image argument")
        case .outOfMemory: throw ImageError(code: .outOfMemory, message: "out of memory")
        case .outputTooSmall: throw ImageError(code: .outputTooSmall, message: "image output buffer too small")
        case .internalError: throw ImageError(code: .internalError, message: "internal image error")
        case .unsupportedFeature: throw ImageError(code: .unsupportedFeature, message: "unsupported image feature")
        case .busy: throw ImageError(code: .busy, message: "image is busy")
        }
    }

    // parity: native/src/image.zig#IccCacheStats [status=implemented hash=a8e6aa99a49b]
    public struct IccCacheStats: Equatable, Hashable, Sendable {
        public var hits: UInt64
        public var misses: UInt64
        public var entries: UInt32

        public init(hits: UInt64 = 0, misses: UInt64 = 0, entries: UInt32 = 0) {
            self.hits = hits
            self.misses = misses
            self.entries = entries
        }
    }

    private struct IccCacheState: Sendable {
        var hits: UInt64 = 0
        var misses: UInt64 = 0
        var entries: UInt32 = 0
        var retainCount: UInt32 = 0
        var failCopyOnce: Bool = false
    }

    private static let iccCache = Mutex(IccCacheState())

    // parity: native/src/image.zig#clearIccCache [status=implemented hash=3a69c3702dcf]
    public static func clearIccCache() {
        iccCache.withLock { state in
            state.hits = 0
            state.misses = 0
            state.entries = 0
        }
    }

    // parity: native/src/image.zig#retainIccCache [status=implemented hash=267bad509668]
    public static func retainIccCache() {
        iccCache.withLock { $0.retainCount &+= 1 }
    }

    // parity: native/src/image.zig#releaseIccCache [status=implemented hash=12a30422fef0]
    public static func releaseIccCache() {
        iccCache.withLock { state in
            if state.retainCount > 0 {
                state.retainCount -= 1
            }
            if state.retainCount == 0 {
                state.entries = 0
            }
        }
    }

    // parity: native/src/image.zig#getIccCacheStats [status=implemented hash=16080d5d89bb]
    public static func getIccCacheStats() -> IccCacheStats {
        iccCache.withLock { IccCacheStats(hits: $0.hits, misses: $0.misses, entries: $0.entries) }
    }

    // parity: native/src/image.zig#testFailIccProfileCopyAllocationOnce [status=implemented hash=9887187cb9eb]
    public static func testFailIccProfileCopyAllocationOnce() {
        iccCache.withLock { $0.failCopyOnce = true }
    }

    // parity: native/src/image.zig#probe [status=implemented hash=86fb43edd224]
    public static func probe(_ data: [UInt8], limits: Limits = Limits()) -> (status: Status, info: Info) {
        guard UInt64(data.count) <= limits.maxEncodedBytes else {
            return (.memoryLimit, Info())
        }
        do {
            let coreInfo = try OpenTUICore.imageInfo(data)
            let info = Info(core: coreInfo)
            guard dimensionsWithinLimits(width: info.width, height: info.height, limits: limits) else {
                return (.dimensionLimit, info)
            }
            return (.ok, info)
        } catch {
            return (statusFromError(error), Info())
        }
    }

    // parity: native/src/image.zig#inspect [status=implemented hash=b667ff6c7688]
    public static func inspect(_ data: [UInt8], limits: Limits = Limits()) -> (status: Status, info: Info) {
        probe(data, limits: limits)
    }

    // parity: native/src/image.zig#inspectOwned [status=implemented hash=f9a4718c1942]
    public static func inspectOwned(_ data: [UInt8], limits: Limits = Limits()) throws(ImageError) -> Info {
        let result = inspect(data, limits: limits)
        try errorFromStatus(result.status)
        return result.info
    }

    // parity: native/src/image.zig#createFromRgba [status=implemented hash=76e420de51e4]
    public static func createFromRgba(
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        stride: UInt32
    ) throws(ImageError) -> Image {
        guard dimensionsWithinLimits(width: width, height: height) else {
            throw ImageError(code: .dimensionLimit, message: "dimensions exceed limits")
        }
        let core = try NativeImage.fromRgba(
            pixels,
            width: Int(width),
            height: Int(height),
            stride: stride == 0 ? nil : Int(stride)
        )
        return Image(core: core)
    }

    // parity: native/src/image.zig#createFromPixels [status=implemented hash=1c890f4d3eb3]
    public static func createFromPixels(
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        options: PixelImportOptions
    ) throws(ImageError) -> Image {
        guard dimensionsWithinLimits(width: width, height: height) else {
            throw ImageError(code: .dimensionLimit, message: "dimensions exceed limits")
        }
        let core = try NativeImage.fromPixels(
            pixels,
            width: Int(width),
            height: Int(height),
            options: OpenTUICore.PixelImportOptions(
                stride: options.stride == 0 ? nil : Int(options.stride),
                format: options.format.coreValue,
                alpha: options.alpha.coreValue
            )
        )
        return Image(core: core)
    }

    // parity: native/src/image.zig#updatePixels [status=implemented hash=1eb6406551e1]
    public static func updatePixels(_ image: Image, pixels: [UInt8], options: PixelImportOptions) throws(ImageError) {
        let updated = try NativeImage.fromPixels(
            pixels,
            width: Int(image.width),
            height: Int(image.height),
            options: OpenTUICore.PixelImportOptions(
                stride: options.stride == 0 ? nil : Int(options.stride),
                format: options.format.coreValue,
                alpha: options.alpha.coreValue
            )
        )
        image.replaceCore(updated)
    }

    // parity: native/src/image.zig#decode [status=implemented hash=c9e58e841107]
    public static func decode(_ data: [UInt8], limits: Limits = Limits()) throws(ImageError) -> Image {
        guard UInt64(data.count) <= limits.maxEncodedBytes else {
            throw ImageError(code: .memoryLimit, message: "encoded bytes exceed limit")
        }
        let core = try NativeImage.decode(data)
        guard dimensionsWithinLimits(width: UInt32(max(0, core.width)), height: UInt32(max(0, core.height)), limits: limits) else {
            throw ImageError(code: .dimensionLimit, message: "decoded image exceeds dimension limits")
        }
        return Image(core: core)
    }

    // parity: native/src/image.zig#transform [status=implemented hash=2d148d49d729]
    public static func transform(_ source: Image, operation: Transform) throws(ImageError) -> Image {
        let result: NativeImage
        switch operation {
        case .rotate90: result = try source.core.rotate(90)
        case .rotate180: result = try source.core.rotate(180)
        case .rotate270: result = try source.core.rotate(270)
        case .flip: result = try source.core.flip()
        case .flop: result = try source.core.flop()
        }
        return Image(core: result)
    }

    // parity: native/src/image.zig#extract [status=implemented hash=564936d18fe7]
    public static func extract(
        _ source: Image,
        left: UInt32,
        top: UInt32,
        width: UInt32,
        height: UInt32
    ) throws(ImageError) -> Image {
        let result = try source.core.extract(
            ExtractOptions(left: Int(left), top: Int(top), width: Int(width), height: Int(height))
        )
        return Image(core: result)
    }

    // parity: native/src/image.zig#extend [status=implemented hash=a63e5518c6a2]
    public static func extend(
        _ source: Image,
        top: UInt32 = 0,
        right: UInt32 = 0,
        bottom: UInt32 = 0,
        left: UInt32 = 0,
        background: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    ) throws(ImageError) -> Image {
        let result = try source.core.extend(
            ExtendOptions(
                top: Int(top),
                right: Int(right),
                bottom: Int(bottom),
                left: Int(left),
                background: background
            )
        )
        return Image(core: result)
    }

    // parity: native/src/image.zig#resize [status=implemented hash=9cd1dbebcc5e]
    public static func resize(
        _ source: Image,
        width: UInt32,
        height: UInt32,
        filter: ResizeFilter = .default
    ) throws(ImageError) -> Image {
        let result = try source.core.resize(
            ResizeOptions(width: Int(width), height: Int(height), kernel: filter.coreValue)
        )
        return Image(core: result)
    }

    // parity: native/src/image.zig#composite [status=implemented hash=17bb448e320a]
    public static func composite(
        base: Image,
        overlay: Image,
        left: Int32 = 0,
        top: Int32 = 0,
        blend: Blend = .sourceOver,
        opacity: Double = 1.0
    ) throws(ImageError) -> Image {
        let result = try base.core.composite(
            overlay.core,
            options: CompositeOptions(left: Int(left), top: Int(top), blend: blend.coreValue, opacity: opacity)
        )
        return Image(core: result)
    }

    // parity: native/src/image.zig#copyPixels [status=implemented hash=c403d45c4d7a]
    public static func copyPixels(
        _ image: Image,
        destination: inout [UInt8],
        stride: UInt32 = 0,
        bgra: Bool = false
    ) -> Status {
        do {
            try image.core.copyTo(
                &destination,
                stride: stride == 0 ? nil : Int(stride),
                format: bgra ? .bgra8 : .rgba8
            )
            return .ok
        } catch {
            return statusFromError(error)
        }
    }
}

// MARK: - 9. native/src/terminal-image.zig (18 unmapped symbols)

public enum NativeZigTerminalImage: Sendable {
    public static let imageIdMask: UInt32 = 0x03FF_FFFF
    private static let tmuxApcStart = "\u{1B}Ptmux;\u{1B}\u{1B}_G"
    private static let tmuxApcEnd = "\u{1B}\u{1B}\\\u{1B}\\"

    // parity: native/src/terminal-image.zig#KittyPixelFormat [status=implemented hash=6340034568b1]
    public enum KittyPixelFormat: Equatable, Hashable, Sendable, CaseIterable {
        case auto
        case rgb
        case rgba
    }

    // parity: native/src/terminal-image.zig#KittyEncoding [status=implemented hash=1a91dfa9af3b]
    public enum KittyEncoding: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case raw = 0
        case zlib = 1
        case png = 2
        case file = 3
    }

    // parity: native/src/terminal-image.zig#KITTY_PREPARE_BYTES_MAX [status=implemented hash=9558ccc61235]
    public static let KITTY_PREPARE_BYTES_MAX: Int = 64 * 1024 * 1024

    // parity: native/src/terminal-image.zig#kittyPayloadSize [status=implemented hash=20044341d28e]
    public static func kittyPayloadSize(_ image: NativeZigImage.Image) -> Int {
        Int(image.width) * Int(image.height) * 4
    }

    // parity: native/src/terminal-image.zig#writeKittyPayload [status=implemented hash=bb8b84529ca6]
    public static func writeKittyPayload(_ image: NativeZigImage.Image, requestedFormat: KittyPixelFormat = .rgba) -> [UInt8] {
        let rgba = image.pixels
        if requestedFormat == .rgb {
            var rgb: [UInt8] = []
            rgb.reserveCapacity((rgba.count / 4) * 3)
            var i = 0
            while i + 3 < rgba.count {
                rgb.append(rgba[i])
                rgb.append(rgba[i + 1])
                rgb.append(rgba[i + 2])
                i += 4
            }
            return rgb
        }
        return rgba
    }

    // parity: native/src/terminal-image.zig#writeKittyTransmitEncoded [status=implemented hash=7767b1efb3dc]
    public static func writeKittyTransmitEncoded(
        payload: [UInt8],
        width: UInt32,
        height: UInt32,
        id: UInt32,
        encoding: KittyEncoding = .raw,
        pixelFormat: KittyPixelFormat = .rgba,
        tmux: Bool = false
    ) -> String {
        let b64 = encodeImageBase64(payload)
        let chunkLimit = 4096
        let startSeq = tmux ? tmuxApcStart : "\u{1B}_G"
        let endSeq = tmux ? tmuxApcEnd : "\u{1B}\\"
        let fmtCode: Int
        switch encoding {
        case .png: fmtCode = 100
        case .raw, .zlib, .file: fmtCode = pixelFormat == .rgb ? 24 : 32
        }
        var headerParts = ["a=t", "f=\(fmtCode)", "i=\(id)", "q=2"]
        if encoding != .png {
            headerParts.append("s=\(width)")
            headerParts.append("v=\(height)")
        }
        if encoding == .zlib {
            headerParts.append("o=z")
        } else if encoding == .file {
            headerParts.append("t=f")
        }
        if b64.isEmpty {
            return "\(startSeq)\(headerParts.joined(separator: ","));\(endSeq)"
        }
        var out = ""
        let bytes = Array(b64.utf8)
        var offset = 0
        var first = true
        while offset < bytes.count {
            let end = min(offset + chunkLimit, bytes.count)
            let more = end < bytes.count ? 1 : 0
            let chunkStr = String(decoding: bytes[offset..<end], as: UTF8.self)
            if first {
                out += "\(startSeq)\(headerParts.joined(separator: ",")),m=\(more);\(chunkStr)\(endSeq)"
                first = false
            } else {
                out += "\(startSeq)m=\(more);\(chunkStr)\(endSeq)"
            }
            offset = end
        }
        return out
    }

    // parity: native/src/terminal-image.zig#writeKittyTransmit [status=implemented hash=7b5ec21f40e8]
    public static func writeKittyTransmit(_ image: NativeZigImage.Image, id: UInt32, tmux: Bool = false) -> String {
        writeKittyTransmitFormat(image, id: id, tmux: tmux, requestedFormat: .auto)
    }

    // parity: native/src/terminal-image.zig#writeKittyTransmitFormat [status=implemented hash=fd6dd72903ac]
    public static func writeKittyTransmitFormat(
        _ image: NativeZigImage.Image,
        id: UInt32,
        tmux: Bool = false,
        requestedFormat: KittyPixelFormat = .auto
    ) -> String {
        let effective: KittyPixelFormat
        if requestedFormat == .auto {
            effective = image.info().hasAlpha != 0 ? .rgba : .rgb
        } else {
            effective = requestedFormat
        }
        let payload = writeKittyPayload(image, requestedFormat: effective)
        return writeKittyTransmitEncoded(
            payload: payload,
            width: image.width,
            height: image.height,
            id: id,
            encoding: .raw,
            pixelFormat: effective,
            tmux: tmux
        )
    }

    // parity: native/src/terminal-image.zig#kittyPlacementZ [status=implemented hash=3c0829852a36]
    public static func kittyPlacementZ(placementId: UInt32) -> Int32 {
        let clamped = min(placementId, imageIdMask)
        return (Int32.min / 2) &+ Int32(bitPattern: clamped)
    }

    // parity: native/src/terminal-image.zig#writeKittyPlacement [status=implemented hash=61025e7ef9a4]
    public static func writeKittyPlacement(
        id: UInt32,
        placementId: UInt32,
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32,
        sourceX: UInt32 = 0,
        sourceY: UInt32 = 0,
        sourceWidth: UInt32 = 0,
        sourceHeight: UInt32 = 0,
        z: Int32,
        tmux: Bool = false
    ) -> String {
        let startSeq = tmux ? tmuxApcStart : "\u{1B}_G"
        let endSeq = tmux ? tmuxApcEnd : "\u{1B}\\"
        return "\u{1B}[\(y + 1);\(x + 1)H\(startSeq)a=p,i=\(id),p=\(placementId),c=\(width),r=\(height),x=\(sourceX),y=\(sourceY),w=\(sourceWidth),h=\(sourceHeight),C=1,z=\(z),q=2\(endSeq)"
    }

    // parity: native/src/terminal-image.zig#writeKittyPlacementAtCursor [status=implemented hash=a3b79e0f85ed]
    public static func writeKittyPlacementAtCursor(
        id: UInt32,
        placementId: UInt32,
        width: UInt32,
        height: UInt32,
        z: Int32,
        tmux: Bool = false
    ) -> String {
        let startSeq = tmux ? tmuxApcStart : "\u{1B}_G"
        let endSeq = tmux ? tmuxApcEnd : "\u{1B}\\"
        return "\(startSeq)a=p,i=\(id),p=\(placementId),c=\(width),r=\(height),C=1,z=\(z),q=2\(endSeq)"
    }

    // parity: native/src/terminal-image.zig#writeKittyDelete [status=implemented hash=a3edca49ad85]
    public static func writeKittyDelete(
        id: UInt32,
        placementId: UInt32? = nil,
        freeImage: Bool = false,
        tmux: Bool = false
    ) -> String {
        let startSeq = tmux ? tmuxApcStart : "\u{1B}_G"
        let endSeq = tmux ? tmuxApcEnd : "\u{1B}\\"
        let deleteKind = freeImage ? "I" : "i"
        var body = "a=d,d=\(deleteKind),i=\(id)"
        if let p = placementId {
            body += ",p=\(p)"
        }
        body += ",q=2"
        return "\(startSeq)\(body)\(endSeq)"
    }

    // parity: native/src/terminal-image.zig#QuantizedSixel [status=implemented hash=a022881be45a]
    public struct QuantizedSixel: Equatable, Hashable, Sendable {
        public var palette: [RGBTriplet]
        public var indices: [UInt8]
        public var width: UInt32
        public var height: UInt32

        public init(palette: [RGBTriplet], indices: [UInt8], width: UInt32, height: UInt32) {
            self.palette = palette
            self.indices = indices
            self.width = width
            self.height = height
        }

        // parity: native/src/terminal-image.zig#QuantizedSixel.deinit [status=implemented hash=487fdd5b7836]
        public mutating func deinitQuantized() {
            palette.removeAll(keepingCapacity: false)
            indices.removeAll(keepingCapacity: false)
            width = 0
            height = 0
        }
    }

    // parity: native/src/terminal-image.zig#quantizeSixel [status=implemented hash=abf7ac9ad586]
    public static func quantizeSixel(_ image: NativeZigImage.Image, maxColors: Int = 255) -> QuantizedSixel {
        let limit = max(1, min(255, maxColors))
        let rgba = image.pixels
        let pixelCount = Int(image.width) * Int(image.height)
        var palette: [RGBTriplet] = []
        var paletteMap: [UInt32: UInt8] = [:]
        var indices: [UInt8] = Array(repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let base = i * 4
            guard base + 3 < rgba.count else { break }
            let r = rgba[base]
            let g = rgba[base + 1]
            let b = rgba[base + 2]
            let a = rgba[base + 3]
            if a < 128 {
                indices[i] = 255 // transparent sentinel
                continue
            }
            let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            if let existing = paletteMap[key] {
                indices[i] = existing
            } else if palette.count < limit {
                let idx = UInt8(palette.count)
                palette.append(RGBTriplet(r, g, b))
                paletteMap[key] = idx
                indices[i] = idx
            } else {
                // Nearest color in palette
                var bestIdx: UInt8 = 0
                var bestDist = Int.max
                for (pIdx, c) in palette.enumerated() {
                    let dr = Int(r) - Int(c.r)
                    let dg = Int(g) - Int(c.g)
                    let db = Int(b) - Int(c.b)
                    let d = dr * dr + dg * dg + db * db
                    if d < bestDist {
                        bestDist = d
                        bestIdx = UInt8(pIdx)
                    }
                }
                indices[i] = bestIdx
            }
        }
        return QuantizedSixel(palette: palette, indices: indices, width: image.width, height: image.height)
    }

    // parity: native/src/terminal-image.zig#writeSixelIndexedPayload [status=implemented hash=4797b0897e46]
    public static func writeSixelIndexedPayload(_ quantized: QuantizedSixel) -> String {
        let width = Int(quantized.width)
        let height = Int(quantized.height)
        guard width > 0 && height > 0 else { return "" }

        var out = "\"1;1;\(width);\(height)"
        for (idx, c) in quantized.palette.enumerated() {
            let rPct = (Int(c.r) * 100 + 127) / 255
            let gPct = (Int(c.g) * 100 + 127) / 255
            let bPct = (Int(c.b) * 100 + 127) / 255
            out += "#\(idx);2;\(rPct);\(gPct);\(bPct)"
        }

        var bandY = 0
        while bandY < height {
            var firstColorInBand = true
            for colorIdx in 0..<quantized.palette.count {
                let target = UInt8(colorIdx)
                var hasAny = false
                var bandBytes: [UInt8] = Array(repeating: 0, count: width)
                for bit in 0..<6 {
                    let y = bandY + bit
                    if y >= height { break }
                    let rowBase = y * width
                    let mask = UInt8(1 << bit)
                    for x in 0..<width {
                        if quantized.indices[rowBase + x] == target {
                            bandBytes[x] |= mask
                            hasAny = true
                        }
                    }
                }
                if !hasAny { continue }
                if !firstColorInBand { out += "$" }
                firstColorInBand = false
                out += "#\(colorIdx)"
                var x = 0
                while x < width {
                    let b = bandBytes[x]
                    var run = 1
                    while x + run < width && bandBytes[x + run] == b {
                        run += 1
                    }
                    let ch = Character(UnicodeScalar(UInt32(b) + 63)!)
                    if run >= 4 {
                        out += "!\(run)\(ch)"
                    } else {
                        for _ in 0..<run { out.append(ch) }
                    }
                    x += run
                }
            }
            if bandY + 6 < height {
                out += "-"
            }
            bandY += 6
        }
        return out
    }

    // parity: native/src/terminal-image.zig#writeSixelPayload [status=implemented hash=629f5f2ca395]
    public static func writeSixelPayload(_ image: NativeZigImage.Image) -> String {
        let quantized = quantizeSixel(image, maxColors: 255)
        return writeSixelIndexedPayload(quantized)
    }

    // parity: native/src/terminal-image.zig#writeSixelFramedPayload [status=implemented hash=9d2438ad2a19]
    public static func writeSixelFramedPayload(_ payload: String, tmux: Bool = false) -> String {
        if tmux {
            return "\u{1B}Ptmux;\u{1B}\u{1B}Pq\(payload)\u{1B}\u{1B}\\\u{1B}\\"
        }
        return "\u{1B}Pq\(payload)\u{1B}\\"
    }

    // parity: native/src/terminal-image.zig#writeSixel [status=implemented hash=fc2a4bae3adb]
    public static func writeSixel(_ image: NativeZigImage.Image, tmux: Bool = false) -> String {
        if !tmux, let encoded = try? SixelEncoder.encode(image.core, maxColors: 255) {
            return encoded
        }
        let payload = writeSixelPayload(image)
        return writeSixelFramedPayload(payload, tmux: tmux)
    }
}

// MARK: - 10. native/src/video.zig (8 unmapped symbols)

public enum NativeZigVideo: Sendable {
    // parity: native/src/video.zig#audio_sample_rate [status=implemented hash=f5213a89849e]
    public static let audioSampleRate: UInt32 = 48_000
    // parity: native/src/video.zig#max_av_sync_offset_us [status=implemented hash=fcb8e758a59e]
    public static let maxAVSyncOffsetUs: Int64 = 60_000_000
    private static let latencyWindowSize = 30
    private static let qualityOverloadLimit: UInt8 = 8
    private static let qualityCooldown: UInt8 = 30
    private static let qualityRecovery: UInt32 = 120
    private static let qualityRecoveryMax: UInt32 = 120 * 8

    // parity: native/src/video.zig#Info [status=implemented hash=c29fc9f4faab]
    public struct Info: Equatable, Hashable, Sendable {
        public var durationUs: Int64
        public var width: UInt32
        public var height: UInt32
        public var fpsNum: UInt32
        public var fpsDen: UInt32
        public var hasAudio: UInt32
        public var audioSampleRate: UInt32
        public var audioChannels: UInt32

        public init(
            durationUs: Int64 = 0,
            width: UInt32 = 0,
            height: UInt32 = 0,
            fpsNum: UInt32 = 30,
            fpsDen: UInt32 = 1,
            hasAudio: UInt32 = 0,
            audioSampleRate: UInt32 = 0,
            audioChannels: UInt32 = 0
        ) {
            self.durationUs = durationUs
            self.width = width
            self.height = height
            self.fpsNum = fpsNum
            self.fpsDen = max(1, fpsDen)
            self.hasAudio = hasAudio
            self.audioSampleRate = audioSampleRate
            self.audioChannels = audioChannels
        }
    }

    // parity: native/src/video.zig#State [status=implemented hash=f203b785be91]
    public struct State: Equatable, Hashable, Sendable {
        public var currentTimeUs: Int64
        public var framePtsUs: Int64
        public var frameSerial: UInt64
        public var hasFrame: UInt32
        public var ended: UInt32
        public var playing: UInt32
        public var buffering: UInt32
        public var audioActive: UInt32
        public var audioEnded: UInt32
        public var audioFailed: UInt32
        public var audioQueuedFrames: UInt32
        public var audioConsumedFrames: UInt64
        public var audioProducedFrames: UInt64
        public var audioUnderruns: UInt64
        public var preparedPtsUs: Int64

        public init(
            currentTimeUs: Int64 = 0,
            framePtsUs: Int64 = -1,
            frameSerial: UInt64 = 0,
            hasFrame: UInt32 = 0,
            ended: UInt32 = 0,
            playing: UInt32 = 0,
            buffering: UInt32 = 0,
            audioActive: UInt32 = 0,
            audioEnded: UInt32 = 0,
            audioFailed: UInt32 = 0,
            audioQueuedFrames: UInt32 = 0,
            audioConsumedFrames: UInt64 = 0,
            audioProducedFrames: UInt64 = 0,
            audioUnderruns: UInt64 = 0,
            preparedPtsUs: Int64 = -1
        ) {
            self.currentTimeUs = currentTimeUs
            self.framePtsUs = framePtsUs
            self.frameSerial = frameSerial
            self.hasFrame = hasFrame
            self.ended = ended
            self.playing = playing
            self.buffering = buffering
            self.audioActive = audioActive
            self.audioEnded = audioEnded
            self.audioFailed = audioFailed
            self.audioQueuedFrames = audioQueuedFrames
            self.audioConsumedFrames = audioConsumedFrames
            self.audioProducedFrames = audioProducedFrames
            self.audioUnderruns = audioUnderruns
            self.preparedPtsUs = preparedPtsUs
        }
    }

    // parity: native/src/video.zig#LatencyWindow [status=implemented hash=8face6d7df56]
    public struct LatencyWindow: Equatable, Hashable, Sendable {
        public private(set) var samples: [UInt32]
        public private(set) var count: UInt8
        public private(set) var cursor: UInt8

        public init() {
            self.samples = Array(repeating: 0, count: NativeZigVideo.latencyWindowSize)
            self.count = 0
            self.cursor = 0
        }

        // parity: native/src/video.zig#LatencyWindow.add [status=implemented hash=a56da490b407]
        public mutating func add(_ sample: UInt32) {
            samples[Int(cursor)] = sample
            cursor = UInt8((Int(cursor) + 1) % NativeZigVideo.latencyWindowSize)
            if Int(count) < NativeZigVideo.latencyWindowSize {
                count += 1
            }
        }

        // parity: native/src/video.zig#LatencyWindow.maximum [status=implemented hash=a111a60f3318]
        public func maximum() -> UInt32 {
            var result: UInt32 = 0
            for i in 0..<Int(count) {
                result = max(result, samples[i])
            }
            return result
        }

        public mutating func reset() {
            self = LatencyWindow()
        }
    }

    // parity: native/src/video.zig#quality_scales [status=implemented hash=8d19b25c0db8]
    public static let qualityScales: [Double] = [1.0, 0.75, 0.5, 0.35, 0.25]

    // parity: native/src/video.zig#Quality [status=implemented hash=e26583cd551a]
    public struct Quality: Equatable, Hashable, Sendable {
        public var tier: UInt8
        public var overload: UInt8
        public var headroom: UInt32
        public var cooldown: UInt8
        public var recovery: UInt32
        public var sinceUpgrade: UInt32?

        public init(
            tier: UInt8 = 0,
            overload: UInt8 = 0,
            headroom: UInt32 = 0,
            cooldown: UInt8 = 0,
            recovery: UInt32 = 120,
            sinceUpgrade: UInt32? = nil
        ) {
            self.tier = tier
            self.overload = overload
            self.headroom = headroom
            self.cooldown = cooldown
            self.recovery = recovery
            self.sinceUpgrade = sinceUpgrade
        }

        // parity: native/src/video.zig#Quality.scale [status=implemented hash=e2b8a90c8d6a]
        public func scale() -> Double {
            let idx = min(Int(tier), NativeZigVideo.qualityScales.count - 1)
            return NativeZigVideo.qualityScales[idx]
        }

        private mutating func settle() {
            overload = 0
            headroom = 0
            cooldown = NativeZigVideo.qualityCooldown
        }

        // parity: native/src/video.zig#Quality.sample [status=implemented hash=f92757f37981]
        public mutating func sample(costUs: UInt32, intervalUs: UInt32) {
            let intervals = UInt8(min(costUs / max(intervalUs, 1), UInt32(NativeZigVideo.qualityOverloadLimit)))
            let step = max(intervals, 1)
            if costUs > intervalUs {
                overload = overload > UInt8.max - step ? UInt8.max : overload + step
            } else {
                overload = overload > 2 ? overload - 2 : 0
            }
            if costUs < intervalUs / 2 {
                headroom = headroom == UInt32.max ? UInt32.max : headroom + 1
            } else {
                headroom = headroom > 4 ? headroom - 4 : 0
            }
            if let samples = sinceUpgrade {
                let next = samples &+ 1
                if next >= recovery {
                    sinceUpgrade = nil
                    recovery = NativeZigVideo.qualityRecovery
                } else {
                    sinceUpgrade = next
                }
            }
            if cooldown > 0 {
                cooldown = cooldown > step ? cooldown - step : 0
                overload = 0
                return
            }
            if overload >= NativeZigVideo.qualityOverloadLimit && Int(tier) + 1 < NativeZigVideo.qualityScales.count {
                tier += 1
                if sinceUpgrade != nil {
                    recovery = min(recovery * 2, NativeZigVideo.qualityRecoveryMax)
                }
                sinceUpgrade = nil
                settle()
            } else if headroom >= recovery && tier > 0 {
                tier -= 1
                sinceUpgrade = 0
                settle()
            }
        }
    }

    // parity: native/src/video.zig#Video [status=implemented hash=8421408151ce]
    public final class Video: @unchecked Sendable {
        public let path: String
        public var info: Info
        public private(set) var state: State = State()
        public var quality: Quality = Quality()
        public var latencyWindow: LatencyWindow = LatencyWindow()
        public private(set) var currentImage: NativeZigImage.Image?
        public private(set) var decodedFrameCount: UInt64 = 0
        public private(set) var lastErrorMessage: String = ""
        public private(set) var muted: Bool = false
        public private(set) var volume: Float = 1.0
        public private(set) var avSyncOffsetUs: Int64 = 0
        public private(set) var outputWidth: UInt32 = 0
        public private(set) var outputHeight: UInt32 = 0
        public private(set) var outputCover: Bool = false
        public private(set) var outputCrop: NativeZigImage.Region?
        public private(set) var audioOffline: Bool = false
        private var audioSamples: [Float] = []
        private var audioReadCursor: Int = 0
        private var audioBaseTimeUs: Int64 = 0
        private var frames: [(ptsUs: Int64, image: NativeZigImage.Image)] = []

        public init(path: String, info: Info = Info()) {
            self.path = path
            self.info = info
        }

        // parity: native/src/video.zig#Video.open [status=adapted hash=001b3118cc7c]
        public static func open(
            path: String,
            externalAudio: Bool = false,
            info: Info = Info()
        ) -> Video {
            let video = Video(path: path, info: info)
            if externalAudio || info.hasAudio != 0 {
                video.state.audioActive = 1
            }
            return video
        }

        // parity: native/src/video.zig#Video.deinit [status=implemented hash=7a7695a48f3b]
        deinit {
            frames.removeAll(keepingCapacity: false)
            audioSamples.removeAll(keepingCapacity: false)
            currentImage = nil
        }

        public func loadFrames(_ frames: [(ptsUs: Int64, image: NativeZigImage.Image)]) {
            self.frames = frames.sorted { $0.ptsUs < $1.ptsUs }
            if let first = self.frames.first {
                currentImage = first.image
                state.hasFrame = 1
                state.framePtsUs = first.ptsUs
                state.frameSerial &+= 1
            }
            if let last = self.frames.last, info.durationUs < last.ptsUs {
                info.durationUs = last.ptsUs
            }
        }

        public func loadAudioSamples(_ interleavedStereo: [Float]) {
            self.audioSamples = interleavedStereo
            self.audioReadCursor = 0
            let channels = max(1, Int(info.audioChannels == 0 ? 2 : info.audioChannels))
            state.audioQueuedFrames = UInt32(interleavedStereo.count / channels)
            state.audioProducedFrames &+= UInt64(interleavedStereo.count / channels)
            state.audioActive = interleavedStereo.isEmpty ? 0 : 1
            state.audioEnded = 0
        }

        // parity: native/src/video.zig#Video.configureOutput [status=implemented hash=37baed5d17f8]
        @discardableResult
        public func configureOutput(width: UInt32, height: UInt32, cover: Bool = false, crop: NativeZigImage.Region? = nil) -> Bool {
            let changed = outputWidth != width || outputHeight != height || outputCover != cover || outputCrop != crop
            outputWidth = width
            outputHeight = height
            outputCover = cover
            outputCrop = crop
            return changed
        }

        // parity: native/src/video.zig#Video.play [status=implemented hash=94b14e17189f]
        public func play() {
            state.playing = 1
            state.ended = 0
        }

        // parity: native/src/video.zig#Video.pause [status=implemented hash=c069a737c98f]
        public func pause() {
            state.playing = 0
        }

        // parity: native/src/video.zig#Video.setMuted [status=implemented hash=8d3208717a9e]
        public func setMuted(_ muted: Bool) { self.muted = muted }

        // parity: native/src/video.zig#Video.setVolume [status=implemented hash=0102b6302f04]
        public func setVolume(_ volume: Float) { self.volume = max(0, volume) }

        // parity: native/src/video.zig#Video.setAvSyncOffset [status=implemented hash=c2878eda793b]
        public func setAvSyncOffset(_ offsetUs: Int64) {
            avSyncOffsetUs = min(NativeZigVideo.maxAVSyncOffsetUs, max(-NativeZigVideo.maxAVSyncOffsetUs, offsetUs))
        }

        // parity: native/src/video.zig#Video.setAudioOffline [status=implemented hash=1af9c0d1c925]
        public func setAudioOffline(_ offline: Bool) {
            self.audioOffline = offline
        }

        // parity: native/src/video.zig#Video.seek [status=implemented hash=49e60a71900a]
        public func seek(targetUs: Int64) {
            let clamped = max(0, info.durationUs > 0 ? min(targetUs, info.durationUs) : targetUs)
            state.currentTimeUs = clamped
            state.ended = 0
            audioBaseTimeUs = clamped
            state.audioConsumedFrames = 0
            audioReadCursor = 0
            _ = update(targetUs: clamped)
        }

        // parity: native/src/video.zig#Video.update [status=implemented hash=15df990f46bb]
        @discardableResult
        public func update(targetUs: Int64) -> Bool {
            state.currentTimeUs = targetUs
            guard !frames.isEmpty else {
                if info.durationUs > 0 && targetUs >= info.durationUs {
                    state.ended = 1
                }
                return false
            }
            var chosen = frames[0]
            for frame in frames {
                if frame.ptsUs <= targetUs {
                    chosen = frame
                } else {
                    break
                }
            }
            let changed = state.framePtsUs != chosen.ptsUs || currentImage == nil
            currentImage = chosen.image
            state.hasFrame = 1
            state.framePtsUs = chosen.ptsUs
            if changed {
                state.frameSerial &+= 1
                decodedFrameCount &+= 1
            }
            if info.durationUs > 0 && targetUs >= info.durationUs {
                state.ended = 1
            }
            return changed
        }

        // parity: native/src/video.zig#Video.prepare [status=implemented hash=c5eba772792f]
        @discardableResult
        public func prepare(targetUs: Int64) -> Bool {
            guard !frames.isEmpty else { return false }
            var candidate: Int64? = nil
            for frame in frames where frame.ptsUs >= targetUs {
                candidate = frame.ptsUs
                break
            }
            guard let pts = candidate else { return false }
            state.preparedPtsUs = pts
            return true
        }

        // parity: native/src/video.zig#Video.drainPreparation [status=implemented hash=9daa2636c5e3]
        public func drainPreparation() {
            if state.preparedPtsUs >= 0 {
                _ = update(targetUs: state.preparedPtsUs)
                state.preparedPtsUs = -1
            }
        }

        // parity: native/src/video.zig#Video.schedule [status=implemented hash=2e43df97ee65]
        public func schedule(fallbackTimeUs: Int64, presentationIntervalUs: UInt32) {
            let effective = state.audioActive != 0 ? audioTimeUs(consumedFrames: state.audioConsumedFrames) : fallbackTimeUs
            _ = update(targetUs: effective)
            _ = prepareNext(presentationIntervalUs: presentationIntervalUs)
        }

        // parity: native/src/video.zig#Video.prepareNext [status=implemented hash=bcb3320f7f72]
        @discardableResult
        public func prepareNext(presentationIntervalUs: UInt32) -> Bool {
            let target = state.currentTimeUs &+ Int64(presentationIntervalUs)
            return prepare(targetUs: target)
        }

        // parity: native/src/video.zig#Video.observeOutput [status=implemented hash=3127602892df]
        public func observeOutput(frame: UInt64, costUs: UInt32, intervalUs: UInt32 = 33_333) {
            _ = frame
            latencyWindow.add(costUs)
            quality.sample(costUs: costUs, intervalUs: intervalUs)
        }

        // parity: native/src/video.zig#Video.readAudio [status=implemented hash=53228acd8965]
        public func readAudio(into samples: inout [Float], capacityFrames: UInt32) -> UInt32 {
            let channels = max(1, Int(info.audioChannels == 0 ? 2 : info.audioChannels))
            let remainingFrames = max(0, (audioSamples.count - audioReadCursor) / channels)
            let framesToRead = min(Int(capacityFrames), min(remainingFrames, samples.count / channels))
            let sampleCount = framesToRead * channels
            let gain: Float = muted ? 0 : volume
            for i in 0..<sampleCount {
                samples[i] = audioSamples[audioReadCursor + i] * gain
            }
            audioReadCursor += sampleCount
            state.audioConsumedFrames &+= UInt64(framesToRead)
            state.audioQueuedFrames = UInt32(max(0, (audioSamples.count - audioReadCursor) / channels))
            if state.audioQueuedFrames == 0 && !audioSamples.isEmpty {
                state.audioEnded = 1
            }
            return UInt32(framesToRead)
        }

        // parity: native/src/video.zig#Video.audioStats [status=implemented hash=2f3564300f61]
        public func audioStats() -> NativeZigAudio.StreamStats? {
            guard info.hasAudio != 0 || state.audioActive != 0 else { return nil }
            let channels = info.audioChannels == 0 ? 2 : info.audioChannels
            return NativeZigAudio.StreamStats(
                bytesReceived: UInt64(audioSamples.count) * 4,
                framesDecoded: state.audioProducedFrames,
                framesPlayed: state.audioConsumedFrames,
                state: state.audioFailed != 0 ? 5 : (state.audioEnded != 0 ? 4 : (state.playing != 0 ? 2 : 3)),
                sampleRate: info.audioSampleRate == 0 ? NativeZigVideo.audioSampleRate : info.audioSampleRate,
                channels: channels,
                bufferedFrames: state.audioQueuedFrames,
                capacityFrames: UInt32(max(1, audioSamples.count / max(1, Int(channels)))),
                underruns: UInt32(clamping: state.audioUnderruns)
            )
        }

        // parity: native/src/video.zig#Video.audioTimeUs [status=implemented hash=b2bf01ad1e6f]
        public func audioTimeUs(consumedFrames: UInt64? = nil) -> Int64 {
            let rate = Int64(max(1, info.audioSampleRate == 0 ? NativeZigVideo.audioSampleRate : info.audioSampleRate))
            let framesPlayed = Int64(consumedFrames ?? state.audioConsumedFrames)
            let elapsedUs = (framesPlayed &* 1_000_000) / rate
            return max(0, audioBaseTimeUs &+ elapsedUs &+ avSyncOffsetUs)
        }

        // parity: native/src/video.zig#Video.mixOffline [status=implemented hash=bae524a99fc9]
        public func mixOffline(output: inout [Float], frames: UInt32) -> Int32 {
            let read = readAudio(into: &output, capacityFrames: frames)
            return Int32(read)
        }

        // parity: native/src/video.zig#Video.syncAudio [status=implemented hash=97c41f8fdfb6]
        public func syncAudio() {
            guard state.audioActive != 0 && state.audioFailed == 0 else { return }
            let synced = audioTimeUs()
            if synced != state.currentTimeUs {
                state.currentTimeUs = synced
            }
        }

        // parity: native/src/video.zig#Video.failAudio [status=implemented hash=da9b0db7c3f4]
        public func failAudio(_ message: String) {
            state.audioFailed = 1
            state.audioActive = 0
            lastErrorMessage = message
        }

        // parity: native/src/video.zig#Video.decodedFrames [status=implemented hash=da6688227b7f]
        public func decodedFrames() -> UInt64 {
            decodedFrameCount
        }

        // parity: native/src/video.zig#Video.lastError [status=implemented hash=2ea011d61fc3]
        public func lastError() -> String {
            lastErrorMessage
        }

        // parity: native/src/video.zig#Video.getState [status=implemented hash=ad8f4d71847b]
        public func getState() -> State { state }
    }

    // parity: native/src/video.zig#PlayerState [status=implemented hash=fbd0e33d3f2c]
    public struct PlayerState: Equatable, Hashable, Sendable {
        public var currentTimeUs: Int64
        public var framePtsUs: Int64
        public var playing: Bool
        public var ended: Bool
        public var buffering: Bool
        public var audio: Bool
        public var hasFrame: Bool
        public var failed: Bool
        public var qualityTier: UInt32

        public init(
            currentTimeUs: Int64 = 0,
            framePtsUs: Int64 = -1,
            playing: Bool = false,
            ended: Bool = false,
            buffering: Bool = false,
            audio: Bool = false,
            hasFrame: Bool = false,
            failed: Bool = false,
            qualityTier: UInt32 = 0
        ) {
            self.currentTimeUs = currentTimeUs
            self.framePtsUs = framePtsUs
            self.playing = playing
            self.ended = ended
            self.buffering = buffering
            self.audio = audio
            self.hasFrame = hasFrame
            self.failed = failed
            self.qualityTier = qualityTier
        }
    }

    // parity: native/src/video.zig#Player [status=implemented hash=b0970a72afef]
    public final class Player: @unchecked Sendable {
        public let video: Video
        public private(set) var playing: Bool = false
        public var loop: Bool = false
        public private(set) var ended: Bool = false
        public private(set) var failed: Bool = false
        public private(set) var positionUs: Int64 = 0
        public private(set) var maxFps: UInt32 = 30

        public init(video: Video) {
            self.video = video
        }

        // parity: native/src/video.zig#Player.open [status=adapted hash=859195e1b208]
        public static func open(
            path: String,
            audioEnabled: Bool = true,
            info: Info = Info()
        ) -> Player {
            Player(video: Video.open(path: path, externalAudio: audioEnabled, info: info))
        }

        // parity: native/src/video.zig#Player.deinit [status=implemented hash=69ec0d868127]
        deinit {
            playing = false
            video.pause()
        }

        // parity: native/src/video.zig#Player.currentTime [status=implemented hash=2d63bb8eef88]
        public func currentTime() -> Int64 { positionUs }

        // parity: native/src/video.zig#Player.play [status=implemented hash=22d3e9109f70]
        public func play() {
            playing = true
            ended = false
            video.play()
        }

        // parity: native/src/video.zig#Player.pause [status=implemented hash=4f4534ba222e]
        public func pause() {
            playing = false
            video.pause()
        }

        // parity: native/src/video.zig#Player.seek [status=implemented hash=79dee26a155b]
        public func seek(timeUs: Int64) {
            positionUs = max(0, timeUs)
            ended = false
            video.seek(targetUs: positionUs)
        }

        public func advance(byUs deltaUs: Int64) {
            guard playing && !failed else { return }
            positionUs &+= max(0, deltaUs)
            if video.info.durationUs > 0 && positionUs >= video.info.durationUs {
                if loop {
                    positionUs %= max(1, video.info.durationUs)
                } else {
                    positionUs = video.info.durationUs
                    ended = true
                    playing = false
                    video.pause()
                }
            }
            _ = video.update(targetUs: positionUs)
        }

        // parity: native/src/video.zig#Player.setLoop [status=implemented hash=89c69083a524]
        public func setLoop(_ loop: Bool) { self.loop = loop }
        // parity: native/src/video.zig#Player.setMuted [status=implemented hash=9eadc4a0790b]
        public func setMuted(_ muted: Bool) { video.setMuted(muted) }
        // parity: native/src/video.zig#Player.setVolume [status=implemented hash=7403b60a267b]
        public func setVolume(_ volume: Float) { video.setVolume(volume) }
        // parity: native/src/video.zig#Player.setAvSyncOffset [status=implemented hash=759b0ce49795]
        public func setAvSyncOffset(_ offsetUs: Int64) { video.setAvSyncOffset(offsetUs) }
        // parity: native/src/video.zig#Player.setMaxFps [status=implemented hash=cd70c20c1129]
        public func setMaxFps(_ fps: UInt32) { maxFps = max(1, fps) }
        // parity: native/src/video.zig#Player.fail [status=implemented hash=3738484dc5e3]
        public func fail() { failed = true; playing = false }

        // parity: native/src/video.zig#Player.observeFrameCost [status=implemented hash=e5e5525cc8ac]
        public func observeFrameCost(completedFrames: UInt64, costUs: UInt32) {
            let intervalUs = UInt32(1_000_000 / max(1, maxFps))
            video.observeOutput(frame: completedFrames, costUs: costUs, intervalUs: intervalUs)
        }

        // parity: native/src/video.zig#Player.frame [status=implemented hash=9baeda60bad7]
        public func frame(width: UInt32, height: UInt32, cover: Bool = false, crop: NativeZigImage.Region? = nil) -> NativeZigImage.Image? {
            _ = video.configureOutput(width: width, height: height, cover: cover, crop: crop)
            return video.currentImage
        }

        // parity: native/src/video.zig#Player.lastError [status=implemented hash=6d23fd5eed14]
        public func lastError() -> String {
            video.lastError()
        }

        // parity: native/src/video.zig#Player.snapshot [status=implemented hash=7c7bade16dc7]
        public func snapshot() -> PlayerState {
            let s = video.getState()
            return PlayerState(
                currentTimeUs: positionUs,
                framePtsUs: s.framePtsUs,
                playing: playing,
                ended: ended || s.ended != 0,
                buffering: s.buffering != 0,
                audio: s.audioActive != 0,
                hasFrame: s.hasFrame != 0,
                failed: failed,
                qualityTier: UInt32(video.quality.tier)
            )
        }
    }
}

// MARK: - 11. native/src/native-span-feed.zig (27 unmapped symbols)

public enum NativeZigSpanFeed: Sendable {
    public static let spanQueueCapacityDefault: UInt32 = 4096

    // parity: native/src/native-span-feed.zig#CallbackFn [status=implemented hash=5013463fe2f0]
    public typealias CallbackFn = @Sendable (_ streamId: UInt64, _ eventId: UInt32, _ arg0: Int, _ arg1: UInt64) -> Void

    // parity: native/src/native-span-feed.zig#GrowthPolicy [status=implemented hash=a5ef69835018]
    public enum GrowthPolicy: UInt8, Equatable, Hashable, Sendable, CaseIterable {
        case grow = 0
        case block = 1

        public var coreValue: OpenTUICore.GrowthPolicy {
            self == .grow ? .grow : .block
        }
    }

    // parity: native/src/native-span-feed.zig#Options [status=implemented hash=9bf306876b76]
    public struct Options: Equatable, Hashable, Sendable {
        public var chunkSize: UInt32
        public var initialChunks: UInt32
        public var maxBytes: UInt64
        public var growthPolicy: UInt8
        public var autoCommitOnFull: UInt8
        public var spanQueueCapacity: UInt32

        public init(
            chunkSize: UInt32 = 64 * 1024,
            initialChunks: UInt32 = 2,
            maxBytes: UInt64 = 0,
            growthPolicy: UInt8 = GrowthPolicy.grow.rawValue,
            autoCommitOnFull: UInt8 = 1,
            spanQueueCapacity: UInt32 = 0
        ) {
            self.chunkSize = chunkSize
            self.initialChunks = initialChunks
            self.maxBytes = maxBytes
            self.growthPolicy = growthPolicy
            self.autoCommitOnFull = autoCommitOnFull
            self.spanQueueCapacity = spanQueueCapacity
        }

        public func toCore() -> NativeSpanFeedOptions {
            let norm = NativeZigSpanFeed.normalizeOptions(self)
            return NativeSpanFeedOptions(
                chunkSize: Int(norm.chunkSize),
                initialChunks: Int(norm.initialChunks),
                maxBytes: norm.maxBytes,
                growthPolicy: norm.growthPolicy == GrowthPolicy.block.rawValue ? .block : .grow,
                autoCommitOnFull: norm.autoCommitOnFull != 0,
                spanQueueCapacity: Int(norm.spanQueueCapacity)
            )
        }
    }

    // parity: native/src/native-span-feed.zig#Stats [status=implemented hash=9cae5b6f87a6]
    public struct Stats: Equatable, Hashable, Sendable {
        public var bytesWritten: UInt64
        public var spansCommitted: UInt64
        public var chunks: UInt32
        public var pendingSpans: UInt32
        public var outstandingSpans: UInt32
        public var reserved: UInt32
        public var outstandingBytes: UInt64

        public init(
            bytesWritten: UInt64 = 0,
            spansCommitted: UInt64 = 0,
            chunks: UInt32 = 0,
            pendingSpans: UInt32 = 0,
            outstandingSpans: UInt32 = 0,
            reserved: UInt32 = 0,
            outstandingBytes: UInt64 = 0
        ) {
            self.bytesWritten = bytesWritten
            self.spansCommitted = spansCommitted
            self.chunks = chunks
            self.pendingSpans = pendingSpans
            self.outstandingSpans = outstandingSpans
            self.reserved = reserved
            self.outstandingBytes = outstandingBytes
        }

        public init(core: NativeSpanFeedStats) {
            self.bytesWritten = core.bytesWritten
            self.spansCommitted = core.spansCommitted
            self.chunks = UInt32(max(0, core.chunks))
            self.pendingSpans = UInt32(max(0, core.pendingSpans))
            self.outstandingSpans = UInt32(max(0, core.outstandingSpans))
            self.reserved = 0
            self.outstandingBytes = core.outstandingBytes
        }
    }

    // parity: native/src/native-span-feed.zig#SpanInfo [status=implemented hash=aa592d381fc4]
    public struct SpanInfo: Equatable, Hashable, Sendable {
        public var chunkIndex: UInt32
        public var offset: UInt32
        public var len: UInt32
        public var slotIndex: UInt32
        public var releaseId: UInt64

        public init(
            chunkIndex: UInt32 = 0,
            offset: UInt32 = 0,
            len: UInt32 = 0,
            slotIndex: UInt32 = 0,
            releaseId: UInt64 = 0
        ) {
            self.chunkIndex = chunkIndex
            self.offset = offset
            self.len = len
            self.slotIndex = slotIndex
            self.releaseId = releaseId
        }

        public init(core: OpenTUICore.SpanInfo) {
            self.chunkIndex = UInt32(max(0, core.chunkIndex))
            self.offset = UInt32(max(0, core.offset))
            self.len = UInt32(max(0, core.len))
            self.slotIndex = UInt32(max(0, core.slotIndex))
            self.releaseId = core.releaseId
        }

        public func toCore() -> OpenTUICore.SpanInfo {
            OpenTUICore.SpanInfo(
                chunkIndex: Int(chunkIndex),
                offset: Int(offset),
                len: Int(len),
                slotIndex: Int(slotIndex),
                releaseId: releaseId
            )
        }

        // parity: native/src/native-span-feed.zig#SpanInfo.slice [status=adapted hash=6ab1d510adf3]
        public func slice(in stream: Stream) -> [UInt8] {
            stream.readSpan(self) ?? []
        }
    }

    /// Ring queue of pending committed `SpanInfo` records matching `native-span-feed.zig#SpanRing`.
    public struct SpanRing: Equatable, Sendable {
        public let capacity: UInt32
        private var slots: [SpanInfo?]
        private var head: Int = 0
        private var tail: Int = 0
        private var len: UInt32 = 0

        public init(capacity: UInt32 = NativeZigSpanFeed.spanQueueCapacityDefault) {
            let cap = max(1, capacity)
            self.capacity = cap
            self.slots = Array(repeating: nil, count: Int(cap))
        }

        // parity: native/src/native-span-feed.zig#SpanRing.count [status=implemented hash=29e47af01889]
        public func count() -> UInt32 {
            len
        }

        // parity: native/src/native-span-feed.zig#SpanRing.push [status=implemented hash=0432f179813a]
        public mutating func push(span: SpanInfo, notify: inout Bool) throws(StreamError) {
            guard len < capacity else { throw .noSpace }
            let wasEmpty = len == 0
            slots[tail] = span
            tail = (tail + 1) % Int(capacity)
            len += 1
            if wasEmpty { notify = true }
        }

        // parity: native/src/native-span-feed.zig#SpanRing.popMany [status=implemented hash=e0e0d227ccd6]
        public mutating func popMany(maxCount: Int) -> [SpanInfo] {
            let n = min(max(0, maxCount), Int(len))
            var out: [SpanInfo] = []
            out.reserveCapacity(n)
            for _ in 0..<n {
                if let item = slots[head] {
                    out.append(item)
                }
                slots[head] = nil
                head = (head + 1) % Int(capacity)
                len -= 1
            }
            return out
        }
    }

    // parity: native/src/native-span-feed.zig#ReserveInfo [status=implemented hash=3de743aa45a3]
    public struct ReserveInfo: Equatable, Hashable, Sendable {
        public var chunkIndex: UInt32
        public var offset: UInt32
        public var len: UInt32
        public var reserved: UInt32

        public init(chunkIndex: UInt32 = 0, offset: UInt32 = 0, len: UInt32 = 0, reserved: UInt32 = 0) {
            self.chunkIndex = chunkIndex
            self.offset = offset
            self.len = len
            self.reserved = reserved
        }

        // parity: native/src/native-span-feed.zig#ReserveInfo.slice [status=adapted hash=26b0d4942d96]
        public func slice(in stream: Stream) -> [UInt8] {
            Array(stream.reservedBuffer.prefix(Int(len)))
        }
    }

    // parity: native/src/native-span-feed.zig#ControlSequenceReservation [status=implemented hash=3ebcf5365653]
    public struct ControlSequenceReservation: Equatable, Hashable, Sendable {
        public var bytes: UInt64
        public var spans: UInt64

        public init(bytes: UInt64 = 0, spans: UInt64 = 0) {
            self.bytes = bytes
            self.spans = spans
        }
    }

    // parity: native/src/native-span-feed.zig#default_pattern [status=implemented hash=a64afa865c3a]
    public static let defaultPattern: String = "\u{1B}[32mnative-span-feed\u{1B}[0m\n"

    // parity: native/src/native-span-feed.zig#EventId [status=implemented hash=edddc1ad7c50]
    public enum EventId: UInt32, Equatable, Hashable, Sendable, CaseIterable {
        case chunkAdded = 2
        case closed = 5
        case error = 6
        case dataAvailable = 7
    }

    // parity: native/src/native-span-feed.zig#Status [status=implemented hash=12909ce7eccf]
    public enum Status: Sendable {
        public static let ok: Int32 = 0
        public static let errNoSpace: Int32 = -1
        public static let errMaxBytes: Int32 = -2
        public static let errInvalid: Int32 = -3
        public static let errAlloc: Int32 = -4
        public static let errBusy: Int32 = -5
    }

    // parity: native/src/native-span-feed.zig#StreamError [status=implemented hash=2485f8221d64]
    public enum StreamError: Error, Equatable, Hashable, Sendable {
        case noSpace
        case maxBytes
        case invalid
        case outOfMemory
        case busy

        public var statusCode: Int32 {
            switch self {
            case .noSpace: return Status.errNoSpace
            case .maxBytes: return Status.errMaxBytes
            case .invalid: return Status.errInvalid
            case .outOfMemory: return Status.errAlloc
            case .busy: return Status.errBusy
            }
        }
    }

    // parity: native/src/native-span-feed.zig#Stream [status=implemented hash=8f2f55c6a363]
    public final class Stream: @unchecked Sendable {
        public let core: NativeSpanFeed
        public fileprivate(set) var options: Options
        public fileprivate(set) var attached: Bool = false
        public var controlReservation: ControlSequenceReservation = ControlSequenceReservation()
        fileprivate var callback: CallbackFn?
        fileprivate var pendingBytes: [UInt8] = []
        fileprivate var activeReservation: SpanReservation?
        fileprivate var reservedBuffer: [UInt8] = []
        fileprivate let streamId: UInt64

        private static let nextId = Mutex<UInt64>(1)

        public init(options: Options = NativeZigSpanFeed.defaultOptions()) {
            let norm = NativeZigSpanFeed.normalizeOptions(options)
            self.options = norm
            self.core = NativeSpanFeed.create(norm.toCore())
            self.streamId = Stream.nextId.withLock { id in
                let cur = id
                id &+= 1
                return cur
            }
        }

        public func readSpan(_ span: SpanInfo) -> [UInt8]? {
            core.readSpan(span.toCore())
        }

        fileprivate func notify(_ event: EventId, arg0: Int = 0, arg1: UInt64 = 0) {
            callback?(streamId, event.rawValue, arg0, arg1)
        }

        // parity: native/src/native-span-feed.zig#Stream.create [status=implemented hash=cdff92334251]
        public static func create(options: Options? = nil) -> Stream {
            Stream(options: NativeZigSpanFeed.normalizeOptions(options ?? NativeZigSpanFeed.defaultOptions()))
        }

        // parity: native/src/native-span-feed.zig#Stream.attach [status=implemented hash=7fa730012063]
        public func attach() throws(StreamError) {
            guard !core.isClosed else { throw .invalid }
            attached = true
        }

        // parity: native/src/native-span-feed.zig#Stream.setCallback [status=implemented hash=ba94231a84df]
        public func setCallback(_ cb: CallbackFn?) {
            callback = cb
        }

        // parity: native/src/native-span-feed.zig#Stream.reserveControlCapacity [status=implemented hash=5ee5e3ccbe48]
        public func reserveControlCapacity(bytes: Int) throws(StreamError) {
            guard bytes >= 0 else { throw .invalid }
            if bounded() && UInt64(bytes) > byteLimit() {
                throw .maxBytes
            }
            controlReservation.bytes = max(controlReservation.bytes, UInt64(bytes))
        }

        // parity: native/src/native-span-feed.zig#Stream.setControlSequenceReservation [status=implemented hash=d0f56ba6e7eb]
        public func setControlSequenceReservation(_ reservation: ControlSequenceReservation) throws(StreamError) {
            if bounded() && reservation.bytes > byteLimit() {
                throw .maxBytes
            }
            controlReservation = reservation
        }

        // parity: native/src/native-span-feed.zig#Stream.write [status=implemented hash=841403636474]
        public func write(_ data: [UInt8]) throws(StreamError) {
            let status = NativeZigSpanFeed.streamWrite(self, bytes: data)
            try Self.throwIfError(status)
        }

        // parity: native/src/native-span-feed.zig#Stream.writeAtomic [status=implemented hash=228914964ad1]
        public func writeAtomic(_ data: [UInt8]) throws(StreamError) {
            let shouldNotify = try writeAtomicUnnotified(data)
            finish(notify: shouldNotify)
        }

        // parity: native/src/native-span-feed.zig#Stream.writeAtomicUnnotified [status=implemented hash=499d8b966231]
        public func writeAtomicUnnotified(_ data: [UInt8]) throws(StreamError) -> Bool {
            guard !core.isClosed else { throw .invalid }
            if data.isEmpty { return false }
            if bounded() && UInt64(data.count) > atomicByteLimit() {
                throw .maxBytes
            }
            let info = try reserveLocked(minLen: UInt32(data.count))
            _ = info
            reservedBuffer = data
            var shouldNotify = false
            try commitReservedLocked(len: UInt32(data.count), notify: &shouldNotify)
            return shouldNotify
        }

        // parity: native/src/native-span-feed.zig#Stream.writeReservedControlAtomic [status=implemented hash=6a95a13c65b3]
        public func writeReservedControlAtomic(_ data: [UInt8]) throws(StreamError) {
            guard !core.isClosed else { throw .invalid }
            guard UInt64(data.count) <= controlReservation.bytes || controlReservation.bytes == 0 else {
                throw .maxBytes
            }
            try writeAtomic(data)
        }

        // parity: native/src/native-span-feed.zig#Stream.reserve [status=implemented hash=947e7993fe43]
        public func reserve(minLen: UInt32) throws(StreamError) -> ReserveInfo {
            try reserveLocked(minLen: minLen)
        }

        // parity: native/src/native-span-feed.zig#Stream.commitReserved [status=implemented hash=2a93ea1655dc]
        public func commitReserved(len: UInt32) throws(StreamError) {
            var shouldNotify = false
            try commitReservedLocked(len: len, notify: &shouldNotify)
            finish(notify: shouldNotify)
        }

        // parity: native/src/native-span-feed.zig#Stream.commit [status=implemented hash=c5dd936bead3]
        public func commit() throws(StreamError) {
            var shouldNotify = false
            try commitLocked(notify: &shouldNotify)
            finish(notify: shouldNotify)
        }

        // parity: native/src/native-span-feed.zig#Stream.getStats [status=implemented hash=2bf919298a97]
        public func getStats() -> Stats {
            Stats(core: core.stats)
        }

        // parity: native/src/native-span-feed.zig#Stream.assertInvariants [status=implemented hash=b3cfd8313d9b]
        public func assertInvariants() {
            let s = getStats()
            precondition(s.pendingSpans <= s.outstandingSpans)
            precondition(options.chunkSize > 0)
        }

        // parity: native/src/native-span-feed.zig#Stream.bounded [status=implemented hash=031cfe2dfc21]
        public func bounded() -> Bool {
            options.growthPolicy == GrowthPolicy.block.rawValue || options.maxBytes > 0
        }

        // parity: native/src/native-span-feed.zig#Stream.byteLimit [status=implemented hash=3e86d5075fd8]
        public func byteLimit() -> UInt64 {
            if options.maxBytes > 0 { return options.maxBytes }
            return UInt64(options.chunkSize) &* UInt64(max(1, options.initialChunks))
        }

        // parity: native/src/native-span-feed.zig#Stream.atomicByteLimit [status=implemented hash=a4b6545023c1]
        public func atomicByteLimit() -> UInt64 {
            let limit = byteLimit()
            let available = limit > controlReservation.bytes ? limit - controlReservation.bytes : 0
            return min(UInt64(options.chunkSize), available)
        }

        // parity: native/src/native-span-feed.zig#Stream.hasAtomicCapacity [status=implemented hash=b7c7803346c2]
        public func hasAtomicCapacity() -> Bool {
            !core.isClosed && atomicByteLimit() > 0 && UInt64(core.stats.outstandingBytes) < byteLimit()
        }

        // parity: native/src/native-span-feed.zig#Stream.setStagedBytes [status=implemented hash=ab90ffb82ded]
        public func setStagedBytes(_ bytes: Int) throws(StreamError) {
            guard bytes >= 0 else { throw .invalid }
            if bounded() && UInt64(bytes) > byteLimit() { throw .maxBytes }
            pendingBytes.reserveCapacity(bytes)
        }

        // parity: native/src/native-span-feed.zig#Stream.hasPendingBytes [status=implemented hash=9dc1482c7785]
        public func hasPendingBytes() -> Bool {
            !pendingBytes.isEmpty
        }

        // parity: native/src/native-span-feed.zig#Stream.setOptions [status=implemented hash=5344f45fa501]
        public func setOptions(_ newOptions: Options) throws(StreamError) {
            guard !core.isClosed else { throw .invalid }
            options = NativeZigSpanFeed.normalizeOptions(newOptions)
        }

        // parity: native/src/native-span-feed.zig#Stream.close [status=implemented hash=095374bb2a0f]
        public func close() throws(StreamError) {
            let status = NativeZigSpanFeed.streamClose(self)
            try Self.throwIfError(status)
        }

        // parity: native/src/native-span-feed.zig#Stream.destroy [status=implemented hash=9274f78b1404]
        public func destroy() {
            _ = NativeZigSpanFeed.destroyNativeSpanFeed(self)
        }

        // parity: native/src/native-span-feed.zig#Stream.tryDestroy [status=implemented hash=753950070a10]
        public func tryDestroy() throws(StreamError) {
            guard activeReservation == nil else { throw .busy }
            destroy()
        }

        // parity: native/src/native-span-feed.zig#Stream.copyQueuedPrefix [status=implemented hash=1181fb35f2d7]
        public func copyQueuedPrefix(into out: inout [UInt8]) -> Int {
            let n = min(out.count, pendingBytes.count)
            for i in 0..<n {
                out[i] = pendingBytes[i]
            }
            return n
        }

        // parity: native/src/native-span-feed.zig#Stream.drainSpans [status=implemented hash=c7d7ef3b9802]
        public func drainSpans(maxSpans: UInt32) -> [SpanInfo] {
            NativeZigSpanFeed.streamDrainSpans(self, maxSpans: maxSpans)
        }

        // parity: native/src/native-span-feed.zig#Stream.hasPendingSpans [status=implemented hash=15df77e58f98]
        public func hasPendingSpans() -> Bool {
            core.stats.pendingSpans > 0
        }

        // parity: native/src/native-span-feed.zig#Stream.releaseSpan [status=implemented hash=65e28bdfa2df]
        public func releaseSpan(slotIndex: UInt32, releaseId: UInt64) throws(StreamError) {
            let status = NativeZigSpanFeed.streamReleaseSpan(self, slotIndex: slotIndex, releaseId: releaseId)
            try Self.throwIfError(status)
        }

        // parity: native/src/native-span-feed.zig#Stream.markSpanConsumed [status=implemented hash=73d1db07515c]
        public func markSpanConsumed(_ span: SpanInfo) {
            core.releaseSpan(slotIndex: Int(span.slotIndex), releaseId: span.releaseId)
        }

        // parity: native/src/native-span-feed.zig#Stream.finish [status=implemented hash=86ec29d9b889]
        public func finish(notify shouldNotify: Bool, queuedOverride: UInt32 = 0) {
            guard shouldNotify else { return }
            let queued = queuedOverride != 0 ? Int(queuedOverride) : core.stats.pendingSpans
            notify(.dataAvailable, arg0: queued, arg1: core.stats.spansCommitted)
        }

        // parity: native/src/native-span-feed.zig#Stream.commitLocked [status=implemented hash=930999577ac4]
        public func commitLocked(notify shouldNotify: inout Bool) throws(StreamError) {
            guard !core.isClosed else { throw .invalid }
            guard !pendingBytes.isEmpty else { return }
            let payload = pendingBytes
            pendingBytes.removeAll(keepingCapacity: true)
            do {
                _ = try core.commit(payload)
                shouldNotify = true
            } catch let err {
                try Self.throwIfError(NativeZigSpanFeed.mapSpanFeedError(err))
            }
        }

        // parity: native/src/native-span-feed.zig#Stream.reserveLocked [status=implemented hash=d3244a699047]
        public func reserveLocked(minLen: UInt32) throws(StreamError) -> ReserveInfo {
            let (status, info) = NativeZigSpanFeed.streamReserve(self, minLen: minLen)
            try Self.throwIfError(status)
            guard let info else { throw .invalid }
            return info
        }

        // parity: native/src/native-span-feed.zig#Stream.commitReservedLocked [status=implemented hash=bfca5d0e0ee1]
        public func commitReservedLocked(len: UInt32, notify shouldNotify: inout Bool) throws(StreamError) {
            guard let reservation = activeReservation else { throw .invalid }
            activeReservation = nil
            let payload = Array(reservedBuffer.prefix(Int(len)))
            reservedBuffer.removeAll(keepingCapacity: false)
            do {
                _ = try core.commit(reservation: reservation, bytes: payload)
                shouldNotify = true
            } catch let err {
                try Self.throwIfError(NativeZigSpanFeed.mapSpanFeedError(err))
            }
        }

        private static func throwIfError(_ status: Int32) throws(StreamError) {
            switch status {
            case Status.ok: return
            case Status.errNoSpace: throw .noSpace
            case Status.errMaxBytes: throw .maxBytes
            case Status.errAlloc: throw .outOfMemory
            case Status.errBusy: throw .busy
            default: throw .invalid
            }
        }
    }

    // parity: native/src/native-span-feed.zig#defaultOptions [status=implemented hash=efa38698b4f1]
    public static func defaultOptions() -> Options {
        Options(
            chunkSize: 64 * 1024,
            initialChunks: 2,
            maxBytes: 0,
            growthPolicy: GrowthPolicy.grow.rawValue,
            autoCommitOnFull: 1,
            spanQueueCapacity: 0
        )
    }

    // parity: native/src/native-span-feed.zig#normalizeOptions [status=implemented hash=6bbddf7be5fa]
    public static func normalizeOptions(_ opts: Options) -> Options {
        var out = opts
        if out.chunkSize == 0 { out.chunkSize = 64 * 1024 }
        if out.initialChunks == 0 { out.initialChunks = 1 }
        if out.spanQueueCapacity == 0 { out.spanQueueCapacity = spanQueueCapacityDefault }
        return out
    }

    // parity: native/src/native-span-feed.zig#createNativeSpanFeedWithAllocator [status=implemented hash=6293d06ff897]
    public static func createNativeSpanFeedWithAllocator(options: Options? = nil) -> Stream {
        Stream(options: normalizeOptions(options ?? defaultOptions()))
    }

    // parity: native/src/native-span-feed.zig#streamSetCallback [status=implemented hash=809af5f9bbe2]
    public static func streamSetCallback(_ stream: Stream?, callback: CallbackFn?) {
        stream?.callback = callback
    }

    // parity: native/src/native-span-feed.zig#attachNativeSpanFeed [status=implemented hash=662f599cc5c2]
    public static func attachNativeSpanFeed(_ stream: Stream?) -> Int32 {
        guard let stream else { return Status.errInvalid }
        guard !stream.core.isClosed else { return Status.errInvalid }
        stream.attached = true
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamClose [status=implemented hash=bd271193fd84]
    public static func streamClose(_ stream: Stream?) -> Int32 {
        guard let stream else { return Status.errInvalid }
        if !stream.pendingBytes.isEmpty {
            _ = streamCommit(stream)
        }
        stream.core.close()
        stream.notify(.closed)
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#destroyNativeSpanFeed [status=implemented hash=7b531d97c4a4]
    public static func destroyNativeSpanFeed(_ stream: Stream?) -> Int32 {
        guard let stream else { return Status.errInvalid }
        if !stream.core.isClosed {
            stream.core.close()
        }
        stream.pendingBytes.removeAll()
        stream.activeReservation = nil
        stream.reservedBuffer.removeAll()
        stream.callback = nil
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamReleaseSpan [status=implemented hash=a663a11d10f9]
    public static func streamReleaseSpan(_ stream: Stream?, slotIndex: UInt32, releaseId: UInt64) -> Int32 {
        guard let stream else { return Status.errInvalid }
        stream.core.releaseSpan(slotIndex: Int(slotIndex), releaseId: releaseId)
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamWrite [status=implemented hash=3912a04e2807]
    public static func streamWrite(_ stream: Stream?, bytes: [UInt8]) -> Int32 {
        guard let stream else { return Status.errInvalid }
        guard !stream.core.isClosed else { return Status.errInvalid }
        if bytes.isEmpty { return Status.ok }
        stream.pendingBytes.append(contentsOf: bytes)
        if stream.options.autoCommitOnFull != 0 && stream.pendingBytes.count >= Int(stream.options.chunkSize) {
            return streamCommit(stream)
        }
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamCommit [status=implemented hash=3de1d4ff83e0]
    public static func streamCommit(_ stream: Stream?) -> Int32 {
        guard let stream else { return Status.errInvalid }
        guard !stream.core.isClosed else { return Status.errInvalid }
        guard !stream.pendingBytes.isEmpty else { return Status.ok }
        let payload = stream.pendingBytes
        stream.pendingBytes.removeAll(keepingCapacity: true)
        do {
            let span = try stream.core.commit(payload)
            stream.notify(.dataAvailable, arg0: span.len, arg1: span.releaseId)
            return Status.ok
        } catch let err {
            return mapSpanFeedError(err)
        }
    }

    // parity: native/src/native-span-feed.zig#streamReserve [status=implemented hash=f437052fa375]
    public static func streamReserve(_ stream: Stream?, minLen: UInt32) -> (status: Int32, info: ReserveInfo?) {
        guard let stream else { return (Status.errInvalid, nil) }
        guard !stream.core.isClosed else { return (Status.errInvalid, nil) }
        guard stream.activeReservation == nil else { return (Status.errBusy, nil) }
        do {
            let reservation = try stream.core.reserve(Int(minLen))
            stream.activeReservation = reservation
            stream.reservedBuffer = Array(repeating: 0, count: Int(minLen))
            return (
                Status.ok,
                ReserveInfo(
                    chunkIndex: UInt32(max(0, reservation.chunkIndex)),
                    offset: UInt32(max(0, reservation.offset)),
                    len: UInt32(max(0, reservation.capacity)),
                    reserved: minLen
                )
            )
        } catch let err {
            return (mapSpanFeedError(err), nil)
        }
    }

    // parity: native/src/native-span-feed.zig#streamCommitReserved [status=implemented hash=08ddca041a4a]
    public static func streamCommitReserved(_ stream: Stream?, bytes: [UInt8]) -> Int32 {
        guard let stream else { return Status.errInvalid }
        guard let reservation = stream.activeReservation else { return Status.errInvalid }
        stream.activeReservation = nil
        stream.reservedBuffer.removeAll(keepingCapacity: false)
        do {
            let span = try stream.core.commit(reservation: reservation, bytes: bytes)
            stream.notify(.dataAvailable, arg0: span.len, arg1: span.releaseId)
            return Status.ok
        } catch let err {
            return mapSpanFeedError(err)
        }
    }

    // parity: native/src/native-span-feed.zig#streamSetOptions [status=implemented hash=85d7d2f18d79]
    public static func streamSetOptions(_ stream: Stream?, options: Options) -> Int32 {
        guard let stream else { return Status.errInvalid }
        stream.options = normalizeOptions(options)
        return Status.ok
    }

    // parity: native/src/native-span-feed.zig#streamGetStats [status=implemented hash=c12af3c63f91]
    public static func streamGetStats(_ stream: Stream?) -> (status: Int32, stats: Stats?) {
        guard let stream else { return (Status.errInvalid, nil) }
        return (Status.ok, Stats(core: stream.core.stats))
    }

    // parity: native/src/native-span-feed.zig#streamDrainSpans [status=implemented hash=5662680842a6]
    public static func streamDrainSpans(_ stream: Stream?, maxSpans: UInt32) -> [SpanInfo] {
        guard let stream, maxSpans > 0 else { return [] }
        return stream.core.drain(maxSpans: Int(maxSpans)).map(SpanInfo.init(core:))
    }

    private static func mapSpanFeedError(_ error: NativeSpanFeedError) -> Int32 {
        switch error {
        case .backpressured, .spanQueueFull: return Status.errNoSpace
        case .outOfSpace: return Status.errMaxBytes
        case .closed, .invalidLength, .reservationMismatch: return Status.errInvalid
        }
    }
}
