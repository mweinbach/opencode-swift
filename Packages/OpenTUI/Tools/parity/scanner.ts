import path from "path"
import fs from "fs"
import { OUT_OF_SCOPE_OPENTUI_PACKAGES, TRACKED_OPENTUI_PACKAGES, type OpenTUITier } from "./config.ts"

export type SymbolKind =
  | "function"
  | "arrow_function"
  | "class"
  | "method"
  | "const"
  | "type"
  | "interface"
  | "enum"
  | "namespace"
  | "zig_fn"
  | "zig_const"

export interface UpstreamSymbol {
  readonly id: string
  readonly package: string
  readonly swiftTarget: string
  readonly tier: OpenTUITier
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
  }
  readonly summary: {
    readonly totalPackages: number
    readonly totalFiles: number
    readonly totalSymbols: number
    readonly totalFunctions: number
    readonly byPackage: Record<string, { files: number; symbols: number; functions: number; lines: number }>
    readonly excludedPackages: readonly string[]
  }
  readonly symbols: UpstreamSymbol[]
}

const PKG_DIR = path.resolve(import.meta.dir, "../..")
const UPSTREAM_DIR = fs.existsSync(path.join(PKG_DIR, "upstream/opentui"))
  ? path.join(PKG_DIR, "upstream/opentui")
  : path.resolve(PKG_DIR, "../../upstream/opentui")
const LOCK_FILE = path.join(PKG_DIR, "upstream.lock.json")
const MANIFEST_PATH = path.join(PKG_DIR, "parity/upstream-manifest.json")

const REGEX_PRECEDING_KEYWORDS = new Set([
  "return",
  "case",
  "throw",
  "in",
  "of",
  "typeof",
  "void",
  "delete",
  "yield",
  "await",
  "new",
  "else",
  "do",
  "extends",
  "instanceof",
  "export",
  "default",
])

const EXCLUDED_CLASS_METHOD_NAMES = new Set(["constructor", "if", "for", "while", "switch", "catch"])

function sha256Short(text: string): string {
  const normalized = text.replace(/\r\n/g, "\n").replace(/[ \t]+/g, " ").trim()
  const hasher = new Bun.CryptoHasher("sha256")
  hasher.update(normalized)
  return hasher.digest("hex").slice(0, 12)
}

function isIdentStart(ch: string): boolean {
  return (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") || ch === "_" || ch === "$"
}

function isIdentPart(ch: string): boolean {
  return isIdentStart(ch) || (ch >= "0" && ch <= "9")
}

function canStartRegex(prevToken: string, prevChar: string): boolean {
  if (prevChar === "<") return false
  if (prevToken === "") return true
  if (REGEX_PRECEDING_KEYWORDS.has(prevToken)) return true
  if (prevToken === "=>") return true
  if (prevChar !== "" && "([{,;:=?!&|^~+*%".includes(prevChar)) return true
  if (prevChar === "-" && prevToken !== "--") return true
  return false
}

// ---------------------------------------------------------------------------
// Shared TypeScript / TSX Lexical State Machine
// ---------------------------------------------------------------------------

interface TSLexerState {
  inLineComment: boolean
  inBlockComment: boolean
  inSingle: boolean
  inDouble: boolean
  inTemplate: boolean
  inRegex: boolean
  inRegexClass: boolean
  templateBraceStack: number[]
  prevToken: string
  prevChar: string
}

interface TSLexStep {
  readonly nextIndex: number
  readonly kind: "comment" | "literal" | "template_expr_brace" | "code"
  readonly token?: string
  readonly isIdent?: boolean
  readonly openedString?: boolean
  readonly closedString?: boolean
  readonly endedLineCommentAtNewline?: boolean
}

function createTSLexerState(): TSLexerState {
  return {
    inLineComment: false,
    inBlockComment: false,
    inSingle: false,
    inDouble: false,
    inTemplate: false,
    inRegex: false,
    inRegexClass: false,
    templateBraceStack: [],
    prevToken: "",
    prevChar: "",
  }
}

function stepTSLexer(state: TSLexerState, source: string, i: number): TSLexStep {
  const ch = source[i]!
  const next = source[i + 1] ?? ""

  if (state.inLineComment) {
    if (ch === "\n") {
      state.inLineComment = false
      return { nextIndex: i + 1, kind: "comment", endedLineCommentAtNewline: true }
    }
    return { nextIndex: i + 1, kind: "comment" }
  }

  if (state.inBlockComment) {
    if (ch === "*" && next === "/") {
      state.inBlockComment = false
      return { nextIndex: i + 2, kind: "comment" }
    }
    return { nextIndex: i + 1, kind: "comment" }
  }

  if (state.inSingle) {
    if (ch === "\\" && i + 1 < source.length) return { nextIndex: i + 2, kind: "literal" }
    if (ch === "'") {
      state.inSingle = false
      state.prevToken = "lit"
      state.prevChar = "'"
      return { nextIndex: i + 1, kind: "literal", closedString: true }
    }
    return { nextIndex: i + 1, kind: "literal" }
  }

  if (state.inDouble) {
    if (ch === "\\" && i + 1 < source.length) return { nextIndex: i + 2, kind: "literal" }
    if (ch === '"') {
      state.inDouble = false
      state.prevToken = "lit"
      state.prevChar = '"'
      return { nextIndex: i + 1, kind: "literal", closedString: true }
    }
    return { nextIndex: i + 1, kind: "literal" }
  }

  if (state.inRegex) {
    if (ch === "\\" && i + 1 < source.length) return { nextIndex: i + 2, kind: "literal" }
    if (ch === "\n") {
      state.inRegex = false
      state.inRegexClass = false
      return { nextIndex: i + 1, kind: "literal" }
    }
    if (ch === "[") {
      state.inRegexClass = true
      return { nextIndex: i + 1, kind: "literal" }
    }
    if (ch === "]") {
      state.inRegexClass = false
      return { nextIndex: i + 1, kind: "literal" }
    }
    if (ch === "/" && !state.inRegexClass) {
      state.inRegex = false
      state.prevToken = "lit"
      state.prevChar = "/"
      return { nextIndex: i + 1, kind: "literal" }
    }
    return { nextIndex: i + 1, kind: "literal" }
  }

  if (state.inTemplate) {
    if (ch === "\\" && i + 1 < source.length) return { nextIndex: i + 2, kind: "literal" }
    if (ch === "`") {
      state.inTemplate = false
      state.prevToken = "lit"
      state.prevChar = "`"
      return { nextIndex: i + 1, kind: "literal" }
    }
    if (ch === "$" && next === "{") {
      state.inTemplate = false
      state.templateBraceStack.push(0)
      state.prevToken = "{"
      state.prevChar = "{"
      return { nextIndex: i + 2, kind: "template_expr_brace" }
    }
    return { nextIndex: i + 1, kind: "literal" }
  }

  // Code mode
  if (ch === "/" && next === "/") {
    state.inLineComment = true
    return { nextIndex: i + 2, kind: "comment" }
  }
  if (ch === "/" && next === "*") {
    state.inBlockComment = true
    return { nextIndex: i + 2, kind: "comment" }
  }
  if (ch === "'") {
    state.inSingle = true
    return { nextIndex: i + 1, kind: "literal", openedString: true }
  }
  if (ch === '"') {
    state.inDouble = true
    return { nextIndex: i + 1, kind: "literal", openedString: true }
  }
  if (ch === "`") {
    state.inTemplate = true
    return { nextIndex: i + 1, kind: "literal" }
  }
  if (ch === "/" && canStartRegex(state.prevToken, state.prevChar)) {
    state.inRegex = true
    state.inRegexClass = false
    return { nextIndex: i + 1, kind: "literal" }
  }

  if (state.templateBraceStack.length > 0) {
    if (ch === "{") {
      state.templateBraceStack[state.templateBraceStack.length - 1] =
        state.templateBraceStack[state.templateBraceStack.length - 1]! + 1
      state.prevToken = "{"
      state.prevChar = "{"
      return { nextIndex: i + 1, kind: "template_expr_brace" }
    }
    if (ch === "}") {
      const top = state.templateBraceStack[state.templateBraceStack.length - 1]!
      if (top === 0) {
        state.templateBraceStack.pop()
        state.inTemplate = true
      } else {
        state.templateBraceStack[state.templateBraceStack.length - 1] = top - 1
        state.prevToken = "}"
        state.prevChar = "}"
      }
      return { nextIndex: i + 1, kind: "template_expr_brace" }
    }
  }

  if (isIdentPart(ch)) {
    let j = i + 1
    while (j < source.length && isIdentPart(source[j]!)) j++
    const ident = source.slice(i, j)
    state.prevToken = ident
    state.prevChar = source[j - 1]!
    return { nextIndex: j, kind: "code", token: ident, isIdent: isIdentStart(ch) }
  }

  if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
    return { nextIndex: i + 1, kind: "code", token: ch }
  }

  if ((ch === "=" && next === ">") || (ch === "+" && next === "+") || (ch === "-" && next === "-")) {
    const pair = ch + next
    state.prevToken = pair
    state.prevChar = next
    return { nextIndex: i + 2, kind: "code", token: pair }
  }

  state.prevToken = ch
  state.prevChar = ch
  return { nextIndex: i + 1, kind: "code", token: ch }
}

