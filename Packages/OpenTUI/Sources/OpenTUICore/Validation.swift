private let reservedDirNames: Set<String> = [
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
]

/// Validates a directory name across Windows and POSIX filesystems.
// parity: core/src/lib/validate-dir-name.ts#isValidDirectoryName [status=implemented hash=5559f4e45527]
public func isValidDirectoryName(_ name: String) -> Bool {
    if name.isEmpty { return false }

    let hasNonWhitespace = name.unicodeScalars.contains { scalar in
        // Match JS `.trim()` whitespace roughly for common ASCII/Unicode spaces
        !(scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A
            || scalar.value == 0x0B || scalar.value == 0x0C || scalar.value == 0x0D
            || scalar.value == 0xA0 || scalar.value == 0xFEFF)
    }
    if !hasNonWhitespace { return false }

    if reservedDirNames.contains(name.uppercased()) {
        return false
    }

    for byte in name.utf8 {
        if byte <= 0x1F { return false }
        switch byte {
        case UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: ":"),
             UInt8(ascii: "\""), UInt8(ascii: "|"), UInt8(ascii: "?"),
             UInt8(ascii: "*"), UInt8(ascii: "/"), UInt8(ascii: "\\"):
            return false
        default:
            continue
        }
    }

    if name.hasSuffix(".") || name.hasSuffix(" ") {
        return false
    }

    if name == "." || name == ".." {
        return false
    }

    return true
}
