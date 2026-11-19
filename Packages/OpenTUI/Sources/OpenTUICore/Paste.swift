/// Classification of pasted payload content.
// parity: core/src/lib/paste.ts#PasteKind [status=implemented hash=fee169c36faf]
public enum PasteKind: String, Equatable, Hashable, Sendable, Codable {
    case text
    case binary
    case unknown
}

/// Optional metadata describing a paste payload.
// parity: core/src/lib/paste.ts#PasteMetadata [status=implemented hash=1c2424db7ecb]
public struct PasteMetadata: Equatable, Hashable, Sendable, Codable {
    public var mimeType: String?
    public var kind: PasteKind?

    public init(mimeType: String? = nil, kind: PasteKind? = nil) {
        self.mimeType = mimeType
        self.kind = kind
    }
}

/// Decodes raw pasted UTF-8 bytes into a Swift `String`, matching JavaScript's default `TextDecoder().decode(bytes)`
/// (stripping a leading UTF-8 BOM and replacing invalid sequences with U+FFFD).
// parity: core/src/lib/paste.ts#decodePasteBytes [status=implemented hash=a40d414835d6]
public func decodePasteBytes(_ bytes: [UInt8]) -> String {
    if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
        return String(decoding: bytes.dropFirst(3), as: UTF8.self)
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Strips ECMA-48 escape sequences in both 7-bit (`ESC`) and 8-bit (`C1`) forms, including CSI sequences,
/// control strings (OSC, DCS, SOS, PM, APC) through BEL or ST, and any other escape sequence or lone ESC.
// parity: core/src/lib/paste.ts#stripAnsiSequences [status=implemented hash=ba30649ed5f5]
public func stripAnsiSequences(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    let count = scalars.count
    var out = String.UnicodeScalarView()
    out.reserveCapacity(count)

    var i = 0
    while i < count {
        let v = scalars[i].value

        // Alternative 1: CSI — (?:\x1b\[|\x9b)[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]?
        if (v == 0x1B && i + 1 < count && scalars[i + 1].value == 0x5B) || v == 0x9B {
            var j = v == 0x1B ? i + 2 : i + 1
            while j < count, scalars[j].value >= 0x30, scalars[j].value <= 0x3F {
                j += 1
            }
            while j < count, scalars[j].value >= 0x20, scalars[j].value <= 0x2F {
                j += 1
            }
            if j < count, scalars[j].value >= 0x40, scalars[j].value <= 0x7E {
                j += 1
            }
            i = j
            continue
        }

        // Alternative 2: Control strings — (?:\x1b[P\]X^_]|[\x90\x98\x9d-\x9f])[^\x07\x1b\x9c]*(?:\x07|\x1b\\|\x9c)?
        let isEscString = v == 0x1B && i + 1 < count && {
            let next = scalars[i + 1].value
            return next == 0x50 || next == 0x5D || next == 0x58 || next == 0x5E || next == 0x5F
        }()
        let isC1String = v == 0x90 || v == 0x98 || (v >= 0x9D && v <= 0x9F)
        if isEscString || isC1String {
            var j = isEscString ? i + 2 : i + 1
            while j < count {
                let cv = scalars[j].value
                if cv == 0x07 || cv == 0x1B || cv == 0x9C {
                    break
                }
                j += 1
            }
            if j < count {
                let cv = scalars[j].value
                if cv == 0x07 || cv == 0x9C {
                    j += 1
                } else if cv == 0x1B, j + 1 < count, scalars[j + 1].value == 0x5C {
                    j += 2
                }
            }
            i = j
            continue
        }

        // Alternative 3: Other escape sequence or lone ESC — \x1b[\x20-\x2f]*[\x30-\x7e]?
        if v == 0x1B {
            var j = i + 1
            while j < count, scalars[j].value >= 0x20, scalars[j].value <= 0x2F {
                j += 1
            }
            if j < count, scalars[j].value >= 0x30, scalars[j].value <= 0x7E {
                j += 1
            }
            i = j
            continue
        }

        out.append(scalars[i])
        i += 1
    }

    return String(out)
}