// ---------------------------------------------------------------------------
// Shared Zig Lexical State Machine
// ---------------------------------------------------------------------------

interface ZigLexerState {
  inLineComment: boolean
  inMultilineString: boolean
  inString: boolean
  inChar: boolean
}

interface ZigLexStep {
  readonly nextIndex: number
  readonly kind: "comment" | "literal" | "code"
  readonly endedLineCommentAtNewline?: boolean
}

function createZigLexerState(): ZigLexerState {
  return {
    inLineComment: false,
    inMultilineString: false,
    inString: false,
    inChar: false,
  }
}

function stepZigLexer(state: ZigLexerState, source: string, i: number): ZigLexStep {
  const ch = source[i]!
  const next = source[i + 1] ?? ""

  if (state.inLineComment) {
    if (ch === "\n") {
      state.inLineComment = false
      return { nextIndex: i + 1, kind: "comment", endedLineCommentAtNewline: true }
    }
    return { nextIndex: i + 1, kind: "comment" }
  }
  if (state.inMultilineString) {
    if (ch === "\n") state.inMultilineString = false
    return { nextIndex: i + 1, kind: "literal" }
  }
  if (state.inString) {
    if (ch === "\\" && i + 1 < source.length) return { nextIndex: i + 2, kind: "literal" }
    if (ch === '"') state.inString = false
    return { nextIndex: i + 1, kind: "literal" }
  }
  if (state.inChar) {
    if (ch === "\\" && i + 1 < source.length) return { nextIndex: i + 2, kind: "literal" }
    if (ch === "'") state.inChar = false
    return { nextIndex: i + 1, kind: "literal" }
  }

  if (ch === "/" && next === "/") {
    state.inLineComment = true
    return { nextIndex: i + 2, kind: "comment" }
  }
  if (ch === "\\" && next === "\\") {
    state.inMultilineString = true
    return { nextIndex: i + 2, kind: "literal" }
  }
  if (ch === '"') {
    state.inString = true
    return { nextIndex: i + 1, kind: "literal" }
  }
  if (ch === "'") {
    state.inChar = true
    return { nextIndex: i + 1, kind: "literal" }
  }
  return { nextIndex: i + 1, kind: "code" }
}

function peekNextTSCodeToken(source: string, index: number): string {
  let i = index
  while (i < source.length) {
    const ch = source[i]!
    const next = source[i + 1] ?? ""
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
      i++
      continue
    }
    if (ch === "/" && next === "/") {
      i += 2
      while (i < source.length && source[i] !== "\n") i++
      continue
    }
    if (ch === "/" && next === "*") {
      i += 2
      while (i < source.length && !(source[i] === "*" && source[i + 1] === "/")) i++
      i += 2
      continue
    }
    if (ch === "=" && next === ">") return "=>"
    return ch
  }
  return ""
}

function peekNextZigCodeChar(source: string, index: number): string {
  let i = index
  while (i < source.length) {
    const ch = source[i]!
    const next = source[i + 1] ?? ""
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
      i++
      continue
    }
    if (ch === "/" && next === "/") {
      i += 2
      while (i < source.length && source[i] !== "\n") i++
      continue
    }
    return ch
  }
  return ""
}

function isCompleteTSNonBlockLine(source: string, startIndex: number, newlineIndex: number): boolean {
  const restLine = source.slice(startIndex, newlineIndex).trim()
  if (restLine.length === 0) return false
  if (
    restLine.endsWith("=") ||
    restLine.endsWith("(") ||
    restLine.endsWith(",") ||
    restLine.endsWith("|") ||
    restLine.endsWith("&") ||
    restLine.endsWith("=>") ||
    restLine.endsWith("[") ||
    restLine.endsWith("<") ||
    restLine.endsWith(":")
  ) {
    return false
  }
  const nextTok = peekNextTSCodeToken(source, newlineIndex + 1)
  return nextTok !== "|" && nextTok !== "&" && nextTok !== "=>"
}

function isCompleteZigNonBlockLine(source: string, startIndex: number, newlineIndex: number): boolean {
  const restLine = source.slice(startIndex, newlineIndex).trim()
  if (restLine.length === 0) return false
  if (
    restLine.endsWith("=") ||
    restLine.endsWith("(") ||
    restLine.endsWith(",") ||
    restLine.endsWith("|") ||
    restLine.endsWith("&") ||
    restLine.endsWith("=>")
  ) {
    return false
  }
  return peekNextZigCodeChar(source, newlineIndex + 1) !== "{"
}

/**
 * Extract the complete balanced TS/TSX declaration snippet starting at `startIndex` (unbounded, no 4KB cap).
 */
function extractBalancedTS(source: string, startIndex: number): string {
  const state = createTSLexerState()
  let braceDepth = 0
  let parenDepth = 0
  let bracketDepth = 0
  let seenTopBrace = false

  for (let i = startIndex; i < source.length; ) {
    const step = stepTSLexer(state, source, i)
    if (step.endedLineCommentAtNewline) {
      if (
        !seenTopBrace &&
        braceDepth === 0 &&
        parenDepth === 0 &&
        bracketDepth === 0 &&
        state.templateBraceStack.length === 0 &&
        isCompleteTSNonBlockLine(source, startIndex, i)
      ) {
        return source.slice(startIndex, i)
      }
      i = step.nextIndex
      continue
    }

    if (step.kind === "code" && state.templateBraceStack.length === 0) {
      const tok = step.token
      if (tok === "(") parenDepth++
      else if (tok === ")") parenDepth = Math.max(0, parenDepth - 1)
      else if (tok === "[") bracketDepth++
      else if (tok === "]") bracketDepth = Math.max(0, bracketDepth - 1)
      else if (tok === "{") {
        if (parenDepth === 0 && bracketDepth === 0) seenTopBrace = true
        braceDepth++
      } else if (tok === "}") {
        braceDepth = Math.max(0, braceDepth - 1)
        if (seenTopBrace && braceDepth === 0 && parenDepth === 0 && bracketDepth === 0) {
          const nextTok = peekNextTSCodeToken(source, step.nextIndex)
          if (
            nextTok === "{" ||
            nextTok === "=>" ||
            nextTok === "|" ||
            nextTok === "&" ||
            nextTok === "=" ||
            nextTok === ":"
          ) {
            seenTopBrace = false
          } else {
            return source.slice(startIndex, step.nextIndex)
          }
        }
      } else if (
        tok === "\n" &&
        !seenTopBrace &&
        braceDepth === 0 &&
        parenDepth === 0 &&
        bracketDepth === 0 &&
        isCompleteTSNonBlockLine(source, startIndex, i)
      ) {
        return source.slice(startIndex, i)
      }
    }

    i = step.nextIndex
  }

  return source.slice(startIndex)
}

