/// How a selection occupies cells between stored anchor and focus offsets.
/// Default `.cell` includes the grapheme under the max endpoint.
/// `.boundary` is the half-open insert range `[min, max)`.
// parity: core/src/types.ts#SelectionOccupancy [status=implemented hash=2ebbd3aa5315]
public enum SelectionOccupancy: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case cell
    case boundary
}

/// How local cell coordinates expand into a highlight range.
// parity: core/src/types.ts#SelectionBehavior [status=implemented hash=af3382dff033]
public enum SelectionBehavior: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case cell
    case word
    case line
}

/// Alias matching upstream selection bounding rectangle (`ViewportBounds`).
public typealias SelectionBounds = ViewportBounds

/// Integer terminal cell coordinate for selection anchor/focus endpoints.
public struct SelectionPoint: Equatable, Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// Pure-Swift protocol abstracting a renderable participating in terminal text selection.
public protocol SelectableRenderable: AnyObject {
    var x: Int { get }
    var y: Int { get }
    var isDestroyed: Bool { get }
    func getSelectedText() -> String
}

private final class SelectionAnchor {
    private let renderable: any SelectableRenderable
    private let relativeX: Int
    private let relativeY: Int

    init(renderable: any SelectableRenderable, absoluteX: Int, absoluteY: Int) {
        self.renderable = renderable
        self.relativeX = absoluteX - renderable.x
        self.relativeY = absoluteY - renderable.y
    }

    var x: Int {
        renderable.x + relativeX
    }

    var y: Int {
        renderable.y + relativeY
    }
}

/// Splits a string on ASCII LF (`\n`, U+000A) preserving empty segments,
/// matching JavaScript `String.prototype.split("\n")` (including `\r\n` and consecutive `\n\n`).
private func splitByLineFeed(_ text: String) -> [String] {
    var result: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if scalar.value == 0x0A {
            result.append(String(current))
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(scalar)
        }
    }
    result.append(String(current))
    return result
}

/// Active terminal text selection state, bounds, and reading-order text assembly.
// parity: core/src/lib/selection.ts#Selection [status=implemented hash=50b1556576a0]
public final class Selection {
    private let _anchor: SelectionAnchor
    private var _focus: SelectionPoint
    private var _selectedRenderables: [any SelectableRenderable] = []
    private var _touchedRenderables: [any SelectableRenderable] = []
    private var _isActive: Bool = true
    private var _isDragging: Bool = true
    private var _isStart: Bool = false
    public var behavior: SelectionBehavior

    public init(
        anchorRenderable: any SelectableRenderable,
        anchor: SelectionPoint,
        focus: SelectionPoint,
        behavior: SelectionBehavior = .cell
    ) {
        self._anchor = SelectionAnchor(renderable: anchorRenderable, absoluteX: anchor.x, absoluteY: anchor.y)
        self._focus = focus
        self.behavior = behavior
    }

    // parity: core/src/lib/selection.ts#Selection.isStart [status=implemented hash=97d581340a28]
    public var isStart: Bool {
        get { _isStart }
        set { _isStart = newValue }
    }

    // parity: core/src/lib/selection.ts#Selection.anchor [status=implemented hash=ee9cc7dcc49b]
    public var anchor: SelectionPoint {
        SelectionPoint(x: _anchor.x, y: _anchor.y)
    }

    // parity: core/src/lib/selection.ts#Selection.focus [status=implemented hash=2733f4274016]
    public var focus: SelectionPoint {
        get { _focus }
        set { _focus = newValue }
    }

    // parity: core/src/lib/selection.ts#Selection.isActive [status=implemented hash=360101ea25b6]
    public var isActive: Bool {
        get { _isActive }
        set { _isActive = newValue }
    }

    // parity: core/src/lib/selection.ts#Selection.isDragging [status=implemented hash=f8daaaeec1b5]
    public var isDragging: Bool {
        get { _isDragging }
        set { _isDragging = newValue }
    }

