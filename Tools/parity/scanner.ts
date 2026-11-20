import path from "path"
import fs from "fs"
import { TRACKED_PACKAGES, OUT_OF_SCOPE_WEB_PACKAGES, packageRoot, type PortTier } from "./config.ts"

export type SymbolKind =
  | "function"
  | "namespace_function"
  | "arrow_function"
  | "effect_function"
  | "method"
  | "class"
  | "const"
  | "type"
  | "interface"
  | "enum"
  | "namespace"
  | "rust_fn"
  | "rust_struct"
  | "rust_enum"
  | "rust_trait"
  | "rust_type"
  | "rust_const"

export interface UpstreamSymbol {
  readonly id: string
  readonly package: string
  readonly swiftTarget: string
  readonly tier: PortTier
  readonly file: string
  readonly symbol: string
  readonly kind: SymbolKind
  readonly line: number
  readonly signature: string
  readonly bodyHash: string
}

export interface UpstreamManifest {
  readonly schemaVersion: 1
  readonly generatedAt: string
  readonly upstream: {
    readonly repository: string
    readonly branch: string
    readonly commit: string
    readonly commitDate: string
    readonly commitSubject: string
    /** Tracked packages that live in their own pinned upstream repositories. */
    readonly external?: ReadonlyArray<{
      readonly package: string
      readonly repository: string
      readonly tag?: string
      readonly commit: string
      readonly commitDate: string
    }>
  }
  readonly summary: {
    readonly totalPackages: number
    readonly totalFiles: number
    readonly totalSymbols: number
    readonly totalFunctions: number
    readonly byPackage: Record<string, { files: number; symbols: number; functions: number; lines: number }>
    readonly excludedWebToolingPackages: readonly string[]
  }
  readonly symbols: UpstreamSymbol[]
}

const ROOT_DIR = path.resolve(import.meta.dir, "../..")
const UPSTREAM_DIR = path.join(ROOT_DIR, "upstream/opencode")
const LOCK_FILE = path.join(ROOT_DIR, "upstream.lock.json")
const MANIFEST_PATH = path.join(ROOT_DIR, "parity/upstream-manifest.json")

const TS_TRANSPILER = new Bun.Transpiler({ loader: "ts" })
const TSX_TRANSPILER = new Bun.Transpiler({ loader: "tsx" })

const REGEX_PREV_KEYWORDS = new Set([
  "return",
  "case",
  "throw",
  "typeof",
  "void",
  "delete",
  "in",
  "of",
  "instanceof",
  "yield",
  "await",
  "else",
  "do",
  "new",
])

const REGEX_PREV_CHARS = new Set([
  "=",
  "(",
  "[",
  "{",
  ",",
  ";",
  ":",
  "!",
  "&",
  "|",
  "?",
  "+",
  "-",
  "*",
  "%",
  "^",
  "~",
  "<",
  ">",
])

const CLASS_METHOD_EXCLUDED_NAMES = new Set([
  "constructor",
  "if",
  "for",
  "while",
  "switch",
  "catch",
  "return",
  "throw",
  "new",
  "typeof",
  "void",
  "delete",
  "await",
  "yield",
  "super",
  "this",
  "else",
  "do",
  "try",
  "finally",
  "case",
  "break",
  "continue",
  "default",
  "import",
  "export",
  "from",
  "as",
  "in",
  "of",
  "instanceof",
  "function",
  "class",
  "const",
  "let",
  "var",
])

const CLASS_METHOD_MODIFIERS = new Set([
  "public",
  "private",
  "protected",
  "static",
  "override",
  "abstract",
  "declare",
  "readonly",
  "async",
  "get",
  "set",
])

function sha256Short(text: string): string {
  const normalized = text.replace(/\r\n/g, "\n").replace(/[ \t]+/g, " ").trim()
  const hasher = new Bun.CryptoHasher("sha256")
  hasher.update(normalized)
  return hasher.digest("hex").slice(0, 12)
}

function isIdentStart(ch: string): boolean {
  const c = ch.charCodeAt(0)
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95 || c === 36
}

function isIdentPart(ch: string): boolean {
  const c = ch.charCodeAt(0)
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c === 95 || c === 36
}

function isDigit(ch: string): boolean {
  const c = ch.charCodeAt(0)
  return c >= 48 && c <= 57
}

// ============================================================================
// TypeScript / TSX Lexical Helpers
// ============================================================================

interface TSLexState {
  braceDepth: number
  parenDepth: number
  bracketDepth: number
  tplBraceStack: number[]
  prevChar: string
  prevIdent: string
}

function createTSLexState(): TSLexState {
  return {
    braceDepth: 0,
    parenDepth: 0,
    bracketDepth: 0,
    tplBraceStack: [],
    prevChar: "",
    prevIdent: "",
  }
}

/**
 * Scan template literal text starting right after `` ` `` or right after closing `}` of `${...}`.
 * Returns the next index in `source`: either right after the closing `` ` `` or right after `${`.
 */
function scanTemplateChunk(source: string, start: number, state: TSLexState): number {
  const n = source.length
  let i = start
  while (i < n) {
    const ch = source[i]!
    if (ch === "\\") {
      i += 2
      continue
    }
    if (ch === "`") {
      state.prevChar = "V"
      state.prevIdent = ""
      return i + 1
    }
    if (ch === "$" && source[i + 1] === "{") {
      state.tplBraceStack.push(state.braceDepth)
      state.braceDepth++
      state.prevChar = "{"
      state.prevIdent = ""
      return i + 2
    }
    i++
  }
  return n
}

function skipTSWhitespaceAndComments(source: string, start: number): number {
  const n = source.length
  let i = start
  while (i < n) {
    const ch = source[i]!
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
      i++
      continue
    }
    if (ch === "/" && source[i + 1] === "/") {
      i += 2
      while (i < n && source[i] !== "\n") i++
      continue
    }
    if (ch === "/" && source[i + 1] === "*") {
      i += 2
      while (i < n && !(source[i] === "*" && source[i + 1] === "/")) i++
      i = Math.min(n, i + 2)
      continue
    }
    break
  }
  return i
}

/**
 * Advance a single lexical step in TypeScript/TSX. Returns the next index.
 */
function stepTSLexer(source: string, i: number, isTsx: boolean, state: TSLexState): number {
  const n = source.length
  const ch = source[i]!

  // Single-line comment
  if (ch === "/" && source[i + 1] === "/") {
    i += 2
    while (i < n && source[i] !== "\n") i++
    return i
  }

  // Block comment
  if (ch === "/" && source[i + 1] === "*") {
    i += 2
    while (i < n && !(source[i] === "*" && source[i + 1] === "/")) i++
    return Math.min(n, i + 2)
  }

  // Single or double quoted string
  if (ch === "'" || ch === '"') {
    const q = ch
    i++
    while (i < n) {
      if (source[i] === "\\") {
        i += 2
        continue
      }
      if (source[i] === q) {
        i++
        break
      }
      if (source[i] === "\n") break
      i++
    }
    state.prevChar = "V"
    state.prevIdent = ""
    return i
  }

  // Template literal
  if (ch === "`") {
    return scanTemplateChunk(source, i + 1, state)
  }

  // Regex literal vs division operator vs TSX closing/self-closing slash
  if (ch === "/") {
    const isJsxSlash = isTsx && (source[i - 1] === "<" || source[i + 1] === ">")
    if (
      !isJsxSlash &&
      (state.prevChar === "" || REGEX_PREV_CHARS.has(state.prevChar) || REGEX_PREV_KEYWORDS.has(state.prevIdent))
    ) {
      i++
      let inClass = false
      while (i < n) {
        const rc = source[i]!
        if (rc === "\\") {
          i += 2
          continue
        }
        if (rc === "[") {
          inClass = true
          i++
          continue
        }
        if (rc === "]") {
          inClass = false
          i++
          continue
        }
        if (rc === "/" && !inClass) {
          i++
          break
        }
        if (rc === "\n") break
        i++
      }
      while (i < n && /[a-z]/i.test(source[i]!)) i++
      state.prevChar = "V"
      state.prevIdent = ""
      return i
    }
  }

  if (ch === "(") {
    state.parenDepth++
    state.prevChar = "("
    state.prevIdent = ""
    return i + 1
  }
  if (ch === ")") {
    state.parenDepth = Math.max(0, state.parenDepth - 1)
    state.prevChar = ")"
    state.prevIdent = ""
    return i + 1
  }
  if (ch === "[") {
    state.bracketDepth++
    state.prevChar = "["
    state.prevIdent = ""
    return i + 1
  }
  if (ch === "]") {
    state.bracketDepth = Math.max(0, state.bracketDepth - 1)
    state.prevChar = "]"
    state.prevIdent = ""
    return i + 1
  }
  if (ch === "{") {
    state.braceDepth++
    state.prevChar = "{"
    state.prevIdent = ""
    return i + 1
  }
  if (ch === "}") {
    state.braceDepth = Math.max(0, state.braceDepth - 1)
    if (state.tplBraceStack.length > 0 && state.braceDepth === state.tplBraceStack[state.tplBraceStack.length - 1]) {
      state.tplBraceStack.pop()
      return scanTemplateChunk(source, i + 1, state)
    }
    state.prevChar = "}"
    state.prevIdent = ""
    return i + 1
  }

  // Distinguish postfix TypeScript non-null assertion `expr!` from prefix logical NOT `!expr`
  if (ch === "!" && source[i + 1] !== "=") {
    const isPostfix =
      state.prevChar === "V" ||
      state.prevChar === ")" ||
      state.prevChar === "]" ||
      (state.prevChar === "I" && !REGEX_PREV_KEYWORDS.has(state.prevIdent))
    state.prevChar = isPostfix ? "V" : "!"
    state.prevIdent = ""
    return i + 1
  }

  if (isIdentStart(ch)) {
    let j = i + 1
    while (j < n && isIdentPart(source[j]!)) j++
    state.prevIdent = source.slice(i, j)
    state.prevChar = "I"
    return j
  }

  if (isDigit(ch)) {
    let j = i + 1
    while (j < n && /[0-9a-zA-Z_.]/.test(source[j]!)) j++
    state.prevIdent = ""
    state.prevChar = "V"
    return j
  }

  if (ch !== " " && ch !== "\t" && ch !== "\r" && ch !== "\n") {
    state.prevChar = ch
    state.prevIdent = ""
  }

  return i + 1
}