/**
 * Extract the complete balanced Zig declaration snippet starting at `startIndex` (unbounded, no 4KB cap).
 */
function extractBalancedZig(source: string, startIndex: number): string {
  const state = createZigLexerState()
  let braceDepth = 0
  let parenDepth = 0
  let seenTopBrace = false

  for (let i = startIndex; i < source.length; ) {
    const step = stepZigLexer(state, source, i)
    if (step.endedLineCommentAtNewline) {
      if (!seenTopBrace && braceDepth === 0 && parenDepth === 0 && isCompleteZigNonBlockLine(source, startIndex, i)) {
        return source.slice(startIndex, i)
      }
      i = step.nextIndex
      continue
    }

    if (step.kind === "code") {
      const ch = source[i]!
      if (ch === "(") parenDepth++
      else if (ch === ")") parenDepth = Math.max(0, parenDepth - 1)
      else if (ch === "{") {
        if (parenDepth === 0) seenTopBrace = true
        braceDepth++
      } else if (ch === "}") {
        braceDepth = Math.max(0, braceDepth - 1)
        if (seenTopBrace && braceDepth === 0 && parenDepth === 0) {
          const nextCh = peekNextZigCodeChar(source, step.nextIndex)
          if (nextCh === "!" || nextCh === "{") {
            seenTopBrace = false
          } else {
            return source.slice(startIndex, step.nextIndex)
          }
        }
      } else if (
        ch === "\n" &&
        !seenTopBrace &&
        braceDepth === 0 &&
        parenDepth === 0 &&
        isCompleteZigNonBlockLine(source, startIndex, i)
      ) {
        return source.slice(startIndex, i)
      }
    }

    i = step.nextIndex
  }

  return source.slice(startIndex)
}

function stripTSCommentsAndWs(text: string): string {
  const state = createTSLexerState()
  let out = ""
  for (let i = 0; i < text.length; ) {
    const step = stepTSLexer(state, text, i)
    if (step.kind !== "comment") {
      const piece = text.slice(i, step.nextIndex)
      if (step.kind !== "code" || !/^\s+$/.test(piece)) out += piece
    }
    i = step.nextIndex
  }
  return out
}

function stripZigCommentsAndWs(text: string): string {
  const state = createZigLexerState()
  let out = ""
  for (let i = 0; i < text.length; ) {
    const step = stepZigLexer(state, text, i)
    if (step.kind !== "comment") {
      const piece = text.slice(i, step.nextIndex)
      if (step.kind !== "code" || !/^\s+$/.test(piece)) out += piece
    }
    i = step.nextIndex
  }
  return out
}

/**
 * Determine whether a TS/TSX or Zig upstream function at `line` (1-based) genuinely has an empty `{}` body
 * (or is an abstract TS method with no implementation body). Reused by audit Gate 11.
 */
export function isUpstreamFunctionBodyEmpty(source: string, line: number, language: "ts" | "zig"): boolean {
  const lines = source.split("\n")
  if (line < 1 || line > lines.length) return false
  let startOffset = 0
  for (let i = 0; i < line - 1; i++) {
    startOffset += lines[i]!.length + 1
  }

  if (language === "zig") {
    const snippet = extractBalancedZig(source, startOffset)
    const state = createZigLexerState()
    let parenDepth = 0
    let braceDepth = 0
    let lastTopBraceOpen = -1
    let lastTopBraceClose = -1

    for (let i = 0; i < snippet.length; ) {
      const step = stepZigLexer(state, snippet, i)
      if (step.kind === "code") {
        const ch = snippet[i]!
        if (ch === "(") parenDepth++
        else if (ch === ")") parenDepth = Math.max(0, parenDepth - 1)
        else if (ch === "{") {
          if (parenDepth === 0 && braceDepth === 0) lastTopBraceOpen = i
          braceDepth++
        } else if (ch === "}") {
          braceDepth = Math.max(0, braceDepth - 1)
          if (parenDepth === 0 && braceDepth === 0 && lastTopBraceOpen >= 0) {
            lastTopBraceClose = i
          }
        }
      }
      i = step.nextIndex
    }

    if (lastTopBraceOpen < 0 || lastTopBraceClose <= lastTopBraceOpen) return false
    return stripZigCommentsAndWs(snippet.slice(lastTopBraceOpen + 1, lastTopBraceClose)).length === 0
  }

  const snippet = extractBalancedTS(source, startOffset)
  const state = createTSLexerState()
  let parenDepth = 0
  let bracketDepth = 0
  let braceDepth = 0
  let lastTopBraceOpen = -1
  let lastTopBraceClose = -1

  for (let i = 0; i < snippet.length; ) {
    const step = stepTSLexer(state, snippet, i)
    if (step.kind === "code" && state.templateBraceStack.length === 0) {
      const tok = step.token
      if (tok === "(") parenDepth++
      else if (tok === ")") parenDepth = Math.max(0, parenDepth - 1)
      else if (tok === "[") bracketDepth++
      else if (tok === "]") bracketDepth = Math.max(0, bracketDepth - 1)
      else if (tok === "{") {
        if (parenDepth === 0 && bracketDepth === 0 && braceDepth === 0) lastTopBraceOpen = i
        braceDepth++
      } else if (tok === "}") {
        braceDepth = Math.max(0, braceDepth - 1)
        if (parenDepth === 0 && bracketDepth === 0 && braceDepth === 0 && lastTopBraceOpen >= 0) {
          lastTopBraceClose = i
        }
      }
    }
    i = step.nextIndex
  }

  if (lastTopBraceOpen < 0 || lastTopBraceClose <= lastTopBraceOpen) {
    return /^\s*(?:public\s+)?(?:static\s+)?abstract\s+/.test(snippet)
  }
  return stripTSCommentsAndWs(snippet.slice(lastTopBraceOpen + 1, lastTopBraceClose)).length === 0
}

export function walkSourceFiles(dir: string, language: "ts" | "zig"): string[] {
  if (!fs.existsSync(dir)) return []
  const results: string[] = []
  const stack = [dir]
  const skipDirs = new Set([
    "node_modules",
    "__snapshots__",
    "__tests__",
    "tests",
    "testing",
    "bench",
    "benchmark",
    "vendor",
    "dist",
    "zig-out",
    ".zig-cache",
  ])

  while (stack.length > 0) {
    const current = stack.pop()!
    const entries = fs.readdirSync(current, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))
    for (const entry of entries) {
      if (skipDirs.has(entry.name) || entry.name.startsWith(".")) continue
      const full = path.join(current, entry.name)
      if (entry.isDirectory()) {
        stack.push(full)
      } else if (entry.isFile()) {
        if (language === "zig") {
          if (entry.name.endsWith(".zig") && !entry.name.includes("bench") && !entry.name.startsWith("test")) {
            results.push(full)
          }
        } else {
          if (
            (entry.name.endsWith(".ts") || entry.name.endsWith(".tsx")) &&
            !entry.name.endsWith(".test.ts") &&
            !entry.name.endsWith(".test.tsx") &&
            !entry.name.endsWith(".spec.ts") &&
            !entry.name.endsWith(".d.ts") &&
            !entry.name.endsWith(".fixture.ts") &&
            !entry.name.includes("benchmark")
          ) {
            results.push(full)
          }
        }
      }
    }
  }
  return results.sort()
}

interface TSToken {
  readonly kind: "ident" | "string" | "punct"
  readonly value: string
  readonly start: number
  readonly end: number
  readonly line: number
  readonly braceDepth: number
}

