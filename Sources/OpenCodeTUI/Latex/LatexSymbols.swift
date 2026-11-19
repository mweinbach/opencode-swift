// Unicode math symbol, operator, delimiter, and spacing tables (`packages/latex/src/symbols.ts`).

/// Definition of a LaTeX math symbol mapping to its Unicode string and optional TeX spacing role.
// parity: latex/src/symbols.ts#SymbolDefinition [status=implemented hash=32b75497b21d]
public struct SymbolDefinition: Equatable, Hashable, Sendable, Codable {
    public var value: String
    public var role: SymbolRole?

    public init(value: String, role: SymbolRole? = nil) {
        self.value = value
        self.role = role
    }
}

private let ordinarySymbols: [String: String] = [
    "alpha": "α",
    "beta": "β",
    "gamma": "γ",
    "delta": "δ",
    "epsilon": "ε",
    "varepsilon": "ϵ",
    "zeta": "ζ",
    "eta": "η",
    "theta": "θ",
    "vartheta": "ϑ",
    "iota": "ι",
    "kappa": "κ",
    "lambda": "λ",
    "mu": "μ",
    "nu": "ν",
    "xi": "ξ",
    "omicron": "ο",
    "pi": "π",
    "varpi": "ϖ",
    "rho": "ρ",
    "varrho": "ϱ",
    "sigma": "σ",
    "varsigma": "ς",
    "tau": "τ",
    "upsilon": "υ",
    "phi": "ϕ",
    "varphi": "φ",
    "chi": "χ",
    "psi": "ψ",
    "omega": "ω",
    "Gamma": "Γ",
    "Delta": "Δ",
    "Theta": "Θ",
    "Lambda": "Λ",
    "Xi": "Ξ",
    "Pi": "Π",
    "Sigma": "Σ",
    "Upsilon": "Υ",
    "Phi": "Φ",
    "Psi": "Ψ",
    "Omega": "Ω",
    "infty": "∞",
    "ell": "ℓ",
    "hbar": "ℏ",
    "imath": "ı",
    "jmath": "ȷ",
    "Re": "ℜ",
    "Im": "ℑ",
    "aleph": "ℵ",
    "beth": "ℶ",
    "gimel": "ℷ",
    "daleth": "ℸ",
    "partial": "∂",
    "nabla": "∇",
    "angle": "∠",
    "measuredangle": "∡",
    "triangle": "△",
    "square": "□",
    "lozenge": "◊",
    "top": "⊤",
    "bot": "⊥",
    "emptyset": "∅",
    "varnothing": "∅",
    "forall": "∀",
    "exists": "∃",
    "nexists": "∄",
    "neg": "¬",
    "lnot": "¬",
    "prime": "′",
    "backprime": "‵",
    "clubsuit": "♣",
    "diamondsuit": "♢",
    "heartsuit": "♡",
    "spadesuit": "♠",
    "checkmark": "✓",
]

private let binarySymbols: [String: String] = [
    "pm": "±",
    "mp": "∓",
    "times": "×",
    "div": "÷",
    "cdot": "·",
    "ast": "∗",
    "star": "⋆",
    "circ": "∘",
    "bullet": "∙",
    "oplus": "⊕",
    "ominus": "⊖",
    "otimes": "⊗",
    "oslash": "⊘",
    "odot": "⊙",
    "cap": "∩",
    "cup": "∪",
    "uplus": "⊎",
    "sqcap": "⊓",
    "sqcup": "⊔",
    "vee": "∨",
    "lor": "∨",
    "wedge": "∧",
    "land": "∧",
    "setminus": "∖",
    "wr": "≀",
    "diamond": "⋄",
    "bigtriangleup": "△",
    "bigtriangledown": "▽",
    "triangleleft": "◁",
    "triangleright": "▷",
]

private let relationSymbols: [String: String] = [
    "equals": "=",
    "neq": "≠",
    "ne": "≠",
    "equiv": "≡",
    "approx": "≈",
    "sim": "∼",
    "simeq": "≃",
    "cong": "≅",
    "asymp": "≍",
    "propto": "∝",
    "lt": "<",
    "gt": ">",
    "le": "≤",
    "leq": "≤",
    "ge": "≥",
    "geq": "≥",
    "ll": "≪",
    "gg": "≫",
    "prec": "≺",
    "succ": "≻",
    "preceq": "⪯",
    "succeq": "⪰",
    "subset": "⊂",
    "supset": "⊃",
    "subseteq": "⊆",
    "supseteq": "⊇",
    "sqsubset": "⊏",
    "sqsupset": "⊐",
    "sqsubseteq": "⊑",
    "sqsupseteq": "⊒",
    "in": "∈",
    "ni": "∋",
    "notin": "∉",
    "owns": "∋",
    "vdash": "⊢",
    "dashv": "⊣",
    "models": "⊨",
    "mid": "∣",
    "parallel": "∥",
    "perp": "⊥",
    "smile": "⌣",
    "frown": "⌢",
]

