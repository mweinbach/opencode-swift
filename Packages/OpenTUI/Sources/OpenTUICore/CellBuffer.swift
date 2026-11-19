/// Pure-Swift cell & framebuffer grid foundation for the native OpenTUI renderer port.
/// Compiles on all Swift platforms with zero Zig/C FFI requirement (optional C ABI bridge can be added later).
public struct TerminalCell: Equatable, Hashable, Sendable {
    public var scalar: UInt32
    public var foreground: RGBA
    public var background: RGBA
    public var attributes: UInt32

    public init(
        scalar: UInt32 = 0x20,
        foreground: RGBA = .defaultForeground(),
        background: RGBA = .defaultBackground(),
        attributes: UInt32 = TextAttributes.none
    ) {
        self.scalar = scalar
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }
}

public struct CellBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var cells: [TerminalCell]

    public init(width: Int, height: Int, fill: TerminalCell = TerminalCell()) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.cells = Array(repeating: fill, count: self.width * self.height)
    }

    @inline(__always)
    public func index(x: Int, y: Int) -> Int? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return y * width + x
    }

    public mutating func setCell(x: Int, y: Int, cell: TerminalCell) {
        guard let idx = index(x: x, y: y) else { return }
        cells[idx] = cell
    }

    public func cell(atX x: Int, y: Int) -> TerminalCell? {
        guard let idx = index(x: x, y: y) else { return nil }
        return cells[idx]
    }

    public mutating func clear(with cell: TerminalCell = TerminalCell()) {
        for i in cells.indices {
            cells[i] = cell
        }
    }
}
