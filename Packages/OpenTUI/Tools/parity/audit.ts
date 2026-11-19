import path from "path"
import fs from "fs"
import {
  EXEMPT_OPENTUI_RUNTIME_DEPS,
  FORBIDDEN_PURE_IMPORTS,
  OS_SPECIFIC_IMPORTS,
  OUT_OF_SCOPE_OPENTUI_PACKAGES,
  SWIFT_OPENTUI_TARGET_PURITY,
  TRACKED_OPENTUI_PACKAGES,
} from "./config.ts"
import {
  isFunctionLikeKind,
  isUpstreamFunctionBodyEmpty,
  verifyFileExportsWithTranspiler,
  walkSourceFiles,
  type UpstreamManifest,
  type UpstreamSymbol,
} from "./scanner.ts"

export type ParityStatus = "implemented" | "partial" | "stub" | "adapted" | "excluded"

const VALID_STATUSES = new Set<string>(["implemented", "adapted", "partial", "stub", "excluded"])
const PINNED_HASH_RE = /^[0-9a-f]{12}$/

interface SwiftAnnotation {
  readonly upstreamId: string
  readonly status: string
  readonly recordedHash?: string
  readonly swiftFile: string
  readonly swiftLine: number
  readonly swiftTarget: string
  readonly swiftSymbol?: string
}

interface PurityViolation {
  readonly target: string
  readonly file: string
  readonly line: number
  readonly importedModule: string
  readonly rule: string
}

interface DuplicateAnnotation {
  readonly upstreamId: string
  readonly firstFile: string
  readonly firstLine: number
  readonly duplicateFile: string
  readonly duplicateLine: number
}

interface UnpinnedAnnotation {
  readonly upstreamId: string
  readonly status: string
  readonly recordedHash?: string
  readonly swiftFile: string
  readonly swiftLine: number
}

interface InvalidStatusAnnotation {
  readonly upstreamId: string
  readonly status: string
  readonly swiftFile: string
  readonly swiftLine: number
}

interface OrphanAnnotation {
  readonly upstreamId: string
  readonly swiftFile: string
  readonly swiftLine: number
  readonly nextLineNumber?: number
  readonly nextCodeLine?: string
}

interface DependencyLawViolation {
  readonly target: string
  readonly dependency: string
  readonly source: string
  readonly line?: number
  readonly rule: string
}

interface TestImportViolation {
  readonly file: string
  readonly lines: number[]
  readonly rule: string
}

interface StubHygieneViolation {
  readonly file: string
  readonly line: number
  readonly pattern: string
  readonly snippet: string
}

interface CompilerExportError {
  readonly package: string
  readonly file: string
  readonly exportName: string
  readonly rule: string
}

interface WorkspaceDepError {
  readonly package: string
  readonly dependency: string
  readonly section: "dependencies" | "optionalDependencies" | "peerDependencies"
  readonly version: string
  readonly outOfScopePackage: string
  readonly rule: string
}

interface SubstanceError {
  readonly upstreamId: string
  readonly upstreamKind: string
  readonly swiftFile: string
  readonly swiftLine: number
  readonly swiftDeclKind?: string
  readonly swiftSymbol?: string
  readonly reason: "empty-body" | "non-callable-declaration"
  readonly rule: string
}

interface UnmappedSymbolEntry {
  readonly id: string
  readonly package: string
  readonly file: string
  readonly symbol: string
  readonly kind: string
  readonly line: number
  readonly bodyHash: string
}

interface SwiftAnnotationDeclMeta {
  readonly absPath: string
  readonly declKind?: string
  readonly declLine?: number
  readonly declOffset?: number
}

interface ParsedPackageTarget {
  readonly kind: string
  readonly name: string
  readonly dependencies: Array<{ name: string; package?: string; kind: "string" | "target" | "product" | "byName" }>
}

const PKG_DIR = path.resolve(import.meta.dir, "../..")
const SOURCES_DIR = path.join(PKG_DIR, "Sources")
const TESTS_DIR = path.join(PKG_DIR, "Tests")
const PACKAGE_SWIFT_PATH = path.join(PKG_DIR, "Package.swift")
const UPSTREAM_DIR = fs.existsSync(path.join(PKG_DIR, "upstream/opentui"))
  ? path.join(PKG_DIR, "upstream/opentui")
  : path.resolve(PKG_DIR, "../../upstream/opentui")
const UPSTREAM_PACKAGES_DIR = path.join(UPSTREAM_DIR, "packages")
const MANIFEST_PATH = path.join(PKG_DIR, "parity/upstream-manifest.json")
const REPORT_PATH = path.join(PKG_DIR, "parity/report.json")
const PARITY_MD_PATH = path.join(PKG_DIR, "PARITY.md")

const SWIFT_REAL_DECL_RE =
  /^(?:(?:public|open|internal|private|fileprivate|package)(?:\s*\(\s*set\s*\))?\s+|weak\s+|unowned(?:\s*\(\s*(?:safe|unsafe)\s*\))?\s+|override\s+|static\s+|class\s+|final\s+|indirect\s+|nonisolated(?:\s*\(\s*unsafe\s*\))?\s+|async\s+|mutating\s+|nonmutating\s+|convenience\s+|required\s+|lazy\s+|consuming\s+|borrowing\s+|distributed\s+|prefix\s+|postfix\s+|infix\s+|optional\s+|dynamic\s+)*(func|struct|enum|class|actor|protocol|typealias|let|var|init|deinit|case|extension|subscript|associatedtype|operator|precedencegroup|macro)\b(?:\s+([A-Za-z_`][\w`]*))?/

const SWIFT_IMPORT_LINE_RE =
  /^\s*(?:@preconcurrency\s+)?(?:@_implementationOnly\s+)?(?:@testable\s+)?(?:(?:public|internal|private|fileprivate|package)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][\w]*)(?:\s*\.[\w.]+)?\s*(?:\/\/.*|\/\*.*\*\/)?$/