private let arrowSymbols: [String: String] = [
    "leftarrow": "←",
    "gets": "←",
    "rightarrow": "→",
    "to": "→",
    "leftrightarrow": "↔",
    "Leftarrow": "⇐",
    "Rightarrow": "⇒",
    "Leftrightarrow": "⇔",
    "mapsto": "↦",
    "hookleftarrow": "↩",
    "hookrightarrow": "↪",
    "leftharpoonup": "↼",
    "leftharpoondown": "↽",
    "rightharpoonup": "⇀",
    "rightharpoondown": "⇁",
    "rightleftharpoons": "⇌",
    "longleftarrow": "⟵",
    "longrightarrow": "⟶",
    "longleftrightarrow": "⟷",
    "Longleftarrow": "⟸",
    "Longrightarrow": "⟹",
    "Longleftrightarrow": "⟺",
    "longmapsto": "⟼",
    "uparrow": "↑",
    "downarrow": "↓",
    "updownarrow": "↕",
    "Uparrow": "⇑",
    "Downarrow": "⇓",
    "Updownarrow": "⇕",
    "nearrow": "↗",
    "searrow": "↘",
    "swarrow": "↙",
    "nwarrow": "↖",
]

private let punctuationSymbols: [String: String] = [
    "cdots": "⋯",
    "ldots": "…",
    "dots": "…",
    "vdots": "⋮",
    "ddots": "⋱",
    "colon": ":",
]

/// Complete table of Greek letters, math symbols, binary operators, relations, arrows, and punctuation.
// parity: latex/src/symbols.ts#symbolTable [status=implemented hash=5e3c4cfcad44]
public let symbolTable: [String: SymbolDefinition] = {
    var table: [String: SymbolDefinition] = [:]
    table.reserveCapacity(
        ordinarySymbols.count
            + binarySymbols.count
            + relationSymbols.count
            + arrowSymbols.count
            + punctuationSymbols.count
    )
    for (name, value) in ordinarySymbols {
        table[name] = SymbolDefinition(value: value, role: .ordinary)
    }
    for (name, value) in binarySymbols {
        table[name] = SymbolDefinition(value: value, role: .binary)
    }
    for (name, value) in relationSymbols {
        table[name] = SymbolDefinition(value: value, role: .relation)
    }
    for (name, value) in arrowSymbols {
        table[name] = SymbolDefinition(value: value, role: .relation)
    }
    for (name, value) in punctuationSymbols {
        table[name] = SymbolDefinition(value: value, role: .punctuation)
    }
    return table
}()

/// Large n-ary mathematical operators (`\sum`, `\prod`, `\int`, `\bigcup`, etc.).
// parity: latex/src/symbols.ts#largeOperators [status=implemented hash=946332950606]
public let largeOperators: [String: String] = [
    "sum": "∑",
    "prod": "∏",
    "coprod": "∐",
    "int": "∫",
    "iint": "∬",
    "iiint": "∭",
    "oint": "∮",
    "bigcap": "⋂",
    "bigcup": "⋃",
    "bigvee": "⋁",
    "bigwedge": "⋀",
    "bigoplus": "⨁",
    "bigotimes": "⨂",
    "bigodot": "⨀",
]

/// Upright named function/limit operators (`\sin`, `\cos`, `\lim`, `\max`, `\log`, etc.).
// parity: latex/src/symbols.ts#namedOperators [status=implemented hash=61225c337b5a]
public let namedOperators: Set<String> = [
    "arccos",
    "arcsin",
    "arctan",
    "arg",
    "cos",
    "cosh",
    "cot",
    "coth",
    "csc",
    "deg",
    "det",
    "dim",
    "exp",
    "gcd",
    "hom",
    "inf",
    "ker",
    "lg",
    "lim",
    "liminf",
    "limsup",
    "ln",
    "log",
    "max",
    "min",
    "mod",
    "Pr",
    "sec",
    "sin",
    "sinh",
    "sup",
    "tan",
    "tanh",
]

/// Delimiter glyphs recognized by `\left`, `\right`, `\middle`, `\big*`, and standalone delimiter commands.
// parity: latex/src/symbols.ts#delimiterTable [status=implemented hash=cb2fe8d03e43]
public let delimiterTable: [String: String] = [
    "(": "(",
    ")": ")",
    "[": "[",
    "]": "]",
    "\\{": "{",
    "\\}": "}",
    "{": "{",
    "}": "}",
    "|": "│",
    "\\|": "║",
    "vert": "│",
    "Vert": "║",
    "lvert": "│",
    "rvert": "│",
    "lVert": "║",
    "rVert": "║",
    "lbrace": "{",
    "rbrace": "}",
    "langle": "⟨",
    "rangle": "⟩",
    "lfloor": "⌊",
    "rfloor": "⌋",
    "lceil": "⌈",
    "rceil": "⌉",
    ".": "",
]

/// Explicit horizontal spacing commands mapped to terminal cell widths.
// parity: latex/src/symbols.ts#spacingCommands [status=implemented hash=70521cf3e357]
public let spacingCommands: [String: Int] = [
    ",": 0,
    ":": 1,
    ";": 1,
    "!": 0,
    "quad": 2,
    "qquad": 4,
    "enspace": 1,
    "thinspace": 0,
]
