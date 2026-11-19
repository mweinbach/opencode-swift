import path from "path"
import fs from "fs"
import {
  FORBIDDEN_PURE_IMPORTS,
  OS_SPECIFIC_IMPORTS,
  OUT_OF_SCOPE_OPENTUI_PACKAGES,
  SWIFT_OPENTUI_TARGET_PURITY,
  TRACKED_OPENTUI_PACKAGES,
} from "./config.ts"
import { isFunctionLikeKind, type UpstreamManifest, type UpstreamSymbol } from "./scanner.ts"

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
): { matched: boolean; symbol?: string; nextLineNumber?: number; nextCodeLine?: string } {
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

function scanSwift(): {
  annotations: SwiftAnnotation[]
  purityViolations: PurityViolation[]
  invalidStatuses: InvalidStatusAnnotation[]
  unpinned: UnpinnedAnnotation[]
  orphans: OrphanAnnotation[]
  stubHygieneViolations: StubHygieneViolation[]
  swiftFiles: number
} {
  const files = walkSwiftFiles(SOURCES_DIR)
  const annotations: SwiftAnnotation[] = []
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
    const lines = fs.readFileSync(absPath, "utf8").split("\n")
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

        annotations.push({
          upstreamId,
          status,
          recordedHash,
          swiftFile: rel,
          swiftLine: i + 1,
          swiftTarget: target,
          swiftSymbol: declCheck.symbol,
        })
      }
    }
  }
  return {
    annotations,
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
  ((failOnDrift || strictMode) && drifted.length > 0) ||
  strictFailures.length > 0
) {
  process.exit(1)
}