const STUB_HYGIENE_RULES: ReadonlyArray<{ label: string; regex: RegExp }> = [
  { label: "// TODO:", regex: /\/\/\/?\s*TODO:/ },
  { label: "// FIXME:", regex: /\/\/\/?\s*FIXME:/ },
  { label: 'fatalError("TODO', regex: /fatalError\s*\(\s*"TODO/i },
  { label: 'fatalError("not implemented', regex: /fatalError\s*\(\s*"not implemented/i },
  { label: "unimplemented(", regex: /\bunimplemented\s*\(/ },
]

function walkSwiftFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) return []
  const out: string[] = []
  const stack = [dir]
  while (stack.length > 0) {
    const cur = stack.pop()!
    for (const entry of fs.readdirSync(cur, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(cur, entry.name)
      if (entry.isDirectory()) stack.push(full)
      else if (entry.isFile() && entry.name.endsWith(".swift")) out.push(full)
    }
  }
  return out.sort()
}

function findAnnotatedSwiftDeclaration(
  lines: readonly string[],
  annotationLineIndex: number,
): {
  matched: boolean
  symbol?: string
  declKind?: string
  declLineIndex?: number
  declColOffset?: number
  nextLineNumber?: number
  nextCodeLine?: string
} {
  let blockCommentDepth = 0
  let attrParenDepth = 0

  for (let j = annotationLineIndex + 1; j < lines.length; j++) {
    const rest = lines[j]!
    let idx = 0

    while (idx < rest.length) {
      if (blockCommentDepth > 0) {
        if (rest[idx] === "/" && rest[idx + 1] === "*") {
          blockCommentDepth++
          idx += 2
        } else if (rest[idx] === "*" && rest[idx + 1] === "/") {
          blockCommentDepth--
          idx += 2
        } else {
          idx++
        }
        continue
      }

      if (attrParenDepth > 0) {
        const ch = rest[idx]!
        if (ch === '"') {
          idx++
          while (idx < rest.length) {
            if (rest[idx] === "\\" && idx + 1 < rest.length) {
              idx += 2
            } else if (rest[idx] === '"') {
              idx++
              break
            } else {
              idx++
            }
          }
          continue
        }
        if (ch === "(") attrParenDepth++
        else if (ch === ")") attrParenDepth--
        idx++
        continue
      }

      if (rest[idx] === " " || rest[idx] === "\t" || rest[idx] === "\r") {
        idx++
        continue
      }

      if (rest[idx] === "/" && rest[idx + 1] === "/") {
        break
      }

      if (rest[idx] === "/" && rest[idx + 1] === "*") {
        blockCommentDepth++
        idx += 2
        continue
      }

      const tail = rest.slice(idx)
      if (/^#(?:if\b|else\b|elseif\b|endif\b)/.test(tail)) {
        break
      }

      if (tail[0] === "@") {
        const attrMatch = tail.match(/^@[A-Za-z_][\w.]*/)
        if (attrMatch) {
          idx += attrMatch[0].length
          if (rest[idx] === "(") {
            attrParenDepth = 1
            idx++
          }
          continue
        }
      }

      const code = tail.trim()
      const declMatch = code.match(SWIFT_REAL_DECL_RE)
      if (declMatch) {
        return {
          matched: true,
          symbol: declMatch[2] || declMatch[1],
          declKind: declMatch[1],
          declLineIndex: j,
          declColOffset: idx,
          nextLineNumber: j + 1,
          nextCodeLine: code.slice(0, 120),
        }
      }
      return {
        matched: false,
        nextLineNumber: j + 1,
        nextCodeLine: code.slice(0, 120),
      }
    }
  }

  return { matched: false }
}

function scanSwiftImports(source: string): Array<{ line: number; module: string }> {
  const lines = source.split("\n")
  const imports: Array<{ line: number; module: string }> = []
  let blockCommentDepth = 0
  let inMultilineString = false

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!

    if (inMultilineString) {
      if (line.includes('"""')) {
        let idx = 0
        while (idx < line.length) {
          if (line[idx] === "\\" && idx + 1 < line.length) {
            idx += 2
            continue
          }
          if (line.slice(idx, idx + 3) === '"""') {
            inMultilineString = !inMultilineString
            idx += 3
            continue
          }
          idx++
        }
      }
      continue
    }

    if (blockCommentDepth === 0) {
      const m = line.match(SWIFT_IMPORT_LINE_RE)
      if (m) {
        imports.push({ line: i + 1, module: m[1]! })
      }
    }

    let idx = 0
    let inString = false
    while (idx < line.length) {
      if (blockCommentDepth > 0) {
        if (line[idx] === "/" && line[idx + 1] === "*") {
          blockCommentDepth++
          idx += 2
        } else if (line[idx] === "*" && line[idx + 1] === "/") {
          blockCommentDepth--
          idx += 2
        } else {
          idx++
        }
        continue
      }
      if (inString) {
        if (line[idx] === "\\" && idx + 1 < line.length) {
          idx += 2
        } else if (line[idx] === '"') {
          inString = false
          idx++
        } else {
          idx++
        }
        continue
      }
      if (line[idx] === "/" && line[idx + 1] === "/") {
        break
      }
      if (line[idx] === "/" && line[idx + 1] === "*") {
        blockCommentDepth++
        idx += 2
        continue
      }
      if (line.slice(idx, idx + 3) === '"""') {
        inMultilineString = !inMultilineString
        idx += 3
        continue
      }
      if (line[idx] === '"') {
        inString = true
        idx++
        continue
      }
      idx++
    }
  }

  return imports
}

function stripSwiftComments(source: string): string {
  let out = ""
  let i = 0
  let blockCommentDepth = 0
  let inString = false
  let inMultilineString = false

  while (i < source.length) {
    if (blockCommentDepth > 0) {
      if (source[i] === "/" && source[i + 1] === "*") {
        blockCommentDepth++
        out += "  "
        i += 2
      } else if (source[i] === "*" && source[i + 1] === "/") {
        blockCommentDepth--
        out += "  "
        i += 2
      } else {
        out += source[i] === "\n" ? "\n" : " "
        i++
      }
      continue
    }
    if (inMultilineString) {
      if (source[i] === "\\" && i + 1 < source.length) {
        out += source.slice(i, i + 2)
        i += 2
      } else if (source.slice(i, i + 3) === '"""') {
        inMultilineString = false
        out += '"""'
        i += 3
      } else {
        out += source[i]
        i++
      }
      continue
    }
    if (inString) {
      if (source[i] === "\\" && i + 1 < source.length) {
        out += source.slice(i, i + 2)
        i += 2
      } else if (source[i] === '"') {
        inString = false
        out += '"'
        i++
      } else {
        out += source[i]
        i++
      }
      continue
    }
    if (source[i] === "/" && source[i + 1] === "/") {
      while (i < source.length && source[i] !== "\n") {
        out += " "
        i++
      }
      continue
    }
    if (source[i] === "/" && source[i + 1] === "*") {
      blockCommentDepth++
      out += "  "
      i += 2
      continue
    }
    if (source.slice(i, i + 3) === '"""') {
      inMultilineString = true
      out += '"""'
      i += 3
      continue
    }
    if (source[i] === '"') {
      inString = true
      out += '"'
      i++
      continue
    }
    out += source[i]
    i++
  }

  return out
}

function extractBalancedBlock(
  source: string,
  openIndex: number,
  openChar: string,
  closeChar: string,
): { content: string; endIndex: number } | null {
  if (source[openIndex] !== openChar) return null
  let depth = 0
  let inString = false

  for (let i = openIndex; i < source.length; i++) {
    const ch = source[i]!
    if (inString) {
      if (ch === "\\" && i + 1 < source.length) {
        i++
      } else if (ch === '"') {
        inString = false
      }
      continue
    }
    if (ch === '"') {
      inString = true
      continue
    }
    if (ch === openChar) depth++
    else if (ch === closeChar) {
      depth--
      if (depth === 0) {
        return { content: source.slice(openIndex + 1, i), endIndex: i }
      }
    }
  }
  return null
}

function splitTopLevelItems(source: string): string[] {
  const items: string[] = []
  let start = 0
  let parenDepth = 0
  let bracketDepth = 0
  let braceDepth = 0
  let inString = false

  for (let i = 0; i < source.length; i++) {
    const ch = source[i]!
    if (inString) {
      if (ch === "\\" && i + 1 < source.length) i++
      else if (ch === '"') inString = false
      continue
    }
    if (ch === '"') {
      inString = true
    } else if (ch === "(") {
      parenDepth++
    } else if (ch === ")") {
      parenDepth = Math.max(0, parenDepth - 1)
    } else if (ch === "[") {
      bracketDepth++
    } else if (ch === "]") {
      bracketDepth = Math.max(0, bracketDepth - 1)
    } else if (ch === "{") {
      braceDepth++
    } else if (ch === "}") {
      braceDepth = Math.max(0, braceDepth - 1)
    } else if (ch === "," && parenDepth === 0 && bracketDepth === 0 && braceDepth === 0) {
      const piece = source.slice(start, i).trim()
      if (piece) items.push(piece)
      start = i + 1
    }
  }

  const tail = source.slice(start).trim()
  if (tail) items.push(tail)
  return items
}

function parsePackageSwift(pkgSwiftPath: string): {
  targets: ParsedPackageTarget[]
  packageDepsRaw: string[]
} {
  if (!fs.existsSync(pkgSwiftPath)) return { targets: [], packageDepsRaw: [] }
  const stripped = stripSwiftComments(fs.readFileSync(pkgSwiftPath, "utf8"))
  const targets: ParsedPackageTarget[] = []
  const packageDepsRaw: string[] = []

  // Parse top-level package dependencies if present
  const pkgCallMatch = stripped.match(/\bPackage\s*\(/)
  if (pkgCallMatch && pkgCallMatch.index !== undefined) {
    const pkgOpen = pkgCallMatch.index + pkgCallMatch[0].length - 1
    const pkgBlock = extractBalancedBlock(stripped, pkgOpen, "(", ")")
    if (pkgBlock) {
      for (const topArg of splitTopLevelItems(pkgBlock.content)) {
        const depsMatch = topArg.match(/^dependencies\s*:\s*\[/)
        if (depsMatch) {
          const openB = depsMatch[0].length - 1
          const depsBlock = extractBalancedBlock(topArg, openB, "[", "]")
          if (depsBlock) {
            packageDepsRaw.push(...splitTopLevelItems(depsBlock.content))
          }
        }
      }
    }
  }

  const targetCallRe = /\.(target|executableTarget|testTarget|macro|plugin)\s*\(/g
  let match: RegExpExecArray | null
  while ((match = targetCallRe.exec(stripped)) !== null) {
    const kind = match[1]!
    const openParen = match.index + match[0].length - 1
    const block = extractBalancedBlock(stripped, openParen, "(", ")")
    if (!block) continue

    const nameMatch = block.content.match(/\bname\s*:\s*"([^"]+)"/)
    if (!nameMatch) continue
    const targetName = nameMatch[1]!

    const dependencies: ParsedPackageTarget["dependencies"] = []
    const depsKeyMatch = block.content.match(/\bdependencies\s*:\s*\[/)
    if (depsKeyMatch && depsKeyMatch.index !== undefined) {
      const openBracket = depsKeyMatch.index + depsKeyMatch[0].length - 1
      const depsBlock = extractBalancedBlock(block.content, openBracket, "[", "]")
      if (depsBlock) {
        for (const rawItem of splitTopLevelItems(depsBlock.content)) {
          const strMatch = rawItem.match(/^"([^"]+)"$/)
          if (strMatch) {
            dependencies.push({ name: strMatch[1]!, kind: "string" })
            continue
          }
          const prodMatch = rawItem.match(/^\.product\s*\(([\s\S]*)\)$/)
          if (prodMatch) {
            const pName = prodMatch[1]!.match(/\bname\s*:\s*"([^"]+)"/)
            const pPkg = prodMatch[1]!.match(/\bpackage\s*:\s*"([^"]+)"/)
            if (pName) {
              dependencies.push({ name: pName[1]!, package: pPkg?.[1], kind: "product" })
            }
            continue
          }
          const tgtMatch = rawItem.match(/^\.target\s*\(([\s\S]*)\)$/)
          if (tgtMatch) {
            const tName = tgtMatch[1]!.match(/\bname\s*:\s*"([^"]+)"/)
            if (tName) {
              dependencies.push({ name: tName[1]!, kind: "target" })
            }
            continue
          }
          const byNameMatch = rawItem.match(/^\.byName\s*\(([\s\S]*)\)$/)
          if (byNameMatch) {
            const bName = byNameMatch[1]!.match(/\bname\s*:\s*"([^"]+)"/)
            if (bName) {
              dependencies.push({ name: bName[1]!, kind: "byName" })
            }
          }
        }
      }
    }

    targets.push({ kind, name: targetName, dependencies })
    targetCallRe.lastIndex = block.endIndex + 1
  }

  return { targets, packageDepsRaw }
}

function checkPackageDependencyLaws(): DependencyLawViolation[] {
  const violations: DependencyLawViolation[] = []
  const { targets, packageDepsRaw } = parsePackageSwift(PACKAGE_SWIFT_PATH)

  if (targets.length === 0) {
    violations.push({
      target: "<Package.swift>",
      dependency: "<none>",
      source: "Packages/OpenTUI/Package.swift",
      rule: "Failed to parse any targets from Packages/OpenTUI/Package.swift",
    })
    return violations
  }

  // Check top-level package dependencies for any OpenCode / parent repo dependency
  for (const rawPkgDep of packageDepsRaw) {
    if (/opencode/i.test(rawPkgDep) || /path\s*:\s*"\.\.\//i.test(rawPkgDep)) {
      violations.push({
        target: "OpenTUI",
        dependency: rawPkgDep.slice(0, 80),
        source: "Packages/OpenTUI/Package.swift",
        rule: "Packages/OpenTUI must remain standalone and must NEVER depend on parent swift-opencode",
      })
    }
  }

  const targetByName = new Map(targets.map((t) => [t.name, t]))
  const pureTargets = new Set(
    Object.entries(SWIFT_OPENTUI_TARGET_PURITY)
      .filter(([, tier]) => tier === "pure")
      .map(([name]) => name),
  )

  for (const requiredTarget of pureTargets) {
    if (!targetByName.has(requiredTarget)) {
      violations.push({
        target: requiredTarget,
        dependency: "<missing>",
        source: "Packages/OpenTUI/Package.swift",
        rule: `Expected pure target '${requiredTarget}' was not found in Packages/OpenTUI/Package.swift`,
      })
    }
  }

  function collectReachableDeps(startName: string): Array<{ dep: string; pkg?: string; via: string[] }> {
    const visited = new Set<string>([startName])
    const queue: Array<{ name: string; via: string[] }> = [{ name: startName, via: [] }]
    const found: Array<{ dep: string; pkg?: string; via: string[] }> = []

    while (queue.length > 0) {
      const current = queue.shift()!
      const target = targetByName.get(current.name)
      if (!target) continue
      for (const dep of target.dependencies) {
        if (visited.has(dep.name)) continue
        visited.add(dep.name)
        found.push({ dep: dep.name, pkg: dep.package, via: current.via })
        if (targetByName.has(dep.name)) {
          queue.push({ name: dep.name, via: [...current.via, dep.name] })
        }
      }
    }
    return found
  }

  // Law 1: Pure targets (OpenTUICore, OpenTUIKeymap, OpenTUILayout, OpenTUIRenderables, OpenTUIView) must NEVER depend on OpenTUITerminal (or any non-pure target)
  for (const pureTarget of pureTargets) {
    if (!targetByName.has(pureTarget)) continue
    for (const { dep, via } of collectReachableDeps(pureTarget)) {
      if (dep === "OpenTUITerminal" || !pureTargets.has(dep)) {
        const suffix = via.length > 0 ? ` (transitive via ${via.join(" -> ")})` : ""
        violations.push({
          target: pureTarget,
          dependency: dep,
          source: "Packages/OpenTUI/Package.swift",
          rule: `pure target '${pureTarget}' must NEVER depend on '${dep}'${suffix}`,
        })
      }
    }
  }

  // Law 2: NO target in Packages/OpenTUI may depend on any OpenCode* module
  for (const target of targets) {
    for (const dep of target.dependencies) {
      if (dep.name.startsWith("OpenCode") || (dep.package && /opencode/i.test(dep.package))) {
        violations.push({
          target: target.name,
          dependency: dep.name,
          source: "Packages/OpenTUI/Package.swift",
          rule: `OpenTUI target '${target.name}' must NEVER depend on OpenCode module '${dep.name}'`,
        })
      }
    }
  }

  // Law 3: NO Swift file in Packages/OpenTUI (Sources or Tests) may import any OpenCode* module
  for (const dir of [SOURCES_DIR, TESTS_DIR]) {
    for (const absPath of walkSwiftFiles(dir)) {
      const rel = path.relative(PKG_DIR, absPath).split(path.sep).join("/")
      const target = path.relative(dir, absPath).split(path.sep)[0] ?? "Unknown"
      const imports = scanSwiftImports(fs.readFileSync(absPath, "utf8"))
      for (const imp of imports) {
        if (imp.module.startsWith("OpenCode")) {
          violations.push({
            target,
            dependency: imp.module,
            source: `Packages/OpenTUI/${rel}`,
            line: imp.line,
            rule: `OpenTUI file '${rel}' must NEVER import OpenCode module '${imp.module}'`,
          })
        }
      }
    }
  }

  return violations
}

function checkUntrackedUpstreamPackages(): string[] {
  if (!fs.existsSync(UPSTREAM_PACKAGES_DIR)) return []
  const known = new Set<string>([
    ...TRACKED_OPENTUI_PACKAGES.map((p) => p.upstreamPackage),
    ...OUT_OF_SCOPE_OPENTUI_PACKAGES,
  ])
  const untracked: string[] = []
  for (const entry of fs.readdirSync(UPSTREAM_PACKAGES_DIR, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name.startsWith(".")) continue
    const full = path.join(UPSTREAM_PACKAGES_DIR, entry.name)
    const isDir = entry.isDirectory() || (entry.isSymbolicLink() && fs.statSync(full).isDirectory())
    if (isDir && !known.has(entry.name)) {
      untracked.push(entry.name)
    }
  }
  return untracked
}

function checkTestImports(): TestImportViolation[] {
  const files = walkSwiftFiles(TESTS_DIR)
  const violations: TestImportViolation[] = []

  for (const absPath of files) {
    const rel = path.relative(PKG_DIR, absPath).split(path.sep).join("/")
    const imports = scanSwiftImports(fs.readFileSync(absPath, "utf8"))

    const xctestLines = imports.filter((imp) => imp.module === "XCTest").map((imp) => imp.line)
    const testingLines = imports.filter((imp) => imp.module === "Testing").map((imp) => imp.line)
    const foundationLines = imports
      .filter((imp) => imp.module === "Foundation" || imp.module === "FoundationEssentials")
      .map((imp) => imp.line)

    if (xctestLines.length > 0) {
      violations.push({
        file: rel,
        lines: xctestLines,
        rule: "Tests must use Swift Testing (import Testing), never XCTest",
      })
    }

    if (testingLines.length > 0 && foundationLines.length > 0) {
      violations.push({
        file: rel,
        lines: [...testingLines, ...foundationLines].sort((a, b) => a - b),
        rule: "macOS CLT cross-import violation: file imports both Testing and Foundation/FoundationEssentials",
      })
    }
  }

  return violations
}

const NON_CALLABLE_SWIFT_DECLS = new Set(["struct", "enum", "protocol", "typealias", "class", "actor"])

const SWIFT_DECL_START_KEYWORDS = new Set([
  "public",
  "open",
  "internal",
  "private",
  "fileprivate",
  "package",
  "func",
  "var",
  "let",
  "init",
  "deinit",
  "subscript",
  "struct",
  "class",
  "enum",
  "actor",
  "protocol",
  "extension",
  "typealias",
  "override",
  "static",
  "final",
  "mutating",
  "nonmutating",
  "associatedtype",
  "convenience",
  "required",
  "indirect",
  "nonisolated",
  "case",
])

// Advance past any Swift line comment, nested block comment, regular string,
// multiline string, or raw/extended-delimiter string (including nested interpolations).
function advanceSwiftNonCode(src: string, i: number): number {
  const ch = src[i]!
  const next = src[i + 1] ?? ""

  if (ch === "/" && next === "/") {
    let j = i + 2
    while (j < src.length && src[j] !== "\n") j++
    return j
  }

  if (ch === "/" && next === "*") {
    let j = i + 2
    let depth = 1
    while (j < src.length && depth > 0) {
      if (src[j] === "/" && src[j + 1] === "*") {
        depth++
        j += 2
      } else if (src[j] === "*" && src[j + 1] === "/") {
        depth--
        j += 2
      } else {
        j++
      }
    }
    return j
  }

  if (ch === "#") {
    let hashes = 0
    while (src[i + hashes] === "#") hashes++
    if (src.slice(i + hashes, i + hashes + 3) === '"""') {
      let j = i + hashes + 3
      const closeDelim = '"""' + "#".repeat(hashes)
      const escPrefix = "\\" + "#".repeat(hashes)
      while (j < src.length) {
        if (src.startsWith(escPrefix, j)) {
          if (src[j + escPrefix.length] === "(") {
            j = advanceSwiftBalancedParen(src, j + escPrefix.length)
          } else {
            j += escPrefix.length + 1
          }
          continue
        }
        if (src.startsWith(closeDelim, j)) return j + closeDelim.length
        j++
      }
      return src.length
    }
    if (src[i + hashes] === '"') {
      let j = i + hashes + 1
      const closeDelim = '"' + "#".repeat(hashes)
      const escPrefix = "\\" + "#".repeat(hashes)
      while (j < src.length) {
        if (src.startsWith(escPrefix, j)) {
          if (src[j + escPrefix.length] === "(") {
            j = advanceSwiftBalancedParen(src, j + escPrefix.length)
          } else {
            j += escPrefix.length + 1
          }
          continue
        }
        if (src.startsWith(closeDelim, j)) return j + closeDelim.length
        if (src[j] === "\n") return j
        j++
      }
      return src.length
    }
    return i
  }

  if (src.slice(i, i + 3) === '"""') {
    let j = i + 3
    while (j < src.length) {
      if (src[j] === "\\") {
        if (src[j + 1] === "(") j = advanceSwiftBalancedParen(src, j + 1)
        else j += 2
        continue
      }
      if (src.slice(j, j + 3) === '"""') return j + 3
      j++
    }
    return src.length
  }

  if (ch === '"') {
    let j = i + 1
    while (j < src.length) {
      if (src[j] === "\\") {
        if (src[j + 1] === "(") j = advanceSwiftBalancedParen(src, j + 1)
        else j += 2
        continue
      }
      if (src[j] === '"') return j + 1
      if (src[j] === "\n") return j
      j++
    }
    return src.length
  }

  return i
}

function advanceSwiftBalancedParen(src: string, openParenIdx: number): number {
  let depth = 0
  let i = openParenIdx
  while (i < src.length) {
    const nextI = advanceSwiftNonCode(src, i)
    if (nextI > i) {
      i = nextI
      continue
    }
    if (src[i] === "(") depth++
    else if (src[i] === ")") {
      depth--
      if (depth === 0) return i + 1
    }
    i++
  }
  return src.length
}

function stripSwiftCommentsAndWs(body: string): string {
  let out = ""
  let i = 0
  while (i < body.length) {
    if (body[i] === "/" && body[i + 1] === "/") {
      i += 2
      while (i < body.length && body[i] !== "\n") i++
      continue
    }
    if (body[i] === "/" && body[i + 1] === "*") {
      let depth = 1
      i += 2
      while (i < body.length && depth > 0) {
        if (body[i] === "/" && body[i + 1] === "*") {
          depth++
          i += 2
        } else if (body[i] === "*" && body[i + 1] === "/") {
          depth--
          i += 2
        } else {
          i++
        }
      }
      continue
    }
    const nextI = advanceSwiftNonCode(body, i)
    if (nextI > i) {
      out += body.slice(i, nextI)
      i = nextI
      continue
    }
    if (!/\s/.test(body[i]!)) out += body[i]
    i++
  }
  return out
}

function extractSwiftDeclarationBody(
  src: string,
  declStartOffset: number,
  declKind: string,
): { found: boolean; isEmpty: boolean } {
  let i = declStartOffset
  let parenDepth = 0
  let bracketDepth = 0
  let seenParamParen = declKind === "deinit" || declKind === "var" || declKind === "let"
  let seenEquals = false
  let braceOpen = -1

  while (i < src.length) {
    const nextI = advanceSwiftNonCode(src, i)
    if (nextI > i) {
      i = nextI
      continue
    }
    const ch = src[i]!

    if (ch === "(") {
      parenDepth++
      i++
      continue
    }
    if (ch === ")") {
      parenDepth = Math.max(0, parenDepth - 1)
      if (parenDepth === 0) seenParamParen = true
      i++
      continue
    }
    if (ch === "[") {
      bracketDepth++
      i++
      continue
    }
    if (ch === "]") {
      bracketDepth = Math.max(0, bracketDepth - 1)
      i++
      continue
    }

    // Parameter-list default closures (`= {}`) occur while `parenDepth > 0` and are ignored here.
    if (parenDepth === 0 && bracketDepth === 0) {
      if (ch === "{") {
        braceOpen = i
        break
      }
      if (ch === "}" || ch === ";") {
        return { found: false, isEmpty: false }
      }
      if (ch === "=" && src[i + 1] !== "=" && src[i + 1] !== ">") {
        seenEquals = true
      }
      if (ch === "\n") {
        let k = i + 1
        while (k < src.length) {
          if (src[k] === " " || src[k] === "\t" || src[k] === "\r" || src[k] === "\n") {
            k++
            continue
          }
          if (src[k] === "/" && (src[k + 1] === "/" || src[k + 1] === "*")) {
            k = advanceSwiftNonCode(src, k)
            continue
          }
          break
        }
        const peekChar = src[k] ?? ""
        if (peekChar === "}" || peekChar === "@") {
          return { found: false, isEmpty: false }
        }
        if ((declKind === "var" || declKind === "let") && seenEquals && peekChar !== "{") {
          return { found: false, isEmpty: false }
        }
        const kwMatch = src.slice(k).match(/^([A-Za-z_]\w*)\b/)
        if (kwMatch && SWIFT_DECL_START_KEYWORDS.has(kwMatch[1]!) && seenParamParen) {
          return { found: false, isEmpty: false }
        }
      }
    }
    i++
  }

  if (braceOpen < 0) return { found: false, isEmpty: false }

  let depth = 0
  let j = braceOpen
  while (j < src.length) {
    const nextJ = advanceSwiftNonCode(src, j)
    if (nextJ > j) {
      j = nextJ
      continue
    }
    if (src[j] === "{") depth++
    else if (src[j] === "}") {
      depth--
      if (depth === 0) {
        const inner = src.slice(braceOpen + 1, j)
        return { found: true, isEmpty: stripSwiftCommentsAndWs(inner).length === 0 }
      }
    }
    j++
  }
  return { found: false, isEmpty: false }
}

// Gate 9 — Compiler Export Completeness Gate
function checkCompilerExportCompleteness(manifestData: UpstreamManifest): CompilerExportError[] {
  if (!fs.existsSync(UPSTREAM_DIR)) return []
  const emittedByFile = new Map<string, Set<string>>()
  for (const sym of manifestData.symbols) {
    if (sym.symbol.includes(".")) continue
    const key = `${sym.package}/${sym.file}`
    let set = emittedByFile.get(key)
    if (!set) {
      set = new Set<string>()
      emittedByFile.set(key, set)
    }
    set.add(sym.symbol)
  }

  const errors: CompilerExportError[] = []
  for (const spec of TRACKED_OPENTUI_PACKAGES) {
    if (spec.language !== "ts") continue
    const pkgRoot = path.join(UPSTREAM_DIR, "packages", spec.upstreamPackage)
    const srcRoot = path.join(pkgRoot, "src")
    for (const absPath of walkSourceFiles(srcRoot, "ts")) {
      const relFile = path.relative(pkgRoot, absPath).split(path.sep).join("/")
      const source = fs.readFileSync(absPath, "utf8")
      const emitted = emittedByFile.get(`${spec.upstreamPackage}/${relFile}`) ?? new Set<string>()
      const missing = verifyFileExportsWithTranspiler(absPath, source, emitted)
      for (const exportName of missing) {
        errors.push({
          package: spec.upstreamPackage,
          file: relFile,
          exportName,
          rule: `Upstream TS/TSX local export '${exportName}' in ${spec.upstreamPackage}/${relFile} is missing from Packages/OpenTUI/parity/upstream-manifest.json`,
        })
      }
    }
  }
  return errors
}

// Gate 10 — Workspace Dependency Graph Gate
function checkWorkspaceDependencyGraph(): WorkspaceDepError[] {
  if (!fs.existsSync(UPSTREAM_PACKAGES_DIR)) return []

  const outOfScopeByPkgName = new Map<string, string>()
  for (const outPkg of OUT_OF_SCOPE_OPENTUI_PACKAGES) {
    const outPkgJsonPath = path.join(UPSTREAM_PACKAGES_DIR, outPkg, "package.json")
    if (fs.existsSync(outPkgJsonPath)) {
      try {
        const parsed = JSON.parse(fs.readFileSync(outPkgJsonPath, "utf8")) as { name?: unknown }
        if (typeof parsed.name === "string" && parsed.name.length > 0) {
          outOfScopeByPkgName.set(parsed.name, outPkg)
        }
      } catch {
        // Ignore malformed package.json and rely on fallback name below
      }
    }
    if (!outOfScopeByPkgName.has(`@opentui/${outPkg}`)) {
      outOfScopeByPkgName.set(`@opentui/${outPkg}`, outPkg)
    }
  }

  const trackedPkgNames = new Set<string>()
  for (const spec of TRACKED_OPENTUI_PACKAGES) {
    trackedPkgNames.add(`@opentui/${spec.upstreamPackage}`)
    const pkgJsonPath = path.join(UPSTREAM_PACKAGES_DIR, spec.upstreamPackage, "package.json")
    if (fs.existsSync(pkgJsonPath)) {
      try {
        const parsed = JSON.parse(fs.readFileSync(pkgJsonPath, "utf8")) as { name?: unknown }
        if (typeof parsed.name === "string" && parsed.name.length > 0) {
          trackedPkgNames.add(parsed.name)
        }
      } catch {
        // Ignore malformed package.json
      }
    }
  }

  const errors: WorkspaceDepError[] = []
  const sections = ["dependencies", "optionalDependencies", "peerDependencies"] as const

  for (const spec of TRACKED_OPENTUI_PACKAGES) {
    const pkgJsonPath = path.join(UPSTREAM_PACKAGES_DIR, spec.upstreamPackage, "package.json")
    if (!fs.existsSync(pkgJsonPath)) continue
    let pkgJson: Record<string, unknown>
    try {
      pkgJson = JSON.parse(fs.readFileSync(pkgJsonPath, "utf8")) as Record<string, unknown>
    } catch {
      continue
    }

    for (const section of sections) {
      const deps = pkgJson[section]
      if (!deps || typeof deps !== "object") continue
      for (const [depName, rawVer] of Object.entries(deps as Record<string, unknown>)) {
        const version = String(rawVer ?? "")
        if (Object.prototype.hasOwnProperty.call(EXEMPT_OPENTUI_RUNTIME_DEPS, depName)) continue

        const outPkg = outOfScopeByPkgName.get(depName)
        if (outPkg) {
          errors.push({
            package: spec.upstreamPackage,
            dependency: depName,
            section,
            version,
            outOfScopePackage: outPkg,
            rule: `Tracked OpenTUI package '${spec.upstreamPackage}' has unexempt ${section} dependency '${depName}' on out-of-scope package '${outPkg}'`,
          })
        } else if (version.startsWith("workspace:") && !trackedPkgNames.has(depName)) {
          errors.push({
            package: spec.upstreamPackage,
            dependency: depName,
            section,
            version,
            outOfScopePackage: depName,
            rule: `Tracked OpenTUI package '${spec.upstreamPackage}' has unexempt workspace ${section} dependency '${depName}' (${version}) outside TRACKED_OPENTUI_PACKAGES`,
          })
        }
      }
    }
  }

  return errors
}

// Gate 11 — Swift Implementation Substance Gate
function checkSwiftSubstance(
  annotationsList: readonly SwiftAnnotation[],
  declMetaByAnnotation: ReadonlyMap<SwiftAnnotation, SwiftAnnotationDeclMeta>,
  symMap: ReadonlyMap<string, UpstreamSymbol>,
): SubstanceError[] {
  const errors: SubstanceError[] = []
  const swiftSourceCache = new Map<string, string>()
  const upstreamSourceCache = new Map<string, string | null>()
  const pkgLangByName = new Map(TRACKED_OPENTUI_PACKAGES.map((p) => [p.upstreamPackage, p.language]))

  function readSwiftSource(absPath: string): string {
    let cached = swiftSourceCache.get(absPath)
    if (cached === undefined) {
      cached = fs.readFileSync(absPath, "utf8")
      swiftSourceCache.set(absPath, cached)
    }
    return cached
  }

  function readUpstreamSource(pkg: string, relFile: string): string | null {
    const key = `${pkg}/${relFile}`
    if (upstreamSourceCache.has(key)) return upstreamSourceCache.get(key)!
    const absPath = path.join(UPSTREAM_DIR, "packages", pkg, relFile)
    const content = fs.existsSync(absPath) ? fs.readFileSync(absPath, "utf8") : null
    upstreamSourceCache.set(key, content)
    return content
  }

  for (const ann of annotationsList) {
    if (ann.status !== "implemented") continue
    const up = symMap.get(ann.upstreamId)
    if (!up || !isFunctionLikeKind(up.kind)) continue

    const meta = declMetaByAnnotation.get(ann)
    const declKind = meta?.declKind
    if (!declKind) continue

    if (NON_CALLABLE_SWIFT_DECLS.has(declKind)) {
      errors.push({
        upstreamId: ann.upstreamId,
        upstreamKind: up.kind,
        swiftFile: ann.swiftFile,
        swiftLine: meta.declLine ?? ann.swiftLine,
        swiftDeclKind: declKind,
        swiftSymbol: ann.swiftSymbol,
        reason: "non-callable-declaration",
        rule: `Implemented upstream function '${ann.upstreamId}' (${up.kind}) maps to non-callable Swift '${declKind}' declaration (use a callable declaration or status=adapted)`,
      })
      continue
    }

    if (meta.declOffset === undefined) continue
    const swiftSrc = readSwiftSource(meta.absPath)
    const bodyCheck = extractSwiftDeclarationBody(swiftSrc, meta.declOffset, declKind)
    if (!bodyCheck.found || !bodyCheck.isEmpty) continue

    const upstreamSrc = readUpstreamSource(up.package, up.file)
    const lang = pkgLangByName.get(up.package) ?? "ts"
    const upstreamEmpty = upstreamSrc !== null ? isUpstreamFunctionBodyEmpty(upstreamSrc, up.line, lang) : false
    if (!upstreamEmpty) {
      errors.push({
        upstreamId: ann.upstreamId,
        upstreamKind: up.kind,
        swiftFile: ann.swiftFile,
        swiftLine: meta.declLine ?? ann.swiftLine,
        swiftDeclKind: declKind,
        swiftSymbol: ann.swiftSymbol,
        reason: "empty-body",
        rule: `Implemented upstream function '${ann.upstreamId}' (${up.kind}) maps to an empty '{}' Swift body while the upstream function body is non-empty`,
      })
    }
  }

  return errors
}

function scanSwift(): {
  annotations: SwiftAnnotation[]
  declMetaByAnnotation: Map<SwiftAnnotation, SwiftAnnotationDeclMeta>
  purityViolations: PurityViolation[]
  invalidStatuses: InvalidStatusAnnotation[]
  unpinned: UnpinnedAnnotation[]
  orphans: OrphanAnnotation[]
  stubHygieneViolations: StubHygieneViolation[]
  swiftFiles: number
} {
  const files = walkSwiftFiles(SOURCES_DIR)
  const annotations: SwiftAnnotation[] = []
  const declMetaByAnnotation = new Map<SwiftAnnotation, SwiftAnnotationDeclMeta>()
  const purityViolations: PurityViolation[] = []
  const invalidStatuses: InvalidStatusAnnotation[] = []
  const unpinned: UnpinnedAnnotation[] = []
  const orphans: OrphanAnnotation[] = []
  const stubHygieneViolations: StubHygieneViolation[] = []

  const annotationRe = /^\s*\/\/\s*parity:\s*(\S+)(?:\s+\[([^\]]+)\])?/
  const importRe = /^\s*(?:@preconcurrency\s+)?(?:@_implementationOnly\s+)?import\s+([A-Za-z_][\w]*)/

  for (const absPath of files) {
    const rel = path.relative(PKG_DIR, absPath).split(path.sep).join("/")
    const target = path.relative(SOURCES_DIR, absPath).split(path.sep)[0] ?? "Unknown"
    const purity = SWIFT_OPENTUI_TARGET_PURITY[target]
    const source = fs.readFileSync(absPath, "utf8")
    const lines = source.split("\n")
    const lineOffsets: number[] = []
    let runningOffset = 0
    for (const l of lines) {
      lineOffsets.push(runningOffset)
      runningOffset += l.length + 1
    }
    let ifDepth = 0

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]!
      const trimmed = line.trim()
      if (trimmed.startsWith("#if ")) ifDepth++
      else if (trimmed.startsWith("#endif")) ifDepth = Math.max(0, ifDepth - 1)

      // Production stub hygiene check
      for (const rule of STUB_HYGIENE_RULES) {
        if (rule.regex.test(line)) {
          stubHygieneViolations.push({
            file: rel,
            line: i + 1,
            pattern: rule.label,
            snippet: trimmed.slice(0, 120),
          })
          break
        }
      }

      if (purity) {
        const m = line.match(importRe)
        if (m) {
          const mod = m[1]!
          if (purity === "pure" && FORBIDDEN_PURE_IMPORTS.has(mod)) {
            purityViolations.push({
              target,
              file: rel,
              line: i + 1,
              importedModule: mod,
              rule: `pure target '${target}' must not import '${mod}'`,
            })
          } else if (purity !== "pure" && OS_SPECIFIC_IMPORTS.has(mod) && ifDepth === 0) {
            purityViolations.push({
              target,
              file: rel,
              line: i + 1,
              importedModule: mod,
              rule: `OS-specific import '${mod}' in '${target}' must be wrapped in #if os(...) / #if canImport(...)`,
            })
          }
        }
      }

      const am = line.match(annotationRe)
      if (am) {
        const upstreamId = am[1]!
        const meta: Record<string, string> = {}
        for (const pair of (am[2] ?? "").split(/\s+/).filter(Boolean)) {
          const eq = pair.indexOf("=")
          if (eq > 0) meta[pair.slice(0, eq)] = pair.slice(eq + 1)
        }
        const status = meta.status ?? "implemented"
        const recordedHash = meta.hash

        if (!VALID_STATUSES.has(status)) {
          invalidStatuses.push({
            upstreamId,
            status,
            swiftFile: rel,
            swiftLine: i + 1,
          })
        }

        if ((status === "implemented" || status === "adapted") && (!recordedHash || !PINNED_HASH_RE.test(recordedHash))) {
          unpinned.push({
            upstreamId,
            status,
            recordedHash,
            swiftFile: rel,
            swiftLine: i + 1,
          })
        }

        const declCheck = findAnnotatedSwiftDeclaration(lines, i)
        if (!declCheck.matched) {
          orphans.push({
            upstreamId,
            swiftFile: rel,
            swiftLine: i + 1,
            nextLineNumber: declCheck.nextLineNumber,
            nextCodeLine: declCheck.nextCodeLine,
          })
        }

        const ann: SwiftAnnotation = {
          upstreamId,
          status,
          recordedHash,
          swiftFile: rel,
          swiftLine: i + 1,
          swiftTarget: target,
          swiftSymbol: declCheck.symbol,
        }
        annotations.push(ann)

        if (declCheck.matched && declCheck.declLineIndex !== undefined && declCheck.declColOffset !== undefined) {
          declMetaByAnnotation.set(ann, {
            absPath,
            declKind: declCheck.declKind,
            declLine: declCheck.declLineIndex + 1,
            declOffset: lineOffsets[declCheck.declLineIndex]! + declCheck.declColOffset,
          })
        }
      }
    }
  }
  return {
    annotations,
    declMetaByAnnotation,
    purityViolations,
    invalidStatuses,
    unpinned,
    orphans,
    stubHygieneViolations,
    swiftFiles: files.length,
  }
}

