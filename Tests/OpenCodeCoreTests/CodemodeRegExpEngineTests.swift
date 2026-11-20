import Testing
import OpenCodeCore

/// Engine-level test262-style unit tests for the pure-Swift ECMAScript 2025 RegExp engine
/// (`ECMAScriptRegExp` operating directly on UTF-16 `[UInt16]` code units).
@Suite("Code Mode: pure-Swift ECMAScript 2025 RegExp engine")
struct CodemodeRegExpEngineTests {
    private func units(_ s: String) -> [UInt16] { Array(s.utf16) }

    private func testMatch(_ pattern: String, _ flags: String = "", _ input: String) throws -> Bool {
        let re = try ECMAScriptRegExp(pattern: pattern, flags: flags)
        return try re.exec(in: units(input)) != nil
    }

    private func execStrings(_ pattern: String, _ flags: String = "", _ input: String, startIndex: Int = 0) throws -> [String?]? {
        let re = try ECMAScriptRegExp(pattern: pattern, flags: flags)
        let u = units(input)
        guard let m = try re.exec(in: u, startIndex: startIndex) else { return nil }
        return m.captures.map { r in r.map { String(decoding: u[$0], as: UTF16.self) } }
    }

    private func expectSyntaxError(_ pattern: String, _ flags: String = "", kind: ECMAScriptRegExpError.Kind = .invalidPattern) {
        do {
            _ = try ECMAScriptRegExp(pattern: pattern, flags: flags)
            Issue.record("Expected \(kind) error for /\(pattern)/\(flags)")
        } catch let err {
            #expect(err.kind == kind)
        }
    }

    // MARK: - UTF-16 Code Units, Surrogate Pairs, and Lone Surrogates

