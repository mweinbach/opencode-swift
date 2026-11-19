/// Clip text to a UTF-16 code unit or UTF-8 byte budget without splitting a character.
public enum TextBoundary {
    /// The first `limit` UTF-16 code units of `text`, dropping a trailing high surrogate if split.
    // parity: util/src/text-boundary.ts#head [status=implemented hash=8aff2245ec6e]
    public static func head(_ text: String, limit: Int) -> String {
        let units = Array(text.utf16)
        if limit <= 0 { return "" }
        if units.count <= limit { return text }
        let code = units[limit - 1]
        let cut = (code >= 0xD800 && code <= 0xDBFF) ? limit - 1 : limit
        return String(decoding: units[0..<cut], as: UTF16.self)
    }

    /// The last `limit` UTF-16 code units of `text`, skipping a leading low surrogate if split.
    // parity: util/src/text-boundary.ts#tail [status=implemented hash=1bfc97044540]
    public static func tail(_ text: String, limit: Int) -> String {
        let units = Array(text.utf16)
        if limit <= 0 { return "" }
        if units.count <= limit { return text }
        let start = units.count - limit
        let code = units[start]
        let cut = (code >= 0xDC00 && code <= 0xDFFF) ? start + 1 : start
        return String(decoding: units[cut..<units.count], as: UTF16.self)
    }

    /// The last `limit` bytes of `bytes`, decoded as UTF-8 (preserving BOM), after skipping up to
    /// 3 leading UTF-8 continuation bytes from a cut multibyte character.
    // parity: util/src/text-boundary.ts#utf8Tail [status=implemented hash=8c5ad3cfe734]
    public static func utf8Tail(_ bytes: [UInt8], limit: Int) -> String {
        if limit <= 0 { return "" }
        if bytes.count <= limit {
            return String(decoding: bytes, as: UTF8.self)
        }
        let start = bytes.count - limit
        let end = min(bytes.count, start + 3)
        var index = start
        while index < end && (bytes[index] & 0xC0) == 0x80 {
            index += 1
        }
        return String(decoding: bytes[index..<bytes.count], as: UTF8.self)
    }
}
