// parity: core/src/lib/border.ts#BorderCharacters [status=implemented hash=3666406c7884]
public struct BorderCharacters: Equatable, Hashable, Sendable, Codable {
    public let topLeft: String
    public let topRight: String
    public let bottomLeft: String
    public let bottomRight: String
    public let horizontal: String
    public let vertical: String
    public let topT: String
    public let bottomT: String
    public let leftT: String
    public let rightT: String
    public let cross: String

    public init(
        topLeft: String,
        topRight: String,
        bottomLeft: String,
        bottomRight: String,
        horizontal: String,
        vertical: String,
        topT: String,
        bottomT: String,
        leftT: String,
        rightT: String,
        cross: String
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
        self.horizontal = horizontal
        self.vertical = vertical
        self.topT = topT
        self.bottomT = bottomT
        self.leftT = leftT
        self.rightT = rightT
        self.cross = cross
    }
}

// parity: core/src/lib/border.ts#BorderStyle [status=implemented hash=54f08d0a33fa]
public enum BorderStyle: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case single
    case double
    case rounded
    case heavy
}

// parity: core/src/lib/border.ts#BorderSides [status=implemented hash=4a16cff573ce]
public enum BorderSide: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case top
    case right
    case bottom
    case left
}

// parity: core/src/lib/border.ts#BorderSidesConfig [status=implemented hash=ce8db1211c84]
public struct BorderSidesConfig: Equatable, Hashable, Sendable, Codable {
    public let top: Bool
    public let right: Bool
    public let bottom: Bool
    public let left: Bool

    public init(top: Bool, right: Bool, bottom: Bool, left: Bool) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

public enum BorderSpec: Equatable, Hashable, Sendable {
    case enabled(Bool)
    case sides([BorderSide])
}

// parity: core/src/lib/border.ts#isValidBorderStyle [status=implemented hash=c919deb7f6fa]
public func isValidBorderStyle(_ value: String?) -> Bool {
    guard let value else { return false }
    return BorderStyle(rawValue: value) != nil
}

// parity: core/src/lib/border.ts#parseBorderStyle [status=implemented hash=7be31fa3ccbc]
public func parseBorderStyle(_ value: String?, fallback: BorderStyle = .single) -> BorderStyle {
    guard let value, let parsed = BorderStyle(rawValue: value) else {
        return fallback
    }
    return parsed
}

// parity: core/src/lib/border.ts#BorderChars [status=implemented hash=1d932117c2cf]
public enum BorderChars {
    public static let single = BorderCharacters(
        topLeft: "┌", topRight: "┐", bottomLeft: "└", bottomRight: "┘",
        horizontal: "─", vertical: "│",
        topT: "┬", bottomT: "┴", leftT: "├", rightT: "┤", cross: "┼"
    )

    public static let double = BorderCharacters(
        topLeft: "╔", topRight: "╗", bottomLeft: "╚", bottomRight: "╝",
        horizontal: "═", vertical: "║",
        topT: "╦", bottomT: "╩", leftT: "╠", rightT: "╣", cross: "╬"
    )

    public static let rounded = BorderCharacters(
        topLeft: "╭", topRight: "╮", bottomLeft: "╰", bottomRight: "╯",
        horizontal: "─", vertical: "│",
        topT: "┬", bottomT: "┴", leftT: "├", rightT: "┤", cross: "┼"
    )

    public static let heavy = BorderCharacters(
        topLeft: "┏", topRight: "┓", bottomLeft: "┗", bottomRight: "┛",
        horizontal: "━", vertical: "┃",
        topT: "┳", bottomT: "┻", leftT: "┣", rightT: "┫", cross: "╋"
    )

    public static func forStyle(_ style: BorderStyle) -> BorderCharacters {
        switch style {
        case .single: single
        case .double: double
        case .rounded: rounded
        case .heavy: heavy
        }
    }
}

// parity: core/src/lib/border.ts#getBorderFromSides [status=implemented hash=74f4bb0c0c7d]
public func getBorderFromSides(_ sides: BorderSidesConfig) -> BorderSpec {
    var result: [BorderSide] = []
    if sides.top { result.append(.top) }
    if sides.right { result.append(.right) }
    if sides.bottom { result.append(.bottom) }
    if sides.left { result.append(.left) }
    return result.isEmpty ? .enabled(false) : .sides(result)
}

// parity: core/src/lib/border.ts#getBorderSides [status=implemented hash=6da9b7e7a862]
public func getBorderSides(_ border: BorderSpec) -> BorderSidesConfig {
    switch border {
    case .enabled(true):
        return BorderSidesConfig(top: true, right: true, bottom: true, left: true)
    case .enabled(false):
        return BorderSidesConfig(top: false, right: false, bottom: false, left: false)
    case .sides(let sides):
        return BorderSidesConfig(
            top: sides.contains(.top),
            right: sides.contains(.right),
            bottom: sides.contains(.bottom),
            left: sides.contains(.left)
        )
    }
}

// parity: core/src/lib/border.ts#borderCharsToArray [status=implemented hash=b7e829be98bb]
public func borderCharsToArray(_ chars: BorderCharacters) -> [UInt32] {
    func firstScalar(_ str: String) -> UInt32 {
        str.unicodeScalars.first?.value ?? 0x20
    }
    return [
        firstScalar(chars.topLeft),
        firstScalar(chars.topRight),
        firstScalar(chars.bottomLeft),
        firstScalar(chars.bottomRight),
        firstScalar(chars.horizontal),
        firstScalar(chars.vertical),
        firstScalar(chars.topT),
        firstScalar(chars.bottomT),
        firstScalar(chars.leftT),
        firstScalar(chars.rightT),
        firstScalar(chars.cross),
    ]
}

// parity: core/src/lib/border.ts#BorderCharArrays [status=implemented hash=0bb7ab34ba47]
public enum BorderCharArrays {
    public static let single = borderCharsToArray(BorderChars.single)
    public static let double = borderCharsToArray(BorderChars.double)
    public static let rounded = borderCharsToArray(BorderChars.rounded)
    public static let heavy = borderCharsToArray(BorderChars.heavy)
}
