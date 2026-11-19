// parity: util/src/session-mention.ts#SessionMention [status=implemented hash=cfc31d820894]
public struct SessionMention: Equatable, Hashable, Sendable, Codable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct SessionMentionMatch: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let text: String
    public let start: Int
    public let end: Int

    public init(id: String, text: String, start: Int, end: Int) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }
}

private let sessionPrefixUnits: [UInt16] = Array("@session:".utf16)
private let sesUnits: [UInt16] = Array("ses_".utf16)
private let sessionSuffixLength = 26

/// Matches complete generated session IDs (`ses_<26 alnum>`), optionally prefixed by `@session:`,
/// respecting exact JS regex boundary assertions `(?<![\w/:@-])` and `(?![\w/-])`.
/// `start` and `end` are UTF-16 code-unit offsets matching JavaScript's `RegExpMatchArray.index`.
// parity: util/src/session-mention.ts#sessionMentions [status=implemented hash=48cfa4464393]
public func sessionMentions(_ text: String) -> [SessionMentionMatch] {
    let units = Array(text.utf16)
    let count = units.count
    var matches: [SessionMentionMatch] = []
    var index = 0

    while index < count {
        // Check lookbehind: preceding character must NOT be in [\w/:@-]
        if index > 0 && isForbiddenBefore(units[index - 1]) {
            index += 1
            continue
        }

        var cursor = index
        var hasAtPrefix = false
        if matchesLiteral(units, at: cursor, literal: sessionPrefixUnits) {
            cursor += sessionPrefixUnits.count
            hasAtPrefix = true
        }

        if matchesLiteral(units, at: cursor, literal: sesUnits) {
            let idStart = cursor
            let suffixStart = cursor + sesUnits.count
            let suffixEnd = suffixStart + sessionSuffixLength
            if suffixEnd <= count && allASCIIAlnum(units, from: suffixStart, to: suffixEnd) {
                // Check lookahead: following character must NOT be in [\w/-]
                if suffixEnd == count || !isForbiddenAfter(units[suffixEnd]) {
                    let id = String(decoding: units[idStart..<suffixEnd], as: UTF16.self)
                    let matchedText = String(decoding: units[index..<suffixEnd], as: UTF16.self)
                    matches.append(
                        SessionMentionMatch(
                            id: id,
                            text: matchedText,
                            start: index,
                            end: suffixEnd
                        )
                    )
                    index = suffixEnd
                    continue
                }
            }
        }

        // If `@session:` didn't yield a valid match, advance by 1 (matching regex backtracking)
        _ = hasAtPrefix
        index += 1
    }

    return matches
}

// parity: util/src/session-mention.ts#parseSessionMention [status=implemented hash=6c62181c54c8]
public func parseSessionMention(_ text: String) -> SessionMention? {
    guard let first = sessionMentions(text).first, first.text == text else {
        return nil
    }
    return SessionMention(id: first.id)
}

// parity: util/src/session-mention.ts#serializeSessionMention [status=implemented hash=4b39ce2cdcea]
public func serializeSessionMention(_ mention: SessionMention) -> String {
    "@session:\(mention.id)"
}

private func isASCIIWord(_ u: UInt16) -> Bool {
    (u >= 0x30 && u <= 0x39)
        || (u >= 0x41 && u <= 0x5A)
        || (u >= 0x61 && u <= 0x7A)
        || u == 0x5F
}

private func isASCIIAlnum(_ u: UInt16) -> Bool {
    (u >= 0x30 && u <= 0x39)
        || (u >= 0x41 && u <= 0x5A)
        || (u >= 0x61 && u <= 0x7A)
}

private func isForbiddenBefore(_ u: UInt16) -> Bool {
    isASCIIWord(u) || u == 0x2F || u == 0x3A || u == 0x40 || u == 0x2D
}

private func isForbiddenAfter(_ u: UInt16) -> Bool {
    isASCIIWord(u) || u == 0x2F || u == 0x2D
}

private func matchesLiteral(_ units: [UInt16], at offset: Int, literal: [UInt16]) -> Bool {
    guard offset + literal.count <= units.count else { return false }
    for i in 0..<literal.count {
        if units[offset + i] != literal[i] { return false }
    }
    return true
}

private func allASCIIAlnum(_ units: [UInt16], from start: Int, to end: Int) -> Bool {
    for i in start..<end {
        if !isASCIIAlnum(units[i]) { return false }
    }
    return true
}
