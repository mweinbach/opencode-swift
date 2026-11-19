import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables

// MARK: - Mounted Virtual-DOM Instance

/// Live reconciled instance binding a `TUIViewNode` descriptor to its mounted `Renderable`.
public final class MountedTUIViewNode: @unchecked Sendable {
    public let kind: String
    public var key: String?
    public let renderable: Renderable
    internal var modifiers: [TUIModifier]
    public internal(set) var children: [MountedTUIViewNode]

    internal init(
        kind: String,
        key: String?,
        renderable: Renderable,
        modifiers: [TUIModifier],
        children: [MountedTUIViewNode] = []
    ) {
        self.kind = kind
        self.key = key
        self.renderable = renderable
        self.modifiers = modifiers
        self.children = children
    }
}

// MARK: - TUIViewReconciler

/// Diffs and reconciles declarative `TUIView` / `TUIViewNode` trees onto live `Renderable` containers.
///
/// Keyed & matching-kind nodes are reused in place (preserving focus, cursor position, scroll offsets,
/// and edit buffers), updated props/modifiers are patched, moved nodes are reordered in minimal DOM
/// operations, and removed nodes are cleanly detached and destroyed.
public final class TUIViewReconciler: @unchecked Sendable {
    public private(set) var mountedRoots: [MountedTUIViewNode] = []

    public init() {}

    /// Reconciles `view` into `parent` within `ctx`, returning the live top-level mounted nodes.
    @discardableResult
    public func reconcile<V: TUIView>(
        _ view: V,
        into parent: Renderable,
        ctx: any RenderContext
    ) -> [MountedTUIViewNode] {
        reconcile(nodes: view.resolveNodes(), into: parent, ctx: ctx)
    }

    /// Reconciles a pre-lowered `[TUIViewNode]` list into `parent` within `ctx`.
    @discardableResult
    public func reconcile(
        nodes: [TUIViewNode],
        into parent: Renderable,
        ctx: any RenderContext
    ) -> [MountedTUIViewNode] {
        mountedRoots = reconcileChildren(
            oldMounted: mountedRoots,
            newNodes: nodes,
            parent: parent,
            ctx: ctx
        )
        return mountedRoots
    }

    /// Removes and recursively destroys all mounted root renderables from `parent`.
    public func unmount(from parent: Renderable) {
        let roots = mountedRoots
        mountedRoots = []
        for mounted in roots {
            if mounted.renderable.parent === parent {
                parent.remove(mounted.renderable)
            }
            if !mounted.renderable.isDestroyed {
                mounted.renderable.destroyRecursively()
            }
        }
    }

    // MARK: - Core Child-List Reconciliation

    private func reconcileChildren(
        oldMounted: [MountedTUIViewNode],
        newNodes: [TUIViewNode],
        parent: Renderable,
        ctx: any RenderContext
    ) -> [MountedTUIViewNode] {
        guard !parent.isDestroyed else { return [] }

        // Index old nodes by explicit key and track positional unkeyed slots.
        var keyedOld: [String: [Int]] = [:]
        var unkeyedOldIndices: [Int] = []
        for (idx, old) in oldMounted.enumerated() {
            if let key = old.key {
                keyedOld[key, default: []].append(idx)
            } else {
                unkeyedOldIndices.append(idx)
            }
        }

        var usedOld = Array(repeating: false, count: oldMounted.count)
        var unkeyedCursor = 0
        var nextMounted: [MountedTUIViewNode] = []
        nextMounted.reserveCapacity(newNodes.count)

        // 1. Match, patch-in-place, or mount fresh nodes.
        for newNode in newNodes {
            var matchedIndex: Int? = nil

            if let key = newNode.key {
                if let candidates = keyedOld[key] {
                    for candidateIdx in candidates where !usedOld[candidateIdx] {
                        let candidate = oldMounted[candidateIdx]
                        if candidate.kind == newNode.kind && !candidate.renderable.isDestroyed {
                            matchedIndex = candidateIdx
                            break
                        }
                    }
                }
            } else {
                let slot = unkeyedCursor
                unkeyedCursor += 1
                if slot < unkeyedOldIndices.count {
                    let candidateIdx = unkeyedOldIndices[slot]
                    if !usedOld[candidateIdx] {
                        let candidate = oldMounted[candidateIdx]
                        if candidate.kind == newNode.kind && !candidate.renderable.isDestroyed {
                            matchedIndex = candidateIdx
                        }
                    }
                }
            }

            if let oldIdx = matchedIndex {
                let reused = oldMounted[oldIdx]
                if newNode.patch(reused.renderable, previousModifiers: reused.modifiers) {
                    usedOld[oldIdx] = true
                    reused.key = newNode.key
                    reused.modifiers = newNode.modifiers
                    if !newNode.isLeaf {
                        reused.children = reconcileChildren(
                            oldMounted: reused.children,
                            newNodes: newNode.children,
                            parent: reused.renderable,
                            ctx: ctx
                        )
                    }
                    nextMounted.append(reused)
                    continue
                }
            }

            let fresh = mountTree(newNode, ctx: ctx)
            nextMounted.append(fresh)
        }

        // 2. Detach & destroy all unmatched old nodes before reordering/inserting new nodes.
        for (oldIdx, old) in oldMounted.enumerated() where !usedOld[oldIdx] {
            if old.renderable.parent === parent {
                parent.remove(old.renderable)
            }
            if !old.renderable.isDestroyed {
                old.renderable.destroyRecursively()
            }
        }

        // 3. Synchronize parent's child order to match `nextMounted` with minimal moves.
        for (desiredIndex, mounted) in nextMounted.enumerated() {
            let target = mounted.renderable
            let currentChildren = parent.getChildren()
            if desiredIndex < currentChildren.count && currentChildren[desiredIndex] === target {
                continue
            }
            if desiredIndex < currentChildren.count {
                _ = parent.insertBefore(target, anchor: currentChildren[desiredIndex])
            } else {
                _ = parent.add(target)
            }
        }

        return nextMounted
    }