    @Test("UTF-16 code units vs Unicode code points for astral characters and lone surrogates")
    func utf16AndSurrogates() throws {
        // Non-unicode dot matches a single UTF-16 code unit; unicode dot matches a full code point
        #expect(try testMatch("^.$", "", "😀") == false)
        #expect(try testMatch("^..$", "", "😀") == true)
        #expect(try testMatch("^.$", "u", "😀") == true)
        #expect(try testMatch("^.$", "v", "😀") == true)

        // Quantifier applies to trailing surrogate only in non-u, whole code point in u
        #expect(try testMatch("^😀+$", "", "😀😀") == false)
        #expect(try testMatch("^😀+$", "u", "😀😀") == true)

        // Escaped surrogate pair joins into one code point in u-mode
        #expect(try testMatch(#"^\uD83D\uDE00$"#, "u", "😀") == true)
        #expect(try testMatch(#"^[\uD83D\uDE00]$"#, "u", "😀") == true)
        #expect(try testMatch(#"^[\u{1F600}-\u{1F64F}]$"#, "u", "😀") == true)

        // Direct [UInt16] lone surrogate matching (readiness for UTF-16 string representation)
        let loneLead: [UInt16] = [0xD83D]
        let loneTrail: [UInt16] = [0xDE00]
        let pair: [UInt16] = [0xD83D, 0xDE00]

        let reLoneLeadU = try ECMAScriptRegExp(pattern: #"\uD83D"#, flags: "u")
        // Under u-mode, a lone lead surrogate matches a lone lead surrogate, NOT the lead half of a valid pair
        #expect(try reLoneLeadU.exec(in: loneLead)?.range == 0..<1)
        #expect(try reLoneLeadU.exec(in: pair) == nil)

        let reLoneLeadNonU = try ECMAScriptRegExp(pattern: #"\uD83D"#, flags: "")
        #expect(try reLoneLeadNonU.exec(in: pair)?.range == 0..<1)

        let reLoneTrailU = try ECMAScriptRegExp(pattern: #"\uDE00"#, flags: "u")
        #expect(try reLoneTrailU.exec(in: loneTrail)?.range == 0..<1)
        #expect(try reLoneTrailU.exec(in: pair) == nil)

        // u-mode startIndex in the middle of a surrogate pair backs up to the lead surrogate
        let dotU = try ECMAScriptRegExp(pattern: ".", flags: "gu")
        let midMatch = try dotU.exec(in: pair, startIndex: 1)
        #expect(midMatch?.range == 0..<2)

        // AdvanceStringIndex
        #expect(ECMAScriptRegExp.advanceIndex(in: pair, from: 0, unicode: false) == 1)
        #expect(ECMAScriptRegExp.advanceIndex(in: pair, from: 0, unicode: true) == 2)
        #expect(ECMAScriptRegExp.advanceIndex(in: loneLead, from: 0, unicode: true) == 1)
        #expect(ECMAScriptRegExp.advanceIndex(in: [0xD83D, 0x0041], from: 0, unicode: true) == 1)
    }

    // MARK: - Character Classes, Shorthands & Line Terminators

    @Test("ASCII-only \\d/\\w/\\b, ECMAScript \\s, dotAll s, multiline m, [] and [^]")
    func shorthandsAndAnchors() throws {
        // \d is strictly ASCII 0-9 (not Arabic-Indic or fullwidth)
        #expect(try testMatch(#"^\d+$"#, "", "0123456789") == true)
        #expect(try testMatch(#"^\d$"#, "", "٠") == false) // U+0660
        #expect(try testMatch(#"^\d$"#, "u", "２") == false) // U+FF12

        // \w is strictly ASCII [A-Za-z0-9_], plus U+017F & U+212A under /iu or /iv
        #expect(try testMatch(#"^\w$"#, "", "é") == false)
        #expect(try testMatch(#"^\w$"#, "i", "\u{212A}") == false)
        #expect(try testMatch(#"^\w$"#, "iu", "\u{212A}") == true)
        #expect(try testMatch(#"^\w$"#, "iu", "\u{017F}") == true)
        #expect(try testMatch(#"^\W$"#, "iu", "\u{212A}") == false)
        #expect(try testMatch(#"\b\u{212A}\b"#, "iu", " \u{212A} ") == true)
        #expect(try testMatch(#"\b\u212A\b"#, "i", " \u{212A} ") == false)

        // \s matches ECMAScript WhiteSpace + LineTerminator, not NEL (U+0085)
        #expect(try testMatch(#"^\s+$"#, "", " \t\n\r\u{000B}\u{000C}\u{00A0}\u{1680}\u{2000}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}") == true)
        #expect(try testMatch(#"^\s$"#, "", "\u{0085}") == false)

        // Dot vs dotAll across all 4 ECMAScript LineTerminators
        for lt in ["\n", "\r", "\u{2028}", "\u{2029}"] {
            #expect(try testMatch("^.$", "", lt) == false)
            #expect(try testMatch("^.$", "s", lt) == true)
            #expect(try testMatch("^[^]$", "", lt) == true)
            #expect(try testMatch("^b$", "m", "a\(lt)b\(lt)c") == true)
            #expect(try testMatch("^b$", "", "a\(lt)b\(lt)c") == false)
        }
        #expect(try testMatch("[]", "", "a") == false)
        #expect(try testMatch("[]", "", "") == false)
    }

    // MARK: - Case-Insensitive Canonicalization (non-u vs u/v)

    @Test("Non-u simple uppercase vs u-mode simple case folding")
    func caseFolding() throws {
        // Non-u blocks folding non-ASCII to ASCII
        #expect(try testMatch("k", "i", "\u{212A}") == false)
        #expect(try testMatch("s", "i", "\u{017F}") == false)
        #expect(try testMatch("[a-z]", "i", "\u{212A}") == false)
        #expect(try testMatch("k", "iu", "\u{212A}") == true)
        #expect(try testMatch("s", "iu", "\u{017F}") == true)
        #expect(try testMatch("[a-z]", "iu", "\u{212A}") == true)
        #expect(try testMatch("[^a-z]", "iu", "\u{212A}") == false)

        // Non-u still folds non-ASCII to non-ASCII (e.g. Greek sigma / Latin accented)
        #expect(try testMatch("\u{00E9}", "i", "\u{00C9}") == true)
        #expect(try testMatch("\u{03C3}", "i", "\u{03C2}") == true) // σ and ς both uppercase to Σ
        #expect(try testMatch("\u{00DF}", "i", "SS") == false) // 1-to-2 fold not used
        #expect(try testMatch("\u{0130}", "i", "i") == false)

        // Astral case folding in u-mode (Deseret U+10400 <-> U+10428)
        #expect(try testMatch("\u{10400}", "iu", "\u{10428}") == true)
        #expect(try testMatch(#"(\u{10400})\1"#, "iu", "\u{10400}\u{10428}") == true)

        // /iu vs /iv complement interaction on \P{Lowercase}
        #expect(try testMatch(#"[\P{Lowercase}]"#, "iu", "a") == true)
        #expect(try testMatch(#"[\P{Lowercase}]"#, "iv", "a") == false)
        #expect(try testMatch(#"[^\P{Lowercase}]"#, "iu", "a") == false)
        #expect(try testMatch(#"[^\P{Lowercase}]"#, "iv", "a") == true)
    }

    // MARK: - Quantifiers, Capture Reset & Zero-Width Termination (test262 classics)

    @Test("Quantifier capture reset and zero-width termination match ECMA-262 RepeatMatcher")
    func quantifierSemantics() throws {
        // Test262 classic: (z)((a+)?(b+)?(c))*
        #expect(try execStrings("(z)((a+)?(b+)?(c))*", "", "zaacbbbcac") == ["zaacbbbcac", "z", "ac", "a", nil, "c"])

        // Capture reset on each iteration
        #expect(try execStrings("(?:(a)|(b))+", "", "ab") == ["ab", nil, "b"])
        #expect(try execStrings("(?:(a)|b){2}", "", "ab") == ["ab", nil])

        // Zero-width termination when min == 0 vs min > 0
        #expect(try execStrings("(a*)*", "", "b") == ["", nil])
        #expect(try execStrings("(a*)+", "", "b") == ["", ""])
        #expect(try execStrings("(a*)*", "", "a") == ["a", "a"])
        #expect(try execStrings("(a*)?", "", "") == ["", nil])
        #expect(try execStrings("(a*){0,1}", "", "") == ["", nil])
        #expect(try execStrings("(a*?){2}", "", "aa") == ["", ""])
        #expect(try execStrings("(?:(a?)){2}", "", "a") == ["a", ""])
        #expect(try execStrings("(a){0}", "", "a") == ["", nil])

        // Greedy vs lazy
        #expect(try execStrings("a+?", "", "aaa") == ["a"])
        #expect(try execStrings("a+", "", "aaa") == ["aaa"])
        #expect(try execStrings("a{2,4}?", "", "aaaaa") == ["aa"])
        #expect(try execStrings("a{2,4}", "", "aaaaa") == ["aaaa"])
    }

    // MARK: - Backreferences, Named Groups, Duplicate Names & Lookbehind

    @Test("Forward/empty/named/duplicate backreferences and right-to-left lookbehind")
    func backrefsAndLookbehind() throws {
        // Forward backreference (unmatched capture -> matches empty string)
        #expect(try execStrings(#"(?:\1a|(b))"#, "", "a") == ["a", nil])
        #expect(try execStrings(#"(?:\1a|(b))+"#, "", "ba") == ["ba", nil])
        // Forward reference in non-u where number exceeds capture count becomes legacy octal
        #expect(try execStrings(#"(?:\2a|(b))"#, "", "\u{0002}a") == ["\u{0002}a", nil])
        // Self-reference (unmatched -> matches empty string)
        #expect(try execStrings(#"(a\1)"#, "", "a") == ["a", "a"])
        // Unmatched optional group backreference matches empty
        #expect(try execStrings(#"(a)?\1"#, "", "") == ["", nil])

        // ES2025 duplicate named groups in different alternatives
        let dup = try ECMAScriptRegExp(pattern: #"(?:(?<a>x)|(?<a>y))\k<a>"#, flags: "d")
        let m1 = try #require(try dup.exec(in: units("xx")))
        #expect(m1.range == 0..<2)
        #expect(m1.namedCaptures["a"] == 0..<1)
        let m2 = try #require(try dup.exec(in: units("yy")))
        #expect(m2.range == 0..<2)
        #expect(m2.namedCaptures["a"] == 0..<1)
        #expect(try dup.exec(in: units("xy")) == nil)

        // Duplicate group name in same alternative or nested is SyntaxError
        expectSyntaxError("(?<a>x)(?<a>y)")
        expectSyntaxError("(?<a>(?<a>x))")

        // Right-to-left lookbehind capture order and backreferences
        #expect(try execStrings(#"(?<=(\w+)(\w+))!"#, "", "abcd!") == ["!", "a", "bcd"])
        #expect(try execStrings(#"(?<=\1(a))b"#, "", "aab") == ["b", "a"])
        #expect(try execStrings(#"(?<=(a)\1)b"#, "", "aab") == ["b", "a"])
        #expect(try execStrings(#"(?<!foo)bar"#, "", "bazbar") == ["bar"])
        #expect(try execStrings(#"(?<!foo)bar"#, "", "foobar") == nil)

        // Lookahead backtracking resets captures from lookahead
        #expect(try execStrings("(?=(a))b|c", "", "ac") == ["c", nil])
        // Negative lookahead discards captures
        #expect(try execStrings("(?!(a)b)ac", "", "ac") == ["ac", nil])
    }

    // MARK: - ES2025 Modifiers & v-mode Unicode Sets

    @Test("ES2025 inline modifiers and v-mode unicodeSets")
    func modifiersAndVSets() throws {
        #expect(try testMatch("(?i:a)b", "", "Ab") == true)
        #expect(try testMatch("(?i:a)b", "", "AB") == false)
        #expect(try testMatch("(?-i:a)", "i", "A") == false)
        #expect(try testMatch("(?-i:a)", "i", "a") == true)
        #expect(try testMatch("(?m:^a)", "", "\na") == true)
        #expect(try testMatch("(?s:.)", "", "\n") == true)
        #expect(try testMatch("(?-s:.)", "s", "\n") == false)
        // Modifiers apply to backreferences inside modifier group
        #expect(try testMatch(#"(a)(?i:\1)"#, "", "aA") == true)
        #expect(try testMatch(#"(a)(?-i:\1)"#, "i", "aA") == false)

        // v-mode set subtraction, intersection, nested classes, \q{} string disjunction
        #expect(try testMatch(#"[\w--\d]"#, "v", "a") == true)
        #expect(try testMatch(#"[\w--\d]"#, "v", "5") == false)
        #expect(try testMatch(#"[\p{ASCII}&&\p{Decimal_Number}]"#, "v", "7") == true)
        #expect(try testMatch(#"[\p{ASCII}&&\p{Decimal_Number}]"#, "v", "a") == false)
        #expect(try testMatch(#"[[a-z]--[aeiou]]"#, "v", "b") == true)
        #expect(try testMatch(#"[[a-z]--[aeiou]]"#, "v", "e") == false)
        // Longest-first with backtracking on \q{}
        #expect(try execStrings(#"[\q{ab|a}]"#, "v", "ab") == ["ab"])
        #expect(try execStrings(#"[\q{ab|a}]b"#, "v", "ab") == ["ab"])
        // Properties of strings
        #expect(try testMatch(#"^\p{Basic_Emoji}$"#, "v", "😀") == true)
        #expect(try testMatch(#"^\p{Emoji_Keycap_Sequence}$"#, "v", "1\u{FE0F}\u{20E3}") == true)
        #expect(try testMatch(#"^\p{RGI_Emoji_Flag_Sequence}$"#, "v", "🇺🇸") == true)
    }

    @Test("ES2025 v-mode RGI_Emoji_ZWJ_Sequence, RGI_Emoji, longest-first backtracking, lookbehind, and set operations")
    func rgiEmojiZWJSequencesAndSetOps() throws {
        // Families, professions, gendered, multi-skin-tone, directional, and Unicode 15.1–17.0 ZWJ sequences
        let validZWJ = [
            "👨‍👩‍👧", "👨‍👩‍👧‍👦", "👩‍👩‍👧‍👧", "🧑‍🧑‍🧒‍🧒", "👨‍❤️‍💋‍👨",
            "👩‍💻", "👨🏽‍🔬", "🧑‍🚀", "👩🏻‍🚒", "👨🏿‍⚕️",
            "🏃‍♀️", "🏋🏽‍♂️", "🧙🏿‍♀️",
            "👩🏻‍🤝‍👨🏿", "👨🏼‍❤️‍👨🏾",
            "\u{1F3C3}\u{200D}\u{2640}\u{FE0F}\u{200D}\u{27A1}\u{FE0F}", // 🏃‍♀️‍➡️
            "\u{1F46F}\u{1F3FB}\u{200D}\u{2640}\u{FE0F}",               // Unicode 17.0 skin-tone bunny ears woman
            "\u{1F93C}\u{1F3FD}\u{200D}\u{2642}\u{FE0F}",               // Unicode 17.0 skin-tone men wrestling
            "🏳️‍🌈", "🏴‍☠️",
            "\u{1F426}\u{200D}\u{1F525}",                               // 🐦‍🔥 phoenix
            "\u{1F34B}\u{200D}\u{1F7E9}",                               // 🍋‍🟩 lime
            "\u{1F642}\u{200D}\u{2195}\u{FE0F}",                        // 🙂‍↕️ head shaking vertically
        ]
        let reZWJ = try ECMAScriptRegExp(pattern: #"^\p{RGI_Emoji_ZWJ_Sequence}$"#, flags: "v")
        let reRGI = try ECMAScriptRegExp(pattern: #"^\p{RGI_Emoji}$"#, flags: "v")
        for seq in validZWJ {
            #expect(try reZWJ.exec(in: units(seq)) != nil, "Expected RGI_Emoji_ZWJ_Sequence to match \(seq)")
            #expect(try reRGI.exec(in: units(seq)) != nil, "Expected RGI_Emoji to match \(seq)")
        }

        // Negative cases: non-RGI ZWJ sequences, missing FE0F, non-ZWJ emojis, U+1F46A + modifier
        let invalidBoth = [
            "😀\u{200D}😀",
            "👨\u{200D}👩",
            "🏳\u{200D}🌈",
            "🏃\u{200D}♀",
            "👨\u{1F3FB}\u{200D}👩\u{1F3FC}\u{200D}👧",
            "🇺🇸\u{200D}🇯🇵",
            "\u{200D}",
            "\u{1F46A}\u{1F3FB}",
        ]
        for s in invalidBoth {
            #expect(try reZWJ.exec(in: units(s)) == nil)
            #expect(try reRGI.exec(in: units(s)) == nil)
        }
        for nonZwjRgi in ["😀", "🇺🇸", "👍🏽", "1\u{FE0F}\u{20E3}", "🏴󠁧󠁢󠁥󠁮󠁧󠁿"] {
            #expect(try reZWJ.exec(in: units(nonZwjRgi)) == nil)
            #expect(try reRGI.exec(in: units(nonZwjRgi)) != nil)
        }

        // Longest-first matching and multi-level backtracking
        #expect(try execStrings(#"\p{RGI_Emoji_ZWJ_Sequence}"#, "v", "👨‍👩‍👧‍👦") == ["👨‍👩‍👧‍👦"])
        #expect(try execStrings(#"\p{RGI_Emoji_ZWJ_Sequence}\u200D👦"#, "v", "👨‍👩‍👧‍👦") == ["👨‍👩‍👧‍👦"])
        #expect(try execStrings(#"\p{RGI_Emoji}\u200D👩"#, "v", "👨‍👩‍👧") == ["👨‍👩"])
        #expect(try execStrings(#"\p{RGI_Emoji}\u200D💻"#, "v", "👩🏽‍💻") == ["👩🏽‍💻"])
        #expect(try execStrings(#"\p{RGI_Emoji}\u{1F3FD}\u200D💻"#, "v", "👩🏽‍💻") == ["👩🏽‍💻"])
        #expect(try execStrings(#"^(\p{RGI_Emoji}+)(\u200D👦)$"#, "v", "👨‍👩‍👧‍👦") == ["👨‍👩‍👧‍👦", "👨‍👩‍👧", "\u{200D}👦"])

        let runnerRight = "\u{1F3C3}\u{200D}\u{2640}\u{FE0F}\u{200D}\u{27A1}\u{FE0F}"
        #expect(try execStrings(#"\p{RGI_Emoji}"#, "v", runnerRight) == [runnerRight])
        #expect(try execStrings(#"\p{RGI_Emoji}\u200D\u27A1\uFE0F"#, "v", runnerRight) == [runnerRight])
        #expect(try execStrings(#"\p{RGI_Emoji}\u200D\u2640\uFE0F"#, "v", runnerRight) == ["\u{1F3C3}\u{200D}\u{2640}\u{FE0F}"])

        // Lookbehind with ZWJ sequences and backtracking
        let lb1 = try ECMAScriptRegExp(pattern: #"(?<=\p{RGI_Emoji_ZWJ_Sequence})!"#, flags: "v")
        #expect(try lb1.exec(in: units("👨‍👩‍👧‍👦!"))?.range == 11..<12)
        let lb2 = try ECMAScriptRegExp(pattern: #"(?<=\p{RGI_Emoji_ZWJ_Sequence})\u200D👦"#, flags: "v")
        #expect(try lb2.exec(in: units("👨‍👩‍👧‍👦"))?.range == 8..<11)
        #expect(try execStrings(#"(?<=(.)\p{RGI_Emoji})!"#, "v", "👨‍👩‍👧!") == ["!", "\u{200D}"])

        // v-mode set operations (subtraction, intersection, union, nested, /iv, /dv)
        #expect(try testMatch(#"^[\p{RGI_Emoji}--\p{RGI_Emoji_ZWJ_Sequence}]$"#, "v", "👨‍👩‍👧") == false)
        #expect(try testMatch(#"^[\p{RGI_Emoji}--\p{RGI_Emoji_ZWJ_Sequence}]$"#, "v", "🇺🇸") == true)
        #expect(try testMatch(#"^[\p{RGI_Emoji}--\p{RGI_Emoji_ZWJ_Sequence}]$"#, "v", "😀") == true)
        #expect(try testMatch(#"^[\p{RGI_Emoji}&&\p{RGI_Emoji_ZWJ_Sequence}]$"#, "v", "👨‍👩‍👧") == true)
        #expect(try testMatch(#"^[\p{RGI_Emoji}&&\p{RGI_Emoji_ZWJ_Sequence}]$"#, "v", "😀") == false)
        #expect(try testMatch(#"^[\p{RGI_Emoji_ZWJ_Sequence}&&\q{👨‍👩‍👧|😀}]$"#, "v", "👨‍👩‍👧") == true)
        #expect(try testMatch(#"^[\p{RGI_Emoji_ZWJ_Sequence}&&\q{👨‍👩‍👧|😀}]$"#, "v", "😀") == false)
        #expect(try testMatch(#"^[\p{RGI_Emoji_ZWJ_Sequence}--\q{👨‍👩‍👧}]$"#, "v", "👨‍👩‍👧") == false)
        #expect(try testMatch(#"^[\p{RGI_Emoji_ZWJ_Sequence}--\q{👨‍👩‍👧}]$"#, "v", "👨‍👩‍👧‍👦") == true)
        #expect(try testMatch(#"^[\p{RGI_Emoji_ZWJ_Sequence}\p{RGI_Emoji_Flag_Sequence}]$"#, "v", "🇺🇸") == true)
        #expect(try testMatch(#"^[\p{RGI_Emoji_ZWJ_Sequence}\p{RGI_Emoji_Flag_Sequence}]$"#, "v", "👩🏽‍💻") == true)
        #expect(try testMatch(#"^[\p{RGI_Emoji_ZWJ_Sequence}\q{abc}]$"#, "iv", "ABC") == true)
        #expect(try testMatch(#"^[\p{RGI_Emoji_ZWJ_Sequence}\q{abc}]$"#, "iv", "👨‍👩‍👧") == true)

        // UTF-16 match indices with d + v flags
        let reDV = try ECMAScriptRegExp(pattern: #"(?<fam>\p{RGI_Emoji_ZWJ_Sequence})"#, flags: "dv")
        let dvMatch = try #require(try reDV.exec(in: units("x👨‍👩‍👧‍👦y")))
        #expect(dvMatch.range == 1..<12)
        #expect(dvMatch.namedCaptures["fam"] == 1..<12)

        // Strict v-mode MayContainStrings & u-mode syntax errors
        expectSyntaxError(#"\p{RGI_Emoji_ZWJ_Sequence}"#, "u")
        expectSyntaxError(#"\P{RGI_Emoji_ZWJ_Sequence}"#, "v")
        expectSyntaxError(#"\P{RGI_Emoji}"#, "v")
        expectSyntaxError(#"[^\p{RGI_Emoji_ZWJ_Sequence}]"#, "v")
        expectSyntaxError(#"[^\p{RGI_Emoji}]"#, "v")
        expectSyntaxError(#"[^\p{RGI_Emoji_ZWJ_Sequence}--\p{RGI_Emoji_ZWJ_Sequence}]"#, "v")
        expectSyntaxError(#"[^\p{RGI_Emoji_ZWJ_Sequence}&&\q{ab}]"#, "v")
        expectSyntaxError(#"[^\q{ab}&&\q{cd}]"#, "v")
        expectSyntaxError(#"[^\q{ab}--\q{ab}]"#, "v")
        // Valid negated intersections/subtractions where MayContainStrings is false
        #expect(try testMatch(#"^[^\p{RGI_Emoji_ZWJ_Sequence}&&\p{ASCII}]$"#, "v", "a") == true)
        #expect(try testMatch(#"^[^[a-z]--\p{RGI_Emoji_ZWJ_Sequence}]$"#, "v", "a") == false)
        #expect(try testMatch(#"^[^[a-z]--\p{RGI_Emoji_ZWJ_Sequence}]$"#, "v", "A") == true)
    }

    // MARK: - Unicode Property Escapes

    @Test("Unicode General_Category, Script, Script_Extensions, and Binary Properties")
    func unicodeProperties() throws {
        #expect(try testMatch(#"^\p{L}+$"#, "u", "hélloαβγ") == true)
        #expect(try testMatch(#"^\p{Lu}$"#, "u", "Ä") == true)
        #expect(try testMatch(#"^\p{Sc}$"#, "u", "€") == true)
        #expect(try testMatch(#"^\p{Script=Greek}+$"#, "u", "αβγ") == true)
        #expect(try testMatch(#"^\p{sc=Cyrillic}+$"#, "u", "привет") == true)
        #expect(try testMatch(#"^\p{sc=Han}+$"#, "u", "漢字") == true)
        // Script vs Script_Extensions difference: U+3001 (IDEOGRAPHIC COMMA) is sc=Common, scx includes Han/Hiragana/Katakana
        #expect(try testMatch(#"^\p{sc=Han}$"#, "u", "\u{3001}") == false)
        #expect(try testMatch(#"^\p{scx=Han}$"#, "u", "\u{3001}") == true)
        #expect(try testMatch(#"^\p{sc=Common}$"#, "u", "\u{3001}") == true)
        #expect(try testMatch(#"^\p{scx=Common}$"#, "u", "\u{3001}") == false)
        #expect(try testMatch(#"^\p{ASCII_Hex_Digit}+$"#, "u", "09afAF") == true)
        #expect(try testMatch(#"^\p{Emoji}$"#, "u", "😀") == true)
        #expect(try testMatch(#"^\p{ID_Start}\p{ID_Continue}*$"#, "u", "α1_") == true)
    }

    // MARK: - Annex B vs u/v Syntax Errors

    @Test("Annex B quirks in non-u mode and strict syntax errors in u/v mode")
    func annexBAndSyntaxErrors() throws {
        // Annex B non-u
        #expect(try testMatch(#"^\cA$"#, "", "\u{0001}") == true)
        #expect(try testMatch(#"^\c1$"#, "", #"\c1"#) == true)
        #expect(try testMatch(#"^[\c1]$"#, "", "\u{0011}") == true)
        #expect(try testMatch(#"^[\c_]$"#, "", "\u{001F}") == true)
        #expect(try testMatch(#"^\101$"#, "", "A") == true)
        #expect(try testMatch(#"^\0$"#, "", "\u{0000}") == true)
        #expect(try testMatch(#"^\01$"#, "", "\u{0001}") == true)
        #expect(try testMatch(#"^\8$"#, "", "8") == true)
        #expect(try testMatch(#"^]$"#, "", "]") == true)
        #expect(try testMatch(#"^{$"#, "", "{") == true)
        #expect(try testMatch(#"^a{b}$"#, "", "a{b}") == true)
        #expect(try testMatch(#"^[\d-a]$"#, "", "-") == true)
        #expect(try testMatch(#"^\a$"#, "", "a") == true)
        #expect(try testMatch(#"^\u{2}$"#, "", "uu") == true)
        #expect(try testMatch(#"^(?=a)?a$"#, "", "a") == true)
        #expect(try testMatch(#"^\k$"#, "", "k") == true)

        // Strict u-mode syntax errors
        expectSyntaxError(#"\a"#, "u")
        expectSyntaxError("]", "u")
        expectSyntaxError("{", "u")
        expectSyntaxError("}", "u")
        expectSyntaxError(#"\01"#, "u")
        expectSyntaxError(#"\1"#, "u")
        expectSyntaxError(#"\c1"#, "u")
        expectSyntaxError(#"\x1"#, "u")
        expectSyntaxError(#"\u123"#, "u")
        expectSyntaxError(#"\u{110000}"#, "u")
        expectSyntaxError(#"[\d-a]"#, "u")
        expectSyntaxError("(?=a)+", "u")
        expectSyntaxError(#"\p{NoSuchProperty}"#, "u")
        expectSyntaxError(#"\k<missing>"#, "u")

        // v-mode syntax errors
        expectSyntaxError("[a-z--b]", "v")
        expectSyntaxError(#"[^\q{ab}]"#, "v")
        expectSyntaxError(#"\P{Basic_Emoji}"#, "v")
        expectSyntaxError("[a&&b--c]", "v")
        expectSyntaxError("[&&]", "v")

        // Modifier & flag errors
        expectSyntaxError("(?-:a)")
        expectSyntaxError("(?ii:a)")
        expectSyntaxError("(?i-i:a)")
        expectSyntaxError("a", "uv", kind: .invalidFlags)
        expectSyntaxError("a", "gg", kind: .invalidFlags)
        expectSyntaxError("a", "z", kind: .invalidFlags)
    }

    // MARK: - RegExp.escape, EscapeRegExpPattern & Interrupt Hook

    @Test("RegExp.escape handles ES2025 rules including lone surrogates")
    func regexpEscape() {
        #expect(ECMAScriptRegExp.escape("abc") == #"\x61bc"#)
        #expect(ECMAScriptRegExp.escape("0a") == #"\x30a"#)
        #expect(ECMAScriptRegExp.escape("_a") == "_a")
        #expect(ECMAScriptRegExp.escape("\t\n\u{000B}\u{000C}\r ") == #"\t\n\v\f\r\x20"#)
        #expect(ECMAScriptRegExp.escape(#"^$\.*+?()[]{}|/"#) == #"\^\$\\\.\*\+\?\(\)\[\]\{\}\|\/"#)
        #expect(ECMAScriptRegExp.escape("😀") == "😀")
        // Lone surrogate in [UInt16]
        let loneEscaped = String(decoding: ECMAScriptRegExp.escape([0xD800]), as: UTF16.self)
        #expect(loneEscaped == #"\ud800"#)
    }

    @Test("Interrupt hook aborts catastrophic backtracking deterministically")
    func interruptHookAbortsBacktracking() throws {
        struct Aborted: Error {}
        let re = try ECMAScriptRegExp(pattern: "(a+)+$", flags: "")
        let input = units(String(repeating: "a", count: 28) + "b")
        var checks = 0
        #expect(throws: Aborted.self) {
            _ = try re.exec(in: input) {
                checks += 1
                if checks >= 5 { throw Aborted() }
            }
        }
        #expect(checks == 5)
    }

    @Test("Code Mode runtime timeoutMs aborts catastrophic regex backtracking as TimeoutExceeded")
    func runtimeTimeoutAbortsCatastrophicBacktracking() async throws {
        let runtime = try CodemodeLanguage.makeRuntime(CodemodeLanguage.RuntimeOptions(
            limits: CodemodeLanguage.Limits(timeoutMs: 50)
        ))
        let result = await runtime.execute(#"return /(a+)+$/.test("a".repeat(32) + "b")"#, nil)
        switch result {
        case .success:
            Issue.record("Expected TimeoutExceeded on catastrophic backtracking")
        case .failure(let error, _, _, _):
            #expect(error.kind == "TimeoutExceeded")
            #expect(error.message == "Execution timed out after 50ms.")
        }
    }
}
