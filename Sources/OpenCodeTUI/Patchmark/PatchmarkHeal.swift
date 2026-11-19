// Streaming tail healing: close inline markers that are still open at the end of the block being written,
// and hide markers that have nothing after them yet, so a half-written `**` never renders as `****` (a rule).

/// Edit descriptor relative to the right-trimmed streaming inline text.
// parity: patchmark/src/heal.ts#TailHeal [status=implemented hash=3d268d6bfc47]
public struct TailHeal: Equatable, Hashable, Sendable {
    /// UTF-16 code units to remove from the end of the (right-trimmed) text.
    public var strip: Int
    /// Text to append after stripping.
    public var append: String

    public init(strip: Int, append: String) {
        self.strip = strip
        self.append = append
    }
}

// MARK: - Shared UTF-16 Inline Math Scanners

@inline(__always)
func isJsLineTerminator(_ c: UInt16) -> Bool {
    c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
}

@inline(__always)
func isJsWhitespace(_ c: UInt16) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D
        || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A)
        || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF
}

@inline(__always)
func isAsciiWordChar(_ c: UInt16) -> Bool {
    isAsciiAlnum(c) || c == 0x5F
}

struct InlineMathMatch {
    let end: Int
    let bodyStart: Int
    let bodyEnd: Int
    let display: Bool
}

/// Matches `/\$\$(?!\$)((?:\\.|[^\\\n])*?(?:\\.|[^\\\n$]))\$\$|\$(?=[^\s$])((?:\\.|[^\\\n$])*?(?:\\\S|[^\s\\$]))\$(?!\w)/y`.
func matchInlineDollarMath(in u: [UInt16], at start: Int) -> InlineMathMatch? {
    let n = u.count
    guard start < n, u[start] == 0x24 /* $ */ else { return nil }

    if start + 1 < n && u[start + 1] == 0x24 {
        // Branch 1: $$...$$
        if start + 2 < n && u[start + 2] == 0x24 { return nil }
        var i = start + 2
        var lastAtomValid = false
        while i < n {
            if lastAtomValid && i + 1 < n && u[i] == 0x24 && u[i + 1] == 0x24 {
                return InlineMathMatch(end: i + 2, bodyStart: start + 2, bodyEnd: i, display: true)
            }
            let c = u[i]
            if c == 0x5C {
                guard i + 1 < n && !isJsLineTerminator(u[i + 1]) else { return nil }
                i += 2
                lastAtomValid = true
            } else if c == 0x0A {
                return nil
            } else {
                i += 1
                lastAtomValid = (c != 0x24)
            }
        }
        return nil
    }

    // Branch 2: $...$
    guard start + 1 < n, !isJsWhitespace(u[start + 1]), u[start + 1] != 0x24 else { return nil }
    var i = start + 1
    var lastAtomValid = false
    while i < n {
        if lastAtomValid && u[i] == 0x24 && (i + 1 >= n || !isAsciiWordChar(u[i + 1])) {
            return InlineMathMatch(end: i + 1, bodyStart: start + 1, bodyEnd: i, display: false)
        }
        let c = u[i]
        if c == 0x5C {
            guard i + 1 < n && !isJsLineTerminator(u[i + 1]) else { return nil }
            let next = u[i + 1]
            i += 2
            lastAtomValid = !isJsWhitespace(next)
        } else if c == 0x0A || c == 0x24 {
            return nil
        } else {
            i += 1
            lastAtomValid = !isJsWhitespace(c)
        }
    }
    return nil
}

/// Matches `/\\\(((?:\\.|[^\\\n])*?)\\\)/y`.
func matchInlineParenMath(in u: [UInt16], at start: Int) -> InlineMathMatch? {
    let n = u.count
    guard start + 1 < n, u[start] == 0x5C, u[start + 1] == 0x28 else { return nil }
    var i = start + 2
    while i < n {
        if u[i] == 0x5C && i + 1 < n && u[i + 1] == 0x29 {
            return InlineMathMatch(end: i + 2, bodyStart: start + 2, bodyEnd: i, display: false)
        }
        let c = u[i]
        if c == 0x5C {
            guard i + 1 < n && !isJsLineTerminator(u[i + 1]) else { return nil }
            i += 2
        } else if c == 0x0A {
            return nil
        } else {
            i += 1
        }
    }
    return nil
}

// MARK: - Tail Healing Helpers

@inline(__always)
private func isHealSpace(_ c: UInt16?) -> Bool {
    guard let c else { return true }
    return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
}

private func rtrimLength(_ u: [UInt16]) -> Int {
    var end = u.count
    while end > 0 && isHealSpace(u[end - 1]) { end -= 1 }
    return end
}