/**
 * Skip a balanced delimiter pair `( )`, `[ ]`, `{ }`, or `< >` in TypeScript/TSX.
 * Returns the index immediately AFTER the matching closing delimiter, or -1 if unmatched.
 */
function skipBalancedTS(source: string, openIndex: number, openChar: string, closeChar: string, isTsx: boolean): number {
  if (source[openIndex] !== openChar) return -1
  const n = source.length
  const state = createTSLexState()
  let depth = 0
  let i = openIndex

  while (i < n) {
    const ch = source[i]!
    // Skip comments, strings, templates, regex via lexer when not directly on open/close
    if (
      (ch === "/" && (source[i + 1] === "/" || source[i + 1] === "*")) ||
      ch === "'" ||
      ch === '"' ||
      ch === "`"
    ) {
      i = stepTSLexer(source, i, isTsx, state)
      continue
    }
    if (ch === "/" && state.tplBraceStack.length === 0) {
      const next = stepTSLexer(source, i, isTsx, state)
      if (next > i + 1) {
        i = next
        continue
      }
    }
    if (openChar === "<" && ch === ">" && source[i - 1] === "=") {
      // Do not close `<...>` on arrow `=>`
      state.prevChar = ">"
      state.prevIdent = ""
      i++
      continue
    }
    if (ch === openChar) {
      depth++
      i = stepTSLexer(source, i, isTsx, state)
      continue
    }
    if (ch === closeChar) {
      depth--
      if (depth === 0) return i + 1
      i = stepTSLexer(source, i, isTsx, state)
      continue
    }
    i = stepTSLexer(source, i, isTsx, state)
  }
  return -1
}

/**
 * Unbounded balanced snippet extraction for TypeScript/TSX using the real TS/TSX lexical state machine.
 */
function extractBalancedSnippetTS(source: string, startIndex: number, isTsx: boolean): string {
  const n = source.length
  const state = createTSLexState()
  let seenOpenBrace = false
  let i = startIndex

  while (i < n) {
    const ch = source[i]!

    if (
      (ch === "/" && (source[i + 1] === "/" || source[i + 1] === "*")) ||
      ch === "'" ||
      ch === '"' ||
      ch === "`"
    ) {
      i = stepTSLexer(source, i, isTsx, state)
      continue
    }

    if (ch === "/") {
      const next = stepTSLexer(source, i, isTsx, state)
      i = next
      continue
    }

    if (ch === "{") {
      seenOpenBrace = true
      i = stepTSLexer(source, i, isTsx, state)
      continue
    }

    if (ch === "}") {
      const inTpl = state.tplBraceStack.length > 0 && state.braceDepth - 1 === state.tplBraceStack[state.tplBraceStack.length - 1]
      const next = stepTSLexer(source, i, isTsx, state)
      if (!inTpl && seenOpenBrace && state.braceDepth <= 0) {
        return source.slice(startIndex, i + 1)
      }
      i = next
      continue
    }

    if (ch === "\n" && !seenOpenBrace && state.parenDepth === 0 && state.braceDepth === 0 && state.tplBraceStack.length === 0) {
      const restLine = source.slice(startIndex, i).trim()
      if (
        restLine.length > 0 &&
        !restLine.endsWith("=") &&
        !restLine.endsWith("(") &&
        !restLine.endsWith(",") &&
        !restLine.endsWith("|") &&
        !restLine.endsWith("&") &&
        !restLine.endsWith("=>")
      ) {
        return source.slice(startIndex, i)
      }
      i++
      continue
    }

    i = stepTSLexer(source, i, isTsx, state)
  }

  return source.slice(startIndex)
}

/**
 * Extract a snippet starting at `startIndex` through the closing `}` matching `bodyOpenIdx`.
 */
function extractSnippetThroughBodyCloseTS(
  source: string,
  startIndex: number,
  bodyOpenIdx: number,
  isTsx: boolean,
): string {
  const afterClose = skipBalancedTS(source, bodyOpenIdx, "{", "}", isTsx)
  if (afterClose < 0) return extractBalancedSnippetTS(source, startIndex, isTsx)
  return source.slice(startIndex, afterClose)
}

/**
 * Extract the complete snippet of a destructured declaration `export const { ... } = <expr>`
 * by skipping past the LHS pattern and `=` and balancing the RHS expression.
 */
function extractDestructuredSnippetTS(
  source: string,
  startIndex: number,
  patternEndIndex: number,
  isTsx: boolean,
): string {
  let i = skipTSWhitespaceAndComments(source, patternEndIndex)
  // Skip optional type annotation `: ...` before `=`
  if (source[i] === ":") {
    i++
    const st = createTSLexState()
    while (i < source.length) {
      const ch = source[i]!
      if (ch === "=" && source[i + 1] !== ">" && source[i + 1] !== "=" && st.braceDepth === 0 && st.parenDepth === 0 && st.bracketDepth === 0) {
        break
      }
      i = stepTSLexer(source, i, isTsx, st)
    }
  }
  if (source[i] === "=") {
    const rhsStart = skipTSWhitespaceAndComments(source, i + 1)
    const rhs = extractBalancedSnippetTS(source, rhsStart, isTsx)
    return source.slice(startIndex, rhsStart + rhs.length)
  }
  return source.slice(startIndex, patternEndIndex)
}

/**
 * Find the opening `{` of a class body, skipping generics `<...>`, extends/implements expressions `(...)`, etc.
 */
function findClassBodyOpenTS(source: string, startIndex: number, isTsx: boolean): number {
  const n = source.length
  const state = createTSLexState()
  let angleDepth = 0
  let i = startIndex

  while (i < n) {
    const ch = source[i]!
    if (
      (ch === "/" && (source[i + 1] === "/" || source[i + 1] === "*")) ||
      ch === "'" ||
      ch === '"' ||
      ch === "`"
    ) {
      i = stepTSLexer(source, i, isTsx, state)
      continue
    }
    if (ch === "<" && state.parenDepth === 0 && state.bracketDepth === 0) {
      angleDepth++
      i = stepTSLexer(source, i, isTsx, state)
      continue
    }
    if (ch === ">" && state.parenDepth === 0 && state.bracketDepth === 0 && source[i - 1] !== "=") {
      angleDepth = Math.max(0, angleDepth - 1)
      i = stepTSLexer(source, i, isTsx, state)
      continue
    }
    if (ch === "{" && state.parenDepth === 0 && state.bracketDepth === 0 && angleDepth === 0 && state.braceDepth === 0) {
      return i
    }
    i = stepTSLexer(source, i, isTsx, state)
  }

  return -1
}

interface ParsedClassMethod {
  readonly name: string
  readonly hasBody: boolean
  readonly bodyOpenIdx: number
}

/**
 * Lexically parse a public class method, getter, or setter starting on `lineStart..lineEnd`.
 * Rejects `constructor`, `private`, `protected`, `readonly`, `#` / `_` prefixed names, and control keywords.
 */
