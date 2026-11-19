#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#elseif canImport(WASILibc)
import WASILibc
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// High-speed, concurrent, `.gitignore`-aware background repository file indexer and fuzzy/frecency ranker
/// (native Swift equivalent of `@ff-labs/fff`).
///
/// Key properties:
/// - **Injectable filesystem**: walks via `OpenCodeFileSystem` so it works identically on `LocalFileSystem`
///   and `InMemoryFileSystem` across every Swift platform.
/// - **Nested `.gitignore` & `.ignore` support**: handles negations (`!`), directory-only trailing `/`,
///   anchored leading/middle `/`, `**`, `*`, `?`, character classes `[...]`, and skips `.git/`,
///   `node_modules/`, and `.build/` by default.
/// - **Background indexing & stale-while-revalidate**: `warm(root:)`, single-entry incremental updates via
///   `applyChange(path:kind:)`, `invalidate(root:)`, and non-blocking background refresh when snapshots age.
/// - **Fast Structure-of-Arrays + Flat Arena fuzzy scorer**: 64-bit ASCII bitmask + tight subsequence
///   pre-filter + zero-ARC pointer-indexed Smith-Waterman / fzf-style affine-gap DP scoring with consecutive,
///   path-separator, camelCase/snake_case/kebab-case boundary, exact-basename, and prefix bonuses,
///   bounded top-K selection, and exact UTF-16 match indices for UI highlighting.
/// - **Frecency integration**: exponential time-decay boosts (`recordAccess(path:at:)`) with JSONL
///   persistence wire-compatible with `TUIPrompt.FrecencyEntry`.
public final class CoreFuzzyFileIndex: Sendable {
    // MARK: - Public Types

    public struct Configuration: Equatable, Hashable, Sendable {
        /// Directory basenames always skipped during traversal (never descended into).
        public var defaultIgnoredDirectories: Set<String>
        /// Whether hidden dotfiles/dotdirectories (other than `defaultIgnoredDirectories`) are indexed.
        public var includeHidden: Bool
        /// Duration (ms) before a cached root snapshot becomes stale and triggers stale-while-revalidate.
        public var staleAfterMs: Int64
        /// Hard upper bound on indexed entries per root.
        public var maxEntries: Int
        /// Exponential half-life (in days) for frecency time decay.
        public var frecencyHalfLifeDays: Double
        /// Weight scaling log-frecency into the fuzzy score domain.
        public var frecencyBoostScale: Double
        /// Maximum number of frecency entries retained (matches `TUIPrompt.MAX_FRECENCY_ENTRIES`).
        public var maxFrecencyEntries: Int
        /// Maximum concurrent directory worker tasks during `warm(root:)`.
        public var walkConcurrency: Int

        public init(
            defaultIgnoredDirectories: Set<String> = [".git", "node_modules", ".build"],
            includeHidden: Bool = true,
            staleAfterMs: Int64 = 10_000,
            maxEntries: Int = 200_000,
            frecencyHalfLifeDays: Double = 7.0,
            frecencyBoostScale: Double = 45.0,
            maxFrecencyEntries: Int = 1_000,
            walkConcurrency: Int = 8
        ) {
            self.defaultIgnoredDirectories = defaultIgnoredDirectories
            self.includeHidden = includeHidden
            self.staleAfterMs = max(0, staleAfterMs)
            self.maxEntries = max(1, maxEntries)
            self.frecencyHalfLifeDays = max(0.01, frecencyHalfLifeDays)
            self.frecencyBoostScale = max(0.0, frecencyBoostScale)
            self.maxFrecencyEntries = max(1, maxFrecencyEntries)
            self.walkConcurrency = max(1, walkConcurrency)
        }
    }

    public enum EntryKind: UInt8, Equatable, Hashable, Sendable, Codable {
        case file = 0
        case directory = 1
    }

    public enum ChangeKind: Equatable, Hashable, Sendable {
        case add(kind: EntryKind = .file)
        case modify
        case remove
        case rename(to: String, kind: EntryKind? = nil)
    }

    /// Persistent frecency record wire-compatible with `TUIPrompt.FrecencyEntry` JSONL.
    public struct FrecencyEntry: Equatable, Hashable, Sendable, Codable {
        public var path: String
        public var frequency: Int
        public var lastOpen: Int64

        public init(path: String, frequency: Int, lastOpen: Int64) {
            self.path = path
            self.frequency = frequency
            self.lastOpen = lastOpen
        }
    }

    public struct MatchResult: Equatable, Hashable, Sendable {
        public let relativePath: String
        public let kind: EntryKind
        public let totalScore: Double
        public let fuzzyScore: Double
        public let frecencyBoost: Double
        /// Sorted, unique UTF-16 code-unit positions inside `relativePath` matched by the query.
        public let matchedIndices: [Int]

        public init(
            relativePath: String,
            kind: EntryKind,
            totalScore: Double,
            fuzzyScore: Double,
            frecencyBoost: Double,
            matchedIndices: [Int]
        ) {
            self.relativePath = relativePath
            self.kind = kind
            self.totalScore = totalScore
            self.fuzzyScore = fuzzyScore
            self.frecencyBoost = frecencyBoost
            self.matchedIndices = matchedIndices
        }
    }

    public struct SearchOptions: Equatable, Hashable, Sendable {
        public var kind: EntryKind?
        public var limit: Int
        public var staleWhileRevalidate: Bool
        public var nowMs: Int64?

        public init(
            kind: EntryKind? = nil,
            limit: Int = 50,
            staleWhileRevalidate: Bool = true,
            nowMs: Int64? = nil
        ) {
            self.kind = kind
            self.limit = max(0, limit)
            self.staleWhileRevalidate = staleWhileRevalidate
            self.nowMs = nowMs
        }
    }

    // MARK: - `.gitignore` / `.ignore` Parser & Matcher

    public struct IgnoreRule: Equatable, Hashable, Sendable {
        public let baseDir: String
        public let rawPattern: String
        public let negated: Bool
        public let directoryOnly: Bool
        public let anchored: Bool
        internal let segments: [String]
        internal let trailingDoubleStar: Bool

        internal init(
            baseDir: String,
            rawPattern: String,
            negated: Bool,
            directoryOnly: Bool,
            anchored: Bool,
            segments: [String],
            trailingDoubleStar: Bool
        ) {
            self.baseDir = baseDir
            self.rawPattern = rawPattern
            self.negated = negated
            self.directoryOnly = directoryOnly
            self.anchored = anchored
            self.segments = segments
            self.trailingDoubleStar = trailingDoubleStar
        }
    }

    public struct IgnoreMatcher: Sendable {
        public let rules: [IgnoreRule]
        public let defaultIgnoredDirectories: Set<String>

        public init(
            rules: [IgnoreRule] = [],
            defaultIgnoredDirectories: Set<String> = [".git", "node_modules", ".build"]
        ) {
            self.rules = rules
            self.defaultIgnoredDirectories = defaultIgnoredDirectories
        }

        /// Parses a `.gitignore` or `.ignore` file located at `baseDir` (relative to repo root; `""` for root).
        public static func parse(_ content: String, baseDir: String = "") -> [IgnoreRule] {
            let normBase = CoreFuzzyFileIndex.normalizeRelativePath(baseDir)
            var parsed: [IgnoreRule] = []
            for rawSub in content.split(separator: "\n", omittingEmptySubsequences: false) {
                var line = String(rawSub)
                if line.hasSuffix("\r") {
                    line.removeLast()
                }
                guard let rule = parseLine(line, baseDir: normBase) else { continue }
                parsed.append(rule)
            }
            return parsed
        }

        /// Evaluates whether `relativePath` (relative to repo root) is ignored.
        /// Checks default ignored directories and ancestor directories so directory-only rules
        /// apply consistently to nested descendants as well.
        public func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
            let clean = CoreFuzzyFileIndex.normalizeRelativePath(relativePath)
            guard !clean.isEmpty else { return false }

            let pathComponents = clean.split(separator: "/").map(String.init)
            for (idx, comp) in pathComponents.enumerated() {
                let compIsDir = (idx < pathComponents.count - 1) || isDirectory
                if compIsDir && defaultIgnoredDirectories.contains(comp) {
                    return true
                }
            }

            if pathComponents.count > 1 {
                var prefix = ""
                for idx in 0..<(pathComponents.count - 1) {
                    prefix = prefix.isEmpty ? pathComponents[idx] : "\(prefix)/\(pathComponents[idx])"
                    if evaluateDirect(prefix, isDirectory: true) {
                        return true
                    }
                }
            }

            return evaluateDirect(clean, isDirectory: isDirectory)
        }

        internal func evaluateDirect(_ cleanPath: String, isDirectory: Bool) -> Bool {
            guard !rules.isEmpty else { return false }
            var ignored = false
            for rule in rules {
                if rule.directoryOnly && !isDirectory { continue }
                if matchesRule(rule, cleanPath: cleanPath) {
                    ignored = !rule.negated
                }
            }
            return ignored
        }

        private func matchesRule(_ rule: IgnoreRule, cleanPath: String) -> Bool {
            let scoped: String
            if rule.baseDir.isEmpty {
                scoped = cleanPath
            } else {
                let prefix = rule.baseDir + "/"
                guard cleanPath.hasPrefix(prefix) else { return false }
                scoped = String(cleanPath.dropFirst(prefix.count))
            }
            guard !scoped.isEmpty else { return false }

            if !rule.anchored {
                guard let patternSeg = rule.segments.first else { return false }
                let basename: Substring
                if let slash = scoped.lastIndex(of: "/") {
                    basename = scoped[scoped.index(after: slash)...]
                } else {
                    basename = Substring(scoped)
                }
                return Self.matchSegment(patternSeg, against: basename)
            }

            let pathSegs = scoped.split(separator: "/")
            return Self.matchSegments(
                rule.segments,
                pathSegments: pathSegs,
                trailingDoubleStar: rule.trailingDoubleStar
            )
        }

        private static func parseLine(_ rawLine: String, baseDir: String) -> IgnoreRule? {
            if rawLine.isEmpty { return nil }

            let stripped = stripTrailingUnescapedSpaces(rawLine)
            if stripped.isEmpty { return nil }
            if stripped.hasPrefix("#") { return nil }

            var body = stripped
            var negated = false
            if body.hasPrefix("!") {
                negated = true
                body.removeFirst()
            } else if body.hasPrefix("\\!") || body.hasPrefix("\\#") {
                body.removeFirst()
            }

            guard !body.isEmpty else { return nil }

            var directoryOnly = false
            if body.hasSuffix("/") && !body.hasSuffix("\\/") {
                directoryOnly = true
                while body.hasSuffix("/") && !body.hasSuffix("\\/") {
                    body.removeLast()
                }
            }

            guard !body.isEmpty else { return nil }

            let anchored = body.contains("/")
            if body.hasPrefix("/") {
                while body.hasPrefix("/") {
                    body.removeFirst()
                }
            }

            guard !body.isEmpty else { return nil }

            let rawSegments = body.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !rawSegments.isEmpty else { return nil }

            var segments: [String] = []
            segments.reserveCapacity(rawSegments.count)
            for seg in rawSegments {
                if seg == "**" && segments.last == "**" { continue }
                segments.append(seg)
            }

            let trailingDoubleStar = segments.last == "**" && segments.count > 1

            return IgnoreRule(
                baseDir: baseDir,
                rawPattern: rawLine,
                negated: negated,
                directoryOnly: directoryOnly,
                anchored: anchored,
                segments: segments,
                trailingDoubleStar: trailingDoubleStar
            )
        }

        private static func stripTrailingUnescapedSpaces(_ line: String) -> String {
            let chars = Array(line)
            var end = chars.count
            while end > 0 && chars[end - 1] == " " {
                var bs = 0
                var k = end - 2
                while k >= 0 && chars[k] == "\\" {
                    bs += 1
                    k -= 1
                }
                if bs % 2 == 1 {
                    break
                }
                end -= 1
            }
            return String(chars[0..<end])
        }

        private static func matchSegments(
            _ patternSegs: [String],
            pathSegments: [Substring],
            trailingDoubleStar: Bool
        ) -> Bool {
            let pCount = patternSegs.count
            let sCount = pathSegments.count

            let stride = sCount + 1
            var dp = [Bool](repeating: false, count: (pCount + 1) * stride)
            dp[pCount * stride + sCount] = true

            var pi = pCount - 1
            while pi >= 0 {
                let pat = patternSegs[pi]
                if pat == "**" {
                    let isTrailing = trailingDoubleStar && (pi == pCount - 1)
                    if isTrailing {
                        for si in 0..<sCount {
                            dp[pi * stride + si] = true
                        }
                    } else {
                        var suffixTrue = dp[(pi + 1) * stride + sCount]
                        dp[pi * stride + sCount] = suffixTrue
                        var si = sCount - 1
                        while si >= 0 {
                            if dp[(pi + 1) * stride + si] {
                                suffixTrue = true
                            }
                            dp[pi * stride + si] = suffixTrue
                            si -= 1
                        }
                    }
                } else {
                    for si in 0..<sCount {
                        if dp[(pi + 1) * stride + (si + 1)] && matchSegment(pat, against: pathSegments[si]) {
                            dp[pi * stride + si] = true
                        }
                    }
                }
                pi -= 1
            }
            return dp[0]
        }

