/// Injectable directory entry descriptor used by `Glob.scan` so pure code and tests can run
/// without OS filesystem dependencies.
public struct GlobFileEntry: Equatable, Hashable, Sendable {
    public let relativePath: String
    public let absolutePath: String
    public let isDirectory: Bool

    public init(relativePath: String, absolutePath: String, isDirectory: Bool) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.isDirectory = isDirectory
    }
}

/// Pure-Swift glob matcher and scanner mirroring `packages/util/src/glob.ts` (`minimatch` + `glob`).
// parity: util/src/glob.ts#Glob [status=implemented hash=b2de3c26b7ce]
public enum Glob {
    public enum IncludeKind: String, Equatable, Hashable, Sendable, Codable {
        case file
        case all
    }

    // parity: util/src/glob.ts#Glob.Options [status=implemented hash=e1895c7008cd]
    public struct Options: Equatable, Hashable, Sendable, Codable {
        public var cwd: String?
        public var absolute: Bool?
        public var include: IncludeKind?
        public var dot: Bool?
        public var symlink: Bool?
        public var ignore: [String]?

        public init(
            cwd: String? = nil,
            absolute: Bool? = nil,
            include: IncludeKind? = nil,
            dot: Bool? = nil,
            symlink: Bool? = nil,
            ignore: [String]? = nil
        ) {
            self.cwd = cwd
            self.absolute = absolute
            self.include = include
            self.dot = dot
            self.symlink = symlink
            self.ignore = ignore
        }
    }

    /// Scans `entries` produced by a directory walker against `pattern` and `options`.
    // parity: util/src/glob.ts#Glob.scan [status=implemented hash=6179518d7050]
    public static func scan(
        _ pattern: String,
        options: Options = Options(),
        walk: @Sendable (Options) async throws -> [GlobFileEntry]
    ) async throws -> [String] {
        let entries = try await walk(options)
        let includeDirs = options.include == .all
        let matchDot = options.dot ?? false
        let ignorePatterns = options.ignore ?? []
        let useAbsolute = options.absolute ?? false

        var results: [String] = []
        for entry in entries {
            if entry.isDirectory && !includeDirs { continue }
            let candidate = entry.relativePath
            if ignorePatterns.contains(where: { match($0, filepath: candidate, dot: true) }) {
                continue
            }
            if match(pattern, filepath: candidate, dot: matchDot) {
                results.append(useAbsolute ? entry.absolutePath : candidate)
            }
        }
        return results
    }

    /// Matches `filepath` against a minimatch-style glob `pattern` (`dot` defaults to `true`).
    // parity: util/src/glob.ts#Glob.match [status=implemented hash=7e1393c270e2]
    public static func match(
        _ pattern: String,
        filepath: String,
        dot: Bool = true
    ) -> Bool {
        if pattern.isEmpty { return filepath.isEmpty }
        // Handle leading `!` negation (minimatch counts consecutive `!` prefixes).
        var negated = false
        var pat = pattern
        while pat.hasPrefix("!") && !pat.hasPrefix("!(") {
            negated.toggle()
            pat.removeFirst()
        }
        let expanded = expandBraces(pat)
        let normalizedPath = normalizeSlashes(filepath)
        let matched = expanded.contains { p in
            matchSinglePattern(p, path: normalizedPath, dot: dot)
        }
        return negated ? !matched : matched
    }

    // MARK: - Minimatch Engine