function tokenizeTopLevelTS(source: string): TSToken[] {
  const tokens: TSToken[] = []
  const state = createTSLexerState()
  let line = 1
  let braceDepth = 0
  let stringStart = 0
  let stringLine = 1

  for (let i = 0; i < source.length; ) {
    const step = stepTSLexer(state, source, i)
    const slice = source.slice(i, step.nextIndex)

    if (step.openedString) {
      stringStart = i
      stringLine = line
    } else if (step.closedString && state.templateBraceStack.length === 0 && braceDepth <= 1) {
      tokens.push({
        kind: "string",
        value: source.slice(stringStart + 1, i),
        start: stringStart,
        end: step.nextIndex,
        line: stringLine,
        braceDepth,
      })
    } else if (step.kind === "code" && state.templateBraceStack.length === 0) {
      const tok = step.token
      if (tok === "{") {
        if (braceDepth <= 1) tokens.push({ kind: "punct", value: "{", start: i, end: step.nextIndex, line, braceDepth })
        braceDepth++
      } else if (tok === "}") {
        braceDepth = Math.max(0, braceDepth - 1)
        if (braceDepth <= 1) tokens.push({ kind: "punct", value: "}", start: i, end: step.nextIndex, line, braceDepth })
      } else if (tok && !/^\s+$/.test(tok) && braceDepth <= 1) {
        tokens.push({
          kind: step.isIdent ? "ident" : "punct",
          value: tok,
          start: i,
          end: step.nextIndex,
          line,
          braceDepth,
        })
      }
    }

    for (let k = 0; k < slice.length; k++) {
      if (slice[k] === "\n") line++
    }
    i = step.nextIndex
  }

  return tokens
}

interface ParsedExportSpecifier {
  readonly localName: string
  readonly exportedName: string
  readonly isTypeOnly: boolean
}

function parseExportSpecifiersFromTokens(
  tokens: readonly TSToken[],
  openBraceIdx: number,
  listIsTypeOnly: boolean,
): { specifiers: ParsedExportSpecifier[]; closeBraceIdx: number } | null {
  const closeBraceIdx = tokens.findIndex(
    (t, idx) => idx > openBraceIdx && t.kind === "punct" && t.value === "}" && t.braceDepth === 0,
  )
  if (closeBraceIdx < 0) return null

  const specifiers: ParsedExportSpecifier[] = []
  let idx = openBraceIdx + 1
  while (idx < closeBraceIdx) {
    if (tokens[idx]!.kind === "punct" && tokens[idx]!.value === ",") {
      idx++
      continue
    }

    let itemIsTypeOnly = listIsTypeOnly
    const t0 = tokens[idx]!
    const t1 = tokens[idx + 1]
    if (
      t0.kind === "ident" &&
      t0.value === "type" &&
      t1 &&
      idx + 1 < closeBraceIdx &&
      (t1.kind === "ident" || t1.kind === "string") &&
      !(t1.kind === "ident" && t1.value === "as")
    ) {
      itemIsTypeOnly = true
      idx++
    }

    const localTok = tokens[idx]
    if (!localTok || idx >= closeBraceIdx || (localTok.kind !== "ident" && localTok.kind !== "string")) {
      idx++
      continue
    }
    const localName = localTok.value
    let exportedName = localName
    idx++

    if (idx + 1 < closeBraceIdx && tokens[idx]!.kind === "ident" && tokens[idx]!.value === "as") {
      const aliasTok = tokens[idx + 1]!
      if (aliasTok.kind === "ident" || aliasTok.kind === "string") {
        exportedName = aliasTok.value
        idx += 2
      }
    }

    specifiers.push({ localName, exportedName, isTypeOnly: itemIsTypeOnly })

    while (idx < closeBraceIdx && !(tokens[idx]!.kind === "punct" && tokens[idx]!.value === ",")) {
      idx++
    }
  }

  return { specifiers, closeBraceIdx }
}

/**
 * Lexically parse ONLY explicit `from "..."` re-exports in a TS/TSX file:
 * - `export { a, b as c, default as d } from "..."` (excluding `export type { ... }` and `type X` specifiers)
 * - `export * as Ns from "..."` (excluding `export type * as Ns`)
 */
export function extractLexicalReExports(source: string): Set<string> {
  const reExports = new Set<string>()
  const tokens = tokenizeTopLevelTS(source)

  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i]!
    if (tok.braceDepth !== 0 || tok.kind !== "ident" || tok.value !== "export") continue

    const next = tokens[i + 1]
    if (!next) continue

    if (next.kind === "ident" && next.value === "type") {
      const afterType = tokens[i + 2]
      if (afterType && afterType.kind === "punct" && (afterType.value === "{" || afterType.value === "*")) {
        continue
      }
    }

    if (next.kind === "punct" && next.value === "*") {
      const tAs = tokens[i + 2]
      const tName = tokens[i + 3]
      const tFrom = tokens[i + 4]
      const tSpec = tokens[i + 5]
      if (
        tAs?.kind === "ident" &&
        tAs.value === "as" &&
        tName &&
        (tName.kind === "ident" || tName.kind === "string") &&
        tFrom?.kind === "ident" &&
        tFrom.value === "from" &&
        tSpec?.kind === "string"
      ) {
        reExports.add(tName.value)
        i += 5
      }
      continue
    }

    if (next.kind === "punct" && next.value === "{") {
      const parsed = parseExportSpecifiersFromTokens(tokens, i + 1, false)
      if (!parsed) continue
      const afterClose = tokens[parsed.closeBraceIdx + 1]
      const fromTarget = tokens[parsed.closeBraceIdx + 2]
      if (afterClose?.kind === "ident" && afterClose.value === "from" && fromTarget?.kind === "string") {
        for (const spec of parsed.specifiers) {
          if (!spec.isTypeOnly) reExports.add(spec.exportedName)
        }
        i = parsed.closeBraceIdx + 2
      } else {
        i = parsed.closeBraceIdx
      }
    }
  }

  return reExports
}

/**
 * Compiler Export Completeness Gate helper (reused by both `scanner.ts` and `audit.ts` Gate 9).
 * Uses `Bun.Transpiler({ loader }).scan(source).exports`, excludes ONLY lexically verified `from "..."` re-exports,
 * and returns any local exports missing from `emittedSymbols`.
 */
export function verifyFileExportsWithTranspiler(
  absPath: string,
  source: string,
  emittedSymbols: ReadonlySet<string> | readonly string[],
): string[] {
  const loader: "ts" | "tsx" = absPath.endsWith(".tsx") ? "tsx" : "ts"
  const transpiler = new Bun.Transpiler({ loader })
  const scanned = transpiler.scan(source)
  const reExports = extractLexicalReExports(source)
  const emittedSet = emittedSymbols instanceof Set ? emittedSymbols : new Set(emittedSymbols)

  const missing: string[] = []
  for (const exp of scanned.exports) {
    if (reExports.has(exp)) continue
    if (!emittedSet.has(exp)) missing.push(exp)
  }
  return missing.sort()
}

function splitTopLevelByComma(source: string): string[] {
  const parts: string[] = []
  const state = createTSLexerState()
  let start = 0
  let parenDepth = 0
  let bracketDepth = 0
  let braceDepth = 0

  for (let i = 0; i < source.length; ) {
    const step = stepTSLexer(state, source, i)
    if (step.kind === "code" && state.templateBraceStack.length === 0) {
      const tok = step.token
      if (tok === "(") parenDepth++
      else if (tok === ")") parenDepth = Math.max(0, parenDepth - 1)
      else if (tok === "[") bracketDepth++
      else if (tok === "]") bracketDepth = Math.max(0, bracketDepth - 1)
      else if (tok === "{") braceDepth++
      else if (tok === "}") braceDepth = Math.max(0, braceDepth - 1)
      else if (tok === "," && parenDepth === 0 && bracketDepth === 0 && braceDepth === 0) {
        parts.push(source.slice(start, i))
        start = step.nextIndex
      }
    }
    i = step.nextIndex
  }
  parts.push(source.slice(start))
  return parts
}

function findTopLevelChar(source: string, target: string): number {
  const state = createTSLexerState()
  let parenDepth = 0
  let bracketDepth = 0
  let braceDepth = 0

  for (let i = 0; i < source.length; ) {
    const step = stepTSLexer(state, source, i)
    if (step.kind === "code" && state.templateBraceStack.length === 0) {
      const tok = step.token
      if (tok === "(") parenDepth++
      else if (tok === ")") parenDepth = Math.max(0, parenDepth - 1)
      else if (tok === "[") bracketDepth++
      else if (tok === "]") bracketDepth = Math.max(0, bracketDepth - 1)
      else if (tok === "{") braceDepth++
      else if (tok === "}") braceDepth = Math.max(0, braceDepth - 1)
      else if (tok === target && parenDepth === 0 && bracketDepth === 0 && braceDepth === 0) {
        if (target === "=" && source[i + 1] === "=") {
          i = step.nextIndex + 1
          continue
        }
        return i
      }
    }
    i = step.nextIndex
  }
  return -1
}