const failOnDrift = process.argv.includes("--fail-on-drift")
const strictMode = process.argv.includes("--strict")
const noWrite = process.argv.includes("--no-write")

const manifest = (await Bun.file(MANIFEST_PATH).json()) as UpstreamManifest
const symbolMap = new Map<string, UpstreamSymbol>(manifest.symbols.map((s) => [s.id, s]))

const {
  annotations,
  declMetaByAnnotation,
  purityViolations,
  invalidStatuses,
  unpinned,
  orphans,
  stubHygieneViolations,
  swiftFiles,
} = scanSwift()

const untrackedUpstreamPackages = checkUntrackedUpstreamPackages()
const dependencyLawViolations = checkPackageDependencyLaws()
const testImportViolations = checkTestImports()
const compilerExportErrors = checkCompilerExportCompleteness(manifest)
const workspaceDepErrors = checkWorkspaceDependencyGraph()
const substanceErrors = checkSwiftSubstance(annotations, declMetaByAnnotation, symbolMap)

const dangling: SwiftAnnotation[] = []
const drifted: Array<{ annotation: SwiftAnnotation; currentHash: string }> = []
const duplicates: DuplicateAnnotation[] = []
const firstSeenById = new Map<string, SwiftAnnotation>()
const mappedById = new Map<string, SwiftAnnotation>()

