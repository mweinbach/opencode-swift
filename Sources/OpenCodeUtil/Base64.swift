public enum Base64Error: Error, Equatable, Sendable {
    case invalidLength
    case invalidCharacter(UInt8)
    case invalidPadding
    case invalidUTF8
}

private let base64Alphabet: [UInt8] = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
)

private let base64DecodeTable: [Int8] = {
    var table = [Int8](repeating: -1, count: 256)
    for (index, byte) in base64Alphabet.enumerated() {
        table[Int(byte)] = Int8(index)
    }
    return table
}()

/// Encodes raw bytes as standard RFC 4648 base64.
// parity: util/src/base64.ts#bytesToBase64 [status=implemented hash=71b1ceeed0c0]
public func bytesToBase64(_ bytes: [UInt8]) -> String {
    if bytes.isEmpty { return "" }

    var output: [UInt8] = []
    output.reserveCapacity(((bytes.count + 2) / 3) * 4)

    var index = 0
    while index + 3 <= bytes.count {
        let b0 = UInt32(bytes[index])
        let b1 = UInt32(bytes[index + 1])
        let b2 = UInt32(bytes[index + 2])
        let triple = (b0 << 16) | (b1 << 8) | b2
        output.append(base64Alphabet[Int((triple >> 18) & 0x3F)])
        output.append(base64Alphabet[Int((triple >> 12) & 0x3F)])
        output.append(base64Alphabet[Int((triple >> 6) & 0x3F)])
        output.append(base64Alphabet[Int(triple & 0x3F)])
        index += 3
    }

    let remaining = bytes.count - index
    if remaining == 1 {
        let b0 = UInt32(bytes[index])
        output.append(base64Alphabet[Int((b0 >> 2) & 0x3F)])
        output.append(base64Alphabet[Int((b0 & 0x03) << 4)])
        output.append(UInt8(ascii: "="))
        output.append(UInt8(ascii: "="))
    } else if remaining == 2 {
        let b0 = UInt32(bytes[index])
        let b1 = UInt32(bytes[index + 1])
        let pair = (b0 << 8) | b1
        output.append(base64Alphabet[Int((pair >> 10) & 0x3F)])
        output.append(base64Alphabet[Int((pair >> 4) & 0x3F)])
        output.append(base64Alphabet[Int((pair & 0x0F) << 2)])
        output.append(UInt8(ascii: "="))
    }

    return String(decoding: output, as: UTF8.self)
}

/// Decodes standard RFC 4648 base64 into bytes.
// parity: util/src/base64.ts#base64ToBytes [status=implemented hash=08cb09d85c41]
public func base64ToBytes(_ value: String) throws(Base64Error) -> [UInt8] {
    var cleaned: [UInt8] = []
    cleaned.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
        // Strip ASCII whitespace matching WHATWG Forgiving-Base64 / Uint8Array.fromBase64
        if byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20 {
            continue
        }
        cleaned.append(byte)
    }

    if cleaned.isEmpty { return [] }

    let mod = cleaned.count % 4
    if mod == 1 {
        throw .invalidLength
    }

    var padding = 0
    if mod == 0 {
        if cleaned[cleaned.count - 1] == UInt8(ascii: "=") {
            padding += 1
            if cleaned[cleaned.count - 2] == UInt8(ascii: "=") {
                padding += 1
            }
        }
    } else {
        // Unpadded length (2 or 3 mod 4) cannot contain '='
        for byte in cleaned where byte == UInt8(ascii: "=") {
            throw .invalidPadding
        }
        padding = 4 - mod
    }

    let dataCount = cleaned.count - (mod == 0 ? padding : 0)
    var values: [UInt8] = []
    values.reserveCapacity(dataCount)
    for i in 0..<dataCount {
        let byte = cleaned[i]
        if byte == UInt8(ascii: "=") {
            throw .invalidPadding
        }
        let decoded = base64DecodeTable[Int(byte)]
        if decoded < 0 {
            throw .invalidCharacter(byte)
        }
        values.append(UInt8(decoded))
    }

    var result: [UInt8] = []
    result.reserveCapacity((values.count * 3) / 4)

    var i = 0
    while i + 4 <= values.count {
        let v0 = UInt32(values[i])
        let v1 = UInt32(values[i + 1])
        let v2 = UInt32(values[i + 2])
        let v3 = UInt32(values[i + 3])
        let triple = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3
        result.append(UInt8((triple >> 16) & 0xFF))
        result.append(UInt8((triple >> 8) & 0xFF))
        result.append(UInt8(triple & 0xFF))
        i += 4
    }

    let tail = values.count - i
    if tail == 2 {
        let v0 = UInt32(values[i])
        let v1 = UInt32(values[i + 1])
        result.append(UInt8(((v0 << 2) | (v1 >> 4)) & 0xFF))
    } else if tail == 3 {
        let v0 = UInt32(values[i])
        let v1 = UInt32(values[i + 1])
        let v2 = UInt32(values[i + 2])
        result.append(UInt8(((v0 << 2) | (v1 >> 4)) & 0xFF))
        result.append(UInt8((((v1 & 0x0F) << 4) | (v2 >> 2)) & 0xFF))
    }

    return result
}
