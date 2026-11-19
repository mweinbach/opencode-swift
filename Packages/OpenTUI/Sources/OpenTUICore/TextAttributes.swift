/// Cell attribute bitmask matching `opentui.h` (`OT_ATTR_*`) and `packages/core/src/types.ts`.
// parity: core/src/types.ts#TextAttributes [status=implemented hash=81f8e20ac68b]
public enum TextAttributes {
    public static let none: UInt32 = 0
    public static let bold: UInt32 = 1 << 0
    public static let dim: UInt32 = 1 << 1
    public static let italic: UInt32 = 1 << 2
    public static let underline: UInt32 = 1 << 3
    public static let blink: UInt32 = 1 << 4
    public static let inverse: UInt32 = 1 << 5
    public static let hidden: UInt32 = 1 << 6
    public static let strikethrough: UInt32 = 1 << 7

    public static let baseMask: UInt32 = 0xFF
    public static let linkShift: UInt32 = 8
    public static let linkMask: UInt32 = 0x00FF_FFFF
}

// parity: core/src/types.ts#getBaseAttributes [status=implemented hash=9dd669e9d08b]
public func getBaseAttributes(_ attr: UInt32) -> UInt32 {
    attr & TextAttributes.baseMask
}

// parity: core/src/utils.ts#createTextAttributes [status=implemented hash=9ae5fcfa148d]
public func createTextAttributes(
    bold: Bool = false,
    italic: Bool = false,
    underline: Bool = false,
    dim: Bool = false,
    blink: Bool = false,
    inverse: Bool = false,
    reverse: Bool = false,
    hidden: Bool = false,
    strikethrough: Bool = false
) -> UInt32 {
    var attributes = TextAttributes.none
    if bold { attributes |= TextAttributes.bold }
    if italic { attributes |= TextAttributes.italic }
    if underline { attributes |= TextAttributes.underline }
    if dim { attributes |= TextAttributes.dim }
    if blink { attributes |= TextAttributes.blink }
    if inverse || reverse { attributes |= TextAttributes.inverse }
    if hidden { attributes |= TextAttributes.hidden }
    if strikethrough { attributes |= TextAttributes.strikethrough }
    return attributes
}

// parity: core/src/utils.ts#attributesWithLink [status=implemented hash=3ab0e95bea99]
public func attributesWithLink(_ baseAttributes: UInt32, linkId: UInt32) -> UInt32 {
    let base = baseAttributes & TextAttributes.baseMask
    let linkBits = (linkId & TextAttributes.linkMask) << TextAttributes.linkShift
    return base | linkBits
}

// parity: core/src/utils.ts#getLinkId [status=implemented hash=f5d2e6b3516e]
public func getLinkId(_ attributes: UInt32) -> UInt32 {
    (attributes >> TextAttributes.linkShift) & TextAttributes.linkMask
}