function parseClassMethodAtLine(
  source: string,
  lineStart: number,
  lineEnd: number,
  isTsx: boolean,
): ParsedClassMethod | null {
  let i = lineStart
  while (i < lineEnd && (source[i] === " " || source[i] === "\t")) i++
  if (i >= lineEnd) return null
  const firstCh = source[i]!
  if (firstCh === "/" || firstCh === "*" || firstCh === "@" || firstCh === "}" || firstCh === ";") return null

  const modifiers = new Set<string>()
  let name = ""

  while (i < lineEnd) {
    while (i < lineEnd && (source[i] === " " || source[i] === "\t")) i++
    if (source[i] === "*") {
      i++
      continue
    }
    const m = source.slice(i, lineEnd).match(/^([A-Za-z_$#][\w$]*)/)
    if (!m) return null
    const tok = m[1]!
    const nextPos = i + tok.length
    let afterWs = nextPos
    while (afterWs < lineEnd && (source[afterWs] === " " || source[afterWs] === "\t")) afterWs++
    if (
      CLASS_METHOD_MODIFIERS.has(tok) &&
      afterWs > nextPos &&
      afterWs < lineEnd &&
      (source[afterWs] === "*" || /[A-Za-z_$#]/.test(source[afterWs]!))
    ) {
      modifiers.add(tok)
      i = afterWs
      continue
    }
    name = tok
    i = nextPos
    break
  }

  if (!name) return null
  if (modifiers.has("private") || modifiers.has("protected") || modifiers.has("readonly")) return null
  if (name.startsWith("#") || name.startsWith("_") || CLASS_METHOD_EXCLUDED_NAMES.has(name)) return null

  i = skipTSWhitespaceAndComments(source, i)
  if (source[i] === "?") {
    i = skipTSWhitespaceAndComments(source, i + 1)
  }
  if (source[i] === "<") {
    const afterGeneric = skipBalancedTS(source, i, "<", ">", isTsx)
    if (afterGeneric < 0) return null
    i = skipTSWhitespaceAndComments(source, afterGeneric)
  }
  if (source[i] !== "(") return null
  const afterParams = skipBalancedTS(source, i, "(", ")", isTsx)
  if (afterParams < 0) return null

  // Determine whether this declaration has an implementation body `{` (vs overload / abstract signature)
  let j = skipTSWhitespaceAndComments(source, afterParams)
  if (source[j] === "{") {
    return { name, hasBody: true, bodyOpenIdx: j }
  }
  if (source[j] === ":") {
    j++
    const state = createTSLexState()
    let angle = 0
    let prevTok = ":"
    while (j < source.length) {
      const ch = source[j]!
      if (ch === " " || ch === "\t" || ch === "\r") {
        j++
        continue
      }
      if (
        (ch === "/" && (source[j + 1] === "/" || source[j + 1] === "*")) ||
        ch === "'" ||
        ch === '"' ||
        ch === "`"
      ) {
        j = stepTSLexer(source, j, isTsx, state)
        if (ch === "'" || ch === '"' || ch === "`") prevTok = "V"
        continue
      }
      if (ch === "(") {
        state.parenDepth++
        prevTok = "("
        j++
        continue
      }
      if (ch === ")") {
        state.parenDepth = Math.max(0, state.parenDepth - 1)
        prevTok = ")"
        j++
        continue
      }
      if (ch === "[") {
        state.bracketDepth++
        prevTok = "["
        j++
        continue
      }
      if (ch === "]") {
        state.bracketDepth = Math.max(0, state.bracketDepth - 1)
        prevTok = "]"
        j++
        continue
      }
      if (ch === "<") {
        angle++
        prevTok = "<"
        j++
        continue
      }
      if (ch === ">" && source[j - 1] !== "=") {
        angle = Math.max(0, angle - 1)
        prevTok = ">"
        j++
        continue
      }
      if (ch === "=" && source[j + 1] === ">") {
        prevTok = "=>"
        j += 2
        continue
      }
      if (ch === "{") {
        if (
          state.parenDepth === 0 &&
          state.bracketDepth === 0 &&
          angle === 0 &&
          state.braceDepth === 0 &&
          prevTok !== ":" &&
          prevTok !== "|" &&
          prevTok !== "&" &&
          prevTok !== "=>"
        ) {
          return { name, hasBody: true, bodyOpenIdx: j }
        }
        state.braceDepth++
        prevTok = "{"
        j++
        continue
      }
      if (ch === "}") {
        if (state.braceDepth === 0) break
        state.braceDepth--
        prevTok = "}"
        j++
        continue
      }
      if (ch === ";" && state.parenDepth === 0 && state.bracketDepth === 0 && angle === 0 && state.braceDepth === 0) {
        return { name, hasBody: false, bodyOpenIdx: -1 }
      }
      if (ch === "\n" && state.parenDepth === 0 && state.bracketDepth === 0 && angle === 0 && state.braceDepth === 0) {
        const nextIdx = skipTSWhitespaceAndComments(source, j + 1)
        const nc = source[nextIdx]
        if (
          prevTok === ":" ||
          prevTok === "|" ||
          prevTok === "&" ||
          prevTok === "=>" ||
          prevTok === "," ||
          nc === "|" ||
          nc === "&" ||
          nc === "{"
        ) {
          j++
          continue
        }
        return { name, hasBody: false, bodyOpenIdx: -1 }
      }
      if (isIdentStart(ch)) {
        let k = j + 1
        while (k < source.length && isIdentPart(source[k]!)) k++
        const id = source.slice(j, k)
        prevTok = id === "is" || id === "asserts" || id === "extends" ? ":" : "I"
        j = k
        continue
      }
      prevTok = ch
      j++
    }
  }

  return { name, hasBody: false, bodyOpenIdx: -1 }
}

/**
 * Split a comma-separated TypeScript list at top-level (respecting nested {}, [], (), comments, strings).
 */
function splitTSCommaItems(text: string, isTsx: boolean): string[] {
  const items: string[] = []
  const state = createTSLexState()
  let start = 0
  let i = 0
  const n = text.length

  while (i < n) {
    const ch = text[i]!
    if (
      ch === "," &&
      state.braceDepth === 0 &&
      state.parenDepth === 0 &&
      state.bracketDepth === 0 &&
      state.tplBraceStack.length === 0
    ) {
      const piece = text.slice(start, i).trim()
      if (piece) items.push(piece)
      start = i + 1
      i++
      continue
    }
    i = stepTSLexer(text, i, isTsx, state)
  }

  const tail = text.slice(start).trim()
  if (tail) items.push(tail)
  return items
}

/**
 * Remove top-level comments from a small TS fragment (preserving string literals).
 */
function stripTSCommentsFragment(text: string): string {
  let out = ""
  let i = 0
  const n = text.length
  while (i < n) {
    const ch = text[i]!
    if (ch === "/" && text[i + 1] === "/") {
      i += 2
      while (i < n && text[i] !== "\n") i++
      continue
    }
    if (ch === "/" && text[i + 1] === "*") {
      i += 2
      while (i < n && !(text[i] === "*" && text[i + 1] === "/")) i++
      i = Math.min(n, i + 2)
      out += " "
      continue
    }
    if (ch === "'" || ch === '"') {
      const q = ch
      out += ch
      i++
      while (i < n) {
        if (text[i] === "\\" && i + 1 < n) {
          out += text.slice(i, i + 2)
          i += 2
          continue
        }
        out += text[i]
        if (text[i] === q) {
          i++
          break
        }
        i++
      }
      continue
    }
    out += ch
    i++
  }
  return out
}

/**
 * Strip a top-level `= defaultValue` suffix from a destructuring binding element.
 */
function stripDefaultInitializer(item: string, isTsx: boolean): string {
  const state = createTSLexState()
  let i = 0
  while (i < item.length) {
    const ch = item[i]!
    if (
      ch === "=" &&
      item[i + 1] !== ">" &&
      item[i + 1] !== "=" &&
      state.braceDepth === 0 &&
      state.parenDepth === 0 &&
      state.bracketDepth === 0 &&
      state.tplBraceStack.length === 0
    ) {
      return item.slice(0, i).trim()
    }
    i = stepTSLexer(item, i, isTsx, state)
  }
  return item.trim()
}

/**
 * Find the first top-level `:` in an object destructuring property `key: target`.
 */
function findTopLevelColon(item: string, isTsx: boolean): number {
  const state = createTSLexState()
  let i = 0
  while (i < item.length) {
    const ch = item[i]!
    if (
      ch === ":" &&
      state.braceDepth === 0 &&
      state.parenDepth === 0 &&
      state.bracketDepth === 0 &&
      state.tplBraceStack.length === 0
    ) {
      return i
    }
    i = stepTSLexer(item, i, isTsx, state)
  }
  return -1
}

/**
 * Recursively extract bound identifier names from an object `{ ... }` or array `[ ... ]` destructuring pattern.
 */
function extractDestructuredBindings(pattern: string, isTsx: boolean): string[] {
  const trimmed = stripTSCommentsFragment(pattern).trim()
  const out: string[] = []

  if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
    const inner = trimmed.slice(1, -1)
    for (const rawItem of splitTSCommaItems(inner, isTsx)) {
      const item = rawItem.trim()
      if (!item) continue
      if (item.startsWith("...")) {
        const restMatch = item.slice(3).trim().match(/^([A-Za-z_$][\w$]*)/)
        if (restMatch) out.push(restMatch[1]!)
        continue
      }
      const noDefault = stripDefaultInitializer(item, isTsx)
      const colonIdx = findTopLevelColon(noDefault, isTsx)
      if (colonIdx >= 0) {
        const target = stripDefaultInitializer(noDefault.slice(colonIdx + 1), isTsx)
        if (target.startsWith("{") || target.startsWith("[")) {
          out.push(...extractDestructuredBindings(target, isTsx))
        } else {
          const m = target.match(/^([A-Za-z_$][\w$]*)/)
          if (m) out.push(m[1]!)
        }
      } else {
        const m = noDefault.match(/^([A-Za-z_$][\w$]*)/)
        if (m) out.push(m[1]!)
      }
    }
    return out
  }

  if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
    const inner = trimmed.slice(1, -1)
    for (const rawItem of splitTSCommaItems(inner, isTsx)) {
      const item = rawItem.trim()
      if (!item) continue
      if (item.startsWith("...")) {
        const restMatch = item.slice(3).trim().match(/^([A-Za-z_$][\w$]*)/)
        if (restMatch) out.push(restMatch[1]!)
        continue
      }
      const noDefault = stripDefaultInitializer(item, isTsx)
      if (noDefault.startsWith("{") || noDefault.startsWith("[")) {
        out.push(...extractDestructuredBindings(noDefault, isTsx))
      } else {
        const m = noDefault.match(/^([A-Za-z_$][\w$]*)/)
        if (m) out.push(m[1]!)
      }
    }
    return out
  }

  return out
}

interface ParsedExportSpecifier {
  readonly localName: string
  readonly exportedName: string
  readonly isType: boolean
  readonly raw: string
}

function unquoteExportName(tok: string): string {
  const t = tok.trim()
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    return t.slice(1, -1)
  }
  return t
}

function parseExportListSpecifiers(inner: string, isTsx: boolean): ParsedExportSpecifier[] {
  const specs: ParsedExportSpecifier[] = []
  for (const rawEntry of splitTSCommaItems(inner, isTsx)) {
    const cleaned = stripTSCommentsFragment(rawEntry).trim()
    if (!cleaned) continue

    let isType = false
    let rest = cleaned
    const typePrefixMatch = rest.match(/^type\s+(?!as\b)(.+)$/)
    if (typePrefixMatch) {
      isType = true
      rest = typePrefixMatch[1]!.trim()
    }

    const asMatch = rest.match(/^([A-Za-z_$][\w$]*|"[^"]*"|'[^']*')\s+as\s+([A-Za-z_$][\w$]*|"[^"]*"|'[^']*)$/)
    if (asMatch) {
      const localName = unquoteExportName(asMatch[1]!)
      const exportedName = unquoteExportName(asMatch[2]!)
      specs.push({ localName, exportedName, isType, raw: cleaned })
    } else {
      const singleMatch = rest.match(/^([A-Za-z_$][\w$]*|"[^"]*"|'[^']*)$/)
      if (singleMatch) {
        const name = unquoteExportName(singleMatch[1]!)
        specs.push({ localName: name, exportedName: name, isType, raw: cleaned })
      }
    }
  }
  return specs
}

/**
 * Lexically scan top-level explicit external re-exports in a TS/TSX file:
 * - `export * as Ns from "..."` -> `"Ns"`
 * - `export { a, b as c, default as D } from "..."` -> `"a"`, `"c"`, `"D"` (ignoring `type`-only specifiers)
 * - `export * from "..."` -> (no explicit names)
 * Comments, strings, templates, and regexes are ignored accurately.
 */
function extractExternalReExports(source: string, isTsx: boolean): Set<string> {
  const reexports = new Set<string>()
  const state = createTSLexState()
  const n = source.length
  let i = 0

  while (i < n) {
    if (
      state.braceDepth === 0 &&
      state.parenDepth === 0 &&
      state.bracketDepth === 0 &&
      state.tplBraceStack.length === 0 &&
      source.startsWith("export", i) &&
      (i === 0 || !isIdentPart(source[i - 1]!)) &&
      (i + 6 >= n || !isIdentPart(source[i + 6]!))
    ) {
      let j = skipTSWhitespaceAndComments(source, i + 6)

      // `export type { ... } from "..."` -> type-only, Bun.Transpiler emits nothing; skip cleanly
      if (source.startsWith("type", j) && (j + 4 >= n || !isIdentPart(source[j + 4]!))) {
        const afterType = skipTSWhitespaceAndComments(source, j + 4)
        if (source[afterType] === "{") {
          const afterBrace = skipBalancedTS(source, afterType, "{", "}", isTsx)
          if (afterBrace > 0) {
            i = afterBrace
            continue
          }
        }
      }

      // `export * as Ns from "..."` or `export * from "..."`
      if (source[j] === "*") {
        j = skipTSWhitespaceAndComments(source, j + 1)
        if (source.startsWith("as", j) && (j + 2 >= n || !isIdentPart(source[j + 2]!))) {
          j = skipTSWhitespaceAndComments(source, j + 2)
          const nameMatch = source.slice(j).match(/^([A-Za-z_$][\w$]*|"[^"]*"|'[^']*')/)
          if (nameMatch) {
            const nsName = unquoteExportName(nameMatch[1]!)
            j = skipTSWhitespaceAndComments(source, j + nameMatch[1]!.length)
            if (source.startsWith("from", j) && (j + 4 >= n || !isIdentPart(source[j + 4]!))) {
              const afterFrom = skipTSWhitespaceAndComments(source, j + 4)
              if (source[afterFrom] === '"' || source[afterFrom] === "'") {
                reexports.add(nsName)
              }
            }
          }
        }
        i = stepTSLexer(source, i, isTsx, state)
        continue
      }

      // `export { ... } from "..."`
      if (source[j] === "{") {
        const afterBrace = skipBalancedTS(source, j, "{", "}", isTsx)
        if (afterBrace > 0) {
          const afterWs = skipTSWhitespaceAndComments(source, afterBrace)
          if (source.startsWith("from", afterWs) && (afterWs + 4 >= n || !isIdentPart(source[afterWs + 4]!))) {
            const afterFrom = skipTSWhitespaceAndComments(source, afterWs + 4)
            if (source[afterFrom] === '"' || source[afterFrom] === "'") {
              const inner = source.slice(j + 1, afterBrace - 1)
              for (const spec of parseExportListSpecifiers(inner, isTsx)) {
                if (!spec.isType) {
                  reexports.add(spec.exportedName)
                }
              }
              i = afterFrom
              continue
            }
          }
        }
      }
    }

    i = stepTSLexer(source, i, isTsx, state)
  }

  return reexports
}

/**
 * Compiler Export Completeness Gate helper (reused by both `scanner.ts` and `audit.ts`).
 * Runs `Bun.Transpiler.scan(source).exports` and returns any non-re-export local export name
 * missing from `emittedSymbols`.
 */
export function verifyFileExportsWithTranspiler(
  absPath: string,
  source: string,
  emittedSymbols: ReadonlySet<string> | readonly (string | Pick<UpstreamSymbol, "symbol">)[],
): string[] {
  const isTsx = absPath.endsWith(".tsx")
  const transpiler = isTsx ? TSX_TRANSPILER : TS_TRANSPILER
  const scannedExports = transpiler.scan(source).exports

  const emittedSet = new Set<string>()
  if (emittedSymbols instanceof Set) {
    for (const s of emittedSymbols) emittedSet.add(s)
  } else {
    for (const item of emittedSymbols) {
      emittedSet.add(typeof item === "string" ? item : item.symbol)
    }
  }

  const externalReExports = extractExternalReExports(source, isTsx)
  const missed: string[] = []
  for (const exp of scannedExports) {
    if (externalReExports.has(exp)) continue
    if (!emittedSet.has(exp)) {
      missed.push(exp)
    }
  }
  return missed.sort()
}

// ============================================================================
// Rust Lexical Helpers (process-daemon)
// ============================================================================

/**
 * Advance a single lexical step in Rust (handles //, nested block comments, strings, raw strings r#"..."#, char literals, lifetimes).
 */
function stepRustLexer(source: string, i: number): { next: number; kind: "comment" | "string" | "char" | "lifetime" | "code" } {
  const n = source.length
  const ch = source[i]!

  // Line comment
  if (ch === "/" && source[i + 1] === "/") {
    i += 2
    while (i < n && source[i] !== "\n") i++
    return { next: i, kind: "comment" }
  }

  // Nested block comment
  if (ch === "/" && source[i + 1] === "*") {
    i += 2
    let depth = 1
    while (i < n && depth > 0) {
      if (source[i] === "/" && source[i + 1] === "*") {
        depth++
        i += 2
      } else if (source[i] === "*" && source[i + 1] === "/") {
        depth--
        i += 2
      } else {
        i++
      }
    }
    return { next: i, kind: "comment" }
  }

  // Raw string literal: r"...", r#"..."#, br#"..."#, cr#"..."#
  if (
    (ch === "r" || ((ch === "b" || ch === "c") && source[i + 1] === "r")) &&
    (i === 0 || !/[A-Za-z0-9_]/.test(source[i - 1]!))
  ) {
    let j = ch === "r" ? i + 1 : i + 2
    let hashes = 0
    while (j < n && source[j] === "#") {
      hashes++
      j++
    }
    if (j < n && source[j] === '"') {
      j++
      while (j < n) {
        if (source[j] === '"') {
          let k = j + 1
          let matched = 0
          while (matched < hashes && k < n && source[k] === "#") {
            matched++
            k++
          }
          if (matched === hashes) {
            return { next: k, kind: "string" }
          }
        }
        j++
      }
      return { next: n, kind: "string" }
    }
  }

  // Standard string literal (also catches b"..." / c"..." once i reaches `"`)
  if (ch === '"') {
    i++
    while (i < n) {
      if (source[i] === "\\") {
        i += 2
        continue
      }
      if (source[i] === '"') {
        return { next: i + 1, kind: "string" }
      }
      i++
    }
    return { next: n, kind: "string" }
  }

  // Character literal vs lifetime ('a, 'static, '_)
  if (ch === "'") {
    if (source[i + 1] === "\\") {
      let j = i + 2
      while (j < n && source[j] !== "'" && source[j] !== "\n" && j - i < 16) j++
      if (j < n && source[j] === "'") {
        return { next: j + 1, kind: "char" }
      }
    } else if (i + 2 < n && source[i + 1] !== "'" && source[i + 1] !== "\n" && source[i + 2] === "'") {
      return { next: i + 3, kind: "char" }
    }
    let j = i + 1
    while (j < n && /[A-Za-z0-9_]/.test(source[j]!)) j++
    return { next: j, kind: "lifetime" }
  }

  return { next: i + 1, kind: "code" }
}

/**
 * Unbounded balanced snippet extraction for Rust using the real Rust lexer.
 */
function extractBalancedSnippetRust(source: string, startIndex: number): string {
  const n = source.length
  let braceDepth = 0
  let parenDepth = 0
  let seenOpenBrace = false
  let i = startIndex

  while (i < n) {
    const step = stepRustLexer(source, i)
    if (step.kind !== "code") {
      i = step.next
      continue
    }

    const ch = source[i]!
    if (ch === "(") {
      parenDepth++
    } else if (ch === ")") {
      parenDepth = Math.max(0, parenDepth - 1)
    } else if (ch === "{") {
      braceDepth++
      seenOpenBrace = true
    } else if (ch === "}") {
      braceDepth--
      if (seenOpenBrace && braceDepth <= 0) {
        return source.slice(startIndex, i + 1)
      }
    } else if (ch === "\n" && !seenOpenBrace && parenDepth === 0 && braceDepth === 0) {
      const restLine = source.slice(startIndex, i).trim()
      if (
        restLine.length > 0 &&
        !restLine.endsWith("=") &&
        !restLine.endsWith("(") &&
        !restLine.endsWith(",") &&
        !restLine.endsWith("|") &&
        !restLine.endsWith("&") &&
        !restLine.endsWith("=>") &&
        !restLine.endsWith("where")
      ) {
        return source.slice(startIndex, i)
      }
    }
    i = step.next
  }

  return source.slice(startIndex)
}

/**
 * Parse `impl [generics] [Trait for] TypeName[generics] [where ...] {` and return `{ typeName, bodyOpenOffset }`.
 */
function parseRustImplHeader(source: string, startIndex: number): { typeName: string; bodyOpenOffset: number } | null {
  const n = source.length
  let i = startIndex
  let paren = 0
  let bracket = 0
  let angle = 0
  let bodyOpenOffset = -1
  let headerCode = ""

  while (i < n) {
    const step = stepRustLexer(source, i)
    if (step.kind !== "code") {
      headerCode += " "
      i = step.next
      continue
    }
    const ch = source[i]!
    if (ch === "(") paren++
    else if (ch === ")") paren = Math.max(0, paren - 1)
    else if (ch === "[") bracket++
    else if (ch === "]") bracket = Math.max(0, bracket - 1)
    else if (ch === "<") angle++
    else if (ch === ">" && source[i - 1] !== "-" && source[i - 1] !== "=") angle = Math.max(0, angle - 1)
    else if (ch === "{" && paren === 0 && bracket === 0 && angle === 0) {
      bodyOpenOffset = i
      break
    } else if (ch === ";" && paren === 0 && bracket === 0 && angle === 0) {
      return null
    }
    headerCode += ch
    i = step.next
  }

  if (bodyOpenOffset < 0) return null

  // Strip `where ...` clause at top level
  let cleaned = headerCode.replace(/\s+/g, " ").trim()
  cleaned = cleaned.replace(/^(?:unsafe\s+)?impl\b/, "").trim()

  // Strip leading generic parameter list `<...>`
  if (cleaned.startsWith("<")) {
    let d = 0
    let k = 0
    while (k < cleaned.length) {
      if (cleaned[k] === "<") d++
      else if (cleaned[k] === ">") {
        d--
        if (d === 0) {
          cleaned = cleaned.slice(k + 1).trim()
          break
        }
      }
      k++
    }
  }

  // Strip trailing top-level `where ...`
  {
    let d = 0
    let p = 0
    for (let k = 0; k < cleaned.length; k++) {
      const ch = cleaned[k]!
      if (ch === "<") d++
      else if (ch === ">") d = Math.max(0, d - 1)
      else if (ch === "(") p++
      else if (ch === ")") p = Math.max(0, p - 1)
      else if (d === 0 && p === 0 && cleaned.slice(k).match(/^where\b/) && (k === 0 || !/\w/.test(cleaned[k - 1]!))) {
        cleaned = cleaned.slice(0, k).trim()
        break
      }
    }
  }

  // If `Trait for TypeName`, take everything after top-level `for`
  {
    let d = 0
    let p = 0
    for (let k = 0; k < cleaned.length; k++) {
      const ch = cleaned[k]!
      if (ch === "<") d++
      else if (ch === ">") d = Math.max(0, d - 1)
      else if (ch === "(") p++
      else if (ch === ")") p = Math.max(0, p - 1)
      else if (d === 0 && p === 0 && cleaned.slice(k).match(/^for\b/) && (k === 0 || !/\w/.test(cleaned[k - 1]!))) {
        cleaned = cleaned.slice(k + 3).trim()
        break
      }
    }
  }

  // Strip trailing `<...>` generic arguments from the target type and take final path segment
  const beforeAngle = cleaned.replace(/<[\s\S]*$/, "").trim()
  const segments = beforeAngle.split("::").map((s) => s.trim()).filter(Boolean)
  const lastSeg = segments[segments.length - 1] ?? ""
  const nameMatch = lastSeg.match(/([A-Za-z_][\w]*)$/)
  if (!nameMatch) return null
  return { typeName: nameMatch[1]!, bodyOpenOffset }
}

// ============================================================================
// File Walking & Classification
// ============================================================================

export function walkSourceFiles(dir: string, language: "ts" | "rs"): string[] {
  if (!fs.existsSync(dir)) return []
  const results: string[] = []
  const stack = [dir]
  while (stack.length > 0) {
    const current = stack.pop()!
    const entries = fs.readdirSync(current, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))
    for (const entry of entries) {
      if (entry.name === "node_modules" || entry.name === "__snapshots__" || entry.name.startsWith(".")) continue
      const full = path.join(current, entry.name)
      if (entry.isDirectory()) {
        stack.push(full)
      } else if (entry.isFile()) {
        if (language === "rs") {
          if (entry.name.endsWith(".rs")) results.push(full)
        } else {
          if (
            (entry.name.endsWith(".ts") || entry.name.endsWith(".tsx")) &&
            !entry.name.endsWith(".test.ts") &&
            !entry.name.endsWith(".test.tsx") &&
            !entry.name.endsWith(".d.ts") &&
            !entry.name.endsWith(".typecheck.ts")
          ) {
            results.push(full)
          }
        }
      }
    }
  }
  return results.sort()
}

function classifyConstKind(line: string): SymbolKind {
  if (/=\s*Effect\.fn\b/.test(line)) return "effect_function"
  if (/=\s*(?:async\s*)?(?:<[^>]+>\s*)?\([^)]*\)\s*(?::[^=]+)?=>/.test(line)) return "arrow_function"
  return "const"
}

function classifyDefaultExportKind(line: string): SymbolKind {
  if (/^export\s+default\s+(?:async\s+)?function\b/.test(line)) return "function"
  if (/^export\s+default\s+Effect\.fn\b/.test(line)) return "effect_function"
  if (
    /^export\s+default\s+(?:async\s*)?(?:<[^>]+>\s*)?\([^)]*\)\s*(?::[^=]+)?=>/.test(line) ||
    /^export\s+default\s+(?:async\s+)?[A-Za-z_$][\w$]*\s*=>/.test(line)
  ) {
    return "arrow_function"
  }
  if (/^export\s+default\s+(?:abstract\s+)?class\b/.test(line)) return "class"
  return "const"
}