for (const ann of annotations) {
  const first = firstSeenById.get(ann.upstreamId)
  if (first) {
    duplicates.push({
      upstreamId: ann.upstreamId,
      firstFile: first.swiftFile,
      firstLine: first.swiftLine,
      duplicateFile: ann.swiftFile,
      duplicateLine: ann.swiftLine,
    })
  } else {
    firstSeenById.set(ann.upstreamId, ann)
  }

  const up = symbolMap.get(ann.upstreamId)
  if (!up) {
    dangling.push(ann)
    continue
  }
  if (!mappedById.has(ann.upstreamId)) {
    mappedById.set(ann.upstreamId, ann)
  }
  if (ann.recordedHash && ann.recordedHash !== up.bodyHash) {
    drifted.push({ annotation: ann, currentHash: up.bodyHash })
  }
}

const unmappedSymbolIds: string[] = []
const unmappedSymbolsList: UnmappedSymbolEntry[] = []
const stubSymbolIds: string[] = []
const partialSymbolIds: string[] = []
const unimplementedFunctionIds: string[] = []

const packageAudits = TRACKED_OPENTUI_PACKAGES.map((spec) => {
  const pkgSymbols = manifest.symbols.filter((s) => s.package === spec.upstreamPackage)
  const meta = manifest.summary.byPackage[spec.upstreamPackage] ?? { files: 0, symbols: 0, functions: 0, lines: 0 }
  let implSyms = 0
  let implFns = 0
  let partialSyms = 0
  let stubSyms = 0
  let excludedSyms = 0
  let unmappedSyms = 0
  let driftCount = 0

  for (const sym of pkgSymbols) {
    const ann = mappedById.get(sym.id)
    const isFn = isFunctionLikeKind(sym.kind)
    if (!ann) {
      unmappedSyms++
      unmappedSymbolIds.push(sym.id)
      unmappedSymbolsList.push({
        id: sym.id,
        package: sym.package,
        file: sym.file,
        symbol: sym.symbol,
        kind: sym.kind,
        line: sym.line,
        bodyHash: sym.bodyHash,
      })
      if (isFn) unimplementedFunctionIds.push(sym.id)
      continue
    }
    if (ann.status === "implemented" || ann.status === "adapted") {
      implSyms++
      if (isFn) implFns++
    } else if (ann.status === "partial") {
      partialSyms++
      partialSymbolIds.push(sym.id)
      if (isFn) unimplementedFunctionIds.push(sym.id)
    } else if (ann.status === "stub") {
      stubSyms++
      stubSymbolIds.push(sym.id)
      if (isFn) unimplementedFunctionIds.push(sym.id)
    } else if (ann.status === "excluded") {
      excludedSyms++
      if (isFn) unimplementedFunctionIds.push(sym.id)
    } else if (isFn) {
      unimplementedFunctionIds.push(sym.id)
    }
    if (ann.recordedHash && ann.recordedHash !== sym.bodyHash) driftCount++
  }

  return {
    package: spec.upstreamPackage,
    swiftTarget: spec.swiftTarget,
    tier: spec.tier,
    language: spec.language,
    files: meta.files,
    lines: meta.lines,
    totalSymbols: pkgSymbols.length,
    totalFunctions: pkgSymbols.filter((s) => isFunctionLikeKind(s.kind)).length,
    implementedSymbols: implSyms,
    implementedFunctions: implFns,
    partialSymbols: partialSyms,
    stubSymbols: stubSyms,
    excludedSymbols: excludedSyms,
    unmappedSymbols: unmappedSyms,
    driftedSymbols: driftCount,
  }
})

