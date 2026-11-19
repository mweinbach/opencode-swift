import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables

// MARK: - TUIView Protocol

/// Idiomatic Swift declarative view protocol (Swift counterpart to `@opentui/solid` & `@opentui/react`).
///
/// Composite views implement `body` with `@TUIViewBuilder`. Primitive views declare
/// `public typealias Body = Never` and override `resolveNodes()`.
public protocol TUIView {
    associatedtype Body: TUIView

    @TUIViewBuilder
    var body: Body { get }

    /// Lowers this declarative view into virtual-DOM `TUIViewNode` descriptors.
    func resolveNodes() -> [TUIViewNode]
}

public extension TUIView {
    func resolveNodes() -> [TUIViewNode] {
        body.resolveNodes()
    }
}

public extension TUIView where Body == Never {
    var body: Never {
        return fatalError("Primitive TUIView (\(Self.self)) does not have a body; call resolveNodes() instead.")
    }
}

extension Never: TUIView {
    public typealias Body = Never

    public func resolveNodes() -> [TUIViewNode] {
        []
    }
}

// MARK: - Type-Erased View Wrapper

/// Type-erased wrapper around any `TUIView`, used by `@TUIViewBuilder` and container initializers.
public struct AnyTUIView: TUIView {
    public typealias Body = Never

    private let _resolve: () -> [TUIViewNode]

    public init<V: TUIView>(_ view: V) {
        if let existing = view as? AnyTUIView {
            self = existing
        } else {
            self._resolve = { view.resolveNodes() }
        }
    }

    public func resolveNodes() -> [TUIViewNode] {
        _resolve()
    }
}

// MARK: - TUIViewNode (Virtual-DOM Representation)

/// Virtual-DOM node produced by lowering a `TUIView` tree.
///
/// Carries structural identity (`kind`, optional `key`), component `props`, ordered `modifiers`,
/// child nodes, and mount/patch closures targeting live `OpenTUIRenderables.Renderable` instances.
public struct TUIViewNode {
    /// Component kind identifier (e.g. `"box"`, `"vstack"`, `"text"`, `"input"`, `"custom:..."`).
    public let kind: String

    /// Explicit reconciliation key (from `.key(_:)` or `TUIForEach`).
    public var key: String?

    /// Inspectable component properties snapshot.
    public var props: [String: Any]

    /// Ordered declarative modifiers applied on mount and reconciled on patch.
    public var modifiers: [TUIModifier]

    /// Child virtual-DOM nodes for container components.
    public var children: [TUIViewNode]

    /// When `true`, `TUIViewReconciler` treats this node as a leaf and does not manage its children.
    public let isLeaf: Bool

    private let _mount: (any RenderContext) -> Renderable
    private let _patch: (Renderable) -> Bool

    public init(
        kind: String,
        key: String? = nil,
        props: [String: Any] = [:],
        modifiers: [TUIModifier] = [],
        children: [TUIViewNode] = [],
        isLeaf: Bool = false,
        mount: @escaping (any RenderContext) -> Renderable,
        patch: @escaping (Renderable) -> Bool
    ) {
        self.kind = kind
        self.key = key
        self.props = props
        self.modifiers = modifiers
        self.children = children
        self.isLeaf = isLeaf
        self._mount = mount
        self._patch = patch
    }

    /// Mounts a fresh `Renderable` in `ctx` and applies all attached modifiers.
    public func mount(in ctx: any RenderContext) -> Renderable {
        let renderable = _mount(ctx)
        applyTUIModifiers(modifiers, to: renderable)
        return renderable
    }

    /// Patches an existing `Renderable` in place if compatible, returning `true` on success.
    @discardableResult
    public func patch(_ existing: Renderable) -> Bool {
        guard _patch(existing) else { return false }
        applyTUIModifiers(modifiers, to: existing)
        return true
    }

    /// Internal reconciler patch hook that resets removed modifiers before patching component props and applying new modifiers.
    @discardableResult
    internal func patch(_ existing: Renderable, previousModifiers: [TUIModifier]) -> Bool {
        resetRemovedTUIModifiers(previous: previousModifiers, next: modifiers, on: existing)
        guard _patch(existing) else { return false }
        applyTUIModifiers(modifiers, to: existing)
        return true
    }

    /// Returns a copy of this node with `modifier` appended (and updates `key` for `.key(_:)`).
    public func appending(modifier: TUIModifier) -> TUIViewNode {
        var copy = self
        if case .key(let newKey) = modifier {
            copy.key = newKey
        }
        copy.modifiers.append(modifier)
        return copy
    }

    /// Returns a copy of this node with `modifier` prepended (lower precedence than existing modifiers).
    internal func prepending(modifier: TUIModifier) -> TUIViewNode {
        var copy = self
        if case .key(let newKey) = modifier, copy.key == nil {
            copy.key = newKey
        }
        copy.modifiers.insert(modifier, at: 0)
        return copy
    }
}

// MARK: - Result Builder

/// Declarative `@resultBuilder` for composing `TUIView` hierarchies with full Swift control flow.
@resultBuilder
public enum TUIViewBuilder {
    public static func buildBlock(_ components: AnyTUIView...) -> AnyTUIView {
        if components.isEmpty {
            return AnyTUIView(EmptyTUIView())
        }
        if components.count == 1 {
            return components[0]
        }
        return AnyTUIView(TUIGroup(children: components))
    }