    private func mountTree(_ node: TUIViewNode, ctx: any RenderContext) -> MountedTUIViewNode {
        let renderable = node.mount(in: ctx)
        var mountedChildren: [MountedTUIViewNode] = []
        if !node.isLeaf && !node.children.isEmpty {
            mountedChildren.reserveCapacity(node.children.count)
            for childNode in node.children {
                let mountedChild = mountTree(childNode, ctx: ctx)
                _ = renderable.add(mountedChild.renderable)
                mountedChildren.append(mountedChild)
            }
        }
        return MountedTUIViewNode(
            kind: node.kind,
            key: node.key,
            renderable: renderable,
            modifiers: node.modifiers,
            children: mountedChildren
        )
    }
}

// MARK: - TUIViewRoot (Reactive Root Controller)

/// Reactive root controller managing a declarative `TUIView` tree mounted inside a `CliRenderer`
/// or `TestRenderer` container.
public final class TUIViewRoot: @unchecked Sendable {
    public let renderer: CliRenderer
    public let container: Renderable
    public let reconciler: TUIViewReconciler

    /// When `true`, `invalidate()` invokes `renderer.renderOnce()` immediately after reconciling
    /// instead of only scheduling via `renderer.requestRender()`.
    public var autoRenderOnInvalidate: Bool = false

    private var viewBuilder: (() -> AnyTUIView)? = nil
    private var lastRenderedView: AnyTUIView? = nil
    private var isReconciling: Bool = false
    private var pendingInvalidate: Bool = false
    private var pendingRenderNow: Bool = false
    private var destroyToken: CliRendererListenerToken? = nil

    public var isMounted: Bool {
        !reconciler.mountedRoots.isEmpty
    }

    public var mountedRenderables: [Renderable] {
        reconciler.mountedRoots.map(\.renderable)
    }

    public init(renderer: CliRenderer, container: Renderable? = nil) {
        self.renderer = renderer
        self.container = container ?? renderer.root
        self.reconciler = TUIViewReconciler()
        attachDestroyHook()
    }

    public convenience init(testRenderer: TestRenderer, container: Renderable? = nil) {
        self.init(renderer: testRenderer.renderer, container: container)
    }

    public convenience init(
        renderer: CliRenderer,
        container: Renderable? = nil,
        autoRenderOnInvalidate: Bool = false,
        @TUIViewBuilder builder: @escaping () -> AnyTUIView
    ) {
        self.init(renderer: renderer, container: container)
        self.autoRenderOnInvalidate = autoRenderOnInvalidate
        render(builder)
    }

    public convenience init(
        testRenderer: TestRenderer,
        container: Renderable? = nil,
        autoRenderOnInvalidate: Bool = false,
        @TUIViewBuilder builder: @escaping () -> AnyTUIView
    ) {
        self.init(
            renderer: testRenderer.renderer,
            container: container,
            autoRenderOnInvalidate: autoRenderOnInvalidate,
            builder: builder
        )
    }

    deinit {
        if let token = destroyToken {
            renderer.off(token)
        }
    }

    private func attachDestroyHook() {
        destroyToken = renderer.on(.destroy) { [weak self] in
            guard let self else { return }
            self.viewBuilder = nil
            self.lastRenderedView = nil
            self.reconciler.unmount(from: self.container)
        }
    }