let diffVectors = 0
let diffFunctions = 0
const snapPath = path.join(PKG_DIR, "Tests/OpenTUIParityTests/Fixtures/oracle-snapshots.json")
if (fs.existsSync(snapPath)) {
  const snap = await Bun.file(snapPath).json()
  diffVectors = snap.vectorCount ?? 0
  diffFunctions = new Set((snap.cases ?? []).map((c: { fn: string }) => c.fn)).size
}

const totals = packageAudits.reduce(
  (acc, p) => ({
    files: acc.files + p.files,
    lines: acc.lines + p.lines,
    totalSymbols: acc.totalSymbols + p.totalSymbols,
    totalFunctions: acc.totalFunctions + p.totalFunctions,
    implementedSymbols: acc.implementedSymbols + p.implementedSymbols,
    implementedFunctions: acc.implementedFunctions + p.implementedFunctions,
    partialSymbols: acc.partialSymbols + p.partialSymbols,
    stubSymbols: acc.stubSymbols + p.stubSymbols,
    excludedSymbols: acc.excludedSymbols + p.excludedSymbols,
    unmappedSymbols: acc.unmappedSymbols + p.unmappedSymbols,
  }),
  {
    files: 0,
    lines: 0,
    totalSymbols: 0,
    totalFunctions: 0,
    implementedSymbols: 0,
    implementedFunctions: 0,
    partialSymbols: 0,
    stubSymbols: 0,
    excludedSymbols: 0,
    unmappedSymbols: 0,
  },
)

