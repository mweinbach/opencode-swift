/// Encodes a UTF-8 string as unpadded URL-safe base64.
// parity: util/src/encode.ts#base64Encode [status=implemented hash=7c4b243db216]
public func base64Encode(_ value: String) -> String {
    let standard = bytesToBase64(Array(value.utf8))
    var out = ""
    out.reserveCapacity(standard.utf8.count)
    for byte in standard.utf8 {
        switch byte {
        case UInt8(ascii: "+"):
            out.append("-")
        case UInt8(ascii: "/"):
            out.append("_")
        case UInt8(ascii: "="):
            continue
        default:
            out.append(Character(Unicode.Scalar(byte)))
        }
    }
    return out
}

/// Decodes unpadded (or padded) URL-safe base64 into a UTF-8 string.
// parity: util/src/encode.ts#base64Decode [status=implemented hash=5802f561ea96]
public func base64Decode(_ value: String) throws(Base64Error) -> String {
    var standard = ""
    standard.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
        switch byte {
        case UInt8(ascii: "-"):
            standard.append("+")
        case UInt8(ascii: "_"):
            standard.append("/")
        default:
            standard.append(Character(Unicode.Scalar(byte)))
        }
    }
    let bytes = try base64ToBytes(standard)
    return String(decoding: bytes, as: UTF8.self)
}

/// FNV-1a 32-bit hash over UTF-16 code units, encoded as lowercase base36.
/// Matches `packages/util/src/encode.ts#checksum` exactly (including non-ASCII & surrogate pairs).
// parity: util/src/encode.ts#checksum [status=implemented hash=55b1d17100d8]
public func checksum(_ content: String) -> String? {
    let units = Array(content.utf16)
    return checksumUTF16(units[...])
}

/// Sampled FNV-1a checksum for large strings using 5 fixed 4096-unit windows.
// parity: util/src/encode.ts#sampledChecksum [status=implemented hash=fd820c3012df]
public func sampledChecksum(_ content: String, limit: Int = 500_000) -> String? {
    let units = Array(content.utf16)
    if units.isEmpty { return nil }
    if units.count <= limit {
        return checksumUTF16(units[...])
    }

    let size = 4096
    let count = units.count
    let points = [
        0,
        Int((Double(count) * 0.25).rounded(.down)),
        Int((Double(count) * 0.5).rounded(.down)),
        Int((Double(count) * 0.75).rounded(.down)),
        count - size,
    ]

    let samples = points.map { point -> String in
        let start = max(0, min(count - size, point - (size / 2)))
        let end = min(count, start + size)
        return checksumUTF16(units[start..<end]) ?? ""
    }

    return "\(count):\(samples.joined(separator: ":"))"
}

private func checksumUTF16(_ units: ArraySlice<UInt16>) -> String? {
    if units.isEmpty { return nil }
    var hash: UInt32 = 0x811C_9DC5
    for codeUnit in units {
        hash ^= UInt32(codeUnit)
        hash = hash &* 0x0100_0193
    }
    return String(hash, radix: 36, uppercase: false)
}
