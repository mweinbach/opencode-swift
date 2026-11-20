import OpenCodeProtocol
import OpenCodeUtil
import OpenTUICore
import OpenTUIRenderables

/// Headless UI action playback, element inspection, semantic snapshotting, and frame capture
/// (`packages/simulation/src/frontend/actions.ts`).
public enum SimulationActions {
    /// Frontend simulation action type re-exported from `OpenCodeProtocol.Frontend.Action`.
    // parity: simulation/src/frontend/actions.ts#Action [status=implemented hash=4dc5e9973487]
    public typealias Action = OpenCodeProtocol.Frontend.Action

    /// Interactive renderable geometry/state descriptor re-exported from `OpenCodeProtocol.Frontend.Element`.
    // parity: simulation/src/frontend/actions.ts#Element [status=implemented hash=d17a86657e1f]
    public typealias Element = OpenCodeProtocol.Frontend.Element

    /// Validation or stale-target error raised while executing UI actions or extracting semantic snapshots.
    public struct ActionError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Live renderer harness driven by `SimulationServer` and scripted action runners.
    // parity: simulation/src/frontend/actions.ts#Harness [status=implemented hash=8355ad7ae180]
    public struct Harness: @unchecked Sendable {
        public let renderer: CliRenderer
        public let mockInput: MockInput
        public let mockMouse: MockMouse
        public let resize: (Int, Int) -> Void
        public let renderOnce: () async -> Void
        public let screen: () -> String

        public init(
            renderer: CliRenderer,
            mockInput: MockInput,
            mockMouse: MockMouse,
            resize: @escaping (Int, Int) -> Void,
            renderOnce: @escaping () async -> Void,
            screen: @escaping () -> String
        ) {
            self.renderer = renderer
            self.mockInput = mockInput
            self.mockMouse = mockMouse
            self.resize = resize
            self.renderOnce = renderOnce
            self.screen = screen
        }
    }

    private static let namedKeyCodes: Set<String> = [
        "RETURN", "LINEFEED", "TAB", "BACKSPACE", "DELETE", "HOME", "END", "ESCAPE",
        "ARROW_UP", "ARROW_DOWN", "ARROW_RIGHT", "ARROW_LEFT",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    ]

    /// Normalizes a key name to OpenTUI's uppercase `KeyCodes` identifier when it matches a known named key.
    public static func normalizeKeyInput(_ key: String) -> String {
        let named = key.uppercased()
        return namedKeyCodes.contains(named) ? named : key
    }

    /// Builds the `Harness` that `SimulationServer` drives for either a headless `TestRenderer` or a visible `CliRenderer`.
    // parity: simulation/src/frontend/actions.ts#createHarness [status=implemented hash=86c711f5c2eb]
    public static func createHarness(_ renderer: CliRenderer) -> Harness {
        let setup = SimulationRenderer.setupFor(renderer)
        let mockInput = setup?.mockInput ?? MockInput(
            renderer: renderer,
            options: MockKeysOptions(kittyKeyboard: renderer.useKittyKeyboard)
        )
        let mockMouse = setup?.mockMouse ?? MockMouse(renderer: renderer)
        let resize: (Int, Int) -> Void = { cols, rows in
            if let setup {
                setup.resize(width: cols, height: rows)
            } else {
                renderer.resize(width: cols, height: rows)
            }
        }
        let renderOnce: () async -> Void = {
            if let setup {
                setup.renderOnce()
            } else {
                renderer.renderOnce()
            }
        }
        // Read directly from the live presented render buffer so recording redirection does not affect screen matching.
        let screen: () -> String = {
            String(decoding: renderer.currentRenderBuffer.getRealCharBytes(addLineBreaks: true), as: UTF8.self)
        }
        return Harness(
            renderer: renderer,
            mockInput: mockInput,
            mockMouse: mockMouse,
            resize: resize,
            renderOnce: renderOnce,
            screen: screen
        )
    }

    /// Enumerates all visible, non-destroyed interactive (focusable, clickable, or editor) renderables in the tree.
    // parity: simulation/src/frontend/actions.ts#elements [status=implemented hash=1a644dd14c8c]
    public static func elements(_ renderer: CliRenderer) -> [Element] {
        let focusedEditor = renderer.currentFocusedEditor
        return allRenderables(from: renderer.root)
            .filter { $0.visible && !$0.isDestroyed }
            .map { renderable in
                let clickable = hasMouseListeners(renderable) && hitsRenderable(renderer: renderer, renderable: renderable)
                return Element(
                    id: renderable.id,
                    num: Double(renderable.num),
                    x: Double(renderable.screenX),
                    y: Double(renderable.screenY),
                    width: Double(renderable.width),
                    height: Double(renderable.height),
                    focusable: renderable.focusable,
                    focused: renderable.focused,
                    clickable: clickable,
                    editor: focusedEditor === renderable
                )
            }
            .filter { $0.focusable || $0.clickable || $0.editor }
    }