const report = {
  generatedAt: new Date().toISOString(),
  upstream: manifest.upstream,
  swiftFiles,
  parityAnnotations: annotations.length,
  differentialParity: { verifiedFunctions: diffFunctions, verifiedVectors: diffVectors },
  totals,
  guards: {
    driftAlerts: drifted.length,
    danglingAnnotations: dangling.length,
    duplicateAnnotations: duplicates.length,
    unpinnedAnnotations: unpinned.length,
    invalidStatusAnnotations: invalidStatuses.length,
    orphanAnnotations: orphans.length,
    untrackedUpstreamPackages: untrackedUpstreamPackages.length,
    dependencyLawViolations: dependencyLawViolations.length,
    testImportViolations: testImportViolations.length,
    stubHygieneViolations: stubHygieneViolations.length,
    purityViolations: purityViolations.length,
    compilerExportErrors: compilerExportErrors.length,
    workspaceDepErrors: workspaceDepErrors.length,
    substanceErrors: substanceErrors.length,
    unmappedSymbols: totals.unmappedSymbols,
    stubSymbols: totals.stubSymbols,
    partialSymbols: totals.partialSymbols,
  },
  danglingAnnotations: dangling,
  driftedAnnotations: drifted,
  duplicateAnnotations: duplicates,
  unpinnedAnnotations: unpinned,
  invalidStatusAnnotations: invalidStatuses,
  orphanAnnotations: orphans,
  untrackedUpstreamPackages,
  dependencyLawViolations,
  testImportViolations,
  stubHygieneViolations,
  purityViolations,
  compilerExportErrors,
  workspaceDepErrors,
  substanceErrors,
  unmappedSymbolsList,
  packages: packageAudits,
}

