public struct BomSplitResult: Equatable, Sendable, Codable {
    public let bom: Bool
    public let text: String

    public init(bom: Bool, text: String) {
        self.bom = bom
        self.text = text
    }
}

public struct BomSyncResult: Equatable, Sendable, Codable {
    public let text: String
    public let bytes: [UInt8]?

    public init(text: String, bytes: [UInt8]?) {
        self.text = text
        self.bytes = bytes
    }
}

public enum Bom {
    private static let scalar = Unicode.Scalar(0xFEFF)!
    private static let marker = "\u{FEFF}"

    // parity: util/src/bom.ts#split [status=implemented hash=a3005f022109]
    public static func split(_ text: String) -> BomSplitResult {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex && scalars[index] == scalar {
            index = scalars.index(after: index)
        }
        let hasBom = index != scalars.startIndex
        let stripped = hasBom ? String(scalars[index...]) : text
        return BomSplitResult(bom: hasBom, text: stripped)
    }

    // parity: util/src/bom.ts#join [status=implemented hash=3244b78b0851]
    public static func join(_ text: String, bom: Bool) -> String {
        let stripped = split(text).text
        return bom ? marker + stripped : stripped
    }

    // parity: util/src/bom.ts#has [status=implemented hash=9255b141b000]
    public static func has(_ content: [UInt8]) -> Bool {
        content.count >= 3 && content[0] == 0xEF && content[1] == 0xBB && content[2] == 0xBF
    }

    // parity: util/src/bom.ts#decodeBytes [status=implemented hash=0efb2d38835d]
    public static func decodeBytes(_ content: [UInt8]) -> BomSplitResult {
        split(decodeUTF8KeepingBOM(content))
    }

    // parity: util/src/bom.ts#syncBytes [status=implemented hash=d6ca903fea7d]
    public static func syncBytes(_ content: [UInt8], bom: Bool) -> BomSyncResult {
        let decoded = decodeUTF8KeepingBOM(content)
        let current = split(decoded)
        let canonical = bom ? marker + current.text : current.text
        if decoded == canonical {
            return BomSyncResult(text: current.text, bytes: nil)
        }
        return BomSyncResult(text: current.text, bytes: Array(canonical.utf8))
    }

    private static func decodeUTF8KeepingBOM(_ content: [UInt8]) -> String {
        String(decoding: content, as: UTF8.self)
    }
}