    /// Selection bounds are inclusive of both anchor and focus:
    /// a selection from `(0, 0)` to `(0, 0)` covers 1×1 cell;
    /// from `(0, 0)` to `(5, 3)` covers 6×4 cells.
    // parity: core/src/lib/selection.ts#Selection.bounds [status=implemented hash=f1a7b769494b]
    public var bounds: SelectionBounds {
        let anchorX = _anchor.x
        let anchorY = _anchor.y
        let minX = min(anchorX, _focus.x)
        let maxX = max(anchorX, _focus.x)
        let minY = min(anchorY, _focus.y)
        let maxY = max(anchorY, _focus.y)

        return SelectionBounds(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    // parity: core/src/lib/selection.ts#Selection.updateSelectedRenderables [status=implemented hash=44b649410b61]
    public func updateSelectedRenderables(_ selectedRenderables: [any SelectableRenderable]) {
        _selectedRenderables = selectedRenderables
    }

    // parity: core/src/lib/selection.ts#Selection.selectedRenderables [status=implemented hash=2b98103eb8dd]
    public var selectedRenderables: [any SelectableRenderable] {
        _selectedRenderables
    }

    // parity: core/src/lib/selection.ts#Selection.updateTouchedRenderables [status=implemented hash=d0791cc5c810]
    public func updateTouchedRenderables(_ touchedRenderables: [any SelectableRenderable]) {
        _touchedRenderables = touchedRenderables
    }

    // parity: core/src/lib/selection.ts#Selection.touchedRenderables [status=implemented hash=2f955bbfa87f]
    public var touchedRenderables: [any SelectableRenderable] {
        _touchedRenderables
    }

    // parity: core/src/lib/selection.ts#Selection.getSelectedText [status=implemented hash=59ed3fc32c7c]
    public func getSelectedText() -> String {
        var selectedTextsByLine: [Int: [(x: Int, order: Int, text: String)]] = [:]

        // Sort by reading order: top-to-bottom, then left-to-right (stable).
        let indexed = _selectedRenderables.enumerated().sorted { lhs, rhs in
            let aY = lhs.element.y
            let bY = rhs.element.y
            if aY != bY {
                return aY < bY
            }
            if lhs.element.x != rhs.element.x {
                return lhs.element.x < rhs.element.x
            }
            return lhs.offset < rhs.offset
        }
        _selectedRenderables = indexed.map(\.element)

        let liveRenderables = _selectedRenderables.filter { !$0.isDestroyed }
        var insertionOrder = 0

        for renderable in liveRenderables {
            let text = renderable.getSelectedText()
            if text.isEmpty { continue }
            let lines = splitByLineFeed(text)
            for (index, lineText) in lines.enumerated() {
                let y = renderable.y + index
                selectedTextsByLine[y, default: []].append((x: renderable.x, order: insertionOrder, text: lineText))
                insertionOrder += 1
            }
        }

        return selectedTextsByLine
            .sorted { $0.key < $1.key }
            .map { _, segments in
                segments
                    .sorted { lhs, rhs in
                        if lhs.x != rhs.x {
                            return lhs.x < rhs.x
                        }
                        return lhs.order < rhs.order
                    }
                    .map(\.text)
                    .joined()
            }
            .joined(separator: "\n")
    }
}

// parity: core/src/lib/selection.ts#LocalSelectionBounds [status=implemented hash=f430b23cd262]
public struct LocalSelectionBounds: Equatable, Hashable, Sendable, Codable {
    public var anchorX: Int
    public var anchorY: Int
    public var focusX: Int
    public var focusY: Int
    public var isActive: Bool
    public var behavior: SelectionBehavior

    public init(
        anchorX: Int,
        anchorY: Int,
        focusX: Int,
        focusY: Int,
        isActive: Bool,
        behavior: SelectionBehavior = .cell
    ) {
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.focusX = focusX
        self.focusY = focusY
        self.isActive = isActive
        self.behavior = behavior
    }
}

// parity: core/src/lib/selection.ts#convertGlobalToLocalSelection [status=implemented hash=4466be1ef0ff]
public func convertGlobalToLocalSelection(
    _ globalSelection: Selection?,
    localX: Int,
    localY: Int
) -> LocalSelectionBounds? {
    guard let globalSelection, globalSelection.isActive else {
        return nil
    }

    let anchor = globalSelection.anchor
    let focus = globalSelection.focus
    return LocalSelectionBounds(
        anchorX: anchor.x - localX,
        anchorY: anchor.y - localY,
        focusX: focus.x - localX,
        focusY: focus.y - localY,
        isActive: true,
        behavior: globalSelection.behavior
    )
}