    /// Captures current focus state and interactive element table from `harness`.
    // parity: simulation/src/frontend/actions.ts#state [status=implemented hash=8138eac15f2b]
    public static func state(_ harness: Harness) -> OpenCodeProtocol.Frontend.State {
        let focusedRenderable = harness.renderer.currentFocusedRenderable.map { Double($0.num) }
        return OpenCodeProtocol.Frontend.State(
            focused: OpenCodeProtocol.Frontend.State.Focused(
                renderable: focusedRenderable,
                editor: harness.renderer.currentFocusedEditor != nil
            ),
            elements: elements(harness.renderer)
        )
    }

    /// Walks the visible render tree, evaluates lazy semantic bindings, validates uniqueness and schema invariants,
    /// and returns a `opencode-ui-snapshot-v1` `SemanticSnapshot`.
    // parity: simulation/src/frontend/actions.ts#snapshot [status=implemented hash=9f9c046feb38]
    public static func snapshot(_ harness: Harness) throws -> OpenCodeProtocol.Frontend.SemanticSnapshot {
        var ids = Set<String>()
        var nodes: [OpenCodeProtocol.Frontend.SemanticNode] = []

        func visit(_ renderable: Renderable, parent: String?) throws {
            guard renderable.visible && !renderable.isDestroyed else { return }
            let definition = SimulationSemantics.read(renderable)?()
            if let definition {
                guard !renderable.id.isEmpty else {
                    throw ActionError("semantic node id must be non-empty")
                }
                guard !definition.role.isEmpty else {
                    throw ActionError("semantic node role must be non-empty for id: \(renderable.id)")
                }
                if let instance = definition.instance, instance.isEmpty {
                    throw ActionError("semantic node instance must be non-empty for id: \(renderable.id)")
                }
                if let label = definition.label, label.isEmpty {
                    throw ActionError("semantic node label must be non-empty for id: \(renderable.id)")
                }
                guard ids.insert(renderable.id).inserted else {
                    throw ActionError("duplicate semantic UI id: \(renderable.id)")
                }
                nodes.append(
                    OpenCodeProtocol.Frontend.SemanticNode(
                        id: renderable.id,
                        instance: definition.instance,
                        parent: parent,
                        role: definition.role,
                        label: definition.label,
                        element: Int(renderable.num),
                        focused: definition.focused,
                        selected: definition.selected,
                        expanded: definition.expanded,
                        disabled: definition.disabled
                    )
                )
            }
            let ancestor = definition != nil ? renderable.id : parent
            for child in renderable.getChildren() {
                try visit(child, parent: ancestor)
            }
        }

        try visit(harness.renderer.root, parent: nil)
        return try OpenCodeProtocol.Frontend.SemanticSnapshot(nodes: nodes)
    }

    /// Checks whether the rendered screen literally contains `text` (case-sensitive substring check).
    // parity: simulation/src/frontend/actions.ts#matches [status=implemented hash=32d2f65775c8]
    public static func matches(_ harness: Harness, text: String) -> Bool {
        matches(screen: harness.screen, text: text)
    }

    /// Overload matching literal `text` against an arbitrary `screen` closure.
    public static func matches(screen: () -> String, text: String) -> Bool {
        if text.isEmpty { return true }
        return screen().contains(text)
    }

    /// Renders a frame and captures styled cell spans and visible `ImageRenderable` RGBA placements.
    // parity: simulation/src/frontend/actions.ts#capture [status=implemented hash=7631435beec8]
    public static func capture(_ harness: Harness) async -> OpenCodeProtocol.Frontend.CapturedFrame {
        await harness.renderOnce()
        let buffer = harness.renderer.currentRenderBuffer
        let lines = buffer.getSpanLines().map { line in
            OpenCodeProtocol.Frontend.CapturedFrame.Line(
                spans: line.spans.map { span in
                    let (fgR, fgG, fgB, fgA) = span.fg.toInts()
                    let (bgR, bgG, bgB, bgA) = span.bg.toInts()
                    return OpenCodeProtocol.Frontend.CapturedFrame.Span(
                        text: span.text,
                        fg: OpenCodeProtocol.Frontend.Color(Double(fgR), Double(fgG), Double(fgB), Double(fgA)),
                        bg: OpenCodeProtocol.Frontend.Color(Double(bgR), Double(bgG), Double(bgB), Double(bgA)),
                        attributes: Double(span.attributes),
                        width: Double(span.width)
                    )
                }
            )
        }
        return OpenCodeProtocol.Frontend.CapturedFrame(
            cols: Double(buffer.width),
            rows: Double(buffer.height),
            cursor: OpenCodeProtocol.Frontend.CapturedFrame.Cursor(0, 0),
            lines: lines,
            images: captureImages(renderer: harness.renderer)
        )
    }

