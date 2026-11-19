private let uuidHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

/// Generates a lowercase RFC 4122 version-4 UUID using Swift's cross-platform CSPRNG
/// (`SystemRandomNumberGenerator`: arc4random_buf / getrandom / BCryptGenRandom / WASI random_get).
// parity: util/src/uuid.ts#uuid [status=implemented hash=7239ded37e95]
public func uuid() -> String {
    var rng = SystemRandomNumberGenerator()
    return uuid(using: &rng)
}

public func uuid<G: RandomNumberGenerator>(using generator: inout G) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let lo = generator.next()
    let hi = generator.next()
    for i in 0..<8 {
        bytes[i] = UInt8((lo >> (i * 8)) & 0xFF)
        bytes[i + 8] = UInt8((hi >> (i * 8)) & 0xFF)
    }
    // Version 4 (0100xxxx) and RFC 4122 variant (10xxxxxx)
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80

    var out: [UInt8] = []
    out.reserveCapacity(36)
    for (index, byte) in bytes.enumerated() {
        if index == 4 || index == 6 || index == 8 || index == 10 {
            out.append(UInt8(ascii: "-"))
        }
        out.append(uuidHexDigits[Int(byte >> 4)])
        out.append(uuidHexDigits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}