// ============================================================================
// TypeScript / TSX File Scanner
// ============================================================================

interface LocalDeclInfo {
  readonly kind: SymbolKind
  readonly line: number
  readonly signature: string
  readonly snippet: string
}

interface DeferredLocalExportList {
  readonly isTypeExport: boolean
  readonly line: number
  readonly fullSnippet: string
  readonly specifiers: ParsedExportSpecifier[]
}

interface DeferredDefaultIdent {
  readonly localName: string
  readonly line: number
  readonly signature: string
  readonly fallbackSnippet: string
}

function scanTypeScriptFile(
  pkg: (typeof TRACKED_PACKAGES)[number],
  absPath: string,
  relFile: string,
): { symbols: UpstreamSymbol[]; lines: number; missedExports: string[] } {
  const source = fs.readFileSync(absPath, "utf8")
  const isTsx = absPath.endsWith(".tsx")
  const lines = source.split("\n")
  const lineOffsets: number[] = new Array(lines.length)
  let runningOffset = 0
  for (let i = 0; i < lines.length; i++) {
    lineOffsets[i] = runningOffset
    runningOffset += lines[i]!.length + 1
  }

  const symbols: UpstreamSymbol[] = []
  const symbolMetaById = new Map<string, { index: number; hasBody: boolean; isClassMethod: boolean }>()
  const localDecls = new Map<string, LocalDeclInfo>()
  const deferredExportLists: DeferredLocalExportList[] = []
  let deferredDefaultIdent: DeferredDefaultIdent | null = null

  function emitSymbol(sym: UpstreamSymbol, hasBody = true, isClassMethod = false): void {
    const existing = symbolMetaById.get(sym.id)
    if (!existing) {
      symbolMetaById.set(sym.id, { index: symbols.length, hasBody, isClassMethod })
      symbols.push(sym)
    } else if (existing.isClassMethod && !isClassMethod) {
      // Declaration-merged `export class Foo` + `export namespace Foo`: preserve namespace member at `Foo.member`
      // and keep the displaced instance method under `Foo.prototype.member` so neither symbol is lost.
      const prevSym = symbols[existing.index]!
      const dotIdx = prevSym.symbol.lastIndexOf(".")
      if (dotIdx > 0) {
        const protoSymbol = `${prevSym.symbol.slice(0, dotIdx)}.prototype.${prevSym.symbol.slice(dotIdx + 1)}`
        const protoId = `${prevSym.package}/${prevSym.file}#${protoSymbol}`
        if (!symbolMetaById.has(protoId)) {
          symbolMetaById.set(protoId, { index: symbols.length, hasBody: existing.hasBody, isClassMethod: true })
          symbols.push({ ...prevSym, id: protoId, symbol: protoSymbol })
        }
      }
      symbols[existing.index] = sym
      existing.hasBody = hasBody
      existing.isClassMethod = false
    } else if (!existing.hasBody && hasBody) {
      symbols[existing.index] = sym
      existing.hasBody = true
    }
  }

  const topExportRe =
    /^export\s+(?:(declare|abstract)\s+)?(?:(async)\s+)?(?:(const)\s+(enum)|(function|const|let|var|class|type|interface|enum|namespace)\*?)\s+([A-Za-z_$][\w$]*)/
  const nsMemberRe =
    /^\s+export\s+(?:(declare|abstract)\s+)?(?:(async)\s+)?(?:(const)\s+(enum)|(function|const|let|var|class|type|interface|enum|namespace)\*?)\s+([A-Za-z_$][\w$]*)/
  const localDeclRe =
    /^(?:(declare|abstract)\s+)?(?:(async)\s+)?(?:(const)\s+(enum)|(function|const|let|var|class|type|interface|enum|namespace)\*?)\s+([A-Za-z_$][\w$]*)/
  const exportDestructureRe = /^export\s+(?:declare\s+)?(?:const|let|var)\s+([{\[])/
  const localDestructureRe = /^(?:const|let|var)\s+([{\[])/
  const exportDefaultRe = /^export\s+default\b/
  const exportListRe = /^export\s+(?:(type)\s+)?\{/

  const lexState = createTSLexState()
  const namespaceStack: Array<{ name: string; bodyOpenOffset: number; bodyDepth: number; entered: boolean }> = []
  let activeClass: { name: string; bodyOpenOffset: number; bodyDepth: number; entered: boolean } | null = null

  let charIdx = 0
  const n = source.length

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!
    const lineNum = i + 1
    const lineStart = lineOffsets[i]!
    const lineEnd = lineStart + line.length

    const atCleanState =
      charIdx <= lineStart &&
      lexState.parenDepth === 0 &&
      lexState.bracketDepth === 0 &&
      lexState.tplBraceStack.length === 0

    if (atCleanState && lexState.braceDepth === 0) {
      // 1. Named top-level `export [declare|abstract] [async] (function|const|let|var|class|type|interface|enum|namespace) Name`
      const topMatch = line.match(topExportRe)
      if (topMatch) {
        const rawKind = topMatch[4] ? "enum" : topMatch[5]!
        const name = topMatch[6]!
        const kind: SymbolKind =
          rawKind === "let" || rawKind === "const" || rawKind === "var"
            ? classifyConstKind(line)
            : (rawKind as SymbolKind)
        const snippet = extractBalancedSnippetTS(source, lineStart, isTsx)
        const id = `${pkg.upstreamPackage}/${relFile}#${name}`
        emitSymbol({
          id,
          package: pkg.upstreamPackage,
          swiftTarget: pkg.swiftTarget,
          tier: pkg.tier,
          file: relFile,
          symbol: name,
          kind,
          line: lineNum,
          signature: line.trim().slice(0, 140),
          bodyHash: sha256Short(snippet),
        })
        if (rawKind === "namespace") {
          const openIdx = findClassBodyOpenTS(source, lineStart, isTsx)
          if (openIdx >= 0) {
            namespaceStack.push({ name, bodyOpenOffset: openIdx, bodyDepth: 1, entered: false })
          }
        } else if (rawKind === "class") {
          const openIdx = findClassBodyOpenTS(source, lineStart, isTsx)
          if (openIdx >= 0) {
            activeClass = { name, bodyOpenOffset: openIdx, bodyDepth: 1, entered: false }
          }
        }
      } else if (exportDefaultRe.test(line)) {
        // 2. `export default ...`
        const bareIdentMatch = line.match(/^export\s+default\s+([A-Za-z_$][\w$]*)\s*;?\s*(?:\/\/.*)?$/)
        if (bareIdentMatch && !["function", "async", "class", "abstract"].includes(bareIdentMatch[1]!)) {
          deferredDefaultIdent = {
            localName: bareIdentMatch[1]!,
            line: lineNum,
            signature: line.trim().slice(0, 140),
            fallbackSnippet: extractBalancedSnippetTS(source, lineStart, isTsx),
          }
        } else {
          const kind = classifyDefaultExportKind(line)
          const snippet = extractBalancedSnippetTS(source, lineStart, isTsx)
          const id = `${pkg.upstreamPackage}/${relFile}#default`
          emitSymbol({
            id,
            package: pkg.upstreamPackage,
            swiftTarget: pkg.swiftTarget,
            tier: pkg.tier,
            file: relFile,
            symbol: "default",
            kind,
            line: lineNum,
            signature: line.trim().slice(0, 140),
            bodyHash: sha256Short(snippet),
          })
          if (kind === "class") {
            const openIdx = findClassBodyOpenTS(source, lineStart, isTsx)
            if (openIdx >= 0) {
              activeClass = { name: "default", bodyOpenOffset: openIdx, bodyDepth: 1, entered: false }
            }
          }
        }
      } else if (exportDestructureRe.test(line)) {
        // 3. Destructured exports `export const { A, B } = ...` / `export const [A, B] = ...`
        const openChar = line.match(exportDestructureRe)![1]!
        const closeChar = openChar === "{" ? "}" : "]"
        const openIdx = lineStart + line.indexOf(openChar)
        const afterPattern = skipBalancedTS(source, openIdx, openChar, closeChar, isTsx)
        if (afterPattern > 0) {
          const patternText = source.slice(openIdx, afterPattern)
          const bindings = extractDestructuredBindings(patternText, isTsx)
          const fullSnippet = extractDestructuredSnippetTS(source, lineStart, afterPattern, isTsx)
          const bodyHash = sha256Short(fullSnippet)
          const signature = line.trim().slice(0, 140)
          for (const binding of bindings) {
            emitSymbol({
              id: `${pkg.upstreamPackage}/${relFile}#${binding}`,
              package: pkg.upstreamPackage,
              swiftTarget: pkg.swiftTarget,
              tier: pkg.tier,
              file: relFile,
              symbol: binding,
              kind: "const",
              line: lineNum,
              signature,
              bodyHash,
            })
          }
        }
      } else if (exportListRe.test(line)) {
        // 4. Local named export lists `export { a, b as c }` or `export type { Foo }` (WITHOUT `from "..."`)
        const listMatch = line.match(exportListRe)!
        const isTypeExport = Boolean(listMatch[1])
        const braceIdx = lineStart + line.indexOf("{")
        const afterBrace = skipBalancedTS(source, braceIdx, "{", "}", isTsx)
        if (afterBrace > 0) {
          const afterWs = skipTSWhitespaceAndComments(source, afterBrace)
          const isExternal =
            source.startsWith("from", afterWs) &&
            (afterWs + 4 >= n || !isIdentPart(source[afterWs + 4]!)) &&
            (() => {
              const quotePos = skipTSWhitespaceAndComments(source, afterWs + 4)
              return source[quotePos] === '"' || source[quotePos] === "'"
            })()
          if (!isExternal) {
            const inner = source.slice(braceIdx + 1, afterBrace - 1)
            const specifiers = parseExportListSpecifiers(inner, isTsx)
            deferredExportLists.push({
              isTypeExport,
              line: lineNum,
              fullSnippet: source.slice(lineStart, afterBrace),
              specifiers,
            })
          }
        }
      } else {
        // 5. Record non-exported local top-level declarations (for resolving `export { a, b as c }` / `export default a`)
        const localMatch = line.match(localDeclRe)
        if (localMatch) {
          const rawKind = localMatch[4] ? "enum" : localMatch[5]!
          const name = localMatch[6]!
          if (!localDecls.has(name)) {
            const kind: SymbolKind =
              rawKind === "let" || rawKind === "const" || rawKind === "var"
                ? classifyConstKind(line)
                : (rawKind as SymbolKind)
            localDecls.set(name, {
              kind,
              line: lineNum,
              signature: line.trim().slice(0, 140),
              snippet: extractBalancedSnippetTS(source, lineStart, isTsx),
            })
          }
        } else if (localDestructureRe.test(line)) {
          const openChar = line.match(localDestructureRe)![1]!
          const closeChar = openChar === "{" ? "}" : "]"
          const openIdx = lineStart + line.indexOf(openChar)
          const afterPattern = skipBalancedTS(source, openIdx, openChar, closeChar, isTsx)
          if (afterPattern > 0) {
            const patternText = source.slice(openIdx, afterPattern)
            const bindings = extractDestructuredBindings(patternText, isTsx)
            const fullSnippet = extractDestructuredSnippetTS(source, lineStart, afterPattern, isTsx)
            const signature = line.trim().slice(0, 140)
            for (const binding of bindings) {
              if (!localDecls.has(binding)) {
                localDecls.set(binding, {
                  kind: "const",
                  line: lineNum,
                  signature,
                  snippet: fullSnippet,
                })
              }
            }
          }
        }
      }
    } else if (atCleanState) {
      const currentNs = namespaceStack.length > 0 ? namespaceStack[namespaceStack.length - 1]! : null
      if (activeClass && activeClass.entered && lexState.braceDepth === activeClass.bodyDepth) {
        // Class public methods / getters / setters
        const parsed = parseClassMethodAtLine(source, lineStart, lineEnd, isTsx)
        if (parsed) {
          const fullName = `${activeClass.name}.${parsed.name}`
          const snippet =
            parsed.hasBody && parsed.bodyOpenIdx >= 0
              ? extractSnippetThroughBodyCloseTS(source, lineStart, parsed.bodyOpenIdx, isTsx)
              : extractBalancedSnippetTS(source, lineStart, isTsx)
          emitSymbol(
            {
              id: `${pkg.upstreamPackage}/${relFile}#${fullName}`,
              package: pkg.upstreamPackage,
              swiftTarget: pkg.swiftTarget,
              tier: pkg.tier,
              file: relFile,
              symbol: fullName,
              kind: "method",
              line: lineNum,
              signature: line.trim().slice(0, 140),
              bodyHash: sha256Short(snippet),
            },
            parsed.hasBody,
            true,
          )
        }
      } else if (currentNs && currentNs.entered && lexState.braceDepth === currentNs.bodyDepth) {
        // Namespace exported members
        const m = line.match(nsMemberRe)
        if (m) {
          const rawKind = m[4] ? "enum" : m[5]!
          const memberName = m[6]!
          const nsPrefix = namespaceStack.map((ns) => ns.name).join(".")
          const fullName = `${nsPrefix}.${memberName}`
          const kind: SymbolKind =
            rawKind === "function"
              ? "namespace_function"
              : rawKind === "let" || rawKind === "const" || rawKind === "var"
                ? classifyConstKind(line)
                : (rawKind as SymbolKind)
          const snippet = extractBalancedSnippetTS(source, lineStart, isTsx)
          emitSymbol({
            id: `${pkg.upstreamPackage}/${relFile}#${fullName}`,
            package: pkg.upstreamPackage,
            swiftTarget: pkg.swiftTarget,
            tier: pkg.tier,
            file: relFile,
            symbol: fullName,
            kind,
            line: lineNum,
            signature: line.trim().slice(0, 140),
            bodyHash: sha256Short(snippet),
          })
          if (rawKind === "namespace") {
            const openIdx = findClassBodyOpenTS(source, lineStart, isTsx)
            if (openIdx >= 0) {
              namespaceStack.push({
                name: memberName,
                bodyOpenOffset: openIdx,
                bodyDepth: lexState.braceDepth + 1,
                entered: false,
              })
            }
          } else if (rawKind === "class") {
            const openIdx = findClassBodyOpenTS(source, lineStart, isTsx)
            if (openIdx >= 0) {
              activeClass = {
                name: fullName,
                bodyOpenOffset: openIdx,
                bodyDepth: lexState.braceDepth + 1,
                entered: false,
              }
            }
          }
        }
      }
    }

    // Advance lexical state across this line (including trailing newline)
    const stop = Math.min(n, lineEnd + 1)
    while (charIdx < stop) {
      if (activeClass && !activeClass.entered && charIdx === activeClass.bodyOpenOffset) {
        activeClass.entered = true
        activeClass.bodyDepth = lexState.braceDepth + 1
      }
      const topNs = namespaceStack.length > 0 ? namespaceStack[namespaceStack.length - 1]! : null
      if (topNs && !topNs.entered && charIdx === topNs.bodyOpenOffset) {
        topNs.entered = true
        topNs.bodyDepth = lexState.braceDepth + 1
      }

      charIdx = stepTSLexer(source, charIdx, isTsx, lexState)

      if (activeClass && activeClass.entered && lexState.braceDepth < activeClass.bodyDepth) {
        activeClass = null
      }
      while (
        namespaceStack.length > 0 &&
        namespaceStack[namespaceStack.length - 1]!.entered &&
        lexState.braceDepth < namespaceStack[namespaceStack.length - 1]!.bodyDepth
      ) {
        namespaceStack.pop()
      }
    }
  }

  // Resolve deferred `export default <ident>` after collecting all local declarations (supports hoisting)
  if (deferredDefaultIdent) {
    const local = localDecls.get(deferredDefaultIdent.localName)
    const kind: SymbolKind = local ? local.kind : "const"
    const snippet = local ? local.snippet : deferredDefaultIdent.fallbackSnippet
    const line = local ? local.line : deferredDefaultIdent.line
    const signature = local ? local.signature : deferredDefaultIdent.signature
    emitSymbol({
      id: `${pkg.upstreamPackage}/${relFile}#default`,
      package: pkg.upstreamPackage,
      swiftTarget: pkg.swiftTarget,
      tier: pkg.tier,
      file: relFile,
      symbol: "default",
      kind,
      line,
      signature,
      bodyHash: sha256Short(snippet),
    })
  }

  // Resolve deferred local `export { a, b as c }` / `export type { Foo }`
  for (const list of deferredExportLists) {
    for (const spec of list.specifiers) {
      const local = localDecls.get(spec.localName)
      const isType = list.isTypeExport || spec.isType
      const kind: SymbolKind = isType ? "type" : local ? local.kind : "const"
      const snippet = local ? local.snippet : list.fullSnippet
      const line = local ? local.line : list.line
      const signature = local
        ? local.signature
        : `${isType ? "export type" : "export"} { ${spec.raw} }`.slice(0, 140)
      emitSymbol({
        id: `${pkg.upstreamPackage}/${relFile}#${spec.exportedName}`,
        package: pkg.upstreamPackage,
        swiftTarget: pkg.swiftTarget,
        tier: pkg.tier,
        file: relFile,
        symbol: spec.exportedName,
        kind,
        line,
        signature,
        bodyHash: sha256Short(snippet),
      })
    }
  }

  const missedExports = verifyFileExportsWithTranspiler(absPath, source, symbols)
  return { symbols, lines: lines.length, missedExports }
}

// ============================================================================
// Rust File Scanner (process-daemon)
// ============================================================================

function scanRustFile(
  pkg: (typeof TRACKED_PACKAGES)[number],
  absPath: string,
  relFile: string,
): { symbols: UpstreamSymbol[]; lines: number } {
  const source = fs.readFileSync(absPath, "utf8")
  const lines = source.split("\n")
  const lineOffsets: number[] = new Array(lines.length)
  let runningOffset = 0
  for (let i = 0; i < lines.length; i++) {
    lineOffsets[i] = runningOffset
    runningOffset += lines[i]!.length + 1
  }

  const symbols: UpstreamSymbol[] = []
  const seen = new Set<string>()

  const pubRe =
    /^\s*pub(?:\([^)]*\))?\s+(?:(?:const|async|unsafe)\s+)*(?:extern(?:\s+"[^"]*")?\s+)?(fn|struct|enum|trait|type|const)\s+([A-Za-z_][\w]*)/
  const implStartRe = /^\s*(?:unsafe\s+)?impl\b/

  let braceDepth = 0
  let parenDepth = 0
  let bracketDepth = 0
  const implStack: Array<{ typeName: string; bodyOpenOffset: number; bodyDepth: number; entered: boolean }> = []
  let charIdx = 0
  const n = source.length

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!
    const lineNum = i + 1
    const lineStart = lineOffsets[i]!
    const lineEnd = lineStart + line.length

    if (charIdx <= lineStart && parenDepth === 0 && bracketDepth === 0) {
      if (implStartRe.test(line)) {
        const parsedImpl = parseRustImplHeader(source, lineStart)
        if (parsedImpl) {
          implStack.push({
            typeName: parsedImpl.typeName,
            bodyOpenOffset: parsedImpl.bodyOpenOffset,
            bodyDepth: braceDepth + 1,
            entered: false,
          })
        }
      }

      const m = line.match(pubRe)
      if (m) {
        const rawKind = m[1]!
        const name = m[2]!
        const kind = `rust_${rawKind}` as SymbolKind
        const activeImpl =
          implStack.length > 0 && implStack[implStack.length - 1]!.entered
            ? implStack[implStack.length - 1]!
            : null

        const baseId = `${pkg.upstreamPackage}/${relFile}#${name}`
        let emittedId: string | null = null
        let emittedSymbol = name

        if (!seen.has(baseId)) {
          emittedId = baseId
        } else if (activeImpl) {
          const qualifiedSymbol = `${activeImpl.typeName}.${name}`
          const qualifiedId = `${pkg.upstreamPackage}/${relFile}#${qualifiedSymbol}`
          if (!seen.has(qualifiedId)) {
            emittedId = qualifiedId
            emittedSymbol = qualifiedSymbol
          }
        }

        if (emittedId) {
          seen.add(emittedId)
          const snippet = extractBalancedSnippetRust(source, lineStart)
          symbols.push({
            id: emittedId,
            package: pkg.upstreamPackage,
            swiftTarget: pkg.swiftTarget,
            tier: pkg.tier,
            file: relFile,
            symbol: emittedSymbol,
            kind,
            line: lineNum,
            signature: line.trim().slice(0, 140),
            bodyHash: sha256Short(snippet),
          })
        }
      }
    }

    const stop = Math.min(n, lineEnd + 1)
    while (charIdx < stop) {
      const topImpl = implStack.length > 0 ? implStack[implStack.length - 1]! : null
      if (topImpl && !topImpl.entered && charIdx === topImpl.bodyOpenOffset) {
        topImpl.entered = true
        topImpl.bodyDepth = braceDepth + 1
      }

      const step = stepRustLexer(source, charIdx)
      if (step.kind === "code") {
        const ch = source[charIdx]!
        if (ch === "{") braceDepth++
        else if (ch === "}") braceDepth = Math.max(0, braceDepth - 1)
        else if (ch === "(") parenDepth++
        else if (ch === ")") parenDepth = Math.max(0, parenDepth - 1)
        else if (ch === "[") bracketDepth++
        else if (ch === "]") bracketDepth = Math.max(0, bracketDepth - 1)
      }
      charIdx = step.next

      while (
        implStack.length > 0 &&
        implStack[implStack.length - 1]!.entered &&
        braceDepth < implStack[implStack.length - 1]!.bodyDepth
      ) {
        implStack.pop()
      }
    }
  }

  return { symbols, lines: lines.length }
}

function findLineOffset(source: string, lineNumber: number): number {
  if (lineNumber <= 1) return 0
  let currentLine = 1
  for (let i = 0; i < source.length; i++) {
    if (source[i] === "\n") {
      currentLine++
      if (currentLine === lineNumber) return i + 1
    }
  }
  return source.length
}

function isTSBlockBodyEmpty(source: string, openBraceIdx: number, isTsx: boolean): boolean {
  if (source[openBraceIdx] !== "{") return false
  let i = skipTSWhitespaceAndComments(source, openBraceIdx + 1)
  return source[i] === "}"
}

function findTSBodyAfterParams(source: string, afterParamsIdx: number, isTsx: boolean): number {
  let j = skipTSWhitespaceAndComments(source, afterParamsIdx)
  if (source[j] === "{") return j
  if (source[j] !== ":") return -1
  j++
  const state = createTSLexState()
  let angle = 0
  let prevTok = ":"
  while (j < source.length) {
    const ch = source[j]!
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
      j++
      continue
    }
    if (
      (ch === "/" && (source[j + 1] === "/" || source[j + 1] === "*")) ||
      ch === "'" ||
      ch === '"' ||
      ch === "`"
    ) {
      j = stepTSLexer(source, j, isTsx, state)
      if (ch === "'" || ch === '"' || ch === "`") prevTok = "V"
      continue
    }
    if (ch === "(") {
      state.parenDepth++
      prevTok = "("
      j++
      continue
    }
    if (ch === ")") {
      state.parenDepth = Math.max(0, state.parenDepth - 1)
      prevTok = ")"
      j++
      continue
    }
    if (ch === "[") {
      state.bracketDepth++
      prevTok = "["
      j++
      continue
    }
    if (ch === "]") {
      state.bracketDepth = Math.max(0, state.bracketDepth - 1)
      prevTok = "]"
      j++
      continue
    }
    if (ch === "<") {
      angle++
      prevTok = "<"
      j++
      continue
    }
    if (ch === ">" && source[j - 1] !== "=") {
      angle = Math.max(0, angle - 1)
      prevTok = ">"
      j++
      continue
    }
    if (ch === "=" && source[j + 1] === ">") {
      prevTok = "=>"
      j += 2
      continue
    }
    if (ch === "{") {
      if (
        state.parenDepth === 0 &&
        state.bracketDepth === 0 &&
        angle === 0 &&
        state.braceDepth === 0 &&
        prevTok !== ":" &&
        prevTok !== "|" &&
        prevTok !== "&" &&
        prevTok !== "=>"
      ) {
        return j
      }
      state.braceDepth++
      prevTok = "{"
      j++
      continue
    }
    if (ch === "}") {
      if (state.braceDepth === 0) return -1
      state.braceDepth--
      prevTok = "}"
      j++
      continue
    }
    if (ch === ";" && state.parenDepth === 0 && state.bracketDepth === 0 && angle === 0 && state.braceDepth === 0) {
      return -1
    }
    if (isIdentStart(ch)) {
      let k = j + 1
      while (k < source.length && isIdentPart(source[k]!)) k++
      const id = source.slice(j, k)
      prevTok = id === "is" || id === "asserts" || id === "extends" ? ":" : "I"
      j = k
      continue
    }
    prevTok = ch
    j++
  }
  return -1
}

/**
 * Determine whether an upstream function declaration at 1-based `line` has an empty `{}` body
 * (ignoring comments and whitespace). Used by Gate 11 in `audit.ts`.
 */
export function isUpstreamFunctionBodyEmpty(
  source: string,
  line: number,
  kind: SymbolKind,
  isTsx: boolean,
): boolean {
  const start = findLineOffset(source, line)
  const n = source.length

  if (kind === "rust_fn") {
    let i = start
    let paren = 0
    let bracket = 0
    let bodyOpen = -1
    while (i < n) {
      const step = stepRustLexer(source, i)
      if (step.kind !== "code") {
        i = step.next
        continue
      }
      const ch = source[i]!
      if (ch === "(") paren++
      else if (ch === ")") paren = Math.max(0, paren - 1)
      else if (ch === "[") bracket++
      else if (ch === "]") bracket = Math.max(0, bracket - 1)
      else if (ch === "{" && paren === 0 && bracket === 0) {
        bodyOpen = i
        break
      } else if (ch === ";" && paren === 0 && bracket === 0) {
        return false
      }
      i = step.next
    }
    if (bodyOpen < 0) return false
    i = bodyOpen + 1
    while (i < n) {
      const ch = source[i]!
      if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
        i++
        continue
      }
      const step = stepRustLexer(source, i)
      if (step.kind === "comment") {
        i = step.next
        continue
      }
      return ch === "}"
    }
    return false
  }

  if (kind === "function" || kind === "namespace_function" || kind === "method") {
    let i = start
    const state = createTSLexState()
    while (i < n) {
      const ch = source[i]!
      if (ch === "<" && state.parenDepth === 0 && state.bracketDepth === 0 && state.braceDepth === 0) {
        const afterGeneric = skipBalancedTS(source, i, "<", ">", isTsx)
        if (afterGeneric > 0) {
          i = afterGeneric
          continue
        }
      }
      if (ch === "(" && state.parenDepth === 0 && state.bracketDepth === 0 && state.braceDepth === 0) {
        const afterParams = skipBalancedTS(source, i, "(", ")", isTsx)
        if (afterParams < 0) return false
        const bodyOpen = findTSBodyAfterParams(source, afterParams, isTsx)
        if (bodyOpen < 0) return false
        return isTSBlockBodyEmpty(source, bodyOpen, isTsx)
      }
      i = stepTSLexer(source, i, isTsx, state)
    }
    return false
  }

  if (kind === "arrow_function") {
    let i = start
    const state = createTSLexState()
    // Advance past top-level `=` (assignment), then locate top-level `=>`
    let seenAssign = false
    while (i < n) {
      const ch = source[i]!
      if (
        !seenAssign &&
        ch === "=" &&
        source[i + 1] !== ">" &&
        source[i + 1] !== "=" &&
        state.parenDepth === 0 &&
        state.bracketDepth === 0 &&
        state.braceDepth === 0
      ) {
        seenAssign = true
        i++
        continue
      }
      if (
        seenAssign &&
        ch === "=" &&
        source[i + 1] === ">" &&
        state.parenDepth === 0 &&
        state.bracketDepth === 0 &&
        state.braceDepth === 0
      ) {
        const afterArrow = skipTSWhitespaceAndComments(source, i + 2)
        if (source[afterArrow] === "{") {
          return isTSBlockBodyEmpty(source, afterArrow, isTsx)
        }
        return false
      }
      i = stepTSLexer(source, i, isTsx, state)
    }
    return false
  }

  if (kind === "effect_function") {
    let i = start
    const state = createTSLexState()
    while (i < n) {
      if (
        source.startsWith("function", i) &&
        (i === 0 || !isIdentPart(source[i - 1]!)) &&
        (i + 8 >= n || !isIdentPart(source[i + 8]!))
      ) {
        let j = i + 8
        while (j < n && source[j] !== "(") j = stepTSLexer(source, j, isTsx, createTSLexState())
        if (source[j] === "(") {
          const afterParams = skipBalancedTS(source, j, "(", ")", isTsx)
          if (afterParams < 0) return false
          const bodyOpen = findTSBodyAfterParams(source, afterParams, isTsx)
          if (bodyOpen < 0) return false
          return isTSBlockBodyEmpty(source, bodyOpen, isTsx)
        }
      }
      i = stepTSLexer(source, i, isTsx, state)
    }
    return false
  }

  return false
}

export function isFunctionLikeKind(kind: SymbolKind): boolean {
  return (
    kind === "function" ||
    kind === "namespace_function" ||
    kind === "arrow_function" ||
    kind === "effect_function" ||
    kind === "method" ||
    kind === "rust_fn"
  )
}

export async function runScan(): Promise<UpstreamManifest> {
  if (!fs.existsSync(UPSTREAM_DIR)) {
    throw new Error(`Missing upstream checkout at ${UPSTREAM_DIR}. Run ./scripts/sync-upstream.sh first.`)
  }
  const lock = await Bun.file(LOCK_FILE).json()
  const symbols: UpstreamSymbol[] = []
  const byPackage: Record<string, { files: number; symbols: number; functions: number; lines: number }> = {}
  const compilerExportFailures: Array<{ file: string; missed: string[] }> = []
  let totalFiles = 0

  const external: Array<{ package: string; repository: string; tag?: string; commit: string; commitDate: string }> = []
  for (const pkg of TRACKED_PACKAGES) {
    const pkgRoot = packageRoot(ROOT_DIR, pkg)
    if (pkg.external) {
      if (!fs.existsSync(path.join(pkgRoot, "src"))) {
        throw new Error(`Missing ${pkg.upstreamPackage} checkout at ${pkgRoot}. Run ./scripts/parity.sh sync first.`)
      }
      const extLock = await Bun.file(path.join(ROOT_DIR, pkg.external.lockFile)).json()
      external.push({
        package: pkg.upstreamPackage,
        repository: extLock.repository,
        tag: extLock.tag,
        commit: extLock.commit,
        commitDate: extLock.commitDate,
      })
    }
    const srcRoot = path.join(pkgRoot, "src")
    const files = walkSourceFiles(srcRoot, pkg.language)
    let pkgSymbols = 0
    let pkgFunctions = 0
    let pkgLines = 0

    for (const absPath of files) {
      const relFile = path.relative(pkgRoot, absPath).split(path.sep).join("/")
      if (pkg.language === "rs") {
        const scanned = scanRustFile(pkg, absPath, relFile)
        symbols.push(...scanned.symbols)
        pkgSymbols += scanned.symbols.length
        pkgFunctions += scanned.symbols.filter((s) => isFunctionLikeKind(s.kind)).length
        pkgLines += scanned.lines
      } else {
        const scanned = scanTypeScriptFile(pkg, absPath, relFile)
        if (scanned.missedExports.length > 0) {
          compilerExportFailures.push({
            file: `${pkg.upstreamPackage}/${relFile}`,
            missed: scanned.missedExports,
          })
        }
        symbols.push(...scanned.symbols)
        pkgSymbols += scanned.symbols.length
        pkgFunctions += scanned.symbols.filter((s) => isFunctionLikeKind(s.kind)).length
        pkgLines += scanned.lines
      }
    }

    totalFiles += files.length
    byPackage[pkg.upstreamPackage] = {
      files: files.length,
      symbols: pkgSymbols,
      functions: pkgFunctions,
      lines: pkgLines,
    }
  }

  if (compilerExportFailures.length > 0) {
    const totalMissed = compilerExportFailures.reduce((acc, f) => acc + f.missed.length, 0)
    console.error(
      `\nCompiler Export Completeness Gate FAILED: ${totalMissed} missed local export(s) across ${compilerExportFailures.length} file(s):`,
    )
    for (const failure of compilerExportFailures) {
      console.error(`  ${failure.file}: ${failure.missed.join(", ")}`)
    }
    throw new Error(
      `Compiler Export Completeness Gate failed with ${totalMissed} missed local export(s) in ${compilerExportFailures.length} file(s)`,
    )
  }

  const manifest: UpstreamManifest = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    upstream: {
      repository: lock.repository,
      branch: lock.branch,
      commit: lock.commit,
      commitDate: lock.commitDate,
      commitSubject: lock.commitSubject,
      external,
    },
    summary: {
      totalPackages: TRACKED_PACKAGES.length,
      totalFiles,
      totalSymbols: symbols.length,
      totalFunctions: symbols.filter((s) => isFunctionLikeKind(s.kind)).length,
      byPackage,
      excludedWebToolingPackages: OUT_OF_SCOPE_WEB_PACKAGES,
    },
    symbols,
  }

  fs.mkdirSync(path.dirname(MANIFEST_PATH), { recursive: true })
  await Bun.write(MANIFEST_PATH, JSON.stringify(manifest, null, 2) + "\n")
  return manifest
}

if (import.meta.main) {
  const manifest = await runScan()
  console.log(
    `Scanned ${manifest.summary.totalPackages} upstream packages (${manifest.summary.totalFiles} files, ${manifest.summary.totalSymbols} symbols, ${manifest.summary.totalFunctions} functions) -> parity/upstream-manifest.json`,
  )
}