function extractBalancedDelimited(source: string, openIndex: number, openChar: string, closeChar: string): string | null {
  if (source[openIndex] !== openChar) return null
  const state = createTSLexerState()
  let depth = 0
  for (let i = openIndex; i < source.length; ) {
    const step = stepTSLexer(state, source, i)
    if (step.kind === "code" && state.templateBraceStack.length === 0) {
      if (step.token === openChar) depth++
      else if (step.token === closeChar) {
        depth--
        if (depth === 0) return source.slice(openIndex + 1, i)
      }
    }
    i = step.nextIndex
  }
  return null
}

function parseDestructuredBindings(pattern: string, isObject: boolean): string[] {
  const names: string[] = []
  for (const rawItem of splitTopLevelByComma(pattern)) {
    const stripped = rawItem.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "").trim()
    if (!stripped) continue

    const eqIdx = findTopLevelChar(stripped, "=")
    const lhs = (eqIdx >= 0 ? stripped.slice(0, eqIdx) : stripped).trim()
    if (!lhs) continue

    const collectTarget = (target: string) => {
      if (/^[A-Za-z_$][\w$]*$/.test(target)) names.push(target)
      else if (target.startsWith("{") && target.endsWith("}")) {
        names.push(...parseDestructuredBindings(target.slice(1, -1), true))
      } else if (target.startsWith("[") && target.endsWith("]")) {
        names.push(...parseDestructuredBindings(target.slice(1, -1), false))
      }
    }

    if (lhs.startsWith("...")) {
      collectTarget(lhs.slice(3).trim())
      continue
    }

    if (isObject) {
      const colonIdx = findTopLevelChar(lhs, ":")
      if (colonIdx >= 0) collectTarget(lhs.slice(colonIdx + 1).trim())
      else if (/^[A-Za-z_$][\w$]*$/.test(lhs)) names.push(lhs)
    } else {
      collectTarget(lhs)
    }
  }
  return names
}

function snippetHasFunctionBody(snippet: string): boolean {
  const state = createTSLexerState()
  let parenDepth = 0
  let bracketDepth = 0
  let seenParamClose = false

  for (let i = 0; i < snippet.length; ) {
    const step = stepTSLexer(state, snippet, i)
    if (step.kind === "code" && state.templateBraceStack.length === 0) {
      const tok = step.token
      if (tok === "(") parenDepth++
      else if (tok === ")") {
        parenDepth = Math.max(0, parenDepth - 1)
        if (parenDepth === 0 && bracketDepth === 0) seenParamClose = true
      } else if (tok === "[") bracketDepth++
      else if (tok === "]") bracketDepth = Math.max(0, bracketDepth - 1)
      else if (tok === "{" && seenParamClose && parenDepth === 0 && bracketDepth === 0) {
        return true
      }
    }
    i = step.nextIndex
  }
  return false
}

function matchClassMethodHeader(source: string, lineStartOffset: number, line: string): string | null {
  const trimmed = line.trim()
  if (
    trimmed.startsWith("private ") ||
    trimmed.startsWith("protected ") ||
    trimmed.startsWith("readonly ") ||
    trimmed.startsWith("#")
  ) {
    return null
  }

  const prefixMatch = line.match(
    /^(\s+(?:public\s+)?(?:(?:static|abstract|override)\s+)*(?:async\s+)?(?:(?:get|set)\s+)?)([A-Za-z_$][\w$]*)/,
  )
  if (!prefixMatch) return null

  const methodName = prefixMatch[2]!
  if (EXCLUDED_CLASS_METHOD_NAMES.has(methodName) || methodName.startsWith("_")) return null

  let pos = lineStartOffset + prefixMatch[0].length
  while (pos < source.length && (source[pos] === " " || source[pos] === "\t")) pos++

  if (source[pos] === "<") {
    let angleDepth = 0
    while (pos < source.length) {
      const ch = source[pos]!
      if (ch === "=" && source[pos + 1] === ">") {
        pos += 2
        continue
      }
      if (ch === "<") angleDepth++
      else if (ch === ">") {
        angleDepth--
        if (angleDepth === 0) {
          pos++
          break
        }
      } else if (ch === ";" || ch === "{") {
        return null
      }
      pos++
    }
    while (pos < source.length && (source[pos] === " " || source[pos] === "\t" || source[pos] === "\r" || source[pos] === "\n")) {
      pos++
    }
  }

  return source[pos] === "(" ? methodName : null
}

function classifyConstKind(rawKind: string, line: string, snippet: string): SymbolKind {
  if (rawKind === "let" || rawKind === "var") {
    if (/=\s*(?:async\s*)?(?:<[^>]+>\s*)?\([^)]*\)\s*(?::[^=]+)?=>/.test(line)) return "arrow_function"
    return "const"
  }
  if (rawKind === "const") {
    if (/=\s*(?:async\s*)?(?:<[^>]+>\s*)?\([^)]*\)\s*(?::[^=]+)?=>/.test(line)) return "arrow_function"
    const eqIdx = findTopLevelChar(snippet, "=")
    if (eqIdx >= 0) {
      const rhs = snippet.slice(eqIdx + 1).trimStart()
      const firstLineRhs = rhs.split("\n")[0] ?? ""
      if (firstLineRhs.startsWith("(") || firstLineRhs.startsWith("async ") || firstLineRhs.startsWith("<")) {
        let pd = 0
        let bd = 0
        for (let i = 0; i < rhs.length; i++) {
          const c = rhs[i]!
          if (c === "(") pd++
          else if (c === ")") pd = Math.max(0, pd - 1)
          else if (c === "[") bd++
          else if (c === "]") bd = Math.max(0, bd - 1)
          else if (c === "{" && pd === 0 && bd === 0) break
          else if (c === "=" && rhs[i + 1] === ">" && pd === 0 && bd === 0) return "arrow_function"
        }
      }
    }
    return "const"
  }
  return rawKind as SymbolKind
}

interface LocalDeclInfo {
  readonly kind: SymbolKind
  readonly line: number
  readonly offset: number
  readonly signature: string
  readonly bodyHash: string
  readonly hasBody: boolean
}

interface ScopeFrame {
  readonly kind: "class" | "namespace"
  readonly name: string
  readonly depth: number
}

