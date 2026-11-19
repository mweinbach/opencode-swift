import path from "path"
import fs from "fs"
import {
  FORBIDDEN_PURE_IMPORTS,
  OS_SPECIFIC_IMPORTS,
  SWIFT_OPENTUI_TARGET_PURITY,
  TRACKED_OPENTUI_PACKAGES,
} from "./config.ts"
import { isFunctionLikeKind, type UpstreamManifest, type UpstreamSymbol } from "./scanner.ts"

export type ParityStatus = "implemented" | "partial" | "stub" | "adapted" | "excluded"

interface SwiftAnnotation {
  readonly upstreamId: string
  readonly status: ParityStatus
  readonly recordedHash?: string
  readonly swiftFile: string
  readonly swiftLine: number
  readonly swiftTarget: string
}

interface PurityViolation {
  readonly target: string
  readonly file: string
  readonly line: number
  readonly importedModule: string
  readonly rule: string
}

const PKG_DIR = path.resolve(import.meta.dir, "../..")
const SOURCES_DIR = path.join(PKG_DIR, "Sources")
const MANIFEST_PATH = path.join(PKG_DIR, "parity/upstream-manifest.json")
const REPORT_PATH = path.join(PKG_DIR, "parity/report.json")
const PARITY_MD_PATH = path.join(PKG_DIR, "PARITY.md")

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

function scanSwift(): { annotations: SwiftAnnotation[]; purityViolations: PurityViolation[]; swiftFiles: number } {
  const files = walkSwiftFiles(SOURCES_DIR)
  const annotations: SwiftAnnotation[] = []
  const purityViolations: PurityViolation[] = []
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
        const meta: Record<string, string> = {}
        for (const pair of (am[2] ?? "").split(/\s+/).filter(Boolean)) {
          const eq = pair.indexOf("=")
          if (eq > 0) meta[pair.slice(0, eq)] = pair.slice(eq + 1)
        }
        annotations.push({
          upstreamId: am[1]!,
          status: (meta.status ?? "implemented") as ParityStatus,
          recordedHash: meta.hash,
          swiftFile: rel,
          swiftLine: i + 1,
          swiftTarget: target,
        })
      }
    }
  }
  return { annotations, purityViolations, swiftFiles: files.length }
}

const manifest = (await Bun.file(MANIFEST_PATH).json()) as UpstreamManifest
const symbolMap = new Map<string, UpstreamSymbol>(manifest.symbols.map((s) => [s.id, s]))
const { annotations, purityViolations, swiftFiles } = scanSwift()

const dangling: SwiftAnnotation[] = []
const drifted: Array<{ annotation: SwiftAnnotation; currentHash: string }> = []
const mappedById = new Map<string, SwiftAnnotation>()

for (const ann of annotations) {
  const up = symbolMap.get(ann.upstreamId)
  if (!up) {
    dangling.push(ann)
    continue
  }
  mappedById.set(ann.upstreamId, ann)
  if (ann.recordedHash && ann.recordedHash !== up.bodyHash) {
    drifted.push({ annotation: ann, currentHash: up.bodyHash })
  }
}

const packageAudits = TRACKED_OPENTUI_PACKAGES.map((spec) => {
  const pkgSymbols = manifest.symbols.filter((s) => s.package === spec.upstreamPackage)
  const meta = manifest.summary.byPackage[spec.upstreamPackage] ?? { files: 0, symbols: 0, functions: 0, lines: 0 }
  let implSyms = 0
  let implFns = 0
  let driftCount = 0
  for (const sym of pkgSymbols) {
    const ann = mappedById.get(sym.id)
    if (!ann) continue
    if (ann.status === "implemented" || ann.status === "adapted") {
      implSyms++
      if (isFunctionLikeKind(sym.kind)) implFns++
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
  }),
  { files: 0, lines: 0, totalSymbols: 0, totalFunctions: 0, implementedSymbols: 0, implementedFunctions: 0 },
)

const report = {
  generatedAt: new Date().toISOString(),
  upstream: manifest.upstream,
  swiftFiles,
  parityAnnotations: annotations.length,
  differentialParity: { verifiedFunctions: diffFunctions, verifiedVectors: diffVectors },
  totals,
  danglingAnnotations: dangling,
  driftedAnnotations: drifted,
  purityViolations,
  packages: packageAudits,
}

await Bun.write(REPORT_PATH, JSON.stringify(report, null, 2) + "\n")

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
  `| Differential oracle-verified functions | ${diffFunctions} (${diffVectors} test vectors) |`,
  `| Upstream code drift alerts | ${drifted.length} |`,
  `| Dangling parity annotations | ${dangling.length} |`,
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

for (const ann of annotations.sort((a, b) => a.upstreamId.localeCompare(b.upstreamId))) {
  const cur = symbolMap.get(ann.upstreamId)?.bodyHash ?? "missing"
  const hashCol = !ann.recordedHash
    ? `\`${cur}\``
    : ann.recordedHash === cur
      ? `\`${ann.recordedHash}\` (synced)`
      : `\`${ann.recordedHash}\` -> \`${cur}\` (**DRIFT**)`
  md.push(`| \`${ann.upstreamId}\` | \`${ann.status}\` | \`${ann.swiftFile}:${ann.swiftLine}\` | ${hashCol} |`)
}

md.push("")
await Bun.write(PARITY_MD_PATH, md.join("\n"))

console.log("=== OpenTUI Code-Level Parity Audit ===")
console.log(`Upstream commit: ${manifest.upstream.commit.slice(0, 12)} (${manifest.upstream.branch})`)
console.log(`Functions:       ${totals.implementedFunctions}/${totals.totalFunctions} (${pct(totals.implementedFunctions, totals.totalFunctions)})`)
console.log(`All symbols:     ${totals.implementedSymbols}/${totals.totalSymbols} (${pct(totals.implementedSymbols, totals.totalSymbols)})`)
console.log(`Diff vectors:    ${diffVectors} across ${diffFunctions} functions`)
console.log(`Drift alerts:    ${drifted.length}`)
console.log(`Dangling refs:   ${dangling.length}`)
console.log(`Purity errors:   ${purityViolations.length}`)

if (dangling.length > 0) {
  for (const d of dangling) console.error(`  DANGLING ${d.swiftFile}:${d.swiftLine} -> ${d.upstreamId}`)
}
if (purityViolations.length > 0) {
  for (const v of purityViolations) console.error(`  PURITY ${v.file}:${v.line} [${v.target}] ${v.rule}`)
}
if (dangling.length > 0 || purityViolations.length > 0 || (process.argv.includes("--fail-on-drift") && drifted.length > 0)) {
  process.exit(1)
}