private func composeHeal(_ a: TailHeal, _ b: TailHeal) -> TailHeal {
    let aAppendU16 = Array(a.append.utf16)
    if b.strip <= aAppendU16.count {
        let kept = String(decoding: aAppendU16[0..<(aAppendU16.count - b.strip)], as: UTF16.self)
        return TailHeal(strip: a.strip, append: kept + b.append)
    }
    return TailHeal(strip: a.strip + (b.strip - aAppendU16.count), append: b.append)
}

private struct OpenDelim {
    var ch: UInt16
    var len: Int
    var after: Int
    var start: Int
}

/// Matches `/(!?)\[([^\]\n]*)\]\(([^)\n]*)$/` starting at `linkStart`.
private func matchIncompleteLinkTail(in u: [UInt16], openBracket: Int) -> (matchLen: Int, replacement: [UInt16])? {
    let n = u.count
    let isImage = openBracket > 0 && u[openBracket - 1] == 0x21
    let linkStart = isImage ? openBracket - 1 : openBracket
    var i = openBracket + 1
    while i < n && u[i] != 0x5D && u[i] != 0x0A { i += 1 }
    guard i < n, u[i] == 0x5D /* ] */ else { return nil }
    let labelEnd = i
    guard i + 1 < n, u[i + 1] == 0x28 /* ( */ else { return nil }
    var j = i + 2
    while j < n {
        if u[j] == 0x29 || u[j] == 0x0A { return nil }
        j += 1
    }
    let matchLen = n - linkStart
    let replacement: [UInt16] = isImage ? [] : Array(u[(openBracket + 1)..<labelEnd])
    return (matchLen, replacement)
}

