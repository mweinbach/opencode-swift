/// Terminal mouse event kinds, matching `packages/core/src/lib/parse.mouse.ts`.
// parity: core/src/lib/parse.mouse.ts#MouseEventType [status=implemented hash=076d10a16238]
public enum MouseEventType: String, Equatable, Hashable, Sendable, Codable {
    case down
    case up
    case move
    case drag
    case dragEnd = "drag-end"
    case drop
    case over
    case out
    case scroll
}

/// Direction of a mouse wheel scroll event.
public enum ScrollDirection: String, Equatable, Hashable, Sendable, Codable {
    case up
    case down
    case left
    case right
}

/// Mouse wheel scroll direction and delta.
// parity: core/src/lib/parse.mouse.ts#ScrollInfo [status=implemented hash=cd5d31ea0d05]
public struct ScrollInfo: Equatable, Hashable, Sendable, Codable {
    public var direction: ScrollDirection
    public var delta: Int

    public init(direction: ScrollDirection, delta: Int) {
        self.direction = direction
        self.delta = delta
    }
}

/// Keyboard modifier flags reported on a mouse event.
public struct MouseModifiers: Equatable, Hashable, Sendable, Codable {
    public var shift: Bool
    public var alt: Bool
    public var ctrl: Bool

    public init(shift: Bool = false, alt: Bool = false, ctrl: Bool = false) {
        self.shift = shift
        self.alt = alt
        self.ctrl = ctrl
    }
}

/// Decoded terminal mouse event (0-based cell coordinates).
// parity: core/src/lib/parse.mouse.ts#RawMouseEvent [status=implemented hash=9af01deb2638]
public struct RawMouseEvent: Equatable, Hashable, Sendable, Codable {
    public var type: MouseEventType
    public var button: Int
    public var x: Int
    public var y: Int
    public var modifiers: MouseModifiers
    public var scroll: ScrollInfo?

    public init(
        type: MouseEventType,
        button: Int,
        x: Int,
        y: Int,
        modifiers: MouseModifiers = MouseModifiers(),
        scroll: ScrollInfo? = nil
    ) {
        self.type = type
        self.button = button
        self.x = x
        self.y = y
        self.modifiers = modifiers
        self.scroll = scroll
    }
}
