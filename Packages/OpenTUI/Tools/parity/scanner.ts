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

function sha256Short(text: string): string {
  const normalized = text.replace(/\r\n/g, "\n").replace(/[ \t]+/g, " ").trim()
  const hasher = new Bun.CryptoHasher("sha256")
  hasher.update(normalized)
  return hasher.digest("hex").slice(0, 12)
}

function extractBalancedSnippet(source: string, startIndex: number, maxLen = 4000): string {
  const slice = source.slice(startIndex, startIndex + maxLen)
  let braceDepth = 0
  let parenDepth = 0
  let seenOpenBrace = false
  let inSingle = false
  let inDouble = false
  let inTemplate = false
  let escaped = false

  for (let i = 0; i < slice.length; i++) {
    const ch = slice[i]!
    if (escaped) {
      escaped = false
      continue
    }
    if (ch === "\\" && (inSingle || inDouble || inTemplate)) {
      escaped = true
      continue
    }
    if (!inDouble && !inTemplate && ch === "'") {
      inSingle = !inSingle
      continue
    }
    if (!inSingle && !inTemplate && ch === '"') {
      inDouble = !inDouble
      continue
    }
    if (!inSingle && !inDouble && ch === "`") {
      inTemplate = !inTemplate
      continue
    }
    if (inSingle || inDouble || inTemplate) continue

    if (ch === "(") parenDepth++
    else if (ch === ")") parenDepth = Math.max(0, parenDepth - 1)
    else if (ch === "{") {
      braceDepth++
      seenOpenBrace = true
    } else if (ch === "}") {
      braceDepth--
      if (seenOpenBrace && braceDepth <= 0) return slice.slice(0, i + 1)
    } else if (ch === "\n" && !seenOpenBrace && parenDepth === 0) {
      const restLine = slice.slice(0, i).trim()
      if (
        restLine.length > 0 &&
        !restLine.endsWith("=") &&
        !restLine.endsWith("(") &&
        !restLine.endsWith(",") &&
        !restLine.endsWith("|") &&
        !restLine.endsWith("&") &&
        !restLine.endsWith("=>")
      ) {
        return slice.slice(0, i)
      }
    }
  }
  return slice
}

function walkSourceFiles(dir: string, language: "ts" | "zig"): string[] {
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

function scanTypeScriptFile(
  pkg: (typeof TRACKED_OPENTUI_PACKAGES)[number],
  absPath: string,
  relFile: string,
): { symbols: UpstreamSymbol[]; lines: number } {
  const source = fs.readFileSync(absPath, "utf8")
  const lines = source.split("\n")
  const symbols: UpstreamSymbol[] = []
  const seen = new Set<string>()

  const topExportRe =
    /^export\s+(?:(declare|abstract)\s+)?(?:(async)\s+)?(function|const|let|class|type|interface|enum)\s+([A-Za-z_$][\w$]*)/
  const classMethodRe =
    /^\s+(?:public\s+)?(?:static\s+)?(?:async\s+)?(?:(?:get|set)\s+)?([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\(/

  let activeClass: string | null = null
  let braceDepth = 0
  let offset = 0

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!
    const lineNum = i + 1

    if (braceDepth === 0) {
      const m = line.match(topExportRe)
      if (m) {
        const rawKind = m[3]!
        const name = m[4]!
        let kind: SymbolKind = rawKind === "let" ? "const" : (rawKind as SymbolKind)
        if (rawKind === "const" && /=\s*(?:async\s*)?(?:<[^>]+>\s*)?\([^)]*\)\s*(?::[^=]+)?=>/.test(line)) {
          kind = "arrow_function"
        }
        const snippet = extractBalancedSnippet(source, offset)
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
            line: lineNum,
            signature: line.trim().slice(0, 140),
            bodyHash: sha256Short(snippet),
          })
        }
        if (rawKind === "class") {
          activeClass = name
        }
      }
    } else if (activeClass && braceDepth === 1) {
      const m = line.match(classMethodRe)
      if (m) {
        const methodName = m[1]!
        if (
          methodName !== "constructor" &&
          methodName !== "if" &&
          methodName !== "for" &&
          methodName !== "while" &&
          methodName !== "switch" &&
          methodName !== "catch" &&
          !line.trim().startsWith("private ") &&
          !line.trim().startsWith("protected ") &&
          !methodName.startsWith("_")
        ) {
          const fullName = `${activeClass}.${methodName}`
          const id = `${pkg.upstreamPackage}/${relFile}#${fullName}`
          if (!seen.has(id)) {
            seen.add(id)
            const snippet = extractBalancedSnippet(source, offset)
            symbols.push({
              id,
              package: pkg.upstreamPackage,
              swiftTarget: pkg.swiftTarget,
              tier: pkg.tier,
              file: relFile,
              symbol: fullName,
              kind: "method",
              line: lineNum,
              signature: line.trim().slice(0, 140),
              bodyHash: sha256Short(snippet),
            })
          }
        }
      }
    }

    const stripped = line
      .replace(/\/\/.*$/, "")
      .replace(/'(?:\\.|[^'\\])*'/g, "")
      .replace(/"(?:\\.|[^"\\])*"/g, "")
    for (const ch of stripped) {
      if (ch === "{") braceDepth++
      else if (ch === "}") {
        braceDepth = Math.max(0, braceDepth - 1)
        if (braceDepth === 0) activeClass = null
      }
    }

    offset += line.length + 1
  }

  return { symbols, lines: lines.length }
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

  const zigFnRe = /^(?:pub\s+|export\s+)(?:inline\s+)?fn\s+([A-Za-z_][\w]*)/
  const zigConstRe = /^pub\s+const\s+([A-Za-z_][\w]*)\s*=/
  let offset = 0

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!
    const fnMatch = line.match(zigFnRe)
    const constMatch = !fnMatch ? line.match(zigConstRe) : null
    if (fnMatch || constMatch) {
      const name = (fnMatch ? fnMatch[1] : constMatch![1])!
      const kind: SymbolKind = fnMatch ? "zig_fn" : "zig_const"
      const id = `${pkg.upstreamPackage}/${relFile}#${name}`
      if (!seen.has(id)) {
        seen.add(id)
        const snippet = extractBalancedSnippet(source, offset)
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
          bodyHash: sha256Short(snippet),
        })
      }
    }
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