    private static func normalizeSlashes(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            out.append(ch == "\\" ? "/" : ch)
        }
        return out
    }

    /// Expands top-level and nested `{a,b,c}` brace groups (preserving literal `{single}` without commas).
    private static func expandBraces(_ pattern: String) -> [String] {
        let chars = Array(pattern)
        guard let openIdx = findExpandableBrace(chars) else {
            return [pattern]
        }
        var depth = 0
        var parts: [String] = []
        var partStart = openIdx + 1
        var closeIdx = -1
        var i = openIdx
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }
            if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    parts.append(String(chars[partStart..<i]))
                    closeIdx = i
                    break
                }
            } else if c == "," && depth == 1 {
                parts.append(String(chars[partStart..<i]))
                partStart = i + 1
            }
            i += 1
        }
        guard closeIdx != -1, parts.count >= 2 else { return [pattern] }
        let prefix = String(chars[0..<openIdx])
        let suffix = String(chars[(closeIdx + 1)...])
        var results: [String] = []
        for part in parts {
            for expanded in expandBraces(prefix + part + suffix) {
                results.append(expanded)
            }
        }
        return results
    }

    private static func findExpandableBrace(_ chars: [Character]) -> Int? {
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }
            if chars[i] == "{" {
                var depth = 0
                var hasCommaAtDepth1 = false
                var j = i
                while j < chars.count {
                    if chars[j] == "\\" && j + 1 < chars.count {
                        j += 2
                        continue
                    }
                    if chars[j] == "{" { depth += 1 }
                    else if chars[j] == "}" {
                        depth -= 1
                        if depth == 0 {
                            if hasCommaAtDepth1 { return i }
                            break
                        }
                    } else if chars[j] == "," && depth == 1 {
                        hasCommaAtDepth1 = true
                    }
                    j += 1
                }
            }
            i += 1
        }
        return nil
    }

    private static func matchSinglePattern(_ pattern: String, path: String, dot: Bool) -> Bool {
        if pattern.isEmpty { return path.isEmpty }
        // Strip leading "./" when matching relative paths (minimatch behavior).
        let cleanPat = stripLeadingDotSlash(pattern)
        let cleanPath = stripLeadingDotSlash(path)

        let patSegments = splitPathSegments(cleanPat)
        let pathSegments = splitPathSegments(cleanPath)

        var memo: [Int: Bool] = [:]
        return matchSegments(
            patSegments, pi: 0,
            pathSegments, si: 0,
            dot: dot,
            memo: &memo
        )
    }

    private static func stripLeadingDotSlash(_ s: String) -> String {
        var result = s
        while result.hasPrefix("./") && result.count > 2 {
            result.removeFirst(2)
        }
        return result
    }

    private static func splitPathSegments(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in s {
            if ch == "/" {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func matchSegments(
        _ pat: [String], pi: Int,
        _ path: [String], si: Int,
        dot: Bool,
        memo: inout [Int: Bool]
    ) -> Bool {
        let key = pi * (path.count + 1) + si
        if let cached = memo[key] { return cached }

        let result: Bool
        if pi == pat.count && si == path.count {
            result = true
        } else if pi == pat.count {
            result = false
        } else if pat[pi] == "**" {
            // `**` matches zero or more path segments.
            // If `dot == false`, `**` must not traverse dot-segments (like `.git`).
            if matchSegments(pat, pi: pi + 1, path, si: si, dot: dot, memo: &memo) {
                result = true
            } else if si < path.count {
                let seg = path[si]
                let allowedDot = dot || !seg.hasPrefix(".") || seg == "." || seg == ".."
                if allowedDot {
                    result = matchSegments(pat, pi: pi, path, si: si + 1, dot: dot, memo: &memo)
                } else {
                    result = false
                }
            } else {
                result = false
            }
        } else if si == path.count {
            result = false
        } else {
            let pSeg = pat[pi]
            let sSeg = path[si]
            if !dot && sSeg.hasPrefix(".") && !pSeg.hasPrefix(".") && !pSeg.hasPrefix("\\.") {
                result = false
            } else if matchSegment(Array(pSeg), pi: 0, Array(sSeg), si: 0) {
                result = matchSegments(pat, pi: pi + 1, path, si: si + 1, dot: dot, memo: &memo)
            } else {
                result = false
            }
        }

        memo[key] = result
        return result
    }

    private static func matchSegment(
        _ pat: [Character], pi: Int,
        _ str: [Character], si: Int
    ) -> Bool {
        var p = pi
        var s = si
        while p < pat.count {
            let ch = pat[p]
            if ch == "\\" && p + 1 < pat.count {
                guard s < str.count && str[s] == pat[p + 1] else { return false }
                p += 2
                s += 1
                continue
            }
            // Extglob operators: @(a|b), ?(a|b), *(a|b), +(a|b), !(a|b)
            // Must be checked before plain `*` and `?` wildcards.
            if (ch == "@" || ch == "?" || ch == "*" || ch == "+" || ch == "!"),
               p + 1 < pat.count && pat[p + 1] == "(",
               let (alts, closeIdx) = parseExtglob(pat, openParen: p + 1) {
                return matchExtglob(op: ch, alts: alts, restPat: pat, restPi: closeIdx + 1, str: str, si: s)
            }
            if ch == "*" {
                while p < pat.count && pat[p] == "*" { p += 1 }
                if p == pat.count { return true }
                for k in s...str.count {
                    if matchSegment(pat, pi: p, str, si: k) { return true }
                }
                return false
            }
            if ch == "?" {
                guard s < str.count else { return false }
                p += 1
                s += 1
                continue
            }
            if ch == "[" {
                if let (matched, nextP) = matchCharClass(pat, start: p, target: s < str.count ? str[s] : nil) {
                    guard matched else { return false }
                    p = nextP
                    s += 1
                    continue
                }
            }

            guard s < str.count && str[s] == ch else { return false }
            p += 1
            s += 1
        }
        return s == str.count
    }

    private static func matchCharClass(
        _ pat: [Character],
        start: Int,
        target: Character?
    ) -> (Bool, Int)? {
        var i = start + 1
        guard i < pat.count else { return nil }
        var negate = false
        if pat[i] == "!" || pat[i] == "^" {
            negate = true
            i += 1
        }
        var found = false
        var first = true
        while i < pat.count {
            if pat[i] == "]" && !first {
                guard target != nil else { return (false, i + 1) }
                return (negate ? !found : found, i + 1)
            }
            first = false
            let lo = pat[i]
            if i + 2 < pat.count && pat[i + 1] == "-" && pat[i + 2] != "]" {
                let hi = pat[i + 2]
                if let t = target, t >= lo && t <= hi {
                    found = true
                }
                i += 3
            } else {
                if let t = target, t == lo {
                    found = true
                }
                i += 1
            }
        }
        return nil
    }

    private static func parseExtglob(_ pat: [Character], openParen: Int) -> ([[Character]], Int)? {
        var depth = 0
        var alts: [[Character]] = []
        var current: [Character] = []
        var i = openParen
        while i < pat.count {
            let c = pat[i]
            if c == "\\" && i + 1 < pat.count {
                current.append(c)
                current.append(pat[i + 1])
                i += 2
                continue
            }
            if c == "(" {
                if depth > 0 { current.append(c) }
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 {
                    alts.append(current)
                    return (alts, i)
                }
                current.append(c)
            } else if c == "|" && depth == 1 {
                alts.append(current)
                current = []
            } else {
                current.append(c)
            }
            i += 1
        }
        return nil
    }

    private static func matchExtglob(
        op: Character,
        alts: [[Character]],
        restPat: [Character],
        restPi: Int,
        str: [Character],
        si: Int
    ) -> Bool {
        func matchesAnyAlt(_ slice: [Character]) -> Bool {
            alts.contains { matchSegment($0, pi: 0, slice, si: 0) }
        }
        switch op {
        case "@":
            for end in si...str.count {
                if matchesAnyAlt(Array(str[si..<end])) && matchSegment(restPat, pi: restPi, str, si: end) {
                    return true
                }
            }
            return false
        case "?":
            if matchSegment(restPat, pi: restPi, str, si: si) { return true }
            for end in si...str.count {
                if matchesAnyAlt(Array(str[si..<end])) && matchSegment(restPat, pi: restPi, str, si: end) {
                    return true
                }
            }
            return false
        case "*":
            if matchSegment(restPat, pi: restPi, str, si: si) { return true }
            if si < str.count {
                for end in (si + 1)...str.count {
                    if matchesAnyAlt(Array(str[si..<end])) {
                        if matchExtglob(op: "*", alts: alts, restPat: restPat, restPi: restPi, str: str, si: end) {
                            return true
                        }
                    }
                }
            }
            return false
        case "+":
            for end in si...str.count {
                if matchesAnyAlt(Array(str[si..<end])) {
                    if matchSegment(restPat, pi: restPi, str, si: end) { return true }
                    if end > si && matchExtglob(op: "+", alts: alts, restPat: restPat, restPi: restPi, str: str, si: end) {
                        return true
                    }
                }
            }
            return false
        case "!":
            for end in si...str.count {
                if !matchesAnyAlt(Array(str[si..<end])) && matchSegment(restPat, pi: restPi, str, si: end) {
                    return true
                }
            }
            return false
        default:
            return false
        }
    }
}