    public static func buildExpression<V: TUIView>(_ expression: V) -> AnyTUIView {
        AnyTUIView(expression)
    }

    public static func buildOptional(_ component: AnyTUIView?) -> AnyTUIView {
        component ?? AnyTUIView(EmptyTUIView())
    }

    public static func buildEither(first component: AnyTUIView) -> AnyTUIView {
        component
    }

    public static func buildEither(second component: AnyTUIView) -> AnyTUIView {
        component
    }

    public static func buildArray(_ components: [AnyTUIView]) -> AnyTUIView {
        AnyTUIView(TUIGroup(children: components))
    }

    public static func buildLimitedAvailability(_ component: AnyTUIView) -> AnyTUIView {
        component
    }
}

// MARK: - Core Structural Views

/// A view that renders no nodes.
public struct EmptyTUIView: TUIView {
    public typealias Body = Never

    public init() {}

    public func resolveNodes() -> [TUIViewNode] {
        []
    }
}

/// Transparent grouping view that flattens its children into the enclosing container without adding a layout node.
public struct TUIGroup: TUIView {
    public typealias Body = Never

    public let children: [AnyTUIView]

    public init(children: [AnyTUIView]) {
        self.children = children
    }

    public init(@TUIViewBuilder content: () -> AnyTUIView) {
        self.children = [content()]
    }

    public func resolveNodes() -> [TUIViewNode] {
        var result: [TUIViewNode] = []
        for child in children {
            result.append(contentsOf: child.resolveNodes())
        }
        return result
    }
}

/// Keyed iteration view over any `Collection`, assigning deterministic reconciliation keys to every emitted node.
public struct TUIForEach<Data: Collection, ID: Hashable>: TUIView {
    public typealias Body = Never

    public let data: Data
    private let idKeyPath: KeyPath<Data.Element, ID>
    private let content: (Data.Element) -> AnyTUIView

    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @TUIViewBuilder content: @escaping (Data.Element) -> AnyTUIView
    ) {
        self.data = data
        self.idKeyPath = id
        self.content = content
    }

    public init(
        _ data: Data,
        @TUIViewBuilder content: @escaping (Data.Element) -> AnyTUIView
    ) where Data.Element: Identifiable, ID == Data.Element.ID {
        self.data = data
        self.idKeyPath = \.id
        self.content = content
    }

    public init(
        _ data: Range<Int>,
        @TUIViewBuilder content: @escaping (Int) -> AnyTUIView
    ) where Data == Range<Int>, ID == Int {
        self.data = data
        self.idKeyPath = \.self
        self.content = content
    }

    public func resolveNodes() -> [TUIViewNode] {
        var resolved: [TUIViewNode] = []
        for element in data {
            let itemKey = String(describing: element[keyPath: idKeyPath])
            let itemNodes = content(element).resolveNodes()
            if itemNodes.count == 1 {
                var node = itemNodes[0]
                if let existingKey = node.key {
                    node.key = "\(itemKey):\(existingKey)"
                } else {
                    node.key = itemKey
                }
                resolved.append(node)
            } else {
                for (index, var node) in itemNodes.enumerated() {
                    if let existingKey = node.key {
                        node.key = "\(itemKey):\(existingKey)"
                    } else {
                        node.key = "\(itemKey)#\(index)"
                    }
                    resolved.append(node)
                }
            }
        }
        return resolved
    }
}

/// Escape-hatch view for mounting any custom `Renderable` subclass into a declarative `TUIView` hierarchy.
public struct TUICustomRenderable<R: Renderable>: TUIView {
    public typealias Body = Never

    public let kind: String
    public let make: (any RenderContext) -> R
    public let update: ((R) -> Void)?
    public let content: AnyTUIView?

    public init(
        kind: String? = nil,
        make: @escaping (any RenderContext) -> R,
        update: ((R) -> Void)? = nil
    ) {
        self.kind = kind.map { "custom:\($0)" } ?? "custom:\(ObjectIdentifier(R.self))"
        self.make = make
        self.update = update
        self.content = nil
    }

    public init(
        kind: String? = nil,
        make: @escaping (any RenderContext) -> R,
        update: ((R) -> Void)? = nil,
        @TUIViewBuilder content: () -> AnyTUIView
    ) {
        self.kind = kind.map { "custom:\($0)" } ?? "custom:\(ObjectIdentifier(R.self))"
        self.make = make
        self.update = update
        self.content = content()
    }

    public func resolveNodes() -> [TUIViewNode] {
        let makeFn = make
        let updateFn = update
        let childNodes = content?.resolveNodes() ?? []
        let isLeafNode = content == nil
        return [
            TUIViewNode(
                kind: kind,
                props: ["renderableType": String(describing: R.self)],
                children: childNodes,
                isLeaf: isLeafNode,
                mount: { ctx in
                    let instance = makeFn(ctx)
                    updateFn?(instance)
                    return instance
                },
                patch: { existing in
                    guard let typed = existing as? R else { return false }
                    updateFn?(typed)
                    return true
                }
            )
        ]
    }
}