    /// Executes one UI simulation `Action`, triggers a frame render, and returns the updated UI `State`.
    // parity: simulation/src/frontend/actions.ts#execute [status=implemented hash=fb0c7362449b]
    @discardableResult
    public static func execute(_ harness: Harness, action: Action) async throws -> OpenCodeProtocol.Frontend.State {
        switch action {
        case .type(let text):
            harness.mockInput.typeText(text)

        case .press(let key, let modifiers):
            harness.mockInput.pressKey(normalizeKeyInput(key), modifiers: toMockKeyModifiers(modifiers))

        case .enter:
            harness.mockInput.pressEnter()

        case .arrow(let direction):
            harness.mockInput.pressArrow(toScrollDirection(direction))

        case .focus(let target):
            if let found = allRenderables(from: harness.renderer.root).first(where: { Double($0.num) == target }) {
                found.focus()
            }

        case .mouse(let params):
            let x: Int
            let y: Int
            switch params {
            case .move(let mx, let my, _),
                 .down(let mx, let my, _, _),
                 .up(let mx, let my, _, _),
                 .scroll(let mx, let my, _, _):
                x = mx
                y = my
            }
            if x < 0 || y < 0 || x >= harness.renderer.width || y >= harness.renderer.height {
                throw ActionError("mouse position must be within the terminal viewport")
            }
            switch params {
            case .move(_, _, let modifiers):
                SimulationRenderer.recordPointer(harness.renderer, action: .move, x: x, y: y)
                harness.mockMouse.moveTo(x: x, y: y, modifiers: toMouseModifiers(modifiers))
            case .down(_, _, let button, let modifiers):
                SimulationRenderer.recordPointer(harness.renderer, action: .down, x: x, y: y)
                harness.mockMouse.pressDown(
                    x: x,
                    y: y,
                    button: toMouseButton(button),
                    modifiers: toMouseModifiers(modifiers)
                )
            case .up(_, _, let button, let modifiers):
                SimulationRenderer.recordPointer(harness.renderer, action: .up, x: x, y: y)
                harness.mockMouse.release(
                    x: x,
                    y: y,
                    button: toMouseButton(button),
                    modifiers: toMouseModifiers(modifiers)
                )
            case .scroll(_, _, let direction, let modifiers):
                SimulationRenderer.recordPointer(harness.renderer, action: .scroll, x: x, y: y)
                harness.mockMouse.scroll(
                    x: x,
                    y: y,
                    direction: toScrollDirection(direction),
                    modifiers: toMouseModifiers(modifiers)
                )
            }

        case .click(let targetNum, let x, let y, let semantic):
            guard let target = allRenderables(from: harness.renderer.root).first(where: { Double($0.num) == targetNum }),
                  target.visible,
                  !target.isDestroyed
            else {
                throw ActionError("click target is stale or unavailable: \(formatTargetNum(targetNum))")
            }
            if let semantic {
                let current = try snapshot(harness).nodes.first { Double($0.element) == targetNum }
                if current?.id != semantic.id || current?.instance != semantic.instance || current?.element != semantic.element {
                    throw ActionError("semantic click target is stale or unavailable: \(semantic.id)")
                }
            }
            guard x.isFinite, x >= 0, x < Double(target.width),
                  y.isFinite, y >= 0, y < Double(target.height)
            else {
                throw ActionError("click position must be within the target element")
            }
            let absX = target.screenX + Int(x)
            let absY = target.screenY + Int(y)
            SimulationRenderer.recordPointer(harness.renderer, action: .click, x: absX, y: absY)
            harness.mockMouse.click(x: absX, y: absY)

        case .resize(let cols, let rows):
            guard cols.isFinite, rows.isFinite,
                  cols.rounded() == cols, rows.rounded() == rows,
                  cols > 0, rows > 0
            else {
                throw ActionError("resize cols and rows must be positive integers")
            }
            let intCols = Int(cols)
            let intRows = Int(rows)
            harness.resize(intCols, intRows)
            SimulationRenderer.recordResize(harness.renderer, cols: intCols, rows: intRows)
        }

        await harness.renderOnce()
        return state(harness)
    }

    // MARK: - Internal Helpers

    private static func allRenderables(from renderable: Renderable) -> [Renderable] {
        var result: [Renderable] = [renderable]
        for child in renderable.getChildren() {
            result.append(contentsOf: allRenderables(from: child))
        }
        return result
    }

    private static func hasMouseListeners(_ renderable: Renderable) -> Bool {
        renderable.onMouse != nil ||
        renderable.onMouseDown != nil ||
        renderable.onMouseUp != nil ||
        renderable.onMouseMove != nil ||
        renderable.onMouseDrag != nil ||
        renderable.onMouseDragEnd != nil ||
        renderable.onMouseDrop != nil ||
        renderable.onMouseOver != nil ||
        renderable.onMouseOut != nil ||
        renderable.onMouseScroll != nil
    }