        private static func matchSegment(_ pattern: String, against segment: Substring) -> Bool {
            if pattern == "*" { return true }
            if !pattern.contains("*") && !pattern.contains("?") && !pattern.contains("[") && !pattern.contains("\\") {
                return pattern == segment
            }

            let pChars = Array(pattern)
            let sChars = Array(segment)
            let pLen = pChars.count
            let sLen = sChars.count

            var prev = [Bool](repeating: false, count: sLen + 1)
            var curr = [Bool](repeating: false, count: sLen + 1)
            prev[0] = true

            var pi = 0
            while pi < pLen {
                let ch = pChars[pi]
                for idx in 0...sLen { curr[idx] = false }

                if ch == "*" {
                    var seen = false
                    for si in 0...sLen {
                        if prev[si] { seen = true }
                        curr[si] = seen
                    }
                    pi += 1
                } else if ch == "?" {
                    for si in 0..<sLen {
                        if prev[si] { curr[si + 1] = true }
                    }
                    pi += 1
                } else if ch == "[" {
                    if let (classEnd, predicate) = parseCharClass(pChars, from: pi) {
                        for si in 0..<sLen {
                            if prev[si] && predicate(sChars[si]) {
                                curr[si + 1] = true
                            }
                        }
                        pi = classEnd + 1
                    } else {
                        for si in 0..<sLen {
                            if prev[si] && sChars[si] == "[" {
                                curr[si + 1] = true
                            }
                        }
                        pi += 1
                    }
                } else if ch == "\\" && pi + 1 < pLen {
                    let lit = pChars[pi + 1]
                    for si in 0..<sLen {
                        if prev[si] && sChars[si] == lit {
                            curr[si + 1] = true
                        }
                    }
                    pi += 2
                } else {
                    for si in 0..<sLen {
                        if prev[si] && sChars[si] == ch {
                            curr[si + 1] = true
                        }
                    }
                    pi += 1
                }

                swap(&prev, &curr)
            }

            return prev[sLen]
        }