    /// Reconciles `view` into `container` and schedules a render pass.
    public func render<V: TUIView>(_ view: V) {
        guard !renderer.isDestroyed && !container.isDestroyed else { return }
        let erased = AnyTUIView(view)
        self.lastRenderedView = erased
        reconcileNow(erased, renderNow: false)
    }

    /// Registers a reactive view builder closure and reconciles its initial view tree immediately.
    public func render(@TUIViewBuilder _ builder: @escaping () -> AnyTUIView) {
        guard !renderer.isDestroyed && !container.isDestroyed else { return }
        self.viewBuilder = builder
        let view = builder()
        self.lastRenderedView = view
        reconcileNow(view, renderNow: false)
    }

    /// Re-evaluates the active view builder (or last rendered view), reconciles changes into
    /// `container`, and schedules or executes a frame render.
    public func invalidate(renderNow: Bool = false) {
        guard !renderer.isDestroyed && !container.isDestroyed else { return }
        let shouldRenderNow = renderNow || autoRenderOnInvalidate
        if isReconciling {
            pendingInvalidate = true
            pendingRenderNow = pendingRenderNow || shouldRenderNow
            return
        }
        guard let nextView = viewBuilder?() ?? lastRenderedView else { return }
        lastRenderedView = nextView
        reconcileNow(nextView, renderNow: shouldRenderNow)
    }

    /// Synchronously executes one render pass on the underlying `CliRenderer`.
    public func renderOnce(force: Bool = false) {
        guard !renderer.isDestroyed else { return }
        renderer.renderOnce(force: force)
    }

    /// Detaches and recursively destroys all mounted views from `container`.
    public func unmount() {
        viewBuilder = nil
        lastRenderedView = nil
        pendingInvalidate = false
        pendingRenderNow = false
        reconciler.unmount(from: container)
        if !renderer.isDestroyed {
            renderer.requestRender()
        }
    }

    /// Looks up a mounted descendant `Renderable` by its `.id(_:)` string.
    public func findRenderable(id: String) -> Renderable? {
        container.findDescendantById(id)
    }

    private func reconcileNow(_ view: AnyTUIView, renderNow: Bool) {
        isReconciling = true
        _ = reconciler.reconcile(view, into: container, ctx: renderer)
        isReconciling = false

        var shouldFlushFrame = renderNow
        while pendingInvalidate && !renderer.isDestroyed && !container.isDestroyed {
            pendingInvalidate = false
            shouldFlushFrame = shouldFlushFrame || pendingRenderNow
            pendingRenderNow = false
            if let followUp = viewBuilder?() ?? lastRenderedView {
                lastRenderedView = followUp
                isReconciling = true
                _ = reconciler.reconcile(followUp, into: container, ctx: renderer)
                isReconciling = false
            }
        }

        guard !renderer.isDestroyed else { return }
        if shouldFlushFrame {
            renderer.renderOnce()
        } else {
            renderer.requestRender()
        }
    }
}

// MARK: - CliRenderer & TestRenderer Integration Conveniences

public extension CliRenderer {
    /// Mounts a declarative `TUIView` onto `self.root` and returns its `TUIViewRoot` controller.
    @discardableResult
    func mountView<V: TUIView>(_ view: V) -> TUIViewRoot {
        let root = TUIViewRoot(renderer: self)
        root.render(view)
        return root
    }

    /// Mounts a reactive `@TUIViewBuilder` onto `self.root` and returns its `TUIViewRoot` controller.
    @discardableResult
    func mountView(
        autoRenderOnInvalidate: Bool = false,
        @TUIViewBuilder _ builder: @escaping () -> AnyTUIView
    ) -> TUIViewRoot {
        TUIViewRoot(
            renderer: self,
            autoRenderOnInvalidate: autoRenderOnInvalidate,
            builder: builder
        )
    }
}

public extension TestRenderer {
    /// Mounts a declarative `TUIView` onto `self.root` and returns its `TUIViewRoot` controller.
    @discardableResult
    func mountView<V: TUIView>(_ view: V) -> TUIViewRoot {
        renderer.mountView(view)
    }

    /// Mounts a reactive `@TUIViewBuilder` onto `self.root` and returns its `TUIViewRoot` controller.
    @discardableResult
    func mountView(
        autoRenderOnInvalidate: Bool = false,
        @TUIViewBuilder _ builder: @escaping () -> AnyTUIView
    ) -> TUIViewRoot {
        renderer.mountView(autoRenderOnInvalidate: autoRenderOnInvalidate, builder)
    }
}
