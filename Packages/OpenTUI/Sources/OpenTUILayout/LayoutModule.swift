import OpenTUICore

/// Pure-Swift Flexbox layout engine contract (port target for `yoga.ts` / `yoga.zig`).
public enum FlexDirection: String, Equatable, Hashable, Sendable, Codable {
    case row
    case rowReverse = "row-reverse"
    case column
    case columnReverse = "column-reverse"
}

public struct LayoutRect: Equatable, Hashable, Sendable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