function scanTypeScriptFile(
  pkg: (typeof TRACKED_OPENTUI_PACKAGES)[number],
  absPath: string,
  relFile: string,
): { symbols: UpstreamSymbol[]; lines: number } {
  const source = fs.readFileSync(absPath, "utf8")
  const lines = source.split("\n")
  const symbols: UpstreamSymbol[] = []
  const symbolIndexById = new Map<string, { index: number; hasBody: boolean }>()
  const emittedTopLevelNames = new Set<string>()
  const localDecls = new Map<string, LocalDeclInfo>()

  const lineOffsets: number[] = []
  let runningOffset = 0
  for (const l of lines) {
    lineOffsets.push(runningOffset)
    runningOffset += l.length + 1
  }

  function upsertSymbol(sym: UpstreamSymbol, hasBody: boolean, topLevelName?: string): void {
    if (topLevelName) emittedTopLevelNames.add(topLevelName)
    const existing = symbolIndexById.get(sym.id)
    if (!existing) {
      symbolIndexById.set(sym.id, { index: symbols.length, hasBody })
      symbols.push(sym)
      return
    }
    if (!existing.hasBody && hasBody) {
      symbols[existing.index] = sym
      symbolIndexById.set(sym.id, { index: existing.index, hasBody: true })
    }
  }

  const topExportRe =
    /^export\s+(?:(declare|abstract)\s+)?(?:(async)\s+)?(?:(const)\s+(enum)|(function|const|let|var|class|type|interface|enum|namespace))\s+([A-Za-z_$][\w$]*)/
  const nsMemberExportRe =
    /^\s+export\s+(?:(declare|abstract)\s+)?(?:(async)\s+)?(?:(const)\s+(enum)|(function|const|let|var|class|type|interface|enum|namespace))\s+([A-Za-z_$][\w$]*)/
  const localDeclRe =
    /^(?:(declare|abstract)\s+)?(?:(async)\s+)?(?:(const)\s+(enum)|(function|const|let|var|class|type|interface|enum|namespace))\s+([A-Za-z_$][\w$]*)/
  const destructuredTopRe = /^export\s+(?:declare\s+)?(const|let|var)\s*(\{|\[)/
  const destructuredNsRe = /^\s+export\s+(?:declare\s+)?(const|let|var)\s*(\{|\[)/
  const exportDefaultRe = /^export\s+default\b/

  const lexState = createTSLexerState()
  let braceDepth = 0
  const scopeStack: ScopeFrame[] = []
  let pendingScope: { kind: "class" | "namespace"; name: string; targetDepth: number } | null = null
  const pendingExportDefaults: Array<{ lineNum: number; offset: number; line: string }> = []

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!
    const lineNum = i + 1
    const offset = lineOffsets[i]!
    const inNonCodeAtStart =
      lexState.inBlockComment || lexState.inTemplate || lexState.templateBraceStack.length > 0

    if (!inNonCodeAtStart) {
      if (braceDepth === 0) {
        if (exportDefaultRe.test(line)) {
          pendingExportDefaults.push({ lineNum, offset, line })
          if (/^export\s+default\s+(?:abstract\s+)?class\b/.test(line)) {
            pendingScope = { kind: "class", name: "default", targetDepth: 1 }
          }
        } else if (destructuredTopRe.test(line)) {
          const dm = line.match(destructuredTopRe)!
          const openChar = dm[2]!
          const closeChar = openChar === "{" ? "}" : "]"
          const openIdx = offset + dm[0].length - 1
          const inner = extractBalancedDelimited(source, openIdx, openChar, closeChar)
          if (inner !== null) {
            const boundNames = parseDestructuredBindings(inner, openChar === "{")
            const snippet = extractBalancedTS(source, offset)
            const bodyHash = sha256Short(snippet)
            for (const name of boundNames) {
              upsertSymbol(
                {
                  id: `${pkg.upstreamPackage}/${relFile}#${name}`,
                  package: pkg.upstreamPackage,
                  swiftTarget: pkg.swiftTarget,
                  tier: pkg.tier,
                  file: relFile,
                  symbol: name,
                  kind: "const",
                  line: lineNum,
                  signature: line.trim().slice(0, 140),
                  bodyHash,
                },
                true,
                name,
              )
            }
          }
        } else {
          const m = line.match(topExportRe)
          if (m) {
            const rawKind = m[4] ? "enum" : m[5]!
            const name = m[6]!
            const snippet = extractBalancedTS(source, offset)
            const kind: SymbolKind =
              rawKind === "const" || rawKind === "let" || rawKind === "var"
                ? classifyConstKind(rawKind, line, snippet)
                : (rawKind as SymbolKind)
            const hasBody = kind === "function" ? snippetHasFunctionBody(snippet) : true
            const bodyHash = sha256Short(snippet)

            upsertSymbol(
              {
                id: `${pkg.upstreamPackage}/${relFile}#${name}`,
                package: pkg.upstreamPackage,
                swiftTarget: pkg.swiftTarget,
                tier: pkg.tier,
                file: relFile,
                symbol: name,
                kind,
                line: lineNum,
                signature: line.trim().slice(0, 140),
                bodyHash,
              },
              hasBody,
              name,
            )

            const prevLocal = localDecls.get(name)
            if (!prevLocal || (!prevLocal.hasBody && hasBody)) {
              localDecls.set(name, {
                kind,
                line: lineNum,
                offset,
                signature: line.trim().slice(0, 140),
                bodyHash,
                hasBody,
              })
            }

            if (rawKind === "class" || rawKind === "namespace") {
              pendingScope = { kind: rawKind, name, targetDepth: 1 }
            }
          } else {
            const lm = line.match(localDeclRe)
            if (lm) {
              const rawKind = lm[4] ? "enum" : lm[5]!
              const name = lm[6]!
              const snippet = extractBalancedTS(source, offset)
              const kind: SymbolKind =
                rawKind === "const" || rawKind === "let" || rawKind === "var"
                  ? classifyConstKind(rawKind, line, snippet)
                  : (rawKind as SymbolKind)
              const hasBody = kind === "function" ? snippetHasFunctionBody(snippet) : true
              const prevLocal = localDecls.get(name)
              if (!prevLocal || (!prevLocal.hasBody && hasBody)) {
                localDecls.set(name, {
                  kind,
                  line: lineNum,
                  offset,
                  signature: line.trim().slice(0, 140),
                  bodyHash: sha256Short(snippet),
                  hasBody,
                })
              }
            }
          }
        }
      } else if (scopeStack.length > 0 && braceDepth === scopeStack[scopeStack.length - 1]!.depth) {
        const active = scopeStack[scopeStack.length - 1]!
        const prefix = scopeStack.map((s) => s.name).join(".")

        if (active.kind === "class") {
          const methodName = matchClassMethodHeader(source, offset, line)
          if (methodName) {
            const fullName = `${prefix}.${methodName}`
            const snippet = extractBalancedTS(source, offset)
            upsertSymbol(
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
              snippetHasFunctionBody(snippet),
            )
          }
        } else if (active.kind === "namespace") {
          if (destructuredNsRe.test(line)) {
            const dm = line.match(destructuredNsRe)!
            const openChar = dm[2]!
            const closeChar = openChar === "{" ? "}" : "]"
            const openIdx = offset + dm[0].length - 1
            const inner = extractBalancedDelimited(source, openIdx, openChar, closeChar)
            if (inner !== null) {
              const boundNames = parseDestructuredBindings(inner, openChar === "{")
              const snippet = extractBalancedTS(source, offset)
              const bodyHash = sha256Short(snippet)
              for (const name of boundNames) {
                const fullName = `${prefix}.${name}`
                upsertSymbol(
                  {
                    id: `${pkg.upstreamPackage}/${relFile}#${fullName}`,
                    package: pkg.upstreamPackage,
                    swiftTarget: pkg.swiftTarget,
                    tier: pkg.tier,
                    file: relFile,
                    symbol: fullName,
                    kind: "const",
                    line: lineNum,
                    signature: line.trim().slice(0, 140),
                    bodyHash,
                  },
                  true,
                )
              }
            }
          } else {
            const nm = line.match(nsMemberExportRe)
            if (nm) {
              const rawKind = nm[4] ? "enum" : nm[5]!
              const memberName = nm[6]!
              const fullName = `${prefix}.${memberName}`
              const snippet = extractBalancedTS(source, offset)
              const kind: SymbolKind =
                rawKind === "const" || rawKind === "let" || rawKind === "var"
                  ? classifyConstKind(rawKind, line, snippet)
                  : (rawKind as SymbolKind)
              upsertSymbol(
                {
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
                },
                kind === "function" ? snippetHasFunctionBody(snippet) : true,
              )

              if (rawKind === "class" || rawKind === "namespace") {
                pendingScope = { kind: rawKind, name: memberName, targetDepth: braceDepth + 1 }
              }
            }
          }
        }
      }
    }

    // Advance TS/TSX lexical state across `line` (+ trailing newline semantics)
    const lineEnd = offset + line.length
    for (let pos = offset; pos < lineEnd; ) {
      const step = stepTSLexer(lexState, source, pos)
      if (step.kind === "code" && lexState.templateBraceStack.length === 0) {
        if (step.token === "{") {
          braceDepth++
          if (pendingScope && braceDepth === pendingScope.targetDepth) {
            scopeStack.push({ kind: pendingScope.kind, name: pendingScope.name, depth: braceDepth })
            pendingScope = null
          }
        } else if (step.token === "}") {
          if (scopeStack.length > 0 && scopeStack[scopeStack.length - 1]!.depth === braceDepth) {
            scopeStack.pop()
          }
          braceDepth = Math.max(0, braceDepth - 1)
        }
      }
      pos = Math.min(step.nextIndex, lineEnd)
    }
    lexState.inLineComment = false
    lexState.inSingle = false
    lexState.inDouble = false
    lexState.inRegex = false
    lexState.inRegexClass = false
  }

  // Resolve `export default ...` after collecting all local declarations
  for (const def of pendingExportDefaults) {
    const id = `${pkg.upstreamPackage}/${relFile}#default`
    const rest = def.line.replace(/^export\s+default\s+/, "").trim()
    const identOnly = rest.match(/^([A-Za-z_$][\w$]*)\s*;?\s*(?:\/\/.*)?$/)
    if (identOnly) {
      const local = localDecls.get(identOnly[1]!)
      if (local) {
        upsertSymbol(
          {
            id,
            package: pkg.upstreamPackage,
            swiftTarget: pkg.swiftTarget,
            tier: pkg.tier,
            file: relFile,
            symbol: "default",
            kind: local.kind,
            line: local.line,
            signature: local.signature,
            bodyHash: local.bodyHash,
          },
          local.hasBody,
          "default",
        )
        continue
      }
    }

    const snippet = extractBalancedTS(source, def.offset)
    let kind: SymbolKind = "const"
    if (/^(?:async\s+)?function\b/.test(rest)) kind = "function"
    else if (/^(?:abstract\s+)?class\b/.test(rest)) kind = "class"
    else if (/^(?:async\s*)?(?:<[^>]+>\s*)?\([^)]*\)\s*(?::[^=]+)?=>/.test(rest)) kind = "arrow_function"

    upsertSymbol(
      {
        id,
        package: pkg.upstreamPackage,
        swiftTarget: pkg.swiftTarget,
        tier: pkg.tier,
        file: relFile,
        symbol: "default",
        kind,
        line: def.lineNum,
        signature: def.line.trim().slice(0, 140),
        bodyHash: sha256Short(snippet),
      },
      true,
      "default",
    )
  }

  // Resolve local named export lists `export { a, b as c }` (WITHOUT `from "..."`; handles multi-line!)
  const tokens = tokenizeTopLevelTS(source)
  for (let tIdx = 0; tIdx < tokens.length; tIdx++) {
    const tok = tokens[tIdx]!
    if (tok.braceDepth !== 0 || tok.kind !== "ident" || tok.value !== "export") continue
    const next = tokens[tIdx + 1]
    if (!next || next.kind !== "punct" || next.value !== "{") continue

    const parsed = parseExportSpecifiersFromTokens(tokens, tIdx + 1, false)
    if (!parsed) continue

    const afterClose = tokens[parsed.closeBraceIdx + 1]
    const fromTarget = tokens[parsed.closeBraceIdx + 2]
    if (afterClose?.kind === "ident" && afterClose.value === "from" && fromTarget?.kind === "string") {
      tIdx = parsed.closeBraceIdx + 2
      continue
    }

    const exportSnippet = source.slice(tok.start, tokens[parsed.closeBraceIdx]!.end)
    const exportFallbackHash = sha256Short(exportSnippet)
    const exportLineSig = (lines[tok.line - 1] ?? "").trim().slice(0, 140)

    for (const spec of parsed.specifiers) {
      if (spec.isTypeOnly) continue
      const id = `${pkg.upstreamPackage}/${relFile}#${spec.exportedName}`
      const local = localDecls.get(spec.localName)
      if (local) {
        upsertSymbol(
          {
            id,
            package: pkg.upstreamPackage,
            swiftTarget: pkg.swiftTarget,
            tier: pkg.tier,
            file: relFile,
            symbol: spec.exportedName,
            kind: local.kind,
            line: local.line,
            signature: local.signature,
            bodyHash: local.bodyHash,
          },
          local.hasBody,
          spec.exportedName,
        )
      } else {
        upsertSymbol(
          {
            id,
            package: pkg.upstreamPackage,
            swiftTarget: pkg.swiftTarget,
            tier: pkg.tier,
            file: relFile,
            symbol: spec.exportedName,
            kind: "const",
            line: tok.line,
            signature: exportLineSig,
            bodyHash: exportFallbackHash,
          },
          true,
          spec.exportedName,
        )
      }
    }

    tIdx = parsed.closeBraceIdx
  }

  // Mandatory Compiler Export Completeness Gate
  const missingExports = verifyFileExportsWithTranspiler(absPath, source, emittedTopLevelNames)
  if (missingExports.length > 0) {
    throw new Error(
      `Compiler Export Completeness Gate failed for ${pkg.upstreamPackage}/${relFile}: missing local export(s): ${missingExports.join(", ")}`,
    )
  }

  return { symbols, lines: lines.length }
}

interface ZigScopeFrame {
  readonly depth: number
  readonly kind: "type" | "factory" | "fn" | "test" | "anon_struct" | "block"
  readonly name?: string
}

function scanZigFile(
  pkg: (typeof TRACKED_OPENTUI_PACKAGES)[number],
  absPath: string,
  relFile: string,
): { symbols: UpstreamSymbol[]; lines: number } {
  const source = fs.readFileSync(absPath, "utf8")
  const lines = source.split("\n")
  const symbols: UpstreamSymbol[] = []
  const seen = new Set<string>()

  const topZigFnRe = /^(?:pub\s+(?:export\s+)?|export\s+)(?:(?:inline|noinline)\s+)?fn\s+([A-Za-z_][\w]*)/
  const topZigConstRe = /^pub\s+const\s+([A-Za-z_][\w]*)\s*(?::[^=]+)?=/
  const indentedZigFnRe = /^\s+(?:pub\s+(?:export\s+)?|export\s+)(?:(?:inline|noinline)\s+)?fn\s+([A-Za-z_][\w]*)/

  const testHeaderRe = /^test(?:\s+""|\s+[A-Za-z_]\w*)?\s*$/
  const namedTypeDeclRe =
    /^(?:pub\s+)?const\s+([A-Za-z_]\w*)(?:\s*:\s*[^=]+)?\s*=\s*(?:(?:if\s*\([^)]*\)\s*[^;{}]+\s+else\s+)?(?:packed\s+|extern\s+)?(?:struct|union|enum)(?:\s*\([^)]*\))?)\s*$/
  const returnTypeDeclRe = /^return\s+(?:packed\s+|extern\s+)?(?:struct|union|enum)(?:\s*\([^)]*\))?\s*$/
  const factoryFnHeaderRe =
    /^(?:pub\s+(?:export\s+)?|export\s+)?(?:(?:inline|noinline)\s+)?fn\s+([A-Za-z_]\w*)\s*\([\s\S]*\)\s*type\s*$/
  const normalFnHeaderRe =
    /^(?:pub\s+(?:export\s+)?|export\s+)?(?:(?:inline|noinline)\s+)?fn\s+([A-Za-z_]\w*)\s*\([\s\S]*\)/

  let offset = 0
  let braceDepth = 0
  let parenDepth = 0
  let inString = false
  let inChar = false
  const frames: ZigScopeFrame[] = []
  let stmtAccum = ""

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!
    if (line.trimStart().startsWith("\\\\")) {
      offset += line.length + 1
      continue
    }

    const inTest = frames.some((f) => f.kind === "test")
    const inNormalFnOrAnon = frames.some((f) => f.kind === "fn" || f.kind === "anon_struct")

    if (!inTest && !inNormalFnOrAnon) {
      if (braceDepth === 0) {
        const fnMatch = line.match(topZigFnRe)
        const constMatch = !fnMatch ? line.match(topZigConstRe) : null
        if (fnMatch || constMatch) {
          const name = (fnMatch ? fnMatch[1] : constMatch![1])!
          const kind: SymbolKind = fnMatch ? "zig_fn" : "zig_const"
          const id = `${pkg.upstreamPackage}/${relFile}#${name}`
          if (!seen.has(id)) {
            seen.add(id)
            symbols.push({
              id,
              package: pkg.upstreamPackage,
              swiftTarget: pkg.swiftTarget,
              tier: pkg.tier,
              file: relFile,
              symbol: name,
              kind,
              line: i + 1,
              signature: line.trim().slice(0, 140),
              bodyHash: sha256Short(extractBalancedZig(source, offset)),
            })
          }
        }
      } else {
        const fnMatch = line.match(indentedZigFnRe)
        if (fnMatch) {
          const topFrame = frames[frames.length - 1]
          const typeNames = frames.filter((f) => f.kind === "type" && f.name).map((f) => f.name!)
          if (topFrame?.kind === "type" && typeNames.length > 0) {
            const fullName = `${typeNames.join(".")}.${fnMatch[1]!}`
            const id = `${pkg.upstreamPackage}/${relFile}#${fullName}`
            if (!seen.has(id)) {
              seen.add(id)
              symbols.push({
                id,
                package: pkg.upstreamPackage,
                swiftTarget: pkg.swiftTarget,
                tier: pkg.tier,
                file: relFile,
                symbol: fullName,
                kind: "zig_fn",
                line: i + 1,
                signature: line.trim().slice(0, 140),
                bodyHash: sha256Short(extractBalancedZig(source, offset)),
              })
            }
          }
        }
      }
    }

    let clean = ""
    for (let j = 0; j < line.length; j++) {
      const ch = line[j]!
      const next = line[j + 1] ?? ""
      if (inString) {
        if (ch === "\\") {
          j++
          continue
        }
        if (ch === '"') inString = false
        continue
      }
      if (inChar) {
        if (ch === "\\") {
          j++
          continue
        }
        if (ch === "'") inChar = false
        continue
      }
      if (ch === "/" && next === "/") break
      if (ch === '"') {
        inString = true
        clean += '""'
        continue
      }
      if (ch === "'") {
        inChar = true
        clean += "''"
        continue
      }
      clean += ch
    }

    for (let k = 0; k < clean.length; k++) {
      const ch = clean[k]!
      if (ch === "(") {
        parenDepth++
        stmtAccum += ch
      } else if (ch === ")") {
        parenDepth = Math.max(0, parenDepth - 1)
        stmtAccum += ch
      } else if (ch === ";") {
        stmtAccum = ""
      } else if (ch === "," && parenDepth === 0 && frames.length > 0 && frames[frames.length - 1]!.kind === "type") {
        stmtAccum = ""
      } else if (ch === "{") {
        if (parenDepth === 0) {
          const ctx = stmtAccum.trim()
          const isReturnInlineBrace =
            /\bfn\s+[A-Za-z_]\w*\s*\([\s\S]*\)/.test(ctx) &&
            /\b(?:error|struct|union|enum)\s*(?:\([^)]*\))?\s*$/.test(ctx) &&
            !/\breturn\s+(?:packed\s+|extern\s+)?(?:struct|union|enum)\b/.test(ctx)

          if (isReturnInlineBrace) {
            braceDepth++
            frames.push({ depth: braceDepth, kind: "block" })
            stmtAccum += "{"
            continue
          }

          let frameKind: ZigScopeFrame["kind"] = "block"
          let frameName: string | undefined

          const testM = ctx.match(testHeaderRe)
          const typeDeclM = !testM ? ctx.match(namedTypeDeclRe) : null
          const returnTypeM = !testM && !typeDeclM ? ctx.match(returnTypeDeclRe) : null
          const factoryFnM = !testM && !typeDeclM && !returnTypeM ? ctx.match(factoryFnHeaderRe) : null
          const normalFnM =
            !testM && !typeDeclM && !returnTypeM && !factoryFnM ? ctx.match(normalFnHeaderRe) : null

          if (testM) {
            frameKind = "test"
          } else if (typeDeclM) {
            frameKind = "type"
            frameName = typeDeclM[1]!
          } else if (returnTypeM) {
            let enclosingFactory: ZigScopeFrame | undefined
            for (let fIdx = frames.length - 1; fIdx >= 0; fIdx--) {
              if (frames[fIdx]!.kind === "factory") {
                enclosingFactory = frames[fIdx]
                break
              }
            }
            if (enclosingFactory?.name) {
              frameKind = "type"
              frameName = enclosingFactory.name
            } else {
              frameKind = "anon_struct"
            }
          } else if (factoryFnM) {
            frameKind = "factory"
            frameName = factoryFnM[1]!
          } else if (normalFnM) {
            frameKind = "fn"
            frameName = normalFnM[1]!
          } else if (/\b(?:packed\s+|extern\s+)?(?:struct|union|enum)(?:\s*\([^)]*\))?\s*$/.test(ctx)) {
            frameKind = "anon_struct"
          }

          braceDepth++
          frames.push({ depth: braceDepth, kind: frameKind, name: frameName })
          stmtAccum = ""
        } else {
          braceDepth++
          frames.push({ depth: braceDepth, kind: "block" })
          stmtAccum += "{"
        }
      } else if (ch === "}") {
        if (frames.length > 0 && frames[frames.length - 1]!.depth === braceDepth) {
          frames.pop()
        }
        braceDepth = Math.max(0, braceDepth - 1)
        stmtAccum = parenDepth > 0 || stmtAccum.includes("{") ? stmtAccum + "}" : ""
      } else {
        stmtAccum += ch === "\t" || ch === "\r" ? " " : ch
      }
    }
    stmtAccum += "\n"
    offset += line.length + 1
  }

  return { symbols, lines: lines.length }
}