/// Computes the edit that heals the end of `input` (an inline run: a paragraph, heading, or table row).
/// Offsets are relative to `input` with trailing whitespace removed.
// parity: patchmark/src/heal.ts#computeTailHeal [status=implemented hash=82e109a1df04]
public func computeTailHeal(_ input: String) -> TailHeal {
    let rawU16 = Array(input.utf16)
    let trimmedEnd = rtrimLength(rawU16)
    if trimmedEnd == 0 { return TailHeal(strip: 0, append: "") }

    var u = Array(rawU16[0..<trimmedEnd])
    var heal = TailHeal(strip: 0, append: "")

    // 1. An unfinished inline link or image at the very end: `[label](https://…` shows just the label.
    var lastOpen = -1
    for idx in stride(from: u.count - 1, through: 0, by: -1) {
        if u[idx] == 0x5B /* [ */ {
            lastOpen = idx
            break
        }
    }
    if lastOpen >= 0 && (lastOpen == 0 || u[lastOpen - 1] != 0x5C) {
        if let m = matchIncompleteLinkTail(in: u, openBracket: lastOpen) {
            let repStr = String(decoding: m.replacement, as: UTF16.self)
            heal = TailHeal(strip: m.matchLen, append: repStr)
            u.removeLast(m.matchLen)
            u.append(contentsOf: m.replacement)
        }
    }

    // 2. Scan code spans, math, and emphasis delimiters.
    let n = u.count
    var codeOpen: (len: Int, start: Int)? = nil
    var wordHadEm = false
    var stack: [OpenDelim] = []
    var stars = 0
    var underscores = 0
    var tildes = 0

    func push(_ open: OpenDelim) {
        if open.ch == 0x2A { stars += 1 }
        else if open.ch == 0x5F { underscores += 1 }
        else { tildes += 1 }
        stack.append(open)
    }

    func pop() {
        let open = stack.removeLast()
        if open.ch == 0x2A { stars -= 1 }
        else if open.ch == 0x5F { underscores -= 1 }
        else { tildes -= 1 }
    }

    func hasOpen(_ ch: UInt16) -> Bool {
        (ch == 0x2A ? stars : ch == 0x5F ? underscores : tildes) > 0
    }

    var i = 0
    while i < n {
        let c = u[i]
        if let co = codeOpen {
            if c == 0x60 {
                var run = 1
                while i + run < n && u[i + run] == 0x60 { run += 1 }
                if run == co.len { codeOpen = nil }
                i += run
            } else {
                i += 1
            }
            continue
        }
        if isHealSpace(c) {
            wordHadEm = false
            i += 1
            continue
        }
        if c == 0x5C /* \ */ {
            if let pm = matchInlineParenMath(in: u, at: i) {
                i = pm.end
                continue
            }
            i += 2
            continue
        }
        if c == 0x60 /* ` */ {
            var run = 1
            while i + run < n && u[i + run] == 0x60 { run += 1 }
            codeOpen = (len: run, start: i)
            i += run
            continue
        }
        if c == 0x24 /* $ */ {
            if let mm = matchInlineDollarMath(in: u, at: i) {
                i = mm.end
                continue
            }
            i += 1
            continue
        }
        if c == 0x2A /* * */ || c == 0x5F /* _ */ || c == 0x7E /* ~ */ {
            var run = 1
            while i + run < n && u[i + run] == c { run += 1 }
            let prev: UInt16? = i > 0 ? u[i - 1] : nil
            let next: UInt16? = i + run < n ? u[i + run] : nil
            let isUnderscore = c == 0x5F
            let isSingleStar = c == 0x2A && run == 1
            let prevAlnum = prev.map(isAsciiAlnum) ?? false
            let nextAlnum = next.map(isAsciiAlnum) ?? false
            let canOpen =
                !isHealSpace(next)
                && !(isUnderscore && prevAlnum)
                && !(isSingleStar && prevAlnum && !wordHadEm)
            let canClose = !isHealSpace(prev) && !(isUnderscore && nextAlnum)
            if c == 0x2A && (run >= 2 || canOpen) { wordHadEm = true }
            if c == 0x7E && run > 2 {
                i += run
                continue
            }
            var remaining = run
            if canClose {
                while remaining > 0 && !stack.isEmpty {
                    if stack[stack.count - 1].ch != c {
                        if !hasOpen(c) { break }
                        while stack[stack.count - 1].ch != c { pop() }
                    }
                    let topIndex = stack.count - 1
                    if stack[topIndex].len <= remaining {
                        remaining -= stack[topIndex].len
                        pop()
                    } else {
                        stack[topIndex].len -= remaining
                        remaining = 0
                    }
                }
            }
            if remaining > 0 && canOpen {
                if c == 0x7E {
                    push(OpenDelim(ch: c, len: remaining, after: i + run, start: i + (run - remaining)))
                } else if remaining >= 3 {
                    push(OpenDelim(ch: c, len: 2, after: i + run, start: i + (run - remaining)))
                    push(OpenDelim(ch: c, len: 1, after: i + run, start: i + (run - remaining) + 2))
                } else {
                    push(OpenDelim(ch: c, len: remaining, after: i + run, start: i + (run - remaining)))
                }
            }
            i += run
            continue
        }
        i += 1
    }

    var strip = 0
    var append = ""
    var codeClosed = false
    var nonSpaceEnd = rtrimLength(u)

    if let co = codeOpen {
        if co.start + co.len >= nonSpaceEnd {
            strip = n - co.start
        } else {
            append.append(String(repeating: "`", count: co.len))
            codeClosed = true
        }
    }

    // Close (innermost first) markers that have content after them; drop trailing markers that have none.
    var limit = n - strip
    if nonSpaceEnd > limit {
        nonSpaceEnd = limit
        while nonSpaceEnd > 0 && isHealSpace(u[nonSpaceEnd - 1]) { nonSpaceEnd -= 1 }
    }
    for s in stride(from: stack.count - 1, through: 0, by: -1) {
        let open = stack[s]
        if open.start >= limit { continue }
        if open.after >= nonSpaceEnd {
            if append.isEmpty {
                // dangling opener at the end: hide it (and the whitespace before it)
                var cut = open.start
                while cut > 0 && (u[cut - 1] == 0x20 || u[cut - 1] == 0x09) { cut -= 1 }
                strip = n - cut
                limit = cut
                if nonSpaceEnd > limit {
                    nonSpaceEnd = limit
                    while nonSpaceEnd > 0 && isHealSpace(u[nonSpaceEnd - 1]) { nonSpaceEnd -= 1 }
                }
            }
            continue
        }
        let ch = Character(UnicodeScalar(open.ch)!)
        append.append(String(repeating: ch, count: open.len))
    }

    // Closers must hug the text: drop trailing spaces before appending.
    if !append.isEmpty && !codeClosed {
        var cut = n - strip
        while cut > 0 && isHealSpace(u[cut - 1]) { cut -= 1 }
        strip = n - cut
    }

    return composeHeal(heal, TailHeal(strip: strip, append: append))
}

/// Applies a `TailHeal` edit to `text` relative to its right-trimmed end.
// parity: patchmark/src/heal.ts#applyTailHeal [status=implemented hash=ac557f44d839]
public func applyTailHeal(_ text: String, _ heal: TailHeal) -> String {
    if heal.strip == 0 && heal.append.isEmpty { return text }
    let u = Array(text.utf16)
    let end = rtrimLength(u)
    let cut = max(0, end - heal.strip)
    return String(decoding: u[0..<cut], as: UTF16.self) + heal.append
}

/// Repairs incomplete inline markers at the tail of an actively streaming block without touching closed spans.
/// `**bold` -> `**bold**`, `` `code `` -> `` `code` ``, `[label](https://…` -> `label`, and a trailing `**` with
/// nothing after it yet is hidden rather than doubled.
// parity: patchmark/src/heal.ts#healStreamingInline [status=implemented hash=2032f776cfda]
public func healStreamingInline(_ raw: String) -> String {
    if raw.isEmpty { return raw }
    let heal = computeTailHeal(raw)
    if heal.strip == 0 && heal.append.isEmpty { return raw }
    return applyTailHeal(raw, heal)
}
