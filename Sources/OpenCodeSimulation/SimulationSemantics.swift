import Synchronization
import OpenCodeProtocol
import OpenTUIRenderables

/// Weakly-bound semantic UI metadata attached to live OpenTUI renderables
/// (`packages/simulation/src/frontend/semantics.ts`).
///
/// Semantic renderables set an explicit stable OpenTUI `id` so `ui.state` and `ui.snapshot`
/// expose the same identity while hierarchy and element handles come from the live render tree.
// parity: simulation/src/frontend/semantics.ts#SimulationSemantics [status=implemented hash=bdab92315e30]
public enum SimulationSemantics {
    /// Semantic properties attached to a renderable (`Omit<SemanticNode, "id" | "element" | "parent">`).
    // parity: simulation/src/frontend/semantics.ts#Definition [status=implemented hash=a249934ad0aa]
    public struct Definition: Equatable, Hashable, Sendable, Codable {
        public let instance: String?
        public let role: String
        public let label: String?
        public let focused: Bool?
        public let selected: Bool?
        public let expanded: Bool?
        public let disabled: Bool?

        public init(
            instance: String? = nil,
            role: String,
            label: String? = nil,
            focused: Bool? = nil,
            selected: Bool? = nil,
            expanded: Bool? = nil,
            disabled: Bool? = nil
        ) {
            self.instance = instance
            self.role = role
            self.label = label
            self.focused = focused
            self.selected = selected
            self.expanded = expanded
            self.disabled = disabled
        }
    }

    private struct WeakBinding: @unchecked Sendable {
        weak var renderable: Renderable?
        let provider: () -> Definition
    }

    private static let bindings = Mutex<[ObjectIdentifier: WeakBinding]>([:])

    /// Returns a binder closure attaching a lazy semantic `Definition` provider to a `Renderable`.
    public static func bind(_ definition: @escaping () -> Definition) -> (Renderable) -> Void {
        return { renderable in
            let key = ObjectIdentifier(renderable)
            bindings.withLock { map in
                if map.count > 256 {
                    map = map.filter { $0.value.renderable != nil }
                }
                map[key] = WeakBinding(renderable: renderable, provider: definition)
            }
        }
    }

    /// Reads the lazy semantic `Definition` provider bound to `renderable`, or `nil` if unbound.
    // parity: simulation/src/frontend/semantics.ts#read [status=implemented hash=ec9b4376b387]
    public static func read(_ renderable: Renderable) -> (() -> Definition)? {
        let key = ObjectIdentifier(renderable)
        return bindings.withLock { map in
            guard let entry = map[key], entry.renderable === renderable else {
                return nil
            }
            return entry.provider
        }
    }
}