    private static func hitsRenderable(renderer: CliRenderer, renderable: Renderable) -> Bool {
        guard renderable.width > 0 && renderable.height > 0 else { return false }
        let x = renderable.screenX + renderable.width / 2
        let y = renderable.screenY + renderable.height / 2
        let target = renderer.hitTest(x: x, y: y)
        return allRenderables(from: renderable).contains { $0.num == target }
    }

    private static func captureImages(renderer: CliRenderer) -> [OpenCodeProtocol.Frontend.CapturedImage] {
        var captured: [OpenCodeProtocol.Frontend.CapturedImage] = []
        for renderable in allRenderables(from: renderer.root) {
            guard let imgRenderable = renderable as? ImageRenderable,
                  imgRenderable.visible,
                  !imgRenderable.isDestroyed,
                  let source = imgRenderable.image
            else {
                continue
            }
            let fitted: (width: Int, height: Int)
            if imgRenderable.fit == .cover {
                fitted = (imgRenderable.width, imgRenderable.height)
            } else {
                fitted = imgRenderable.getFittedSize(targetWidth: imgRenderable.width, targetHeight: imgRenderable.height)
            }
            guard fitted.width > 0 && fitted.height > 0 else { continue }
            let x = imgRenderable.screenX + (imgRenderable.width - fitted.width) / 2
            let y = imgRenderable.screenY + (imgRenderable.height - fitted.height) / 2

            let pixelWidth: Int
            let pixelHeight: Int
            let rgbaBytes: [UInt8]

            if imgRenderable.fit == .cover {
                let targetAspect = Double(imgRenderable.width) / (Double(imgRenderable.height) * imgRenderable.cellAspectRatio)
                let sourceAspect = Double(source.width) / Double(source.height)
                let cropW = sourceAspect > targetAspect
                    ? max(1, Int((Double(source.height) * targetAspect).rounded()))
                    : source.width
                let cropH = sourceAspect > targetAspect
                    ? source.height
                    : max(1, Int((Double(source.width) / targetAspect).rounded()))
                let left = max(0, (source.width - cropW) / 2)
                let top = max(0, (source.height - cropH) / 2)
                let clampedW = min(cropW, source.width - left)
                let clampedH = min(cropH, source.height - top)
                pixelWidth = clampedW
                pixelHeight = clampedH
                var cropped: [UInt8] = []
                cropped.reserveCapacity(clampedW * clampedH * 4)
                let rowStride = source.width * 4
                for row in top..<(top + clampedH) {
                    let start = row * rowStride + left * 4
                    cropped.append(contentsOf: source.pixels[start..<(start + clampedW * 4)])
                }
                rgbaBytes = cropped
            } else {
                pixelWidth = source.width
                pixelHeight = source.height
                rgbaBytes = source.pixels
            }

            captured.append(
                OpenCodeProtocol.Frontend.CapturedImage(
                    x: Double(x),
                    y: Double(y),
                    width: Double(fitted.width),
                    height: Double(fitted.height),
                    pixelWidth: Double(pixelWidth),
                    pixelHeight: Double(pixelHeight),
                    rgba: bytesToBase64(rgbaBytes)
                )
            )
        }
        return captured
    }

    private static func toMockKeyModifiers(_ modifiers: OpenCodeProtocol.Frontend.KeyModifiers?) -> MockKeyModifiers? {
        guard let modifiers else { return nil }
        return MockKeyModifiers(
            shift: modifiers.shift ?? false,
            ctrl: modifiers.ctrl ?? false,
            meta: modifiers.meta ?? false,
            super: modifiers.superKey ?? false,
            hyper: modifiers.hyper ?? false
        )
    }

    private static func toMouseModifiers(_ modifiers: OpenCodeProtocol.Frontend.MouseModifiers?) -> OpenTUICore.MouseModifiers {
        OpenTUICore.MouseModifiers(
            shift: modifiers?.shift ?? false,
            alt: modifiers?.alt ?? false,
            ctrl: modifiers?.ctrl ?? false
        )
    }

    private static func toMouseButton(_ button: OpenCodeProtocol.Frontend.MouseButton?) -> Int {
        switch button ?? .left {
        case .left: return MockMouseButtons.left
        case .middle: return MockMouseButtons.middle
        case .right: return MockMouseButtons.right
        }
    }

    private static func toScrollDirection(_ direction: OpenCodeProtocol.Frontend.Direction) -> ScrollDirection {
        switch direction {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }

    private static func formatTargetNum(_ value: Double) -> String {
        if value.isFinite && value.rounded() == value {
            return String(Int64(value))
        }
        return String(value)
    }
}