export function isFunctionLikeKind(kind: SymbolKind): boolean {
  return kind === "function" || kind === "arrow_function" || kind === "method" || kind === "zig_fn"
}

export async function runScan(): Promise<UpstreamManifest> {
  if (!fs.existsSync(UPSTREAM_DIR)) {
    throw new Error(`Missing upstream OpenTUI checkout at ${UPSTREAM_DIR}. Run ./scripts/sync-upstream.sh first.`)
  }
  const lock = await Bun.file(LOCK_FILE).json()
  const symbols: UpstreamSymbol[] = []
  const byPackage: Record<string, { files: number; symbols: number; functions: number; lines: number }> = {}
  let totalFiles = 0

  for (const pkg of TRACKED_OPENTUI_PACKAGES) {
    const pkgRoot = path.join(UPSTREAM_DIR, "packages", pkg.upstreamPackage)
    const srcRoot = path.join(pkgRoot, "src")
    const files = walkSourceFiles(srcRoot, pkg.language)
    let pkgSymbols = 0
    let pkgFunctions = 0
    let pkgLines = 0

    for (const absPath of files) {
      const relFile = path.relative(pkgRoot, absPath).split(path.sep).join("/")
      const scanned =
        pkg.language === "zig"
          ? scanZigFile(pkg, absPath, relFile)
          : scanTypeScriptFile(pkg, absPath, relFile)
      symbols.push(...scanned.symbols)
      pkgSymbols += scanned.symbols.length
      pkgFunctions += scanned.symbols.filter((s) => isFunctionLikeKind(s.kind)).length
      pkgLines += scanned.lines
    }

    totalFiles += files.length
    byPackage[pkg.upstreamPackage] = {
      files: files.length,
      symbols: pkgSymbols,
      functions: pkgFunctions,
      lines: pkgLines,
    }
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
    },
    summary: {
      totalPackages: TRACKED_OPENTUI_PACKAGES.length,
      totalFiles,
      totalSymbols: symbols.length,
      totalFunctions: symbols.filter((s) => isFunctionLikeKind(s.kind)).length,
      byPackage,
      excludedPackages: OUT_OF_SCOPE_OPENTUI_PACKAGES,
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
    `Scanned ${manifest.summary.totalPackages} OpenTUI packages (${manifest.summary.totalFiles} files, ${manifest.summary.totalSymbols} symbols, ${manifest.summary.totalFunctions} functions) -> Packages/OpenTUI/parity/upstream-manifest.json`,
  )
}