const pct = (n: number, d: number) => (d === 0 ? "0.0%" : `${((n / d) * 100).toFixed(1)}%`)

const md: string[] = [
  "# swift-opentui Parity Dashboard",
  "",
  `> Auto-generated by \`./Packages/OpenTUI/scripts/parity.sh audit\` against \`anomalyco/opentui\` commit \`${manifest.upstream.commit.slice(0, 12)}\` (\`${manifest.upstream.branch}\`, ${manifest.upstream.commitDate}).`,
  "",
  "## Summary",
  "",
  "| Metric | Count |",
  "| --- | ---: |",
  `| Tracked upstream OpenTUI packages | ${packageAudits.length} |`,
  `| Tracked upstream source files (TS + Zig) | ${totals.files} |`,
  `| Tracked upstream LOC | ${totals.lines.toLocaleString()} |`,
  `| Upstream exported symbols (implemented / total) | ${totals.implementedSymbols} / ${totals.totalSymbols} (${pct(totals.implementedSymbols, totals.totalSymbols)}) |`,
  `| Upstream functions/methods (implemented / total) | ${totals.implementedFunctions} / ${totals.totalFunctions} (${pct(totals.implementedFunctions, totals.totalFunctions)}) |`,
  `| Unmapped / stub / partial symbols | ${totals.unmappedSymbols} / ${totals.stubSymbols} / ${totals.partialSymbols} |`,
  `| Differential oracle-verified functions | ${diffFunctions} (${diffVectors} test vectors) |`,
  `| Upstream code drift alerts | ${drifted.length} |`,
  `| Dangling parity annotations | ${dangling.length} |`,
  `| Duplicate parity annotations | ${duplicates.length} |`,
  `| Unpinned parity annotations (missing hash) | ${unpinned.length} |`,
  `| Invalid parity status annotations | ${invalidStatuses.length} |`,
  `| Orphan parity annotations | ${orphans.length} |`,
  `| Untracked upstream packages | ${untrackedUpstreamPackages.length} |`,
  `| Module dependency law violations | ${dependencyLawViolations.length} |`,
  `| Swift Testing / CLT cross-import violations | ${testImportViolations.length} |`,
  `| Production stub hygiene violations | ${stubHygieneViolations.length} |`,
  `| Cross-platform purity violations | ${purityViolations.length} |`,
  `| Compiler export completeness errors | ${compilerExportErrors.length} |`,
  `| Workspace dependency graph errors | ${workspaceDepErrors.length} |`,
  `| Swift implementation substance errors | ${substanceErrors.length} |`,
  "",
  "## Package Parity Matrix",
  "",
  "| Upstream Package | Lang | Swift Target | Tier | Files | LOC | Functions (Impl/Total) | Symbols (Impl/Total) | Drift |",
  "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
]

for (const p of packageAudits) {
  md.push(
    `| \`packages/${p.package}\` | ${p.language} | \`${p.swiftTarget}\` | \`${p.tier}\` | ${p.files} | ${p.lines.toLocaleString()} | ${p.implementedFunctions}/${p.totalFunctions} (${pct(p.implementedFunctions, p.totalFunctions)}) | ${p.implementedSymbols}/${p.totalSymbols} (${pct(p.implementedSymbols, p.totalSymbols)}) | ${p.driftedSymbols} |`,
  )
}

if (unmappedSymbolsList.length > 0) {
  md.push(
    "",
    "## Unmapped Upstream Symbols",
    "",
    "| Upstream Symbol | Package | Kind | File:Line | Hash |",
    "| --- | --- | --- | --- | --- |",
  )
  for (const sym of unmappedSymbolsList) {
    md.push(`| \`${sym.id}\` | \`${sym.package}\` | \`${sym.kind}\` | \`${sym.file}:${sym.line}\` | \`${sym.bodyHash}\` |`)
  }
}

md.push(
  "",
  "## Implemented Parity Mappings",
  "",
  "| Upstream Symbol | Status | Swift Location | Hash |",
  "| --- | --- | --- | --- |",
)

for (const ann of [...annotations].sort((a, b) => a.upstreamId.localeCompare(b.upstreamId))) {
  const cur = symbolMap.get(ann.upstreamId)?.bodyHash ?? "missing"
  const hashCol = !ann.recordedHash
    ? `\`${cur}\` (unpinned)`
    : ann.recordedHash === cur
      ? `\`${ann.recordedHash}\` (synced)`
      : `\`${ann.recordedHash}\` -> \`${cur}\` (**DRIFT**)`
  md.push(`| \`${ann.upstreamId}\` | \`${ann.status}\` | \`${ann.swiftFile}:${ann.swiftLine}\` | ${hashCol} |`)
}

