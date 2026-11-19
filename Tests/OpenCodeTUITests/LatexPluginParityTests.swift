import OpenCodeCore
import OpenCodeSchema
import OpenCodeTUI
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import Synchronization
import Testing

@Suite("LaTeX Limits, Macro Expansion & Symbol Tables Parity")
struct LatexLimitsAndSymbolsParityTests {

    @Test("Default limit constants and resolvePositiveInteger validation")
    func limitConstantsAndValidation() throws {
        #expect(DEFAULT_MAX_SOURCE_LENGTH == 100_000)
        #expect(DEFAULT_MAX_NESTING_DEPTH == 256)

        #expect(try resolvePositiveInteger(nil, fallback: 42, optionName: "maxDepth") == 42)
        #expect(try resolvePositiveInteger(1, fallback: 42, optionName: "maxDepth") == 1)
        #expect(try resolvePositiveInteger(9_007_199_254_740_991, fallback: 42, optionName: "maxDepth") == 9_007_199_254_740_991)

        #expect(throws: LatexRangeError.self) {
            _ = try resolvePositiveInteger(0, fallback: 42, optionName: "maxSourceLength")
        }
        #expect(throws: LatexRangeError.self) {
            _ = try resolvePositiveInteger(-5, fallback: 42, optionName: "maxDepth")
        }
    }

    @Test("assertSourceLength enforces UTF-16 length limits and reports offset")
    func sourceLengthLimits() throws {
        try assertSourceLength("1234", maximum: 4)
        do {
            try assertSourceLength("12345", maximum: 4, label: "Expanded LaTeX source")
            Issue.record("Expected LatexParseError")
        } catch let err as LatexParseError {
            #expect(err.position == 4)
            #expect(err.message.contains("Expanded LaTeX source exceeds the 4-character limit"))
        }

        // Non-BMP characters count as 2 UTF-16 code units matching JS string.length.
        try assertSourceLength("😀", maximum: 2)
        #expect(throws: LatexParseError.self) {
            try assertSourceLength("😀", maximum: 1)
        }
    }

    @Test("assertNestingDepth tracks unescaped braces and ignores escaped braces")
    func nestingDepthValidation() throws {
        try assertNestingDepth("{{x}}", maximum: 2)
        try assertNestingDepth(#"\{\{\{x\}\}\}"#, maximum: 1)

        // Even backslash run before `{` means the brace IS unescaped.
        do {
            try assertNestingDepth(#"\\{{x}}"#, maximum: 1)
            Issue.record("Expected LatexParseError for double-escaped nesting")
        } catch let err as LatexParseError {
            #expect(err.position == 3)
            #expect(err.message.contains("1-level limit"))
        }
    }

    @Test("expandLatexMacros supports bare/prefixed names, chaining, and expansion bounds")
    func macroExpansion() throws {
        let expanded = try expandLatexMacros(
            #"\R \to \vecx"#,
            options: ParseOptions(macros: [
                #"\R"#: #"\mathbb{R}"#,
                "vecx": #"\vec{x}"#,
            ])
        )
        #expect(expanded == #"\mathbb{R} \to \vec{x}"#)

        // Double backslash consumes `\\` and must not accidentally match `\a`.
        let untouched = try expandLatexMacros(#"\\a"#, options: ParseOptions(macros: ["a": "REPLACED"]))
        #expect(untouched == #"\\a"#)

        // Infinite non-growing cycle hits maxExpand passes.
        do {
            _ = try expandLatexMacros(#"\a"#, options: ParseOptions(macros: ["a": #"\b"#, "b": #"\a"#], maxExpand: 5))
            Issue.record("Expected LatexParseError for macro cycle")
        } catch let err as LatexParseError {
            #expect(err.message.contains("Macro expansion exceeded 5 passes"))
            #expect(err.position == 0)
        }

        // Exponential blowup hits maxExpandedLength.
        do {
            _ = try expandLatexMacros(#"\a"#, options: ParseOptions(macros: ["a": #"\a\a"#], maxExpandedLength: 64))
            Issue.record("Expected LatexParseError for expanded length")
        } catch let err as LatexParseError {
            #expect(err.message.contains("64-character limit"))
        }
    }

    @Test("Unicode symbol, operator, delimiter, and spacing tables match upstream counts and mappings")
    func symbolTablesParity() {
        #expect(symbolTable.count == 186)
        #expect(largeOperators.count == 14)
        #expect(namedOperators.count == 33)
        #expect(delimiterTable.count == 25)
        #expect(spacingCommands.count == 8)

        // Greek letters (including epsilon/varepsilon and phi/varphi distinction)
        #expect(symbolTable["alpha"] == SymbolDefinition(value: "α", role: .ordinary))
        #expect(symbolTable["beta"] == SymbolDefinition(value: "β", role: .ordinary))
        #expect(symbolTable["epsilon"] == SymbolDefinition(value: "ε", role: .ordinary))
        #expect(symbolTable["varepsilon"] == SymbolDefinition(value: "ϵ", role: .ordinary))
        #expect(symbolTable["phi"] == SymbolDefinition(value: "ϕ", role: .ordinary))
        #expect(symbolTable["varphi"] == SymbolDefinition(value: "φ", role: .ordinary))
        #expect(symbolTable["Omega"] == SymbolDefinition(value: "Ω", role: .ordinary))
        #expect(symbolTable["infty"] == SymbolDefinition(value: "∞", role: .ordinary))
        #expect(symbolTable["partial"] == SymbolDefinition(value: "∂", role: .ordinary))
        #expect(symbolTable["nabla"] == SymbolDefinition(value: "∇", role: .ordinary))

        // Binary, relation, arrows, punctuation
        #expect(symbolTable["pm"] == SymbolDefinition(value: "±", role: .binary))
        #expect(symbolTable["otimes"] == SymbolDefinition(value: "⊗", role: .binary))
        #expect(symbolTable["leq"] == SymbolDefinition(value: "≤", role: .relation))
        #expect(symbolTable["approx"] == SymbolDefinition(value: "≈", role: .relation))
        #expect(symbolTable["in"] == SymbolDefinition(value: "∈", role: .relation))
        #expect(symbolTable["rightarrow"] == SymbolDefinition(value: "→", role: .relation))
        #expect(symbolTable["Longleftrightarrow"] == SymbolDefinition(value: "⟺", role: .relation))
        #expect(symbolTable["cdots"] == SymbolDefinition(value: "⋯", role: .punctuation))
        #expect(symbolTable["ddots"] == SymbolDefinition(value: "⋱", role: .punctuation))

        // Large & named operators, delimiters, spacing
        #expect(largeOperators["sum"] == "∑")
        #expect(largeOperators["prod"] == "∏")
        #expect(largeOperators["int"] == "∫")
        #expect(largeOperators["oint"] == "∮")
        #expect(largeOperators["bigcup"] == "⋃")
        #expect(namedOperators.contains("sin"))
        #expect(namedOperators.contains("lim"))
        #expect(namedOperators.contains("Pr"))
        #expect(delimiterTable["|"] == "│")
        #expect(delimiterTable[#"\|"#] == "║")
        #expect(delimiterTable["langle"] == "⟨")
        #expect(delimiterTable["rceil"] == "⌉")
        #expect(delimiterTable["."] == "")
        #expect(spacingCommands[","] == 0)
        #expect(spacingCommands["quad"] == 2)
        #expect(spacingCommands["qquad"] == 4)
    }
}

@Suite("LaTeX Parser Parity")
struct LatexParserParityTests {

    @Test("Parses fractions and scripts structurally")
    func parsesFractionsAndScripts() throws {
        let node = try parseLatex(#"\frac{x^2+1}{y_0}"#)
        guard case .fraction(let num, let den, let bar, let align) = node else {
            Issue.record("Expected fraction node, got \(node)")
            return
        }
        #expect(bar == true)
        #expect(align == nil)
        if case .row = num {} else { Issue.record("Expected row numerator") }
        if case .scripts = den {} else { Issue.record("Expected scripts denominator") }
    }

    @Test("Parses matrix environments, array specs, and starred alignment environments")
    func parsesMatrixAndArrayEnvironments() throws {
        let pmat = try parseLatex(#"\begin{pmatrix}a & b \\ c & d\end{pmatrix}"#)
        #expect(
            pmat
                == .matrix(
                    rows: [
                        [.symbol(value: "a", role: .ordinary), .symbol(value: "b", role: .ordinary)],
                        [.symbol(value: "c", role: .ordinary), .symbol(value: "d", role: .ordinary)],
                    ],
                    environment: .pmatrix,
                    columns: nil
                )
        )

        let arr = try parseLatex(#"\begin{array}{cc}a & b \\ c & d\end{array}"#)
        guard case .matrix(let arrRows, let arrEnv, let arrCols) = arr else {
            Issue.record("Expected array matrix")
            return
        }
        #expect(arrEnv == .array)
        #expect(arrCols == "cc")
        #expect(arrRows.count == 2)
        #expect(arrRows[0].count == 2)

        let alignStar = try parseLatex(#"\begin{align*}a &= b \\ c &= d\end{align*}"#)
        guard case .matrix(_, let alignEnv, _) = alignStar else {
            Issue.record("Expected align matrix")
            return
        }
        #expect(alignEnv == .align)

        let normalized = try parseLatex(#"\begin{array}{ | l || c r | }a&b&c\end{array}"#, options: ParseOptions(strict: true))
        guard case .matrix(_, .array, let normCols) = normalized else {
            Issue.record("Expected array with normalized columns")
            return
        }
        #expect(normCols == "|l||cr|")

        for invalidSpec in ["", "||", "p{2cm}", "*{2}{c}", "c@{}c", "lXr"] {
            #expect(throws: LatexParseError.self) {
                _ = try parseLatex(#"\begin{array}{\#(invalidSpec)}a\end{array}"#, options: ParseOptions(strict: true))
            }
        }
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(#"\begin{array}a&b\end{array}"#, options: ParseOptions(strict: true))
        }
    }

    @Test("Preserves double norm delimiters and whole right commands with nesting")
    func delimitersAndLeftRight() throws {
        let doubleNorm = try parseLatex(#"\|v\|"#, options: ParseOptions(strict: true))
        #expect(
            doubleNorm
                == .row([
                    .symbol(value: "║", role: nil),
                    .symbol(value: "v", role: .ordinary),
                    .symbol(value: "║", role: nil),
                ])
        )

        let leftRightDouble = try parseLatex(#"\left\|v\right\|"#, options: ParseOptions(strict: true))
        #expect(leftRightDouble == .delimited(left: "║", body: .symbol(value: "v", role: .ordinary), right: "║"))

        let leftRightSingle = try parseLatex(#"\left|v\right|"#, options: ParseOptions(strict: true))
        #expect(leftRightSingle == .delimited(left: "│", body: .symbol(value: "v", role: .ordinary), right: "│"))

        let arrowInside = try parseLatex(#"\left(A\rightarrow B\right)"#, options: ParseOptions(strict: true))
        #expect(
            arrowInside
                == .delimited(
                    left: "(",
                    body: .row([
                        .symbol(value: "A", role: .ordinary),
                        .symbol(value: "→", role: .relation),
                        .symbol(value: "B", role: .ordinary),
                    ]),
                    right: ")"
                )
        )

        let nested = try parseLatex(#"\left(\left[A\right]\rightharpoonup B\right)"#)
        guard case .delimited(_, .row(let parts), _) = nested, parts.count == 3 else {
            Issue.record("Expected nested delimited row")
            return
        }
        if case .delimited = parts[0] {} else { Issue.record("Expected inner delimited") }
        #expect(parts[1] == .symbol(value: "⇀", role: .relation))

        do {
            _ = try parseLatex(#"\left(A\rightarrow B"#, options: ParseOptions(strict: true))
            Issue.record("Expected Missing \\right")
        } catch let err as LatexParseError {
            #expect(err.message.contains(#"Missing \right"#))
        }

        do {
            _ = try parseLatex(#"\left(A\rightward B\right)"#, options: ParseOptions(strict: true))
            Issue.record("Expected Unsupported command \\rightward")
        } catch let err as LatexParseError {
            #expect(err.message.contains(#"Unsupported command \rightward"#))
        }
    }

    @Test("Handles empty matrix cells, displaylines, cfrac alignment, braces, and named delimiters")
    func emptyCellsDisplaylinesCfracBraces() throws {
        let aligned = try parseLatex(#"\begin{aligned}&=x\\&=y\end{aligned}"#, options: ParseOptions(strict: true))
        #expect(
            aligned
                == .matrix(
                    rows: [
                        [.row([]), .row([.symbol(value: "=", role: .relation), .symbol(value: "x", role: .ordinary)])],
                        [.row([]), .row([.symbol(value: "=", role: .relation), .symbol(value: "y", role: .ordinary)])],
                    ],
                    environment: .aligned,
                    columns: nil
                )
        )

        let emptyGrid = try parseLatex(#"\begin{matrix}a&&\\&b&\end{matrix}"#, options: ParseOptions(strict: true))
        guard case .matrix(let gridRows, .matrix, nil) = emptyGrid else {
            Issue.record("Expected matrix")
            return
        }
        #expect(gridRows.count == 2)
        #expect(gridRows[0] == [.symbol(value: "a", role: .ordinary), .row([]), .row([])])
        #expect(gridRows[1] == [.row([]), .symbol(value: "b", role: .ordinary), .row([])])

        let trailingBreak = try parseLatex(#"\begin{matrix}a\\\end{matrix}"#)
        #expect(trailingBreak == .matrix(rows: [[.symbol(value: "a", role: .ordinary)]], environment: .matrix, columns: nil))

        let onlyBreak = try parseLatex(#"\begin{matrix}\\\end{matrix}"#)
        #expect(onlyBreak == .matrix(rows: [[.row([])]], environment: .matrix, columns: nil))

        // displaylines
        let dl = try parseLatex(#"\displaylines{x=1\\y=2}"#, options: ParseOptions(strict: true))
        guard case .matrix(let dlRows, .gathered, nil) = dl else {
            Issue.record("Expected gathered matrix for displaylines")
            return
        }
        #expect(dlRows.count == 2)
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(#"\displaylines[l]{x\\y}"#, options: ParseOptions(strict: true))
        }
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(#"\displaylines{x\\y"#, options: ParseOptions(strict: true))
        }

        // cfrac alignments
        let cfracCases: [(String, FractionNumeratorAlign?)] = [
            ("", nil),
            ("[]", nil),
            ("[l]", .left),
            ("[r]", .right),
        ]
        for (opt, expectedAlign) in cfracCases {
            let parsed = try parseLatex(#"\cfrac\#(opt){1}{23}"#, options: ParseOptions(strict: true))
            #expect(
                parsed
                    == .fraction(
                        numerator: .symbol(value: "1", role: .ordinary),
                        denominator: .row([
                            .symbol(value: "2", role: .ordinary),
                            .symbol(value: "3", role: .ordinary),
                        ]),
                        bar: true,
                        numeratorAlign: expectedAlign
                    )
            )
        }
        for badOpt in ["[c]", "[lr]", "[left]", "[l"] {
            #expect(throws: LatexParseError.self) {
                _ = try parseLatex(#"\cfrac\#(badOpt){1}{2}"#, options: ParseOptions(strict: true))
            }
        }

        // overbrace / underbrace
        let ob = try parseLatex(#"\overbrace{a+b}^{n}"#, options: ParseOptions(strict: true))
        guard case .scripts(.brace(_, .over), .symbol(value: "n", role: .ordinary), nil) = ob else {
            Issue.record("Expected overbrace scripts, got \(ob)")
            return
        }
        let ub = try parseLatex(#"\underbrace{x}_{k}"#, options: ParseOptions(strict: true))
        guard case .scripts(.brace(.symbol(value: "x", role: .ordinary), .under), nil, .symbol(value: "k", role: .ordinary)) = ub else {
            Issue.record("Expected underbrace scripts, got \(ub)")
            return
        }

        // Named braces & strict delimiter errors
        let lbrace = try parseLatex(#"\left\lbrace x\right\rbrace"#, options: ParseOptions(strict: true))
        #expect(lbrace == .delimited(left: "{", body: .symbol(value: "x", role: .ordinary), right: "}"))
        for badDelim in [
            #"\left\unknown x\right)"#,
            #"\left(x\right\unknown"#,
            #"\big\unknown"#,
            #"\left(x\middle\unknown y\right)"#,
        ] {
            do {
                _ = try parseLatex(badDelim, options: ParseOptions(strict: true))
                Issue.record("Expected unsupported delimiter error for \(badDelim)")
            } catch let err as LatexParseError {
                #expect(err.message.contains(#"Unsupported delimiter \unknown"#))
            }
        }
    }

    @Test("Parses text groups, operatorname, limits modifiers, macros, and error bounds")
    func textGroupsOperatorsAndBounds() throws {
        #expect(try parseLatex(#"\text{left \{ only}"#) == .text("left { only"))
        #expect(try parseLatex(#"\text{right \} only}"#) == .text("right } only"))
        #expect(try parseLatex(#"\text{a\textbackslash b~c\!d}"#) == .text(#"a\ b cd"#))

        #expect(
            try parseLatex(#"\operatorname{arg\,max}"#, options: ParseOptions(strict: true))
                == .operator(value: "arg max", limits: false)
        )
        #expect(
            try parseLatex(#"\textrm{ if }"#, options: ParseOptions(strict: true))
                == .variant(variant: .normal, body: .text(" if "))
        )

        let starred = try parseLatex(#"\operatorname*{arg\,max}_{x}"#)
        guard case .scripts(.operator(value: "arg max", limits: true), nil, .symbol(value: "x", role: .ordinary)) = starred else {
            Issue.record("Expected starred operatorname with limits=true")
            return
        }

        let intLimits = try parseLatex(#"\int\limits_0^1"#)
        guard case .scripts(.operator(value: "∫", limits: true), _, _) = intLimits else {
            Issue.record("Expected \\int\\limits with limits=true")
            return
        }

        let sumNoLimits = try parseLatex(#"\sum\nolimits_{i=1}"#)
        guard case .scripts(.operator(value: "∑", limits: false), _, _) = sumNoLimits else {
            Issue.record("Expected \\sum\\nolimits with limits=false")
            return
        }

        // Limits modifier placed after scripts updates the underlying operator too.
        let intPostLimits = try parseLatex(#"\int_0^1\limits"#)
        guard case .scripts(.operator(value: "∫", limits: true), _, _) = intPostLimits else {
            Issue.record("Expected post-script \\limits to set limits=true")
            return
        }

        // Strict unknown command & malformed environments
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(#"\definitelyUnknown{x}"#, options: ParseOptions(strict: true))
        }
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(#"\begin{matrix}]"#)
        }
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(#"\begin{matrix}x}"#)
        }
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(#"\begin{matrix}&}"#)
        }

        // Deep nesting bounds
        let deepBraces = String(repeating: "{", count: 80) + "x" + String(repeating: "}", count: 80)
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(deepBraces, options: ParseOptions(maxDepth: 64))
        }
        let deepFracs = String(repeating: #"\frac"#, count: 80) + "x"
        #expect(throws: LatexParseError.self) {
            _ = try parseLatex(deepFracs, options: ParseOptions(maxDepth: 64))
        }
        #expect(throws: LatexRangeError.self) {
            _ = try parseLatex("x", options: ParseOptions(maxSourceLength: 0))
        }
    }
}

@Suite("LaTeX 2D Layout, Root Geometry & Rendering Parity")
struct LatexLayoutAndRenderParityTests {

    @Test("Renders fractions, compact/2D scripts, display modes, binomials, roots, matrices, and limits")
    func renderCoreStructures() throws {
        #expect(try renderLatexToString(#"\frac{x+1}{y-1}"#) == " x + 1\n───────\n y - 1")

        let scriptCases: [(String, String)] = [
            (#"E = mc^2"#, "E = mc²"),
            (#"a_n"#, "aₙ"),
            (#"x_i^2"#, "x²ᵢ"),
            (#"x^{}"#, "x"),
            (#"x_{}"#, "x"),
            (#"x^{}_{}"#, "x"),
            (#"x^m_1"#, " m\nx\n 1"),
            (#"x^2_q"#, " 2\nx\n q"),
            (#"x^{\frac{1}{2}}_1"#, "  1\n ───\n  2\nx\n 1"),
        ]
        for (source, expected) in scriptCases {
            #expect(try renderLatexToString(source) == expected, "Mismatch for \(source)")
        }

        #expect(try renderLatexToString(#"x_i^2"#, options: RenderLatexOptions(compactScripts: false)) == " 2\nx\n i")
        #expect(try renderLatexToString(#"\sum_1^n"#, options: RenderLatexOptions(displayMode: false)) == "∑ⁿ₁")
        #expect(try renderLatexToString(#"\sum_1^n"#, options: RenderLatexOptions(compactScripts: false)) == "n\n∑\n1")

        #expect(
            try renderLatexToString(#"P = \binom{n}{k}"#)
                == ["    ⎛ n ⎞", "P = ⎜   ⎟", "    ⎝ k ⎠"].joined(separator: "\n")
        )
        #expect(
            try renderLatexToString(#"\sqrt{x^2+y^2}"#)
                == [" ╭───────", "╰╯x² + y²"].joined(separator: "\n")
        )
        #expect(
            try renderLatexToString(#"\begin{pmatrix}a & b \\ c & d\end{pmatrix}"#)
                == ["⎛a b⎞", "⎜   ⎟", "⎝c d⎠"].joined(separator: "\n")
        )
        #expect(
            try renderLatexToString(#"\sum_{i=1}^{n} i^2"#)
                == ["  n", "  ∑   i²", "i = 1"].joined(separator: "\n")
        )

        let fracLayout = try renderLatex(#"\frac{1}{2}"#)
        #expect(fracLayout.width == 3)
        #expect(fracLayout.height == 3)
        #expect(fracLayout.baseline == 1)

        // Variants and inherited styles
        #expect(try renderLatexToString(#"\mathbb{R} \to \mathcal{C} \times \mathfrak{g}"#) == "ℝ → 𝒞 × 𝔤")
        let styledLayout = try renderLatex(#"\mathbf{\mathsf{\textcolor{red}{\mathit{x}}}}"#)
        #expect(
            styledLayout.cells[0][0]
                == MathCell(char: "x", style: MathStyle(color: "red", bold: true, italic: true, dim: nil))
        )

        // Nested fractions
        let nestedFrac = try renderLatexToString(#"\frac{1}{1+\frac{1}{x}}"#)
        #expect(nestedFrac.split(separator: "\n", omittingEmptySubsequences: false).count == 5)
        let ruleCount = nestedFrac.unicodeScalars.filter { $0 == "─" }.count
        #expect(ruleCount >= 10)

        // Textbook quadratic formula
        let quad = try renderLatexToString(#"\left[\frac{-b \pm \sqrt{b^2-4ac}}{2a}\right]"#)
        #expect(quad.contains("±"))
        #expect(quad.contains("╰╯"))
        #expect(quad.contains("─"))
        #expect(quad.contains("⎡"))
        #expect(quad.contains("⎦"))

        // Combining negation & interval delimiters
        let negated = try renderLatexToString(#"\not\rightarrow"#)
        #expect(Array(negated.unicodeScalars) == ["→", "\u{0338}"])
        #expect(try renderLatexToString(#"x\in[0,1]"#) == "x ∈ [0,1]")
        #expect(try renderLatexToString(#"[-1,1]"#) == "[-1,1]")
    }

    @Test("Structured layout matches upstream layout.test.ts and parser-render.test.ts")
    func structuredLayoutParity() throws {
        // Empty scripts never change geometry
        for source in [
            #"\sqrt{x}"#,
            #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#,
            #"\underbrace{abcd}"#,
            #"\overbrace{abcd}"#,
            #"\sum"#,
        ] {
            let expected = try renderLatexToString(source)
            for scripts in ["^{}", "_{}", "^{}_{}"] {
                #expect(try renderLatexToString(source + scripts) == expected)
            }
        }

        // Brace junction centering & baseline
        #expect(try renderLatexToString(#"\overbrace{abcd}^{n}"#) == " n\n╭┴─╮\nabcd")
        #expect(try renderLatexToString(#"\underbrace{abcd}_{n}"#) == "abcd\n╰┬─╯\n n")

        let overBrace = layoutMath(
            .scripts(base: .brace(body: .text("a + b + c"), position: .over), superscript: .text("n"), subscript: nil)
        )
        #expect(overBrace.toString() == "    n\n╭───┴───╮\na + b + c")
        #expect(overBrace.baseline == 2)

        let underBrace = layoutMath(
            .scripts(base: .brace(body: .text("a + b + c"), position: .under), superscript: nil, subscript: .text("n"))
        )
        #expect(underBrace.toString() == "a + b + c\n╰───┬───╯\n    n")
        #expect(underBrace.baseline == 0)

        // Raised power above matrix & piecewise cases
        #expect(
            try renderLatexToString(#"\begin{pmatrix}a&b\\c&d\end{pmatrix}^2"#)
                == ["     2", "⎛a b⎞", "⎜   ⎟", "⎝c d⎠"].joined(separator: "\n")
        )
        #expect(
            try renderLatexToString(#"\begin{cases}x & x>0\\x^2+1 & x\le0\end{cases}"#)
                == ["⎧x       x > 0", "⎨", "⎩x² + 1  x ≤ 0"].joined(separator: "\n")
        )

        // Array alignment & vertical rules
        let arr1 = layoutMath(
            .matrix(
                rows: [[.text("a"), .text("wide")], [.text("long"), .text("b")]],
                environment: .array,
                columns: "l|r"
            )
        )
        #expect(arr1.toString() == ["a    │ wide", "     │", "long │    b"].joined(separator: "\n"))

        let arr2 = layoutMath(
            .matrix(
                rows: [[.text("a"), .text("b")], [.text("long"), .text("c")]],
                environment: .array,
                columns: "|l||r|"
            )
        )
        #expect(arr2.toString() == ["│ a    ││ b │", "│      ││   │", "│ long ││ c │"].joined(separator: "\n"))

        // Continued fraction alignment
        let cLeft = layoutMath(
            .fraction(numerator: .text("1"), denominator: .text("12345"), bar: true, numeratorAlign: .left)
        )
        #expect(cLeft.toString() == " 1\n───────\n 12345")
        let cRight = layoutMath(
            .fraction(numerator: .text("1"), denominator: .text("12345"), bar: true, numeratorAlign: .right)
        )
        #expect(cRight.toString() == "     1\n───────\n 12345")

        // Accents
        #expect(try renderLatexToString(#"\hat{x}"#) == "^\nx")
        #expect(try renderLatexToString(#"\widehat{xy}"#) == "⌢\nxy")
        #expect(try renderLatexToString(#"\overline{ab}"#) == "──\nab")
        #expect(try renderLatexToString(#"\underline{ab}"#) == "ab\n──")
        #expect(try renderLatexToString(#"\vec{v}"#) == "→\nv")
        #expect(try renderLatexToString(#"\tilde{a}"#) == "~\na")
        #expect(try renderLatexToString(#"\dot{x}"#) == "·\nx")
        #expect(try renderLatexToString(#"\ddot{x}"#) == "¨\nx")

        // parser-render regressions
        let regressions: [(String, String)] = [
            (#"\|v\|"#, "║v║"),
            (#"\left\|v\right\|"#, "║v║"),
            (#"\left|v\right|"#, "│v│"),
            (#"\left(A\rightarrow B\right)"#, "(A → B)"),
            (#"\left\lbrace x\right\rbrace"#, "{x}"),
            (#"\operatorname{arg\,max} x"#, "arg max x"),
            (#"\textrm{if }x"#, "if x"),
            (#"\displaylines{x=1\\y=2}"#, "x = 1\n\ny = 2"),
        ]
        for (source, expected) in regressions {
            #expect(try renderLatexToString(source, options: RenderLatexOptions(strict: true)) == expected)
        }
        #expect(
            try renderLatexToString(#"\begin{aligned}&=x\\&=y\end{aligned}"#, options: RenderLatexOptions(strict: true))
                == renderLatexToString(#"\begin{aligned}{}&=x\\{}&=y\end{aligned}"#, options: RenderLatexOptions(strict: true))
        )
    }

    @Test("Root geometry preserves radicand/index cells, stems, baselines, and wide characters")
    func rootGeometryParity() throws {
        let pairs: [(String, String)] = [
            ("x", #"\frac{1}{2}"#),
            ("x", #"\sqrt{n}"#),
            ("x", "123456789"),
            ("x", #"\frac{123456789}{\frac{n}{m}}"#),
            (#"\frac{a}{b}"#, "3"),
            (#"\sqrt{\frac{a}{b}}"#, #"\sqrt{\frac{n}{m}}"#),
            (#"\text{界}"#, #"\text{次}"#),
            ("", #"\frac{1}{2}"#),
        ]
        for (bodySource, indexSource) in pairs {
            let body = try renderLatex(bodySource, options: RenderLatexOptions(color: "red"))
            let index = try renderLatex(indexSource, options: RenderLatexOptions(color: "blue"))
            let root = try renderLatex(#"\sqrt[\textcolor{blue}{\#(indexSource)}]{\textcolor{red}{\#(bodySource)}}"#)
            let bodyX = root.width - body.width
            let bodyY = root.height - body.height

            #expect(root.cells.count == root.height)
            #expect(root.baseline == bodyY + body.baseline)
            #expect(bodyX > index.width)
            #expect(bodyY >= index.height)
            for row in root.cells {
                #expect(row.count == root.width)
            }
            for (y, row) in body.cells.enumerated() {
                for (x, cell) in row.enumerated() {
                    #expect(root.cells[bodyY + y][bodyX + x] == cell)
                }
            }
            for (y, row) in index.cells.enumerated() {
                for (x, cell) in row.enumerated() {
                    #expect(root.cells[y][x] == cell)
                }
            }
            let redCells = root.cells.flatMap { $0 }.compactMap { $0 }.filter { $0.style?.color == "red" }.count
            let expectedRed = body.cells.flatMap { $0 }.compactMap { $0 }.count
            let blueCells = root.cells.flatMap { $0 }.compactMap { $0 }.filter { $0.style?.color == "blue" }.count
            let expectedBlue = index.cells.flatMap { $0 }.compactMap { $0 }.count
            #expect(redCells == expectedRed)
            #expect(blueCells == expectedBlue)
        }

        let triple = try renderLatex(#"\sqrt{\sqrt{\sqrt{x}}}"#)
        #expect(triple.toString() == [" ╭─────", " │ ╭───", " │ │ ╭─", "╰╯╰╯╰╯x"].joined(separator: "\n"))
        #expect(triple.height == 4)
        #expect(triple.baseline == 3)

        let fracRoot = try renderLatex(#"\sqrt{\frac{a}{b}}"#)
        #expect(fracRoot.toString() == [" ╭───", " │ a", " │───", "╰╯ b"].joined(separator: "\n"))
        #expect(fracRoot.height == 4)
        #expect(fracRoot.baseline == 2)

        #expect(try renderLatex(#"\sqrt{x}"#).toString() == " ╭─\n╰╯x")
        #expect(try renderLatex(#"\sqrt[3]{x}"#).toString() == "3╭─\n╰╯x")
        #expect(try renderLatex(#"\sqrt[\frac{1}{2}]{x}"#).toString() == " 1\n───\n 2 ╭─\n  ╰╯x")
        #expect(try renderLatex(#"\sqrt[\sqrt{n}]{x}"#).toString() == " ╭─\n╰╯n╭─\n  ╰╯x")
    }

    @Test("Oracle-verified rendering of matrices, stretching delimiters, variants, overunder, pmod, negation, spacing, and comments")
    func oracleVerifiedExtendedRendering() throws {
        let cases: [(String, String)] = [
            (#"\overset{def}{=}"#, "def\n ="),
            (#"\stackrel{?}{=}"#, "?\n="),
            (#"\underset{x \to 0}{\lim} \frac{\sin x}{x} = 1"#, "       sin x\n lim  ─────── = 1\nx → 0    x"),
            (#"a \equiv b \pmod{n}"#, "a ≡ b (mod n)"),
            (#"a \bmod b"#, "a mod b"),
            (#"\not= \not\in \not\subset \not\le"#, "≠ ∉ ⊄ ≰"),
            (#"\begin{bmatrix}1 & 2 \\ 3 & 4\end{bmatrix}"#, "⎡1 2⎤\n⎢   ⎥\n⎣3 4⎦"),
            (#"\begin{Bmatrix}1 & 2 \\ 3 & 4\end{Bmatrix}"#, "⎧1 2⎫\n⎨   ⎬\n⎩3 4⎭"),
            (#"\begin{vmatrix}1 & 2 \\ 3 & 4\end{vmatrix}"#, "│1 2│\n│   │\n│3 4│"),
            (#"\begin{Vmatrix}1 & 2 \\ 3 & 4\end{Vmatrix}"#, "║1 2║\n║   ║\n║3 4║"),
            (#"\left\lfloor \frac{x}{2} \right\rfloor"#, "│ x │\n│───│\n⌊ 2 ⌋"),
            (#"\left\lceil \frac{x}{2} \right\rceil"#, "⌈ x ⌉\n│───│\n│ 2 │"),
            (#"\left\langle \frac{a}{b}, c \right\rangle"#, "/ a   \\\n│───,c│\n\\ b   /"),
            ("a % comment\n+ b", "a + b"),
            (#"\begin{pmatrix}1 & 2 \\[4pt] 3 & 4\end{pmatrix}"#, "⎛1 2⎞\n⎜   ⎟\n⎝3 4⎠"),
            (#"\mathsf{ABCabc012}"#, "𝖠𝖡𝖢𝖺𝖻𝖼𝟢𝟣𝟤"),
            (#"\mathtt{ABCabc012}"#, "𝙰𝙱𝙲𝚊𝚋𝚌𝟶𝟷𝟸"),
            (#"\mathbb{CHNPQRZ012}"#, "ℂℍℕℙℚℝℤ𝟘𝟙𝟚"),
            (#"\mathcal{BEFHILMR}"#, "ℬℰℱℋℐℒℳℛ"),
            (#"\mathfrak{CHIRZ}"#, "ℭℌℑℜℨ"),
            (#"a\,b\:c\;d\!e\quad f\qquad g\enspace h"#, "ab c de  f    g h"),
            (#"\alpha\beta\gamma\delta\epsilon\varepsilon\phi\varphi\Gamma\Delta\Omega"#, "αβγδεϵϕφΓΔΩ"),
            (#"\color{blue} x + y"#, "x + y"),
        ]
        for (source, expected) in cases {
            #expect(try renderLatexToString(source) == expected, "Mismatch for \(source)")
        }
        let colored = try renderLatex(#"\color{blue} x + y"#)
        #expect(colored.cells[0][0]?.style?.color == "blue")
    }
}

@Suite("LaTeX Markdown Adapter & Built-In TUI Plugin Parity")
struct LatexMarkdownAndPluginParityTests {

    private final class MutablePalette: @unchecked Sendable {
        var text: Color
        var subdued: Color

        init(text: Color = .string("#abcdef"), subdued: Color = .string("#667788")) {
            self.text = text
            self.subdued = subdued
        }
    }

    private func makeMarkdownSetup(
        content: String,
        width: Int = 80
    ) -> (test: TestRenderer, markdown: MarkdownRenderable, palette: MutablePalette) {
        let test = createTestRenderer(width: width, height: 24)
        let style = SyntaxStyle.fromStyles(["default": StyleDefinition(fg: parseColor("#ffffff"))])
        let palette = MutablePalette()
        let render = createLatexCodeBlockRenderer(test.renderer) {
            LatexOptions(text: palette.text, subdued: palette.subdued)
        }
        let markdown = MarkdownRenderable(
            ctx: test.renderer,
            options: MarkdownOptions(
                content: content,
                syntaxStyle: style,
                streaming: true,
                renderNode: createMarkdownCodeBlockRenderer(["latex": render, "math": render])
            )
        )
        test.renderer.root.add(markdown)
        test.renderOnce()
        return (test, markdown, palette)
    }

    @Test("Renders latex, math, tex, and titled LATEX fences into styled TextRenderable inside ScrollBoxRenderable")
    func rendersFencedLanguages() {
        for language in ["latex", "math", "tex", "LATEX title=example"] {
            let setup = makeMarkdownSetup(content: "```\(language)\n\\frac{1}{2}\n```")
            defer { setup.test.destroy() }

            let viewport = setup.markdown.getChildren().first as? ScrollBoxRenderable
            #expect(viewport != nil, "Expected ScrollBoxRenderable for \(language)")
            let formula = viewport?.getChildren().first as? TextRenderable
            #expect(formula != nil, "Expected TextRenderable for \(language)")
            #expect(formula?.height == 3)
            #expect(formula?.chunks.first(where: { $0.text == "1" })?.fg == RGBA.fromHex("#abcdef"))

            let frame = setup.test.captureCharFrame()
            #expect(frame.contains("1"))
            #expect(frame.contains("2"))
            #expect(!frame.contains(#"\frac"#))
        }
    }

    @Test("Preserves invalid or unsupported math as CodeRenderable source fallback")
    func preservesInvalidMathAsSource() {
        let invalidSources = [
            #"\frac{1}{"#,
            #"\unsupported{x}"#,
            #"\cfrac[x]{1}{2}"#,
            #"\left\unknown x\right)"#,
            #"\begin{array}{p{2cm}}x\end{array}"#,
            "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}",
        ]
        for source in invalidSources {
            let setup = makeMarkdownSetup(content: "```latex\n\(source)\n```")
            defer { setup.test.destroy() }
            let block = setup.markdown.getChildren().first as? CodeRenderable
            #expect(block != nil, "Expected CodeRenderable fallback for \(source)")
            #expect(block?.content == source)
        }
    }

    @Test("Renders structured math formulas through Markdown adapter without leaking backslashes")
    func rendersStructuredMathViaMarkdown() {
        let sources = [
            #"\sqrt[\frac{1}{2}]{x}"#,
            #"\left\|v\right\|"#,
            #"\left(A\rightarrow B\right)"#,
            #"\begin{aligned}a&=b+c\\&=d\end{aligned}"#,
            #"\displaylines{x=1\\y=2}"#,
            #"\cfrac[l]{1}{12345}"#,
            #"\underbrace{a+b+c}_{n}"#,
            #"\begin{array}{l|r}a&wide\\long&b\end{array}"#,
        ]
        for source in sources {
            let setup = makeMarkdownSetup(content: "```latex\n\(source)\n```")
            defer { setup.test.destroy() }
            #expect(setup.markdown.getChildren().first is ScrollBoxRenderable)
            #expect(setup.markdown.getChildren().first?.getChildren().first is TextRenderable)
            #expect(!setup.test.captureCharFrame().contains("\\"))
        }
    }

    @Test("Streaming lifecycle retains last valid formula during open fence and discards on close, stop, or removal")
    func streamingRetentionAndCleanup() {
        // Incomplete prefix -> valid formula -> close
        do {
            let setup = makeMarkdownSetup(content: "```latex\n\\frac{1}{")
            defer { setup.test.destroy() }
            #expect(setup.markdown.getChildren().first is CodeRenderable)

            setup.markdown.content += "2}"
            setup.test.renderOnce()
            #expect(setup.markdown.getChildren().first?.getChildren().first is TextRenderable)
            #expect(!setup.test.captureCharFrame().contains(#"\frac"#))

            setup.markdown.content += "\n```"
            setup.markdown.streaming = false
            setup.test.renderOnce()
            #expect(setup.markdown.getChildren().first?.getChildren().first is TextRenderable)
        }

        // Retain previous valid formula while appending an incomplete fraction
        do {
            let setup = makeMarkdownSetup(content: "```latex\n\\frac{a_1+b_1}{c_1+d_1}")
            defer { setup.test.destroy() }
            let previous = setup.test.captureCharFrame()

            setup.markdown.content += "+\\frac{a_"
            setup.test.renderOnce()
            #expect(setup.markdown.getChildren().first is ScrollBoxRenderable)
            #expect(setup.test.captureCharFrame() == previous)

            setup.markdown.content += "2+b_2}{c_2+d_2}"
            setup.test.renderOnce()
            #expect(setup.test.captureCharFrame() != previous)
            #expect(!setup.test.captureCharFrame().contains(#"\frac"#))
        }

        // Discard incomplete preview on fence close or streaming stop
        for endMode in ["close", "stop"] {
            let setup = makeMarkdownSetup(content: "```latex\nx^2")
            defer { setup.test.destroy() }
            setup.markdown.content += " + \\frac{1}{"
            setup.test.renderOnce()
            #expect(setup.markdown.getChildren().first is ScrollBoxRenderable)

            if endMode == "close" {
                setup.markdown.content += "\n```"
            } else {
                setup.markdown.streaming = false
            }
            setup.test.renderOnce()
            #expect(setup.markdown.getChildren().first is CodeRenderable)
        }

        // Never reuse another fence's preview or keep a removed fence's preview
        do {
            let setup = makeMarkdownSetup(content: "```latex\nx^2\n```\n\n```latex\n\\frac{1}{")
            defer { setup.test.destroy() }
            #expect(setup.markdown.getChildren().count >= 2)
            #expect(setup.markdown.getChildren()[1] is CodeRenderable)

            setup.markdown.content = ""
            setup.test.renderOnce()
            setup.markdown.content = "```latex\nx^2 + \\frac{1}{"
            setup.test.renderOnce()
            #expect(setup.markdown.getChildren().first is CodeRenderable)
        }

        // Renders final formula when last text update applied before completion
        do {
            let setup = makeMarkdownSetup(content: "```latex\n\\frac{1}{")
            defer { setup.test.destroy() }
            setup.markdown.content += "2}\n```"
            setup.markdown.streaming = false
            setup.test.renderOnce()
            #expect(setup.markdown.getChildren().filter { $0 is ScrollBoxRenderable }.count == 1)
            #expect(!setup.test.captureCharFrame().contains(#"\frac"#))
        }

        // Does not leave stale formula when stream ends with invalid math
        do {
            let setup = makeMarkdownSetup(content: "```latex\nx^2")
            defer { setup.test.destroy() }
            #expect(setup.markdown.getChildren().first?.getChildren().first is TextRenderable)
            setup.markdown.content += " + \\unsupported{x}\n```"
            setup.markdown.streaming = false
            setup.test.renderOnce()
            #expect(setup.markdown.getChildren().first is CodeRenderable)
        }

        // Keeps matrix and surrounding Markdown intact in a narrow terminal
        do {
            let setup = makeMarkdownSetup(
                content: "Before\n\n```math\n\\begin{pmatrix}a & b \\\\ c & d\\end{pmatrix}\n```\n\nAfter",
                width: 32
            )
            defer { setup.test.destroy() }
            let frame = setup.test.captureCharFrame()
            #expect(frame.contains("Before"))
            #expect(frame.contains("a b"))
            #expect(frame.contains("c d"))
            #expect(frame.contains("After"))
            #expect(!frame.contains("pmatrix"))
        }
    }

    @Test("Subdues structural glyphs, emphasizes relations, handles wide formulas/CJK, and refreshes theme colors")
    func stylingScrollingAndWideCharacters() throws {
        // Subdued structure + bold relations + dynamic palette refresh
        do {
            let setup = makeMarkdownSetup(content: "```latex\nx=\\sqrt{\\frac{1}{2}}\n```")
            defer { setup.test.destroy() }
            guard let formula = setup.markdown.getChildren().first?.getChildren().first as? TextRenderable else {
                Issue.record("Expected TextRenderable formula")
                return
            }
            for mark in ["\u{2500}", "\u{2502}", "\u{256D}", "\u{256F}", "\u{2570}"] {
                #expect(formula.chunks.first(where: { $0.text == mark })?.fg == RGBA.fromHex("#667788"))
            }
            #expect(formula.chunks.first(where: { $0.text == "x" })?.fg == RGBA.fromHex("#abcdef"))
            #expect(formula.chunks.first(where: { $0.text == "=" })?.attributes == TextAttributes.bold)

            setup.palette.text = .string("#123456")
            setup.palette.subdued = .string("#789abc")
            setup.markdown.refreshStyles()
            setup.test.renderOnce()

            guard let updated = setup.markdown.getChildren().first?.getChildren().first as? TextRenderable else {
                Issue.record("Expected updated TextRenderable formula")
                return
            }
            #expect(updated.chunks.first(where: { $0.text == "x" })?.fg == RGBA.fromHex("#123456"))
            for mark in ["\u{2500}", "\u{2502}", "\u{256D}", "\u{256F}", "\u{2570}"] {
                #expect(updated.chunks.first(where: { $0.text == mark })?.fg == RGBA.fromHex("#789abc"))
            }
        }

        // Ordinary typescript fences remain CodeRenderable
        do {
            let setup = makeMarkdownSetup(content: "```typescript\nconst x = 2\n```")
            defer { setup.test.destroy() }
            #expect(setup.markdown.getChildren().first is CodeRenderable)
        }

        // Wide formula scrolls horizontally without wrapping
        do {
            let setup = makeMarkdownSetup(
                content: "```latex\n\\text{Start a very long formula with enough content to overflow Finish}\n```",
                width: 24
            )
            defer { setup.test.destroy() }
            guard let viewport = setup.markdown.getChildren().first as? ScrollBoxRenderable else {
                Issue.record("Expected ScrollBoxRenderable viewport")
                return
            }
            #expect(viewport.height == 1)
            #expect(setup.test.captureCharFrame().contains("Start"))
            #expect(!setup.test.captureCharFrame().contains("Finish"))

            setup.test.mockMouse.scroll(x: 2, y: 1, direction: .right)
            setup.test.renderOnce()
            #expect(viewport.scrollLeft > 0)

            viewport.scrollLeft = viewport.scrollWidth
            setup.test.renderOnce()
            #expect(setup.test.captureCharFrame().contains("Finish"))
            #expect(!setup.test.captureCharFrame().contains("Start"))
        }

        // Wide CJK alignment preserved without extra phantom spaces
        for source in [#"\text{中文}=x"#, #"\frac{\text{中文}}{abcd}=x"#] {
            let layout = try renderLatex(source)
            let setup = makeMarkdownSetup(content: "```latex\n\(source)\n```", width: max(layout.width, 10))
            defer { setup.test.destroy() }
            guard let viewport = setup.markdown.getChildren().first as? ScrollBoxRenderable,
                  let formula = viewport.getChildren().first as? TextRenderable
            else {
                Issue.record("Expected math viewport and formula for \(source)")
                return
            }
            let renderedText = formula.chunks
                .map(\.text)
                .joined()
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    var s = String(line)
                    while s.hasSuffix(" ") { s.removeLast() }
                    return s
                }
                .joined(separator: "\n")
            #expect(renderedText == layout.toString())
        }
    }

    @Test("Inline math hook and Patchmark markdown extraction integrate with LaTeX renderer")
    func inlineMathHookAndPatchmarkExtraction() throws {
        // Inline hook renders compact single-line math spans and preserves prose
        let hook = createLatexInlineMathHook {
            LatexOptions(text: .string("#eeeeee"), subdued: .string("#888888"))
        }
        let style = SyntaxStyle.create()
        let ctx = MarkdownInlineContext(source: "Energy $E=mc^2$", conceal: true, syntaxStyle: style, tableCell: false)
        let rewritten = hook(
            [
                MarkdownInlineSpan(text: "Energy "),
                MarkdownInlineSpan(text: "$E=mc^2$", math: "E=mc^2"),
            ],
            ctx
        )
        #expect(rewritten.map(\.text).joined() == "Energy E = mc²")
        #expect(rewritten.first(where: { $0.text == "=" })?.attributes == TextAttributes.bold)

        // Patchmark extracts both inline `$...$` and block `$$...$$` math nodes
        let stream = PatchmarkStream(StreamOptions(math: true))
        let frame = stream.update("Inline $E = mc^2$ and:\n\n$$\n\\frac{a}{b}\n$$\n", streaming: false)
        let blocks = frame.blocks
        var inlineMathSources: [String] = []
        var blockMathSources: [String] = []
        for block in blocks {
            switch block.kind {
            case .paragraph(let inlines):
                for inline in inlines {
                    if case .math(let src, _, _) = inline {
                        inlineMathSources.append(src)
                    }
                }
            case .math(let src, _, _):
                var trimmed = src
                while trimmed.first == "\n" || trimmed.first == " " { trimmed.removeFirst() }
                while trimmed.last == "\n" || trimmed.last == " " { trimmed.removeLast() }
                blockMathSources.append(trimmed)
            default:
                break
            }
        }
        #expect(inlineMathSources == ["E = mc^2"])
        #expect(blockMathSources == [#"\frac{a}{b}"#])
        #expect(try renderLatexToString(inlineMathSources[0], options: RenderLatexOptions(displayMode: false)) == "E = mc²")
        #expect(try renderLatexToString(blockMathSources[0], options: RenderLatexOptions(displayMode: true)) == " a\n───\n b")
    }

    @Test("Built-in opencode.latex plugin registers latex and math hooks and cleans up cleanly")
    func builtinLatexPluginHooks() async throws {
        #expect(latexPlugin.id == "opencode.latex")
        #expect(LatexPlugin.id == "opencode.latex")
        #expect(LatexPlugin.languages == ["latex", "math"])
        #expect(TUIPluginHost.builtins.contains(where: { $0.id == "opencode.latex" }))

        // Verify PluginTui.DescriptorRegistry integration
        let descriptorRegistry = PluginTui.DescriptorRegistry()
        let registryCleanup = try await descriptorRegistry.register(latexPlugin)
        #expect(descriptorRegistry.codeBlockLanguages() == ["latex", "math"])
        await registryCleanup()
        #expect(descriptorRegistry.codeBlockLanguages().isEmpty)

        // Verify PluginTui.Definition setup, RenderNode output, and cleanup directly
        let registered = Mutex<[String: @Sendable (String) -> PluginTui.RenderNode]>([:])
        let context = PluginTui.Context(
            app: PluginTui.App(version: "2.0.0", channel: "dev"),
            data: PluginTui.Data(
                on: { _, _ in {} },
                listen: { _ in {} },
                sessionList: { [] },
                sessionStatus: { _ in "idle" },
                defaultLocation: { LocationSchema.Ref(directory: SchemaPrimitive.AbsolutePath(rawValue: "/tmp")) }
            ),
            attention: PluginTui.Attention(notify: { _ in
                PluginTui.AttentionNotifyResult(ok: false, notification: false, sound: false, skipped: .emptyMessage)
            }),
            registerCodeBlockRenderer: { lang, renderer in
                registered.withLock { $0[lang] = renderer }
                return {
                    registered.withLock { _ = $0.removeValue(forKey: lang) }
                }
            },
            keymap: PluginTui.Keymap(
                layer: { _ in },
                dispatch: { _, _ in },
                shortcuts: { _ in [] },
                commands: { [] },
                pending: { [] },
                active: { [] },
                currentMode: { "base" },
                pushMode: { _ in {} }
            ),
            storage: PluginTui.Storage(
                getStore: { _ in nil },
                setStore: { _, _ in },
                getMemory: { _ in nil },
                setMemory: { _, _ in }
            ),
            ui: PluginTui.UI(
                registerPage: { _ in {} },
                navigate: { _ in },
                currentRoute: { .home },
                openPanel: { _, _ in false },
                closePanel: {},
                slot: { _ in {} }
            )
        )

        let cleanup = try await latexPlugin.setup(context)
        let latexRenderer = registered.withLock { $0["latex"] }
        let mathRenderer = registered.withLock { $0["math"] }
        #expect(latexRenderer != nil)
        #expect(mathRenderer != nil)

        let renderedNode = latexRenderer?(#"\frac{1}{2}"#)
        #expect(renderedNode?.kind == "latex")
        #expect(renderedNode?.text == " 1\n───\n 2")
        #expect(renderedNode?.props["width"] == .int(3))
        #expect(renderedNode?.props["height"] == .int(3))
        #expect(renderedNode?.props["baseline"] == .int(1))

        let fallbackNode = mathRenderer?(#"\unsupported{x}"#)
        #expect(fallbackNode?.kind == "code")
        #expect(fallbackNode?.text == #"\unsupported{x}"#)
        #expect(fallbackNode?.props["fallback"] == .bool(true))

        await cleanup?()
        #expect(registered.withLock { $0.isEmpty })

        // Verify TUIPluginHost.PluginRuntimeContext integration
        let hostContext = TUIPluginHost.createPluginContext(
            host: TUIPluginHost.HostServices(),
            id: LatexPlugin.id
        )
        let disposeHost = try LatexPlugin.register(on: hostContext)
        let hostRenderers = hostContext.registry.markdownRenderers()
        #expect(hostRenderers["latex"] != nil)
        #expect(hostRenderers["math"] != nil)
        #expect(hostRenderers["latex"]?(#"\alpha + \beta"#) == "α + β")
        #expect(hostRenderers["math"]?(#"\unsupported{x}"#) == #"\unsupported{x}"#)
        disposeHost()
        #expect(hostContext.registry.markdownRenderers().isEmpty)

        // Verify LatexPlugin.setup with real OpenTUI renderer + ResolvedTheme
        let test = createTestRenderer(width: 40, height: 12)
        defer { test.destroy() }
        let theme = try resolveThemeDocument(ThemeDefaults.opencode, mode: .dark)
        var map: MarkdownCodeBlockRendererMap = [:]
        LatexPlugin.setup(renderer: test.renderer, theme: { theme }) { lang, renderer in
            map[lang] = renderer
        }
        #expect(map["latex"] != nil)
        #expect(map["math"] != nil)
        let md = MarkdownRenderable(
            ctx: test.renderer,
            options: MarkdownOptions(
                content: "```math\n\\sum_{i=1}^{n} i^2\n```",
                syntaxStyle: SyntaxStyle.create(),
                renderNode: createMarkdownCodeBlockRenderer(map)
            )
        )
        test.renderer.root.add(md)
        test.renderOnce()
        #expect(md.getChildren().first is ScrollBoxRenderable)
        #expect(test.captureCharFrame().contains("∑"))
    }
}