        private static func parseCharClass(
            _ chars: [Character],
            from openIndex: Int
        ) -> (endIndex: Int, matcher: (Character) -> Bool)? {
            var i = openIndex + 1
            guard i < chars.count else { return nil }
            var negate = false
            if chars[i] == "!" || chars[i] == "^" {
                negate = true
                i += 1
            }

            var ranges: [(ClosedRange<UInt32>)] = []
            var singles: [Character] = []
            var first = true

            while i < chars.count {
                if chars[i] == "]" && !first {
                    let capturedNegate = negate
                    let capturedRanges = ranges
                    let capturedSingles = singles
                    return (i, { candidate in
                        if candidate == "/" { return false }
                        var matched = capturedSingles.contains(candidate)
                        if !matched, let scalar = candidate.unicodeScalars.first, candidate.unicodeScalars.count == 1 {
                            let val = scalar.value
                            for r in capturedRanges where r.contains(val) {
                                matched = true
                                break
                            }
                        }
                        return capturedNegate ? !matched : matched
                    })
                }
                first = false
                let startChar: Character
                if chars[i] == "\\" && i + 1 < chars.count {
                    startChar = chars[i + 1]
                    i += 2
                } else {
                    startChar = chars[i]
                    i += 1
                }

                if i + 1 < chars.count && chars[i] == "-" && chars[i + 1] != "]" {
                    i += 1
                    let endChar: Character
                    if chars[i] == "\\" && i + 1 < chars.count {
                        endChar = chars[i + 1]
                        i += 2
                    } else {
                        endChar = chars[i]
                        i += 1
                    }
                    if let s1 = startChar.unicodeScalars.first,
                       let s2 = endChar.unicodeScalars.first,
                       startChar.unicodeScalars.count == 1,
                       endChar.unicodeScalars.count == 1,
                       s1.value <= s2.value
                    {
                        ranges.append(s1.value...s2.value)
                    } else {
                        singles.append(startChar)
                        singles.append(endChar)
                    }
                } else {
                    singles.append(startChar)
                }
            }
            return nil
        }
    }

    // MARK: - Flat Contiguous Arenas & Structure-of-Arrays Metadata

    internal struct EntryMeta: Sendable {
        let kind: EntryKind
        let isASCII: Bool
        let arenaOffset: Int
        let pathLength: Int
        let basenameStart: Int
        let basenameStemLength: Int
        let asciiBitmask: UInt64
    }

    internal struct ASCIIArena: Sendable {
        var raw: [UInt8] = []
        var lower: [UInt8] = []
        var bonus: [Int16] = []

        mutating func reservePaths(_ count: Int, avgLen: Int = 48) {
            let cap = count * avgLen
            raw.reserveCapacity(cap)
            lower.reserveCapacity(cap)
            bonus.reserveCapacity(cap)
        }

        mutating func append(path: String, kind: EntryKind) -> EntryMeta {
            let start = raw.count
            var mask: UInt64 = 0
            var lastSlash = -1
            var n = 0
            for b in path.utf8 {
                raw.append(b)
                if b == 47 { lastSlash = n }
                let lb = Matcher.asciiToLower(b)
                lower.append(lb)
                mask |= Matcher.asciiBit(for: lb)
                n += 1
            }

            let baseStart = lastSlash + 1
            var stemLen = n - baseStart
            if kind == .file {
                var k = n - 1
                while k > baseStart {
                    if raw[start + k] == 46 {
                        stemLen = k - baseStart
                        break
                    }
                    k -= 1
                }
            }

            for j in 0..<n {
                let curr = raw[start + j]
                if j == baseStart {
                    bonus.append(Matcher.bonusBasenameStart)
                } else if j == 0 {
                    bonus.append(Matcher.bonusPathStart)
                } else {
                    let prev = raw[start + j - 1]
                    if prev == 47 {
                        bonus.append(Matcher.bonusSlashBoundary)
                    } else if prev == 95 || prev == 45 || prev == 46 || prev == 32 {
                        bonus.append(Matcher.bonusDelimiterBoundary)
                    } else if Matcher.isASCIIUpper(curr) && (Matcher.isASCIILower(prev) || Matcher.isASCIIDigit(prev)) {
                        bonus.append(Matcher.bonusCamelBoundary)
                    } else if Matcher.isASCIIUpper(curr) && Matcher.isASCIIUpper(prev) && (j + 1 < n) && Matcher.isASCIILower(raw[start + j + 1]) {
                        bonus.append(Matcher.bonusAcronymBoundary)
                    } else if (Matcher.isASCIIDigit(curr) && Matcher.isASCIIAlpha(prev)) || (Matcher.isASCIIAlpha(curr) && Matcher.isASCIIDigit(prev)) {
                        bonus.append(Matcher.bonusDigitBoundary)
                    } else {
                        bonus.append(0)
                    }
                }
            }

            return EntryMeta(
                kind: kind,
                isASCII: true,
                arenaOffset: start,
                pathLength: n,
                basenameStart: baseStart,
                basenameStemLength: stemLen,
                asciiBitmask: mask
            )
        }
    }

    internal struct UTF16Arena: Sendable {
        var raw: [UInt16] = []
        var lower: [UInt16] = []
        var bonus: [Int16] = []

        mutating func append(path: String, kind: EntryKind) -> EntryMeta {
            let start = raw.count
            let rawUnits = Array(path.utf16)
            let lowerUnits = Matcher.lowercaseUTF16Units(path)
            let n = rawUnits.count

            var lastSlash = -1
            for i in 0..<n where rawUnits[i] == 47 {
                lastSlash = i
            }
            let baseStart = lastSlash + 1
            var stemLen = n - baseStart
            if kind == .file {
                var k = n - 1
                while k > baseStart {
                    if rawUnits[k] == 46 {
                        stemLen = k - baseStart
                        break
                    }
                    k -= 1
                }
            }

            let bonuses = Matcher.computeUTF16Bonuses(rawUnits, basenameStart: baseStart)
            raw.append(contentsOf: rawUnits)
            lower.append(contentsOf: lowerUnits)
            bonus.append(contentsOf: bonuses)

            return EntryMeta(
                kind: kind,
                isASCII: false,
                arenaOffset: start,
                pathLength: n,
                basenameStart: baseStart,
                basenameStemLength: stemLen,
                asciiBitmask: 0
            )
        }
    }

    // MARK: - High-Speed Fuzzy Matcher & Scorer

    public enum Matcher {
        public struct ScoreResult: Equatable, Hashable, Sendable {
            public let score: Double
            /// Sorted, unique UTF-16 code-unit indices in the candidate matched by the query.
            public let matchedIndices: [Int]

            public init(score: Double, matchedIndices: [Int]) {
                self.score = score
                self.matchedIndices = matchedIndices
            }
        }

        internal static let scoreMatch: Int32 = 16
        internal static let penaltyGapStart: Int32 = -3
        internal static let penaltyGapExtension: Int32 = -1
        internal static let bonusConsecutive: Int16 = 8
        internal static let bonusPathStart: Int16 = 10
        internal static let bonusSlashBoundary: Int16 = 12
        internal static let bonusBasenameStart: Int16 = 16
        internal static let bonusDelimiterBoundary: Int16 = 9
        internal static let bonusCamelBoundary: Int16 = 8
        internal static let bonusAcronymBoundary: Int16 = 7
        internal static let bonusDigitBoundary: Int16 = 5
        internal static let bonusCaseExact: Int32 = 2
        internal static let negInf: Int32 = -1_000_000_000
        internal static let halfNegInf: Int32 = -500_000_000
        internal static let maxDPMatrixCells: Int = 16_384

        /// Standalone fuzzy scorer useful for direct ranking and UI highlight computation.
        public static func score(query: String, candidate: String) -> ScoreResult? {
            let trimmed = trimASCIIAndUnicodeWhitespace(query)
            if trimmed.isEmpty {
                return ScoreResult(score: 0, matchedIndices: [])
            }
            var asciiArena = ASCIIArena()
            var utf16Arena = UTF16Arena()
            let meta: EntryMeta
            if candidate.utf8.allSatisfy({ $0 < 128 }) {
                meta = asciiArena.append(path: candidate, kind: .file)
            } else {
                meta = utf16Arena.append(path: candidate, kind: .file)
            }
            let prepared = PreparedQuery(raw: trimmed)
            var scratch = ScoringScratch(minWidth: max(256, meta.pathLength))
            guard let (s, indices) = scoreEntry(
                query: prepared,
                meta: meta,
                asciiArena: asciiArena,
                utf16Arena: utf16Arena,
                computeIndices: true,
                scratch: &scratch
            ) else {
                return nil
            }
            return ScoreResult(score: s, matchedIndices: indices)
        }

        internal struct PreparedToken: Sendable {
            let isASCII: Bool
            let asciiRaw: [UInt8]
            let asciiLower: [UInt8]
            let asciiMask: UInt64
            let utf16Raw: [UInt16]
            let utf16Lower: [UInt16]
            let length: Int

            init(_ text: String) {
                if text.utf8.allSatisfy({ $0 < 128 }) {
                    let raw = Array(text.utf8)
                    var lower = [UInt8](repeating: 0, count: raw.count)
                    var mask: UInt64 = 0
                    for i in 0..<raw.count {
                        let b = Matcher.asciiToLower(raw[i])
                        lower[i] = b
                        mask |= Matcher.asciiBit(for: b)
                    }
                    self.isASCII = true
                    self.asciiRaw = raw
                    self.asciiLower = lower
                    self.asciiMask = mask
                    self.utf16Raw = []
                    self.utf16Lower = []
                    self.length = raw.count
                } else {
                    let raw = Array(text.utf16)
                    let lower = Matcher.lowercaseUTF16Units(text)
                    self.isASCII = false
                    self.asciiRaw = []
                    self.asciiLower = []
                    self.asciiMask = 0
                    self.utf16Raw = raw
                    self.utf16Lower = lower
                    self.length = raw.count
                }
            }
        }

        internal struct PreparedQuery: Sendable {
            let trimmed: String
            let fullToken: PreparedToken
            let tokens: [PreparedToken]
            let isMultiToken: Bool

            init(raw: String) {
                self.trimmed = raw
                self.fullToken = PreparedToken(raw)
                let parts = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if parts.count > 1 {
                    self.tokens = parts.map(PreparedToken.init)
                    self.isMultiToken = true
                } else {
                    self.tokens = [self.fullToken]
                    self.isMultiToken = false
                }
            }
        }

        internal struct ScoringScratch {
            var prevM: [Int32]
            var currM: [Int32]
            var prevB: [Int16]
            var currB: [Int16]
            var prevFirst: [Int32]
            var currFirst: [Int32]
            var backPtr: [Int32]

            init(minWidth: Int = 256) {
                let w = max(64, minWidth)
                prevM = [Int32](repeating: negInf, count: w)
                currM = [Int32](repeating: negInf, count: w)
                prevB = [Int16](repeating: 0, count: w)
                currB = [Int16](repeating: 0, count: w)
                prevFirst = [Int32](repeating: 0, count: w)
                currFirst = [Int32](repeating: 0, count: w)
                backPtr = []
            }

            mutating func ensure(width: Int, rows: Int) {
                if prevM.count < width {
                    prevM = [Int32](repeating: negInf, count: width)
                    currM = [Int32](repeating: negInf, count: width)
                    prevB = [Int16](repeating: 0, count: width)
                    currB = [Int16](repeating: 0, count: width)
                    prevFirst = [Int32](repeating: 0, count: width)
                    currFirst = [Int32](repeating: 0, count: width)
                }
                let neededBack = rows * width
                if neededBack > 0 && backPtr.count < neededBack {
                    backPtr = [Int32](repeating: -1, count: neededBack)
                }
            }
        }

        /// Zero-ARC, pre-opened pointer fast path for scoring one ASCII entry against one ASCII token.
        /// Called directly inside the hoisted-pointer batch loop across 10,000+ entries.
        @inline(__always)
        internal static func scoreASCIIPointers(
            m: Int,
            qLow: UnsafePointer<UInt8>,
            qRaw: UnsafePointer<UInt8>,
            cLow: UnsafePointer<UInt8>,
            cRaw: UnsafePointer<UInt8>,
            cBonus: UnsafePointer<Int16>,
            n: Int,
            baseStart: Int,
            stemLen: Int,
            pMInit: UnsafeMutablePointer<Int32>,
            cMInit: UnsafeMutablePointer<Int32>,
            pBInit: UnsafeMutablePointer<Int16>,
            cBInit: UnsafeMutablePointer<Int16>,
            pFInit: UnsafeMutablePointer<Int32>,
            cFInit: UnsafeMutablePointer<Int32>
        ) -> Double? {
            if m == 1 {
                let q0Low = qLow[0]
                let q0Raw = qRaw[0]
                var bestPos = -1
                var bestVal: Int32 = negInf
                var j = 0
                while j < n {
                    if cLow[j] == q0Low {
                        let caseExtra: Int32 = cRaw[j] == q0Raw ? bonusCaseExact : 0
                        let val = scoreMatch &+ Int32(cBonus[j]) &* 2 &+ caseExtra
                        if val > bestVal {
                            bestVal = val
                            bestPos = j
                        }
                    }
                    j &+= 1
                }
                guard bestPos >= 0 else { return nil }
                return applyPathBonusesASCIIPtr(
                    dpScore: Double(bestVal),
                    firstMatchedPos: bestPos,
                    m: 1,
                    qLow: qLow,
                    qRaw: qRaw,
                    cLow: cLow,
                    cRaw: cRaw,
                    n: n,
                    baseStart: baseStart,
                    stemLen: stemLen
                )
            }

            // Subsequence pre-filter + tight [winStart...winEnd] window.
            var qi = 0
            var firstPos = -1
            var j = 0
            var target = qLow[0]
            while j < n {
                if cLow[j] == target {
                    if qi == 0 { firstPos = j }
                    qi &+= 1
                    if qi == m { break }
                    target = qLow[qi]
                }
                j &+= 1
            }
            guard qi == m else { return nil }

            let lastQ = qLow[m &- 1]
            var lastPos = n &- 1
            while lastPos >= firstPos && cLow[lastPos] != lastQ {
                lastPos &-= 1
            }

            let w = lastPos &- firstPos &+ 1
            if m &* w > maxDPMatrixCells {
                var pos = firstPos
                var totalDP: Int32 = 0
                var prevPos = -2
                var k = 0
                while k < m {
                    let qb = qLow[k]
                    while pos <= lastPos && cLow[pos] != qb { pos &+= 1 }
                    guard pos <= lastPos else { return nil }
                    let b = Int32(cBonus[pos])
                    if pos == prevPos &+ 1 {
                        totalDP &+= scoreMatch &+ (b > Int32(bonusConsecutive) ? b : Int32(bonusConsecutive))
                    } else {
                        totalDP &+= scoreMatch &+ b
                    }
                    prevPos = pos
                    pos &+= 1
                    k &+= 1
                }
                return applyPathBonusesASCIIPtr(
                    dpScore: Double(totalDP),
                    firstMatchedPos: firstPos,
                    m: m,
                    qLow: qLow,
                    qRaw: qRaw,
                    cLow: cLow,
                    cRaw: cRaw,
                    n: n,
                    baseStart: baseStart,
                    stemLen: stemLen
                )
            }

            // Two-row semi-global affine-gap DP on raw pointers (zero closures, zero bounds checks, zero ARC).
            let wLow = cLow.advanced(by: firstPos)
            let wRaw = cRaw.advanced(by: firstPos)
            let wBonus = cBonus.advanced(by: firstPos)
            let winStart32 = Int32(firstPos)

            var pM = pMInit
            var cM = cMInit
            var pB = pBInit
            var cB = cBInit
            var pF = pFInit
            var cF = cFInit

            // Row 0 (only up to `w - (m - 1)` can lead to a full match).
            let q0Low = qLow[0]
            let q0Raw = qRaw[0]
            let row0End = w &- (m &- 1)
            var firstValidInPrevRow = w
            var col = 0
            while col < row0End {
                if wLow[col] == q0Low {
                    let b = wBonus[col]
                    let caseExtra: Int32 = wRaw[col] == q0Raw ? bonusCaseExact : 0
                    pM[col] = scoreMatch &+ Int32(b) &* 2 &+ caseExtra
                    pB[col] = b
                    pF[col] = winStart32 &+ Int32(col)
                    if col < firstValidInPrevRow { firstValidInPrevRow = col }
                } else {
                    pM[col] = negInf
                    pB[col] = 0
                }
                col &+= 1
            }
            guard firstValidInPrevRow < row0End else { return nil }

            var row = 1
            while row < m {
                let qiLow = qLow[row]
                let qiRaw = qRaw[row]
                let startCol = firstValidInPrevRow &+ 1
                let rowEnd = w &- (m &- 1 &- row)
                guard startCol < rowEnd else { return nil }

                var clearCol = firstValidInPrevRow
                while clearCol < startCol {
                    cM[clearCol] = negInf
                    clearCol &+= 1
                }

                var nextFirstValid = rowEnd
                var bestGap: Int32 = negInf
                var bestGapFirst: Int32 = winStart32

                col = startCol
                while col < rowEnd {
                    if bestGap > halfNegInf {
                        bestGap &+= penaltyGapExtension
                    }
                    if col >= 2 {
                        let openCol = col &- 2
                        if openCol >= firstValidInPrevRow {
                            let prevScore = pM[openCol]
                            if prevScore > halfNegInf {
                                let openScore = prevScore &+ penaltyGapStart
                                if openScore > bestGap {
                                    bestGap = openScore
                                    bestGapFirst = pF[openCol]
                                }
                            }
                        }
                    }

                    if wLow[col] == qiLow {
                        let b = wBonus[col]
                        let caseExtra: Int32 = wRaw[col] == qiRaw ? bonusCaseExact : 0
                        var bestVal: Int32 = negInf
                        var bestB: Int16 = 0
                        var bestStart: Int32 = winStart32

                        let prevDiag = pM[col &- 1]
                        if prevDiag > halfNegInf {
                            var effB = pB[col &- 1]
                            if b > effB { effB = b }
                            if bonusConsecutive > effB { effB = bonusConsecutive }
                            bestVal = prevDiag &+ scoreMatch &+ Int32(effB) &+ caseExtra
                            bestB = effB
                            bestStart = pF[col &- 1]
                        }

                        if bestGap > halfNegInf {
                            let gapVal = bestGap &+ scoreMatch &+ Int32(b) &+ caseExtra
                            if gapVal > bestVal {
                                bestVal = gapVal
                                bestB = b
                                bestStart = bestGapFirst
                            }
                        }

                        cM[col] = bestVal
                        cB[col] = bestB
                        cF[col] = bestStart
                        if bestVal > halfNegInf && col < nextFirstValid {
                            nextFirstValid = col
                        }
                    } else {
                        cM[col] = negInf
                    }
                    col &+= 1
                }

                guard nextFirstValid < rowEnd else { return nil }

                let tmpM = pM; pM = cM; cM = tmpM
                let tmpB = pB; pB = cB; cB = tmpB
                let tmpF = pF; pF = cF; cF = tmpF
                firstValidInPrevRow = nextFirstValid
                row &+= 1
            }

            var bestScore: Int32 = negInf
            var bestFirstPos = Int(pF[firstValidInPrevRow])
            col = firstValidInPrevRow
            while col < w {
                let s = pM[col]
                if s > bestScore {
                    bestScore = s
                    bestFirstPos = Int(pF[col])
                }
                col &+= 1
            }
            guard bestScore > halfNegInf else { return nil }

            return applyPathBonusesASCIIPtr(
                dpScore: Double(bestScore),
                firstMatchedPos: bestFirstPos,
                m: m,
                qLow: qLow,
                qRaw: qRaw,
                cLow: cLow,
                cRaw: cRaw,
                n: n,
                baseStart: baseStart,
                stemLen: stemLen
            )
        }

        @inline(__always)
        private static func applyPathBonusesASCIIPtr(
            dpScore: Double,
            firstMatchedPos: Int,
            m: Int,
            qLow: UnsafePointer<UInt8>,
            qRaw: UnsafePointer<UInt8>,
            cLow: UnsafePointer<UInt8>,
            cRaw: UnsafePointer<UInt8>,
            n: Int,
            baseStart: Int,
            stemLen: Int
        ) -> Double {
            var total = dpScore
            let baseLen = n &- baseStart

            // 1. Exact full path or full path prefix (only check if first byte matches!).
            if cLow[0] == qLow[0] {
                if n == m && ptrEqual(cLow, qLow, count: m) {
                    total += 1_000.0
                    if ptrEqual(cRaw, qRaw, count: m) {
                        total += 50.0
                    }
                } else if n > m && ptrEqual(cLow, qLow, count: m) {
                    total += 120.0
                }
            }

            // 2. Exact basename / exact stem / basename prefix (only check if first basename byte matches!).
            if baseLen >= m && cLow[baseStart] == qLow[0] {
                let bLow = cLow.advanced(by: baseStart)
                if baseLen == m && ptrEqual(bLow, qLow, count: m) {
                    total += 500.0
                    if ptrEqual(cRaw.advanced(by: baseStart), qRaw, count: m) {
                        total += 20.0
                    }
                } else if baseLen > m && ptrEqual(bLow, qLow, count: m) {
                    total += 160.0
                    if stemLen == m {
                        total += 300.0
                    }
                }
            }

            // 3. Entire match contained inside basename.
            if firstMatchedPos >= baseStart {
                total += 40.0
            }

            // 4. Shorter-path compactness tie-breaker.
            total -= Double(n &- m) * 0.15
            return total
        }

        @inline(__always)
        private static func ptrEqual(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, count: Int) -> Bool {
            var i = 0
            while i < count {
                if a[i] != b[i] { return false }
                i &+= 1
            }
            return true
        }

        // MARK: General Entry Scorer (Multi-token, UTF-16, and Phase-2 Traceback)

        internal static func scoreEntry(
            query: PreparedQuery,
            meta: EntryMeta,
            asciiArena: ASCIIArena,
            utf16Arena: UTF16Arena,
            computeIndices: Bool,
            scratch: inout ScoringScratch
        ) -> (score: Double, indices: [Int])? {
            if !query.isMultiToken {
                return scoreSingleToken(
                    token: query.fullToken,
                    meta: meta,
                    asciiArena: asciiArena,
                    utf16Arena: utf16Arena,
                    computeIndices: computeIndices,
                    scratch: &scratch
                )
            }

            var totalScore = 0.0
            var combinedIndices: [Int] = []
            if computeIndices {
                combinedIndices.reserveCapacity(query.fullToken.length)
            }
            for token in query.tokens {
                guard let (s, idx) = scoreSingleToken(
                    token: token,
                    meta: meta,
                    asciiArena: asciiArena,
                    utf16Arena: utf16Arena,
                    computeIndices: computeIndices,
                    scratch: &scratch
                ) else {
                    return nil
                }
                totalScore += s
                if computeIndices {
                    combinedIndices.append(contentsOf: idx)
                }
            }

            if computeIndices {
                combinedIndices.sort()
                var deduped: [Int] = []
                deduped.reserveCapacity(combinedIndices.count)
                var last = -1
                for pos in combinedIndices where pos != last {
                    deduped.append(pos)
                    last = pos
                }
                return (totalScore, deduped)
            }
            return (totalScore, [])
        }

        private static func scoreSingleToken(
            token: PreparedToken,
            meta: EntryMeta,
            asciiArena: ASCIIArena,
            utf16Arena: UTF16Arena,
            computeIndices: Bool,
            scratch: inout ScoringScratch
        ) -> (score: Double, indices: [Int])? {
            let m = token.length
            let n = meta.pathLength
            guard m > 0 && m <= n else { return nil }

            if token.isASCII && meta.isASCII {
                if (meta.asciiBitmask & token.asciiMask) != token.asciiMask {
                    return nil
                }
                return scoreASCIIWithIndices(
                    token: token,
                    meta: meta,
                    asciiArena: asciiArena,
                    computeIndices: computeIndices,
                    scratch: &scratch
                )
            }

            return scoreUTF16(
                token: token,
                meta: meta,
                asciiArena: asciiArena,
                utf16Arena: utf16Arena,
                computeIndices: computeIndices,
                scratch: &scratch
            )
        }

        private static func scoreASCIIWithIndices(
            token: PreparedToken,
            meta: EntryMeta,
            asciiArena: ASCIIArena,
            computeIndices: Bool,
            scratch: inout ScoringScratch
        ) -> (score: Double, indices: [Int])? {
            let m = token.length
            let n = meta.pathLength
            let offset = meta.arenaOffset

            if m == 1 {
                let q0Low = token.asciiLower[0]
                let q0Raw = token.asciiRaw[0]
                var bestPos = -1
                var bestVal: Int32 = negInf
                for j in 0..<n where asciiArena.lower[offset + j] == q0Low {
                    let caseExtra: Int32 = asciiArena.raw[offset + j] == q0Raw ? bonusCaseExact : 0
                    let val = scoreMatch &+ Int32(asciiArena.bonus[offset + j]) &* 2 &+ caseExtra
                    if val > bestVal {
                        bestVal = val
                        bestPos = j
                    }
                }
                guard bestPos >= 0 else { return nil }
                let score = asciiArena.lower.withUnsafeBufferPointer { aLow in
                    asciiArena.raw.withUnsafeBufferPointer { aRaw in
                        token.asciiLower.withUnsafeBufferPointer { qLow in
                            token.asciiRaw.withUnsafeBufferPointer { qRaw in
                                applyPathBonusesASCIIPtr(
                                    dpScore: Double(bestVal),
                                    firstMatchedPos: bestPos,
                                    m: 1,
                                    qLow: qLow.baseAddress!,
                                    qRaw: qRaw.baseAddress!,
                                    cLow: aLow.baseAddress!.advanced(by: offset),
                                    cRaw: aRaw.baseAddress!.advanced(by: offset),
                                    n: n,
                                    baseStart: meta.basenameStart,
                                    stemLen: meta.basenameStemLength
                                )
                            }
                        }
                    }
                }
                return (score, computeIndices ? [bestPos] : [])
            }

            // Subsequence pre-filter + window.
            var qi = 0
            var firstPos = -1
            for j in 0..<n {
                if asciiArena.lower[offset + j] == token.asciiLower[qi] {
                    if qi == 0 { firstPos = j }
                    qi += 1
                    if qi == m { break }
                }
            }
            guard qi == m else { return nil }

            let lastQ = token.asciiLower[m - 1]
            var lastPos = n - 1
            while lastPos >= firstPos && asciiArena.lower[offset + lastPos] != lastQ {
                lastPos -= 1
            }

            let w = lastPos - firstPos + 1
            if m * w > maxDPMatrixCells {
                var indices: [Int] = []
                if computeIndices { indices.reserveCapacity(m) }
                var pos = firstPos
                var totalDP: Int32 = 0
                var prevPos = -2
                for k in 0..<m {
                    let qb = token.asciiLower[k]
                    while pos <= lastPos && asciiArena.lower[offset + pos] != qb { pos += 1 }
                    guard pos <= lastPos else { return nil }
                    if computeIndices { indices.append(pos) }
                    let b = Int32(asciiArena.bonus[offset + pos])
                    totalDP &+= (pos == prevPos + 1) ? (scoreMatch &+ max(b, Int32(bonusConsecutive))) : (scoreMatch &+ b)
                    prevPos = pos
                    pos += 1
                }
                let finalScore = asciiArena.lower.withUnsafeBufferPointer { aLow in
                    asciiArena.raw.withUnsafeBufferPointer { aRaw in
                        token.asciiLower.withUnsafeBufferPointer { qLow in
                            token.asciiRaw.withUnsafeBufferPointer { qRaw in
                                applyPathBonusesASCIIPtr(
                                    dpScore: Double(totalDP),
                                    firstMatchedPos: firstPos,
                                    m: m,
                                    qLow: qLow.baseAddress!,
                                    qRaw: qRaw.baseAddress!,
                                    cLow: aLow.baseAddress!.advanced(by: offset),
                                    cRaw: aRaw.baseAddress!.advanced(by: offset),
                                    n: n,
                                    baseStart: meta.basenameStart,
                                    stemLen: meta.basenameStemLength
                                )
                            }
                        }
                    }
                }
                return (finalScore, indices)
            }

            scratch.ensure(width: w, rows: computeIndices ? m : 0)

            let dpResult: (score: Int32, bestEndOffset: Int, firstMatchPos: Int) =
                asciiArena.lower.withUnsafeBufferPointer { aLow in
                    asciiArena.raw.withUnsafeBufferPointer { aRaw in
                        asciiArena.bonus.withUnsafeBufferPointer { aBonus in
                            token.asciiLower.withUnsafeBufferPointer { qLow in
                                token.asciiRaw.withUnsafeBufferPointer { qRaw in
                                    runDPASCIIWithTrace(
                                        m: m,
                                        winStart: firstPos,
                                        w: w,
                                        candLow: aLow.baseAddress!.advanced(by: offset),
                                        candRaw: aRaw.baseAddress!.advanced(by: offset),
                                        bonuses: aBonus.baseAddress!.advanced(by: offset),
                                        qLow: qLow.baseAddress!,
                                        qRaw: qRaw.baseAddress!,
                                        computeIndices: computeIndices,
                                        scratch: &scratch
                                    )
                                }
                            }
                        }
                    }
                }

            guard dpResult.score > halfNegInf else { return nil }

            let indices: [Int]
            let firstMatchedPos: Int
            if computeIndices {
                indices = reconstructIndices(
                    m: m,
                    winStart: firstPos,
                    w: w,
                    bestEndOffset: dpResult.bestEndOffset,
                    backPtr: scratch.backPtr
                )
                firstMatchedPos = indices.first ?? firstPos
            } else {
                indices = []
                firstMatchedPos = dpResult.firstMatchPos
            }

            let finalScore = asciiArena.lower.withUnsafeBufferPointer { aLow in
                asciiArena.raw.withUnsafeBufferPointer { aRaw in
                    token.asciiLower.withUnsafeBufferPointer { qLow in
                        token.asciiRaw.withUnsafeBufferPointer { qRaw in
                            applyPathBonusesASCIIPtr(
                                dpScore: Double(dpResult.score),
                                firstMatchedPos: firstMatchedPos,
                                m: m,
                                qLow: qLow.baseAddress!,
                                qRaw: qRaw.baseAddress!,
                                cLow: aLow.baseAddress!.advanced(by: offset),
                                cRaw: aRaw.baseAddress!.advanced(by: offset),
                                n: n,
                                baseStart: meta.basenameStart,
                                stemLen: meta.basenameStemLength
                            )
                        }
                    }
                }
            }
            return (finalScore, indices)
        }

        private static func runDPASCIIWithTrace(
            m: Int,
            winStart: Int,
            w: Int,
            candLow: UnsafePointer<UInt8>,
            candRaw: UnsafePointer<UInt8>,
            bonuses: UnsafePointer<Int16>,
            qLow: UnsafePointer<UInt8>,
            qRaw: UnsafePointer<UInt8>,
            computeIndices: Bool,
            scratch: inout ScoringScratch
        ) -> (score: Int32, bestEndOffset: Int, firstMatchPos: Int) {
            let cLow = candLow.advanced(by: winStart)
            let cRaw = candRaw.advanced(by: winStart)
            let cBonus = bonuses.advanced(by: winStart)
            let winStart32 = Int32(winStart)

            return scratch.prevM.withUnsafeMutableBufferPointer { prevMBuf in
                scratch.currM.withUnsafeMutableBufferPointer { currMBuf in
                    scratch.prevB.withUnsafeMutableBufferPointer { prevBBuf in
                        scratch.currB.withUnsafeMutableBufferPointer { currBBuf in
                            scratch.prevFirst.withUnsafeMutableBufferPointer { prevFBuf in
                                scratch.currFirst.withUnsafeMutableBufferPointer { currFBuf in
                                    scratch.backPtr.withUnsafeMutableBufferPointer { backBuf in
                                        var pM = prevMBuf.baseAddress!
                                        var cM = currMBuf.baseAddress!
                                        var pB = prevBBuf.baseAddress!
                                        var cB = currBBuf.baseAddress!
                                        var pF = prevFBuf.baseAddress!
                                        var cF = currFBuf.baseAddress!
                                        let backP = backBuf.baseAddress

                                        let q0Low = qLow[0]
                                        let q0Raw = qRaw[0]
                                        let row0End = w - (m - 1)
                                        var firstValidInPrevRow = w

                                        for col in 0..<row0End {
                                            if cLow[col] == q0Low {
                                                let b = cBonus[col]
                                                let caseExtra: Int32 = cRaw[col] == q0Raw ? bonusCaseExact : 0
                                                pM[col] = scoreMatch &+ Int32(b) &* 2 &+ caseExtra
                                                pB[col] = b
                                                pF[col] = winStart32 &+ Int32(col)
                                                if col < firstValidInPrevRow { firstValidInPrevRow = col }
                                            } else {
                                                pM[col] = negInf
                                                pB[col] = 0
                                                pF[col] = winStart32
                                            }
                                        }
                                        guard firstValidInPrevRow < row0End else { return (negInf, 0, winStart) }

                                        for row in 1..<m {
                                            let qiLow = qLow[row]
                                            let qiRaw = qRaw[row]
                                            let startCol = firstValidInPrevRow + 1
                                            let rowEnd = w - (m - 1 - row)
                                            guard startCol < rowEnd else { return (negInf, 0, winStart) }

                                            for col in 0..<startCol {
                                                cM[col] = negInf
                                                cB[col] = 0
                                                cF[col] = winStart32
                                            }

                                            var nextFirstValid = rowEnd
                                            var bestGap: Int32 = negInf
                                            var bestGapCol: Int32 = -1
                                            var bestGapFirst: Int32 = winStart32
                                            let rowOffset = computeIndices ? row * w : 0

                                            for col in startCol..<rowEnd {
                                                if bestGap > halfNegInf {
                                                    bestGap &+= penaltyGapExtension
                                                }
                                                if col >= 2 {
                                                    let openCol = col - 2
                                                    if openCol >= firstValidInPrevRow {
                                                        let prevScore = pM[openCol]
                                                        if prevScore > halfNegInf {
                                                            let openScore = prevScore &+ penaltyGapStart
                                                            if openScore > bestGap {
                                                                bestGap = openScore
                                                                bestGapCol = Int32(openCol)
                                                                bestGapFirst = pF[openCol]
                                                            }
                                                        }
                                                    }
                                                }

                                                if cLow[col] == qiLow {
                                                    let b = cBonus[col]
                                                    let caseExtra: Int32 = cRaw[col] == qiRaw ? bonusCaseExact : 0
                                                    var bestVal: Int32 = negInf
                                                    var bestB: Int16 = 0
                                                    var bestPrevCol: Int32 = -1
                                                    var bestStart: Int32 = winStart32

                                                    let prevDiag = pM[col - 1]
                                                    if prevDiag > halfNegInf {
                                                        var effB = pB[col - 1]
                                                        if b > effB { effB = b }
                                                        if bonusConsecutive > effB { effB = bonusConsecutive }
                                                        bestVal = prevDiag &+ scoreMatch &+ Int32(effB) &+ caseExtra
                                                        bestB = effB
                                                        bestPrevCol = Int32(col - 1)
                                                        bestStart = pF[col - 1]
                                                    }

                                                    if bestGap > halfNegInf {
                                                        let gapVal = bestGap &+ scoreMatch &+ Int32(b) &+ caseExtra
                                                        if gapVal > bestVal {
                                                            bestVal = gapVal
                                                            bestB = b
                                                            bestPrevCol = bestGapCol
                                                            bestStart = bestGapFirst
                                                        }
                                                    }

                                                    cM[col] = bestVal
                                                    cB[col] = bestB
                                                    cF[col] = bestStart
                                                    if computeIndices, let bp = backP {
                                                        bp[rowOffset + col] = bestPrevCol
                                                    }
                                                    if bestVal > halfNegInf && col < nextFirstValid {
                                                        nextFirstValid = col
                                                    }
                                                } else {
                                                    cM[col] = negInf
                                                    cB[col] = 0
                                                    cF[col] = winStart32
                                                    if computeIndices, let bp = backP {
                                                        bp[rowOffset + col] = -1
                                                    }
                                                }
                                            }

                                            guard nextFirstValid < rowEnd else { return (negInf, 0, winStart) }

                                            swap(&pM, &cM)
                                            swap(&pB, &cB)
                                            swap(&pF, &cF)
                                            firstValidInPrevRow = nextFirstValid
                                        }

                                        var bestScore: Int32 = negInf
                                        var bestCol = firstValidInPrevRow
                                        var bestFirstPos = Int(pF[firstValidInPrevRow])
                                        for col in firstValidInPrevRow..<w {
                                            let s = pM[col]
                                            if s > bestScore {
                                                bestScore = s
                                                bestCol = col
                                                bestFirstPos = Int(pF[col])
                                            }
                                        }
                                        return (bestScore, bestCol, bestFirstPos)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // MARK: UTF-16 General Path (Unicode, CJK, Emoji/Surrogate Pairs)

        private static func scoreUTF16(
            token: PreparedToken,
            meta: EntryMeta,
            asciiArena: ASCIIArena,
            utf16Arena: UTF16Arena,
            computeIndices: Bool,
            scratch: inout ScoringScratch
        ) -> (score: Double, indices: [Int])? {
            let n = meta.pathLength
            let off = meta.arenaOffset
            let candLower: [UInt16]
            let candRaw: [UInt16]
            let bonuses: [Int16]
            if meta.isASCII {
                candLower = asciiArena.lower[off..<(off + n)].map(UInt16.init)
                candRaw = asciiArena.raw[off..<(off + n)].map(UInt16.init)
                bonuses = Array(asciiArena.bonus[off..<(off + n)])
            } else {
                candLower = Array(utf16Arena.lower[off..<(off + n)])
                candRaw = Array(utf16Arena.raw[off..<(off + n)])
                bonuses = Array(utf16Arena.bonus[off..<(off + n)])
            }

            let qLower: [UInt16] = token.isASCII ? token.asciiLower.map(UInt16.init) : token.utf16Lower
            let qRaw: [UInt16] = token.isASCII ? token.asciiRaw.map(UInt16.init) : token.utf16Raw
            let m = qLower.count
            guard m > 0 && m <= n else { return nil }

            if m == 1 {
                var best = -1
                var bestVal: Int32 = negInf
                for j in 0..<n where candLower[j] == qLower[0] {
                    let caseExtra: Int32 = candRaw[j] == qRaw[0] ? bonusCaseExact : 0
                    let val = scoreMatch &+ Int32(bonuses[j]) &* 2 &+ caseExtra
                    if val > bestVal {
                        bestVal = val
                        best = j
                    }
                }
                guard best >= 0 else { return nil }
                let finalScore = applyPathBonusesUTF16(
                    dpScore: Double(bestVal),
                    firstMatchedPos: best,
                    qLower: qLower,
                    qRaw: qRaw,
                    candLower: candLower,
                    candRaw: candRaw,
                    meta: meta
                )
                return (finalScore, computeIndices ? [best] : [])
            }

            var qi = 0
            var firstPos = -1
            for j in 0..<n {
                if candLower[j] == qLower[qi] {
                    if qi == 0 { firstPos = j }
                    qi += 1
                    if qi == m { break }
                }
            }
            guard qi == m else { return nil }

            let lastQ = qLower[m - 1]
            var lastPos = n - 1
            while lastPos >= firstPos && candLower[lastPos] != lastQ {
                lastPos -= 1
            }

            let w = lastPos - firstPos + 1
            if m * w > maxDPMatrixCells {
                var indices: [Int] = []
                var pos = firstPos
                for qIdx in 0..<m {
                    while pos <= lastPos && candLower[pos] != qLower[qIdx] { pos += 1 }
                    guard pos <= lastPos else { return nil }
                    indices.append(pos)
                    pos += 1
                }
                let finalScore = applyPathBonusesUTF16(
                    dpScore: Double(m) * Double(scoreMatch),
                    firstMatchedPos: indices.first ?? firstPos,
                    qLower: qLower,
                    qRaw: qRaw,
                    candLower: candLower,
                    candRaw: candRaw,
                    meta: meta
                )
                return (finalScore, computeIndices ? indices : [])
            }

            scratch.ensure(width: w, rows: computeIndices ? m : 0)

            let dpResult = runDPUTF16(
                m: m,
                winStart: firstPos,
                w: w,
                candLower: candLower,
                candRaw: candRaw,
                bonuses: bonuses,
                qLower: qLower,
                qRaw: qRaw,
                computeIndices: computeIndices,
                scratch: &scratch
            )
            guard dpResult.score > halfNegInf else { return nil }

            let indices: [Int]
            let firstMatchedPos: Int
            if computeIndices {
                indices = reconstructIndices(
                    m: m,
                    winStart: firstPos,
                    w: w,
                    bestEndOffset: dpResult.bestEndOffset,
                    backPtr: scratch.backPtr
                )
                firstMatchedPos = indices.first ?? firstPos
            } else {
                indices = []
                firstMatchedPos = dpResult.firstMatchPos
            }

            let finalScore = applyPathBonusesUTF16(
                dpScore: Double(dpResult.score),
                firstMatchedPos: firstMatchedPos,
                qLower: qLower,
                qRaw: qRaw,
                candLower: candLower,
                candRaw: candRaw,
                meta: meta
            )
            return (finalScore, indices)
        }

        private static func runDPUTF16(
            m: Int,
            winStart: Int,
            w: Int,
            candLower: [UInt16],
            candRaw: [UInt16],
            bonuses: [Int16],
            qLower: [UInt16],
            qRaw: [UInt16],
            computeIndices: Bool,
            scratch: inout ScoringScratch
        ) -> (score: Int32, bestEndOffset: Int, firstMatchPos: Int) {
            let q0Low = qLower[0]
            let q0Raw = qRaw[0]
            let row0End = w - (m - 1)
            var firstValidInPrevRow = w

            for col in 0..<row0End {
                let pos = winStart + col
                if candLower[pos] == q0Low {
                    let b = bonuses[pos]
                    let caseExtra: Int32 = candRaw[pos] == q0Raw ? bonusCaseExact : 0
                    scratch.prevM[col] = scoreMatch &+ Int32(b) &* 2 &+ caseExtra
                    scratch.prevB[col] = b
                    scratch.prevFirst[col] = Int32(pos)
                    if col < firstValidInPrevRow { firstValidInPrevRow = col }
                } else {
                    scratch.prevM[col] = negInf
                    scratch.prevB[col] = 0
                    scratch.prevFirst[col] = Int32(winStart)
                }
            }
            guard firstValidInPrevRow < row0End else { return (negInf, 0, winStart) }

            for row in 1..<m {
                let qiLow = qLower[row]
                let qiRaw = qRaw[row]
                let startCol = firstValidInPrevRow + 1
                let rowEnd = w - (m - 1 - row)
                guard startCol < rowEnd else { return (negInf, 0, winStart) }

                for col in 0..<startCol {
                    scratch.currM[col] = negInf
                    scratch.currB[col] = 0
                    scratch.currFirst[col] = Int32(winStart)
                }

                var nextFirstValid = rowEnd
                var bestGap: Int32 = negInf
                var bestGapCol: Int = -1
                var bestGapFirst: Int32 = Int32(winStart)
                let rowOffset = computeIndices ? row * w : 0

                for col in startCol..<rowEnd {
                    if bestGap > halfNegInf {
                        bestGap &+= penaltyGapExtension
                    }
                    if col >= 2 {
                        let openCol = col - 2
                        if openCol >= firstValidInPrevRow {
                            let prevScore = scratch.prevM[openCol]
                            if prevScore > halfNegInf {
                                let openScore = prevScore &+ penaltyGapStart
                                if openScore > bestGap {
                                    bestGap = openScore
                                    bestGapCol = openCol
                                    bestGapFirst = scratch.prevFirst[openCol]
                                }
                            }
                        }
                    }

                    let pos = winStart + col
                    if candLower[pos] == qiLow {
                        let b = bonuses[pos]
                        let caseExtra: Int32 = candRaw[pos] == qiRaw ? bonusCaseExact : 0
                        var bestVal: Int32 = negInf
                        var bestB: Int16 = 0
                        var bestPrevCol: Int32 = -1
                        var bestStart: Int32 = Int32(winStart)

                        let prevDiag = scratch.prevM[col - 1]
                        if prevDiag > halfNegInf {
                            let effB = max(scratch.prevB[col - 1], max(b, bonusConsecutive))
                            bestVal = prevDiag &+ scoreMatch &+ Int32(effB) &+ caseExtra
                            bestB = effB
                            bestPrevCol = Int32(col - 1)
                            bestStart = scratch.prevFirst[col - 1]
                        }

                        if bestGap > halfNegInf {
                            let gapVal = bestGap &+ scoreMatch &+ Int32(b) &+ caseExtra
                            if gapVal > bestVal {
                                bestVal = gapVal
                                bestB = b
                                bestPrevCol = Int32(bestGapCol)
                                bestStart = bestGapFirst
                            }
                        }

                        scratch.currM[col] = bestVal
                        scratch.currB[col] = bestB
                        scratch.currFirst[col] = bestStart
                        if computeIndices {
                            scratch.backPtr[rowOffset + col] = bestPrevCol
                        }
                        if bestVal > halfNegInf && col < nextFirstValid {
                            nextFirstValid = col
                        }
                    } else {
                        scratch.currM[col] = negInf
                        scratch.currB[col] = 0
                        scratch.currFirst[col] = Int32(winStart)
                        if computeIndices {
                            scratch.backPtr[rowOffset + col] = -1
                        }
                    }
                }

                guard nextFirstValid < rowEnd else { return (negInf, 0, winStart) }

                swap(&scratch.prevM, &scratch.currM)
                swap(&scratch.prevB, &scratch.currB)
                swap(&scratch.prevFirst, &scratch.currFirst)
                firstValidInPrevRow = nextFirstValid
            }

            var bestScore: Int32 = negInf
            var bestCol = firstValidInPrevRow
            var bestFirstPos = Int(scratch.prevFirst[firstValidInPrevRow])
            for col in firstValidInPrevRow..<w {
                let s = scratch.prevM[col]
                if s > bestScore {
                    bestScore = s
                    bestCol = col
                    bestFirstPos = Int(scratch.prevFirst[col])
                }
            }
            return (bestScore, bestCol, bestFirstPos)
        }

        private static func applyPathBonusesUTF16(
            dpScore: Double,
            firstMatchedPos: Int,
            qLower: [UInt16],
            qRaw: [UInt16],
            candLower: [UInt16],
            candRaw: [UInt16],
            meta: EntryMeta
        ) -> Double {
            var total = dpScore
            let m = qLower.count
            let n = candLower.count
            let baseStart = meta.basenameStart
            let baseLen = n - baseStart

            if n == m && utf16SlicesEqual(candLower, start: 0, other: qLower) {
                total += 1_000.0
                if utf16SlicesEqual(candRaw, start: 0, other: qRaw) {
                    total += 50.0
                }
            } else if n > m && utf16SlicesEqual(candLower, start: 0, other: qLower) {
                total += 120.0
            }

            if baseLen == m && utf16SlicesEqual(candLower, start: baseStart, other: qLower) {
                total += 500.0
                if utf16SlicesEqual(candRaw, start: baseStart, other: qRaw) {
                    total += 20.0
                }
            } else if baseLen > m && utf16SlicesEqual(candLower, start: baseStart, other: qLower) {
                total += 160.0
                if meta.basenameStemLength == m {
                    total += 300.0
                }
            }

            if firstMatchedPos >= baseStart {
                total += 40.0
            }

            total -= Double(n - m) * 0.15
            return total
        }

        @inline(__always)
        private static func utf16SlicesEqual(_ haystack: [UInt16], start: Int, other: [UInt16]) -> Bool {
            let count = other.count
            guard start + count <= haystack.count else { return false }
            for i in 0..<count {
                if haystack[start + i] != other[i] { return false }
            }
            return true
        }

        private static func reconstructIndices(
            m: Int,
            winStart: Int,
            w: Int,
            bestEndOffset: Int,
            backPtr: [Int32]
        ) -> [Int] {
            var indices = [Int](repeating: 0, count: m)
            var col = bestEndOffset
            var row = m - 1
            while row >= 0 {
                indices[row] = winStart + col
                if row > 0 {
                    let prev = Int(backPtr[row * w + col])
                    col = prev >= 0 ? prev : max(0, col - 1)
                }
                row -= 1
            }
            return indices
        }

        // MARK: Character Classification & Precomputation Helpers

        @inline(__always)
        internal static func asciiToLower(_ byte: UInt8) -> UInt8 {
            (byte >= 65 && byte <= 90) ? (byte &+ 32) : byte
        }

        @inline(__always)
        internal static func asciiBit(for lowerByte: UInt8) -> UInt64 {
            let shift: UInt64
            if lowerByte >= 97 && lowerByte <= 122 {
                shift = UInt64(lowerByte - 97)
            } else if lowerByte >= 48 && lowerByte <= 57 {
                shift = 26 + UInt64(lowerByte - 48)
            } else {
                switch lowerByte {
                case 47: shift = 36
                case 46: shift = 37
                case 95: shift = 38
                case 45: shift = 39
                case 32: shift = 40
                case 64: shift = 41
                case 43: shift = 42
                case 36: shift = 43
                case 126: shift = 44
                case 40: shift = 45
                case 41: shift = 46
                case 91: shift = 47
                case 93: shift = 48
                case 123: shift = 49
                case 125: shift = 50
                case 35: shift = 51
                case 33: shift = 52
                case 58: shift = 53
                case 61: shift = 54
                case 44: shift = 55
                case 59: shift = 56
                case 38: shift = 57
                case 37: shift = 58
                default: shift = 63
                }
            }
            return UInt64(1) &<< shift
        }

        internal static func computeUTF16Bonuses(_ raw: [UInt16], basenameStart: Int) -> [Int16] {
            let n = raw.count
            var bonuses = [Int16](repeating: 0, count: n)
            for j in 0..<n {
                let curr = raw[j]
                if j == basenameStart {
                    bonuses[j] = bonusBasenameStart
                    continue
                }
                if j == 0 {
                    bonuses[j] = bonusPathStart
                    continue
                }
                let prev = raw[j - 1]
                if prev == 47 {
                    bonuses[j] = bonusSlashBoundary
                } else if prev == 95 || prev == 45 || prev == 46 || prev == 32 {
                    bonuses[j] = bonusDelimiterBoundary
                } else if curr < 128 && prev < 128 {
                    let cb = UInt8(curr)
                    let pb = UInt8(prev)
                    if isASCIIUpper(cb) && (isASCIILower(pb) || isASCIIDigit(pb)) {
                        bonuses[j] = bonusCamelBoundary
                    } else if isASCIIUpper(cb) && isASCIIUpper(pb) && (j + 1 < n) && raw[j + 1] < 128 && isASCIILower(UInt8(raw[j + 1])) {
                        bonuses[j] = bonusAcronymBoundary
                    } else if (isASCIIDigit(cb) && isASCIIAlpha(pb)) || (isASCIIAlpha(cb) && isASCIIDigit(pb)) {
                        bonuses[j] = bonusDigitBoundary
                    }
                }
            }
            return bonuses
        }

        internal static func lowercaseUTF16Units(_ string: String) -> [UInt16] {
            var result: [UInt16] = []
            result.reserveCapacity(string.utf16.count)
            for scalar in string.unicodeScalars {
                let val = scalar.value
                if val >= 65 && val <= 90 {
                    result.append(UInt16(val + 32))
                } else if val < 128 {
                    result.append(UInt16(val))
                } else {
                    let origCount = scalar.utf16.count
                    let lowered = String(scalar).lowercased()
                    if lowered.utf16.count == origCount {
                        result.append(contentsOf: lowered.utf16)
                    } else {
                        result.append(contentsOf: scalar.utf16)
                    }
                }
            }
            return result
        }

        internal static func trimASCIIAndUnicodeWhitespace(_ value: String) -> String {
            var start = value.startIndex
            var end = value.endIndex
            while start < end && value[start].isWhitespace {
                start = value.index(after: start)
            }
            while end > start {
                let prev = value.index(before: end)
                if value[prev].isWhitespace {
                    end = prev
                } else {
                    break
                }
            }
            return String(value[start..<end])
        }

        @inline(__always) internal static func isASCIIUpper(_ b: UInt8) -> Bool { b >= 65 && b <= 90 }
        @inline(__always) internal static func isASCIILower(_ b: UInt8) -> Bool { b >= 97 && b <= 122 }
        @inline(__always) internal static func isASCIIDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        @inline(__always) internal static func isASCIIAlpha(_ b: UInt8) -> Bool { isASCIIUpper(b) || isASCIILower(b) }
    }

    // MARK: - Internal Snapshot & Index State

    private struct RootSnapshot: Sendable {
        let root: String
        var paths: [String]
        var metas: [EntryMeta]
        var asciiArena: ASCIIArena
        var utf16Arena: UTF16Arena
        var maxPathLength: Int
        var indexByPath: [String: Int]
        var ignoreMatcher: IgnoreMatcher
        var builtAtMs: Int64
        var isStale: Bool
        let generation: UInt64

        mutating func upsert(relativePath: String, kind: EntryKind) {
            let meta: EntryMeta
            if relativePath.utf8.allSatisfy({ $0 < 128 }) {
                meta = asciiArena.append(path: relativePath, kind: kind)
            } else {
                meta = utf16Arena.append(path: relativePath, kind: kind)
            }
            if meta.pathLength > maxPathLength {
                maxPathLength = meta.pathLength
            }
            if let existing = indexByPath[relativePath] {
                metas[existing] = meta
            } else {
                indexByPath[relativePath] = paths.count
                paths.append(relativePath)
                metas.append(meta)
            }
        }

        mutating func removeExact(_ relativePath: String) {
            guard let idx = indexByPath.removeValue(forKey: relativePath) else { return }
            let lastIdx = paths.count - 1
            if idx != lastIdx {
                let movedPath = paths[lastIdx]
                paths[idx] = movedPath
                metas[idx] = metas[lastIdx]
                indexByPath[movedPath] = idx
            }
            paths.removeLast()
            metas.removeLast()
        }

        mutating func removeSubtree(_ relativePath: String) {
            let prefix = relativePath + "/"
            var toRemove: [String] = []
            if indexByPath[relativePath] != nil {
                toRemove.append(relativePath)
            }
            for key in indexByPath.keys where key.hasPrefix(prefix) {
                toRemove.append(key)
            }
            for key in toRemove {
                removeExact(key)
            }
        }

        mutating func ensureParentDirectories(for relativePath: String) {
            let comps = relativePath.split(separator: "/")
            guard comps.count > 1 else { return }
            var current = ""
            for i in 0..<(comps.count - 1) {
                current = current.isEmpty ? String(comps[i]) : "\(current)/\(comps[i])"
                if indexByPath[current] == nil {
                    upsert(relativePath: current, kind: .directory)
                }
            }
        }
    }

    private struct RootRecord: Sendable {
        var snapshot: RootSnapshot?
        var inFlightTask: Task<RootSnapshot, any Error>?
        var generation: UInt64 = 0
    }

    private struct IndexState: Sendable {
        var roots: [String: RootRecord] = [:]
        var frecency: [String: FrecencyEntry] = [:]
    }

    // MARK: - Stored Properties

    public let fileSystem: any OpenCodeFileSystem
    public let configuration: Configuration
    private let nowMs: @Sendable () -> Int64
    private let state = Mutex(IndexState())

    // MARK: - Initialization

    public init(
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        configuration: Configuration = Configuration(),
        nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
    ) {
        self.fileSystem = fileSystem
        self.configuration = configuration
        self.nowMs = nowMs
    }

    // MARK: - Background Index Lifecycle

    /// Walks `root` concurrently using `.gitignore` / `.ignore` rules and populates the index cache.
    /// Coalesces concurrent warm requests targeting the same `root`.
    @discardableResult
    public func warm(root: String) async throws -> Int {
        let normRoot = Self.normalizeRootPath(root)
        let task = acquireOrStartScanTask(normRoot: normRoot, forceNew: false)
        let snapshot = try await task.value
        return snapshot.paths.count
    }

    /// Invalidates the cached snapshot for `root`, forcing the next search or `warm(root:)` to rescan.
    public func invalidate(root: String) {
        let normRoot = Self.normalizeRootPath(root)
        let taskToCancel: Task<RootSnapshot, any Error>? = state.withLock { s in
            var record = s.roots[normRoot] ?? RootRecord()
            record.generation &+= 1
            record.snapshot = nil
            let existing = record.inFlightTask
            record.inFlightTask = nil
            s.roots[normRoot] = record
            return existing
        }
        taskToCancel?.cancel()
    }

    /// Invalidates every cached root snapshot.
    public func invalidateAll() {
        let tasksToCancel: [Task<RootSnapshot, any Error>] = state.withLock { s in
            var tasks: [Task<RootSnapshot, any Error>] = []
            for key in s.roots.keys {
                if let t = s.roots[key]?.inFlightTask {
                    tasks.append(t)
                }
            }
            s.roots.removeAll()
            return tasks
        }
        for t in tasksToCancel {
            t.cancel()
        }
    }

    /// Marks `root`'s cached snapshot as stale while retaining it for stale-while-revalidate queries.
    public func markStale(root: String) {
        let normRoot = Self.normalizeRootPath(root)
        state.withLock { s in
            s.roots[normRoot]?.snapshot?.isStale = true
        }
    }

    /// Returns `true` if a background scan or revalidation task is currently running for `root`.
    public func isScanning(root: String) -> Bool {
        let normRoot = Self.normalizeRootPath(root)
        return state.withLock { s in
            s.roots[normRoot]?.inFlightTask != nil
        }
    }

    /// Returns the number of currently indexed entries cached for `root` (0 if not yet warmed).
    public func entryCount(root: String) -> Int {
        let normRoot = Self.normalizeRootPath(root)
        return state.withLock { s in
            s.roots[normRoot]?.snapshot?.paths.count ?? 0
        }
    }

    /// Waits for any in-flight background revalidation scan on `root` to settle.
    public func waitForBackgroundRefresh(root: String) async {
        let normRoot = Self.normalizeRootPath(root)
        let task: Task<RootSnapshot, any Error>? = state.withLock { s in
            s.roots[normRoot]?.inFlightTask
        }
        if let task {
            _ = try? await task.value
        }
    }

    /// Populates the cache for `root` directly from an explicit list of relative paths (useful for
    /// tests, benchmarks, or externally supplied file lists).
    public func seed(
        root: String,
        entries: [(path: String, kind: EntryKind)],
        ignoreMatcher: IgnoreMatcher? = nil,
        builtAtMs: Int64? = nil
    ) {
        let normRoot = Self.normalizeRootPath(root)
        let timestamp = builtAtMs ?? nowMs()
        let matcher = ignoreMatcher ?? IgnoreMatcher(
            rules: [],
            defaultIgnoredDirectories: configuration.defaultIgnoredDirectories
        )

        var paths: [String] = []
        paths.reserveCapacity(entries.count)
        var metas: [EntryMeta] = []
        metas.reserveCapacity(entries.count)
        var asciiArena = ASCIIArena()
        asciiArena.reservePaths(entries.count)
        var utf16Arena = UTF16Arena()
        var map: [String: Int] = [:]
        map.reserveCapacity(entries.count)
        var maxLen = 0

        for (rawPath, kind) in entries {
            let rel = Self.normalizeRelativePath(rawPath)
            guard !rel.isEmpty else { continue }
            if map[rel] != nil { continue }
            let meta: EntryMeta
            if rel.utf8.allSatisfy({ $0 < 128 }) {
                meta = asciiArena.append(path: rel, kind: kind)
            } else {
                meta = utf16Arena.append(path: rel, kind: kind)
            }
            if meta.pathLength > maxLen { maxLen = meta.pathLength }
            map[rel] = paths.count
            paths.append(rel)
            metas.append(meta)
        }

        state.withLock { s in
            var record = s.roots[normRoot] ?? RootRecord()
            record.generation &+= 1
            record.snapshot = RootSnapshot(
                root: normRoot,
                paths: paths,
                metas: metas,
                asciiArena: asciiArena,
                utf16Arena: utf16Arena,
                maxPathLength: maxLen,
                indexByPath: map,
                ignoreMatcher: matcher,
                builtAtMs: timestamp,
                isStale: false,
                generation: record.generation
            )
            record.inFlightTask = nil
            s.roots[normRoot] = record
        }
    }

    // MARK: - Incremental Single-Entry Updates (No Full Rescan)

    /// Applies a single-entry add, modify, remove, or rename change directly to the cached index
    /// without triggering a full repository rescan.
    public func applyChange(path: String, kind: ChangeKind, root: String? = nil) {
        let explicitRoot = root.map(Self.normalizeRootPath)
        state.withLock { s in
            let targetRoots: [String]
            if let explicitRoot {
                targetRoots = s.roots[explicitRoot]?.snapshot != nil ? [explicitRoot] : []
            } else {
                targetRoots = Array(s.roots.keys)
            }

            for cachedRoot in targetRoots {
                guard var snapshot = s.roots[cachedRoot]?.snapshot else { continue }
                guard let rel = Self.resolveRelativeToRoot(path: path, root: cachedRoot) else { continue }
                guard !rel.isEmpty else { continue }

                let basename = Self.basename(rel)
                let affectsIgnoreRules = basename == ".gitignore" || basename == ".ignore"

                switch kind {
                case .add(let entryKind):
                    if affectsIgnoreRules {
                        snapshot.isStale = true
                    }
                    if !snapshot.ignoreMatcher.isIgnored(rel, isDirectory: entryKind == .directory) {
                        if configuration.includeHidden || !Self.hasHiddenSegment(rel) {
                            snapshot.ensureParentDirectories(for: rel)
                            snapshot.upsert(relativePath: rel, kind: entryKind)
                        }
                    }

                case .modify:
                    if affectsIgnoreRules {
                        snapshot.isStale = true
                    } else if snapshot.indexByPath[rel] == nil {
                        if !snapshot.ignoreMatcher.isIgnored(rel, isDirectory: false) {
                            if configuration.includeHidden || !Self.hasHiddenSegment(rel) {
                                snapshot.ensureParentDirectories(for: rel)
                                snapshot.upsert(relativePath: rel, kind: .file)
                            }
                        }
                    }

                case .remove:
                    if affectsIgnoreRules {
                        snapshot.isStale = true
                    }
                    snapshot.removeSubtree(rel)

                case .rename(let destination, let explicitKind):
                    if affectsIgnoreRules {
                        snapshot.isStale = true
                    }
                    let destRel = Self.resolveRelativeToRoot(path: destination, root: cachedRoot)
                    let existingIdx = snapshot.indexByPath[rel]
                    let oldKind: EntryKind = explicitKind
                        ?? existingIdx.map { snapshot.metas[$0].kind }
                        ?? .file

                    let destBasename = destRel.map(Self.basename) ?? ""
                    if destBasename == ".gitignore" || destBasename == ".ignore" {
                        snapshot.isStale = true
                    }

                    if oldKind == .directory {
                        let oldPrefix = rel + "/"
                        var movedDescendants: [(String, EntryKind)] = []
                        for i in 0..<snapshot.paths.count where snapshot.paths[i].hasPrefix(oldPrefix) {
                            let suffix = String(snapshot.paths[i].dropFirst(oldPrefix.count))
                            movedDescendants.append((suffix, snapshot.metas[i].kind))
                        }
                        snapshot.removeSubtree(rel)

                        if let destRel, !destRel.isEmpty {
                            if !snapshot.ignoreMatcher.isIgnored(destRel, isDirectory: true) {
                                if configuration.includeHidden || !Self.hasHiddenSegment(destRel) {
                                    snapshot.ensureParentDirectories(for: destRel)
                                    snapshot.upsert(relativePath: destRel, kind: .directory)
                                    for (suffix, descKind) in movedDescendants {
                                        let newDesc = "\(destRel)/\(suffix)"
                                        if !snapshot.ignoreMatcher.isIgnored(newDesc, isDirectory: descKind == .directory) {
                                            if configuration.includeHidden || !Self.hasHiddenSegment(newDesc) {
                                                snapshot.upsert(relativePath: newDesc, kind: descKind)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        snapshot.removeExact(rel)
                        if let destRel, !destRel.isEmpty {
                            if !snapshot.ignoreMatcher.isIgnored(destRel, isDirectory: false) {
                                if configuration.includeHidden || !Self.hasHiddenSegment(destRel) {
                                    snapshot.ensureParentDirectories(for: destRel)
                                    snapshot.upsert(relativePath: destRel, kind: .file)
                                }
                            }
                        }
                    }
                }

                s.roots[cachedRoot]?.snapshot = snapshot
            }
        }
    }

    // MARK: - Search (Async Stale-While-Revalidate + Synchronous Cached Search)

    /// Searches indexed paths under `root` for `query`.
    /// - On cold cache: scans `root` first.
    /// - On fresh cache: scores immediately with zero filesystem I/O.
    /// - On stale cache: when `options.staleWhileRevalidate == true`, immediately returns results from the
    ///   cached snapshot while triggering a coalesced background refresh task.
    public func search(
        root: String,
        query: String,
        options: SearchOptions = SearchOptions()
    ) async -> [MatchResult] {
        guard options.limit > 0 else { return [] }
        let normRoot = Self.normalizeRootPath(root)
        let now = options.nowMs ?? nowMs()

        let existingSnapshot: RootSnapshot? = state.withLock { s in
            s.roots[normRoot]?.snapshot
        }

        let snapshot: RootSnapshot
        if let existing = existingSnapshot {
            let ageMs = now - existing.builtAtMs
            let isExpired = existing.isStale || (configuration.staleAfterMs > 0 && ageMs >= configuration.staleAfterMs)
            if isExpired {
                let refreshTask = acquireOrStartScanTask(normRoot: normRoot, forceNew: false)
                if options.staleWhileRevalidate {
                    snapshot = existing
                } else if let fresh = try? await refreshTask.value {
                    snapshot = fresh
                } else {
                    snapshot = existing
                }
            } else {
                snapshot = existing
            }
        } else {
            let scanTask = acquireOrStartScanTask(normRoot: normRoot, forceNew: false)
            guard let built = try? await scanTask.value else {
                return []
            }
            snapshot = built
        }

        return scoreSnapshot(snapshot, query: query, options: options, now: now)
    }

    /// Synchronous search against the currently cached snapshot for `root`.
    /// Triggers background revalidation if the cached snapshot is stale.
    public func searchCached(
        root: String,
        query: String,
        options: SearchOptions = SearchOptions()
    ) -> [MatchResult] {
        guard options.limit > 0 else { return [] }
        let normRoot = Self.normalizeRootPath(root)
        let now = options.nowMs ?? nowMs()

        guard let snapshot = state.withLock({ $0.roots[normRoot]?.snapshot }) else {
            return []
        }

        let ageMs = now - snapshot.builtAtMs
        if snapshot.isStale || (configuration.staleAfterMs > 0 && ageMs >= configuration.staleAfterMs) {
            _ = acquireOrStartScanTask(normRoot: normRoot, forceNew: false)
        }

        return scoreSnapshot(snapshot, query: query, options: options, now: now)
    }

    // MARK: - Frecency Tracking & JSONL Persistence

    /// Records a file/directory access at `epochMs` (defaults to current clock), incrementing frequency
    /// and updating `lastOpen` with exponential time-decay scoring.
    public func recordAccess(path: String, at epochMs: Int64? = nil, root: String? = nil) {
        let timestamp = epochMs ?? nowMs()
        let key = Self.normalizeFrecencyKey(path: path, root: root)
        guard !key.isEmpty else { return }

        state.withLock { s in
            let prevFreq = s.frecency[key]?.frequency ?? 0
            s.frecency[key] = FrecencyEntry(path: key, frequency: prevFreq + 1, lastOpen: timestamp)
            if s.frecency.count > configuration.maxFrecencyEntries {
                let top = s.frecency.values
                    .sorted { $0.lastOpen > $1.lastOpen }
                    .prefix(configuration.maxFrecencyEntries)
                s.frecency = Dictionary(uniqueKeysWithValues: top.map { ($0.path, $0) })
            }
        }
    }

    /// Computes the exponential time-decay frecency score for `path` at `epochMs`.
    /// Formula: `frequency * exp(-ln(2) * ageDays / frecencyHalfLifeDays)`.
    public func frecencyScore(for path: String, at epochMs: Int64? = nil, root: String? = nil) -> Double {
        let now = epochMs ?? nowMs()
        let frecencyMap = state.withLock { $0.frecency }
        let normalizedKey = Self.normalizeFrecencyKey(path: path, root: root)
        let rawNormalized = Self.normalizeFrecencyKey(path: path, root: nil)

        var best = 0.0
        if let entry = frecencyMap[normalizedKey] {
            best = max(best, computeDecayedFrecency(entry, nowMs: now))
        }
        if rawNormalized != normalizedKey, let entry = frecencyMap[rawNormalized] {
            best = max(best, computeDecayedFrecency(entry, nowMs: now))
        }
        return best
    }

    /// Returns all currently stored frecency entries sorted by `lastOpen` descending.
    public func frecencyEntries() -> [FrecencyEntry] {
        state.withLock { s in
            s.frecency.values.sorted { lhs, rhs in
                if lhs.lastOpen != rhs.lastOpen { return lhs.lastOpen > rhs.lastOpen }
                return lhs.path < rhs.path
            }
        }
    }

    /// Parses TUI-compatible JSONL (`{"path":...,"frequency":...,"lastOpen":...}` per line).
    public static func parseFrecencyJSONL(_ text: String, maxEntries: Int = 1_000) -> [FrecencyEntry] {
        var latest: [String: FrecencyEntry] = [:]
        let decoder = JSONDecoder()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = Matcher.trimASCIIAndUnicodeWhitespace(String(rawLine))
            guard !trimmed.isEmpty else { continue }
            if let entry = try? decoder.decode(FrecencyEntry.self, from: Data(trimmed.utf8)) {
                latest[entry.path] = entry
            }
        }
        return Array(
            latest.values
                .sorted { lhs, rhs in
                    if lhs.lastOpen != rhs.lastOpen { return lhs.lastOpen > rhs.lastOpen }
                    return lhs.path < rhs.path
                }
                .prefix(max(0, maxEntries))
        )
    }

    /// Encodes frecency entries as compact JSONL compatible with `TUIPrompt.parseFrecency`.
    public static func encodeFrecencyJSONL(_ entries: [FrecencyEntry]) -> String {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.lastOpen != rhs.lastOpen { return lhs.lastOpen > rhs.lastOpen }
            return lhs.path < rhs.path
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(sorted.count)
        for entry in sorted {
            if let data = try? encoder.encode(entry) {
                lines.append(String(decoding: data, as: UTF8.self))
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Replaces in-memory frecency state with entries parsed from `text`.
    public func loadFrecencyJSONL(_ text: String) {
        let parsed = Self.parseFrecencyJSONL(text, maxEntries: configuration.maxFrecencyEntries)
        state.withLock { s in
            var map: [String: FrecencyEntry] = [:]
            map.reserveCapacity(parsed.count)
            for entry in parsed {
                let norm = Self.normalizeFrecencyKey(path: entry.path, root: nil)
                map[norm] = FrecencyEntry(path: norm, frequency: entry.frequency, lastOpen: entry.lastOpen)
            }
            s.frecency = map
        }
    }

    /// Exports current frecency entries as TUI-compatible JSONL text.
    public func exportFrecencyJSONL() -> String {
        Self.encodeFrecencyJSONL(frecencyEntries())
    }

    /// Loads frecency JSONL from `path` via the injected `OpenCodeFileSystem`.
    /// Returns `0` when the file does not exist yet.
    @discardableResult
    public func loadFrecency(from path: String) async throws -> Int {
        do {
            let bytes = try await fileSystem.readFile(at: path)
            let text = String(decoding: bytes, as: UTF8.self)
            loadFrecencyJSONL(text)
            return state.withLock { $0.frecency.count }
        } catch let err as PlatformError {
            if case .notFound = err { return 0 }
            throw err
        }
    }

    /// Persists current frecency entries as JSONL to `path` via the injected `OpenCodeFileSystem`.
    public func saveFrecency(to path: String) async throws {
        let content = exportFrecencyJSONL()
        try await fileSystem.writeFile(Array(content.utf8), to: path, createDirectories: true)
    }

    // MARK: - Bounded Top-K Scoring Engine

    private struct ScoredCandidate {
        let entryIndex: Int
        let totalScore: Double
        let fuzzyScore: Double
        let frecencyBoost: Double
        let pathLength: Int
    }

    /// Returns `true` if `lhs` ranks strictly better than `rhs`.
    @inline(__always)
    private static func ranksBetter(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate, paths: [String]) -> Bool {
        if lhs.totalScore != rhs.totalScore { return lhs.totalScore > rhs.totalScore }
        if lhs.fuzzyScore != rhs.fuzzyScore { return lhs.fuzzyScore > rhs.fuzzyScore }
        if lhs.pathLength != rhs.pathLength { return lhs.pathLength < rhs.pathLength }
        return paths[lhs.entryIndex] < paths[rhs.entryIndex]
    }

    /// Maintains a min-heap of size `<= limit` where `heap[0]` is the worst of the top-K candidates.
    @inline(__always)
    private static func pushTopK(
        _ candidate: ScoredCandidate,
        into heap: inout [ScoredCandidate],
        limit: Int,
        paths: [String]
    ) {
        if heap.count < limit {
            heap.append(candidate)
            var idx = heap.count - 1
            while idx > 0 {
                let parent = (idx - 1) >> 1
                // Min-heap: worse item sits closer to root (index 0).
                if ranksBetter(heap[parent], heap[idx], paths: paths) {
                    heap.swapAt(idx, parent)
                    idx = parent
                } else {
                    break
                }
            }
        } else if limit > 0 && ranksBetter(candidate, heap[0], paths: paths) {
            heap[0] = candidate
            var idx = 0
            let count = heap.count
            while true {
                let left = (idx << 1) &+ 1
                if left >= count { break }
                var worst = left
                let right = left &+ 1
                if right < count && ranksBetter(heap[worst], heap[right], paths: paths) {
                    worst = right
                }
                if ranksBetter(heap[idx], heap[worst], paths: paths) {
                    heap.swapAt(idx, worst)
                    idx = worst
                } else {
                    break
                }
            }
        }
    }

    private func scoreSnapshot(
        _ snapshot: RootSnapshot,
        query: String,
        options: SearchOptions,
        now: Int64
    ) -> [MatchResult] {
        let trimmed = Matcher.trimASCIIAndUnicodeWhitespace(query)
        let frecencyMap = state.withLock { $0.frecency }
        let paths = snapshot.paths
        let metas = snapshot.metas
        let entryCount = paths.count
        let rootPrefix = snapshot.root == "/" ? "/" : snapshot.root + "/"
        let filterKind = options.kind
        let limit = options.limit

        guard entryCount > 0 else { return [] }

        // Empty query: rank purely by decayed frecency descending, then shorter path, then lexicographical.
        if trimmed.isEmpty {
            var topHeap: [ScoredCandidate] = []
            topHeap.reserveCapacity(min(limit, entryCount))
            let hasFrecency = !frecencyMap.isEmpty

            for idx in 0..<entryCount {
                let meta = metas[idx]
                if let filterKind, meta.kind != filterKind { continue }
                let frec = hasFrecency
                    ? lookupFrecency(relativePath: paths[idx], rootPrefix: rootPrefix, frecencyMap: frecencyMap, nowMs: now)
                    : 0.0
                Self.pushTopK(
                    ScoredCandidate(
                        entryIndex: idx,
                        totalScore: frec,
                        fuzzyScore: 0.0,
                        frecencyBoost: frec,
                        pathLength: meta.pathLength
                    ),
                    into: &topHeap,
                    limit: limit,
                    paths: paths
                )
            }

            topHeap.sort { Self.ranksBetter($0, $1, paths: paths) }
            return topHeap.map { item in
                MatchResult(
                    relativePath: paths[item.entryIndex],
                    kind: metas[item.entryIndex].kind,
                    totalScore: item.totalScore,
                    fuzzyScore: 0.0,
                    frecencyBoost: item.frecencyBoost,
                    matchedIndices: []
                )
            }
        }

        let prepared = Matcher.PreparedQuery(raw: trimmed)
        var scratch = Matcher.ScoringScratch(minWidth: max(256, snapshot.maxPathLength))
        let hasFrecency = !frecencyMap.isEmpty
        var topHeap: [ScoredCandidate] = []
        topHeap.reserveCapacity(min(limit, entryCount))

        // Phase 1: Hoisted-pointer fast path for single-token ASCII queries (zero ARC, zero closures per entry!).
        if !prepared.isMultiToken && prepared.fullToken.isASCII && !snapshot.asciiArena.lower.isEmpty {
            let token = prepared.fullToken
            let m = token.length
            let qMask = token.asciiMask
            var nonASCIIIndices: [Int] = []

            snapshot.metas.withUnsafeBufferPointer { metaBuf in
                snapshot.asciiArena.lower.withUnsafeBufferPointer { aLowBuf in
                    snapshot.asciiArena.raw.withUnsafeBufferPointer { aRawBuf in
                        snapshot.asciiArena.bonus.withUnsafeBufferPointer { aBonusBuf in
                            token.asciiLower.withUnsafeBufferPointer { qLowBuf in
                                token.asciiRaw.withUnsafeBufferPointer { qRawBuf in
                                    scratch.prevM.withUnsafeMutableBufferPointer { prevMBuf in
                                        scratch.currM.withUnsafeMutableBufferPointer { currMBuf in
                                            scratch.prevB.withUnsafeMutableBufferPointer { prevBBuf in
                                                scratch.currB.withUnsafeMutableBufferPointer { currBBuf in
                                                    scratch.prevFirst.withUnsafeMutableBufferPointer { prevFBuf in
                                                        scratch.currFirst.withUnsafeMutableBufferPointer { currFBuf in
                                                            let metaPtr = metaBuf.baseAddress!
                                                            let aLowBase = aLowBuf.baseAddress!
                                                            let aRawBase = aRawBuf.baseAddress!
                                                            let aBonusBase = aBonusBuf.baseAddress!
                                                            let qLowPtr = qLowBuf.baseAddress!
                                                            let qRawPtr = qRawBuf.baseAddress!
                                                            let pMPtr = prevMBuf.baseAddress!
                                                            let cMPtr = currMBuf.baseAddress!
                                                            let pBPtr = prevBBuf.baseAddress!
                                                            let cBPtr = currBBuf.baseAddress!
                                                            let pFPtr = prevFBuf.baseAddress!
                                                            let cFPtr = currFBuf.baseAddress!

                                                            var idx = 0
                                                            while idx < entryCount {
                                                                let meta = metaPtr[idx]
                                                                if let filterKind, meta.kind != filterKind {
                                                                    idx &+= 1
                                                                    continue
                                                                }
                                                                if !meta.isASCII {
                                                                    nonASCIIIndices.append(idx)
                                                                    idx &+= 1
                                                                    continue
                                                                }
                                                                let n = meta.pathLength
                                                                if m > n || (meta.asciiBitmask & qMask) != qMask {
                                                                    idx &+= 1
                                                                    continue
                                                                }
                                                                let off = meta.arenaOffset
                                                                if let fuzzy = Matcher.scoreASCIIPointers(
                                                                    m: m,
                                                                    qLow: qLowPtr,
                                                                    qRaw: qRawPtr,
                                                                    cLow: aLowBase.advanced(by: off),
                                                                    cRaw: aRawBase.advanced(by: off),
                                                                    cBonus: aBonusBase.advanced(by: off),
                                                                    n: n,
                                                                    baseStart: meta.basenameStart,
                                                                    stemLen: meta.basenameStemLength,
                                                                    pMInit: pMPtr,
                                                                    cMInit: cMPtr,
                                                                    pBInit: pBPtr,
                                                                    cBInit: cBPtr,
                                                                    pFInit: pFPtr,
                                                                    cFInit: cFPtr
                                                                ) {
                                                                    let boost: Double
                                                                    if hasFrecency {
                                                                        let rawFrec = lookupFrecency(
                                                                            relativePath: paths[idx],
                                                                            rootPrefix: rootPrefix,
                                                                            frecencyMap: frecencyMap,
                                                                            nowMs: now
                                                                        )
                                                                        boost = rawFrec > 0 ? log1p(rawFrec) * configuration.frecencyBoostScale : 0.0
                                                                    } else {
                                                                        boost = 0.0
                                                                    }
                                                                    Self.pushTopK(
                                                                        ScoredCandidate(
                                                                            entryIndex: idx,
                                                                            totalScore: fuzzy + boost,
                                                                            fuzzyScore: fuzzy,
                                                                            frecencyBoost: boost,
                                                                            pathLength: n
                                                                        ),
                                                                        into: &topHeap,
                                                                        limit: limit,
                                                                        paths: paths
                                                                    )
                                                                }
                                                                idx &+= 1
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Score any non-ASCII paths in the same snapshot.
            for idx in nonASCIIIndices {
                let meta = metas[idx]
                guard let (fuzzy, _) = Matcher.scoreEntry(
                    query: prepared,
                    meta: meta,
                    asciiArena: snapshot.asciiArena,
                    utf16Arena: snapshot.utf16Arena,
                    computeIndices: false,
                    scratch: &scratch
                ) else {
                    continue
                }
                let boost: Double
                if hasFrecency {
                    let rawFrec = lookupFrecency(
                        relativePath: paths[idx],
                        rootPrefix: rootPrefix,
                        frecencyMap: frecencyMap,
                        nowMs: now
                    )
                    boost = rawFrec > 0 ? log1p(rawFrec) * configuration.frecencyBoostScale : 0.0
                } else {
                    boost = 0.0
                }
                Self.pushTopK(
                    ScoredCandidate(
                        entryIndex: idx,
                        totalScore: fuzzy + boost,
                        fuzzyScore: fuzzy,
                        frecencyBoost: boost,
                        pathLength: meta.pathLength
                    ),
                    into: &topHeap,
                    limit: limit,
                    paths: paths
                )
            }
        } else {
            // General path (multi-token queries, Unicode queries, or all-Unicode snapshots).
            for idx in 0..<entryCount {
                let meta = metas[idx]
                if let filterKind, meta.kind != filterKind { continue }
                guard let (fuzzy, _) = Matcher.scoreEntry(
                    query: prepared,
                    meta: meta,
                    asciiArena: snapshot.asciiArena,
                    utf16Arena: snapshot.utf16Arena,
                    computeIndices: false,
                    scratch: &scratch
                ) else {
                    continue
                }
                let boost: Double
                if hasFrecency {
                    let rawFrec = lookupFrecency(
                        relativePath: paths[idx],
                        rootPrefix: rootPrefix,
                        frecencyMap: frecencyMap,
                        nowMs: now
                    )
                    boost = rawFrec > 0 ? log1p(rawFrec) * configuration.frecencyBoostScale : 0.0
                } else {
                    boost = 0.0
                }
                Self.pushTopK(
                    ScoredCandidate(
                        entryIndex: idx,
                        totalScore: fuzzy + boost,
                        fuzzyScore: fuzzy,
                        frecencyBoost: boost,
                        pathLength: meta.pathLength
                    ),
                    into: &topHeap,
                    limit: limit,
                    paths: paths
                )
            }
        }

        guard !topHeap.isEmpty else { return [] }

        topHeap.sort { Self.ranksBetter($0, $1, paths: paths) }

        // Phase 2: Compute exact UTF-16 matched highlight indices ONLY for the final top-K winners.
        var results: [MatchResult] = []
        results.reserveCapacity(topHeap.count)
        for candidate in topHeap {
            let meta = metas[candidate.entryIndex]
            let indices = Matcher.scoreEntry(
                query: prepared,
                meta: meta,
                asciiArena: snapshot.asciiArena,
                utf16Arena: snapshot.utf16Arena,
                computeIndices: true,
                scratch: &scratch
            )?.indices ?? []

            results.append(MatchResult(
                relativePath: paths[candidate.entryIndex],
                kind: meta.kind,
                totalScore: candidate.totalScore,
                fuzzyScore: candidate.fuzzyScore,
                frecencyBoost: candidate.frecencyBoost,
                matchedIndices: indices
            ))
        }

        return results
    }

    private func lookupFrecency(
        relativePath: String,
        rootPrefix: String,
        frecencyMap: [String: FrecencyEntry],
        nowMs: Int64
    ) -> Double {
        var best = 0.0
        if let relEntry = frecencyMap[relativePath] {
            best = max(best, computeDecayedFrecency(relEntry, nowMs: nowMs))
        }
        let absPath = rootPrefix + relativePath
        if let absEntry = frecencyMap[absPath] {
            best = max(best, computeDecayedFrecency(absEntry, nowMs: nowMs))
        }
        return best
    }

    private func computeDecayedFrecency(_ entry: FrecencyEntry, nowMs: Int64) -> Double {
        guard entry.frequency > 0 else { return 0.0 }
        let ageMs = max(0, nowMs - entry.lastOpen)
        let ageDays = Double(ageMs) / 86_400_000.0
        let ln2 = 0.6931471805599453
        let decay = exp(-ln2 * ageDays / configuration.frecencyHalfLifeDays)
        return Double(entry.frequency) * decay
    }

    // MARK: - Concurrent `.gitignore`-Aware Directory Walker

    private func acquireOrStartScanTask(normRoot: String, forceNew: Bool) -> Task<RootSnapshot, any Error> {
        state.withLock { s in
            var record = s.roots[normRoot] ?? RootRecord()
            if !forceNew, let existing = record.inFlightTask {
                return existing
            }
            record.generation &+= 1
            let scanGeneration = record.generation

            let fs = self.fileSystem
            let config = self.configuration
            let clock = self.nowMs

            let task = Task<RootSnapshot, any Error> { [weak self] in
                let built = try await Self.scanDirectoryTree(
                    root: normRoot,
                    fileSystem: fs,
                    configuration: config,
                    generation: scanGeneration,
                    builtAtMs: clock()
                )
                self?.publishScanResult(normRoot: normRoot, snapshot: built, generation: scanGeneration)
                return built
            }

            record.inFlightTask = task
            s.roots[normRoot] = record
            return task
        }
    }

    private func publishScanResult(normRoot: String, snapshot: RootSnapshot, generation: UInt64) {
        state.withLock { s in
            guard var record = s.roots[normRoot] else { return }
            guard record.generation == generation else { return }
            record.snapshot = snapshot
            record.inFlightTask = nil
            s.roots[normRoot] = record
        }
    }

    private struct WalkDirectoryResult: Sendable {
        var entries: [(relativePath: String, kind: EntryKind)]
        var discoveredRules: [IgnoreRule]
        var childDirectories: [(relativePath: String, inheritedRules: [IgnoreRule])]
    }

    private static func scanDirectoryTree(
        root: String,
        fileSystem: any OpenCodeFileSystem,
        configuration: Configuration,
        generation: UInt64,
        builtAtMs: Int64
    ) async throws -> RootSnapshot {
        var paths: [String] = []
        var metas: [EntryMeta] = []
        var asciiArena = ASCIIArena()
        var utf16Arena = UTF16Arena()
        var indexByPath: [String: Int] = [:]
        var maxLen = 0
        var allRules: [IgnoreRule] = []
        var pending: [(relativePath: String, inheritedRules: [IgnoreRule])] = [("", [])]
        let maxEntries = configuration.maxEntries
        let maxConcurrency = configuration.walkConcurrency

        while !pending.isEmpty && paths.count < maxEntries {
            try Task.checkCancellation()
            let batchCount = min(pending.count, maxConcurrency)
            let batch = Array(pending[0..<batchCount])
            pending.removeFirst(batchCount)

            let results: [WalkDirectoryResult]
            if batch.count == 1 {
                let single = await scanSingleDirectory(
                    root: root,
                    relativeDir: batch[0].relativePath,
                    inheritedRules: batch[0].inheritedRules,
                    fileSystem: fileSystem,
                    configuration: configuration
                )
                results = [single]
            } else {
                results = try await withThrowingTaskGroup(of: (Int, WalkDirectoryResult).self) { group in
                    for (idx, work) in batch.enumerated() {
                        group.addTask {
                            try Task.checkCancellation()
                            let res = await scanSingleDirectory(
                                root: root,
                                relativeDir: work.relativePath,
                                inheritedRules: work.inheritedRules,
                                fileSystem: fileSystem,
                                configuration: configuration
                            )
                            return (idx, res)
                        }
                    }
                    var ordered = [(Int, WalkDirectoryResult)]()
                    ordered.reserveCapacity(batch.count)
                    for try await item in group {
                        ordered.append(item)
                    }
                    ordered.sort { $0.0 < $1.0 }
                    return ordered.map(\.1)
                }
            }

            for res in results {
                allRules.append(contentsOf: res.discoveredRules)
                for (rel, kind) in res.entries {
                    if paths.count >= maxEntries { break }
                    if indexByPath[rel] != nil { continue }
                    let meta: EntryMeta
                    if rel.utf8.allSatisfy({ $0 < 128 }) {
                        meta = asciiArena.append(path: rel, kind: kind)
                    } else {
                        meta = utf16Arena.append(path: rel, kind: kind)
                    }
                    if meta.pathLength > maxLen { maxLen = meta.pathLength }
                    indexByPath[rel] = paths.count
                    paths.append(rel)
                    metas.append(meta)
                }
                if paths.count < maxEntries {
                    pending.append(contentsOf: res.childDirectories)
                }
            }
        }

        let combinedMatcher = IgnoreMatcher(
            rules: allRules,
            defaultIgnoredDirectories: configuration.defaultIgnoredDirectories
        )

        return RootSnapshot(
            root: root,
            paths: paths,
            metas: metas,
            asciiArena: asciiArena,
            utf16Arena: utf16Arena,
            maxPathLength: maxLen,
            indexByPath: indexByPath,
            ignoreMatcher: combinedMatcher,
            builtAtMs: builtAtMs,
            isStale: false,
            generation: generation
        )
    }

    private static func scanSingleDirectory(
        root: String,
        relativeDir: String,
        inheritedRules: [IgnoreRule],
        fileSystem: any OpenCodeFileSystem,
        configuration: Configuration
    ) async -> WalkDirectoryResult {
        let absDir = relativeDir.isEmpty ? root : joinPath(root, relativeDir)
        guard let names = try? await fileSystem.readDirectory(at: absDir) else {
            return WalkDirectoryResult(entries: [], discoveredRules: [], childDirectories: [])
        }

        let sortedNames = names.sorted()
        var discoveredRules: [IgnoreRule] = []
        var activeRules = inheritedRules

        for ignoreFile in [".gitignore", ".ignore"] {
            if sortedNames.contains(ignoreFile) {
                let ignoreAbs = joinPath(absDir, ignoreFile)
                if let bytes = try? await fileSystem.readFile(at: ignoreAbs) {
                    let content = String(decoding: bytes, as: UTF8.self)
                    let rules = IgnoreMatcher.parse(content, baseDir: relativeDir)
                    if !rules.isEmpty {
                        discoveredRules.append(contentsOf: rules)
                        activeRules.append(contentsOf: rules)
                    }
                }
            }
        }

        let matcher = IgnoreMatcher(
            rules: activeRules,
            defaultIgnoredDirectories: configuration.defaultIgnoredDirectories
        )

        var entries: [(relativePath: String, kind: EntryKind)] = []
        var children: [(relativePath: String, inheritedRules: [IgnoreRule])] = []
        entries.reserveCapacity(sortedNames.count)

        for name in sortedNames {
            if name == "." || name == ".." { continue }
            if !configuration.includeHidden && name.hasPrefix(".") { continue }

            let rel = relativeDir.isEmpty ? name : "\(relativeDir)/\(name)"
            let abs = joinPath(absDir, name)

            guard let st = try? await fileSystem.stat(at: abs) else { continue }

            switch st.type {
            case .directory:
                if configuration.defaultIgnoredDirectories.contains(name) { continue }
                if matcher.evaluateDirect(rel, isDirectory: true) { continue }
                entries.append((rel, .directory))
                children.append((rel, activeRules))

            case .file:
                if matcher.evaluateDirect(rel, isDirectory: false) { continue }
                entries.append((rel, .file))

            case .symlink, .other:
                continue
            }
        }

        return WalkDirectoryResult(
            entries: entries,
            discoveredRules: discoveredRules,
            childDirectories: children
        )
    }

    // MARK: - Path Normalization Helpers

    internal static func normalizeRootPath(_ raw: String) -> String {
        let slashed = raw.replacing("\\", with: "/")
        var parts: [String] = []
        let isAbsolute = slashed.hasPrefix("/")
        for seg in slashed.split(separator: "/") {
            if seg == "." || seg.isEmpty { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(seg))
            }
        }
        if isAbsolute {
            return "/" + parts.joined(separator: "/")
        }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    internal static func normalizeRelativePath(_ raw: String) -> String {
        let slashed = raw.replacing("\\", with: "/")
        var parts: [String] = []
        for seg in slashed.split(separator: "/") {
            if seg == "." || seg.isEmpty { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(seg))
            }
        }
        return parts.joined(separator: "/")
    }

    internal static func resolveRelativeToRoot(path: String, root: String) -> String? {
        let clean = path.replacing("\\", with: "/")
        if clean.hasPrefix("/") {
            let normAbs = normalizeRootPath(clean)
            if normAbs == root { return "" }
            let prefix = root == "/" ? "/" : root + "/"
            guard normAbs.hasPrefix(prefix) else { return nil }
            return normalizeRelativePath(String(normAbs.dropFirst(prefix.count)))
        }
        return normalizeRelativePath(clean)
    }

    internal static func normalizeFrecencyKey(path: String, root: String?) -> String {
        let clean = path.replacing("\\", with: "/")
        if clean.hasPrefix("/") {
            return normalizeRootPath(clean)
        }
        if let root, !root.isEmpty {
            let normRoot = normalizeRootPath(root)
            let rel = normalizeRelativePath(clean)
            if rel.isEmpty { return normRoot }
            return joinPath(normRoot, rel)
        }
        return normalizeRelativePath(clean)
    }

    internal static func joinPath(_ base: String, _ child: String) -> String {
        if base == "/" { return "/\(child)" }
        if base.hasSuffix("/") { return base + child }
        return "\(base)/\(child)"
    }

    internal static func basename(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[path.index(after: slash)...])
        }
        return path
    }

    private static func hasHiddenSegment(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }
}