md.push("")

if (!noWrite) {
  await Bun.write(REPORT_PATH, JSON.stringify(report, null, 2) + "\n")
  await Bun.write(PARITY_MD_PATH, md.join("\n"))
}

console.log("=== OpenTUI Code-Level Parity Audit ===")
console.log(`Upstream commit:   ${manifest.upstream.commit.slice(0, 12)} (${manifest.upstream.branch})`)
console.log(
  `Functions:         ${totals.implementedFunctions}/${totals.totalFunctions} (${pct(totals.implementedFunctions, totals.totalFunctions)})`,
)
console.log(
  `All symbols:       ${totals.implementedSymbols}/${totals.totalSymbols} (${pct(totals.implementedSymbols, totals.totalSymbols)})`,
)
console.log(`Unmapped/Stub/Par: ${totals.unmappedSymbols} / ${totals.stubSymbols} / ${totals.partialSymbols}`)
console.log(`Diff vectors:      ${diffVectors} across ${diffFunctions} functions`)
console.log(`Drift alerts:      ${drifted.length}`)
console.log(`Dangling refs:     ${dangling.length}`)
console.log(`Duplicate refs:    ${duplicates.length}`)
console.log(`Unpinned hashes:   ${unpinned.length}`)
console.log(`Invalid statuses:  ${invalidStatuses.length}`)
console.log(`Orphan refs:       ${orphans.length}`)
console.log(`Untracked pkgs:    ${untrackedUpstreamPackages.length}`)
console.log(`Dep law errors:    ${dependencyLawViolations.length}`)
console.log(`CLT/XCTest errors: ${testImportViolations.length}`)
console.log(`Stub hygiene errs: ${stubHygieneViolations.length}`)
console.log(`Purity errors:     ${purityViolations.length}`)
console.log(`Compiler exports:  ${compilerExportErrors.length}`)
console.log(`Workspace deps:    ${workspaceDepErrors.length}`)
console.log(`Substance errors:  ${substanceErrors.length}`)
if (!noWrite) {
  console.log("Wrote Packages/OpenTUI/parity/report.json and Packages/OpenTUI/PARITY.md")
}

if (dangling.length > 0) {
  console.error("\nDangling parity annotations:")
  for (const d of dangling) console.error(`  DANGLING ${d.swiftFile}:${d.swiftLine} -> ${d.upstreamId}`)
}
if (duplicates.length > 0) {
  console.error("\nDuplicate parity annotations:")
  for (const d of duplicates) {
    console.error(`  DUPLICATE ${d.duplicateFile}:${d.duplicateLine} duplicates ${d.firstFile}:${d.firstLine} -> ${d.upstreamId}`)
  }
}
if (unpinned.length > 0) {
  console.error("\nUnpinned parity annotations (missing or malformed hash=<12-hex>):")
  for (const u of unpinned) {
    console.error(
      `  UNPINNED ${u.swiftFile}:${u.swiftLine} ${u.upstreamId} [status=${u.status} hash=${u.recordedHash ?? "<missing>"}]`,
    )
  }
}
if (invalidStatuses.length > 0) {
  console.error("\nInvalid parity annotation status values:")
  for (const inv of invalidStatuses) {
    console.error(`  INVALID_STATUS ${inv.swiftFile}:${inv.swiftLine} ${inv.upstreamId}: status='${inv.status}'`)
  }
}
if (orphans.length > 0) {
  console.error("\nOrphan parity annotations (not followed by a Swift declaration):")
  for (const o of orphans) {
    const detail = o.nextCodeLine ? `next line ${o.nextLineNumber}: ${o.nextCodeLine}` : "reached end of file"
    console.error(`  ORPHAN ${o.swiftFile}:${o.swiftLine} ${o.upstreamId} (${detail})`)
  }
}
if (untrackedUpstreamPackages.length > 0) {
  console.error("\nUntracked upstream OpenTUI packages (missing from TRACKED_OPENTUI_PACKAGES / OUT_OF_SCOPE_OPENTUI_PACKAGES):")
  for (const pkg of untrackedUpstreamPackages) {
    console.error(`  upstream/opentui/packages/${pkg}`)
  }
}
if (dependencyLawViolations.length > 0) {
  console.error("\nModule dependency law violations:")
  for (const v of dependencyLawViolations) {
    const loc = v.line ? `${v.source}:${v.line}` : v.source
    console.error(`  DEP_LAW ${loc} [${v.target} -> ${v.dependency}] ${v.rule}`)
  }
}
if (testImportViolations.length > 0) {
  console.error("\nSwift Testing / macOS CLT cross-import violations:")
  for (const v of testImportViolations) {
    console.error(`  TEST_IMPORT ${v.file}:${v.lines.join(",")} ${v.rule}`)
  }
}
if (stubHygieneViolations.length > 0) {
  console.error("\nProduction stub hygiene violations:")
  for (const v of stubHygieneViolations) {
    console.error(`  STUB_HYGIENE ${v.file}:${v.line} [${v.pattern}] ${v.snippet}`)
  }
}
if (drifted.length > 0) {
  console.error("\nUpstream drift detected (source hash changed):")
  for (const d of drifted) {
    console.error(
      `  DRIFT ${d.annotation.swiftFile}:${d.annotation.swiftLine} ${d.annotation.upstreamId}: recorded=${d.annotation.recordedHash} upstream=${d.currentHash}`,
    )
  }
}
if (purityViolations.length > 0) {
  console.error("\nCross-platform purity violations:")
  for (const v of purityViolations) {
    console.error(`  PURITY ${v.file}:${v.line} [${v.target}] ${v.rule}`)
  }
}
if (compilerExportErrors.length > 0) {
  console.error("\nCompiler export completeness errors (Gate 9):")
  for (const e of compilerExportErrors) {
    console.error(`  COMPILER_EXPORT ${e.package}/${e.file}#${e.exportName}: ${e.rule}`)
  }
}
if (workspaceDepErrors.length > 0) {
  console.error("\nWorkspace dependency graph errors (Gate 10):")
  for (const e of workspaceDepErrors) {
    console.error(`  WORKSPACE_DEP packages/${e.package} [${e.section}] -> ${e.dependency} (${e.version}): ${e.rule}`)
  }
}
if (substanceErrors.length > 0) {
  console.error("\nSwift implementation substance errors (Gate 11):")
  for (const e of substanceErrors) {
    console.error(
      `  SUBSTANCE ${e.swiftFile}:${e.swiftLine} ${e.upstreamId} [${e.reason} decl=${e.swiftDeclKind ?? "?"}]: ${e.rule}`,
    )
  }
}

const strictFailures: string[] = []
if (strictMode) {
  if (totals.unmappedSymbols > 0) {
    strictFailures.push(
      `unmappedSymbols=${totals.unmappedSymbols} (sample: ${unmappedSymbolIds.slice(0, 10).join(", ")})`,
    )
  }
  if (totals.stubSymbols > 0) {
    strictFailures.push(`stubSymbols=${totals.stubSymbols} (sample: ${stubSymbolIds.slice(0, 10).join(", ")})`)
  }
  if (totals.partialSymbols > 0) {
    strictFailures.push(
      `partialSymbols=${totals.partialSymbols} (sample: ${partialSymbolIds.slice(0, 10).join(", ")})`,
    )
  }
  if (totals.implementedFunctions < totals.totalFunctions) {
    strictFailures.push(
      `implementedFunctions=${totals.implementedFunctions} < totalFunctions=${totals.totalFunctions} (sample: ${unimplementedFunctionIds.slice(0, 10).join(", ")})`,
    )
  }
  if (strictFailures.length > 0) {
    console.error("\nStrict completeness failures (--strict):")
    for (const msg of strictFailures) console.error(`  ${msg}`)
  }
}

if (
  dangling.length > 0 ||
  duplicates.length > 0 ||
  unpinned.length > 0 ||
  invalidStatuses.length > 0 ||
  orphans.length > 0 ||
  untrackedUpstreamPackages.length > 0 ||
  dependencyLawViolations.length > 0 ||
  testImportViolations.length > 0 ||
  stubHygieneViolations.length > 0 ||
  purityViolations.length > 0 ||
  compilerExportErrors.length > 0 ||
  workspaceDepErrors.length > 0 ||
  substanceErrors.length > 0 ||
  ((failOnDrift || strictMode) && drifted.length > 0) ||
  strictFailures.length > 0
) {
  process.exit(1)
}
