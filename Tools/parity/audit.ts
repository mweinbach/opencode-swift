import path from "path"
import fs from "fs"
import {
  FORBIDDEN_PURE_IMPORTS,
  OS_SPECIFIC_IMPORTS,
  SWIFT_TARGET_PURITY,
  TRACKED_PACKAGES,
} from "./config.ts"
import { isFunctionLikeKind, type UpstreamManifest, type UpstreamSymbol } from "./scanner.ts"

export type ParityStatus = "implemented" | "partial" | "stub" | "adapted" | "excluded"

interface SwiftParityAnnotation {
  readonly upstreamId: string
  readonly status: ParityStatus
  readonly recordedHash?: string
  readonly reason?: string
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

const ROOT_DIR = path.resolve(import.meta.dir, "../..")
const SOURCES_DIR = path.join(ROOT_DIR, "Sources")
const MANIFEST_PATH = path.join(ROOT_DIR, "parity/upstream-manifest.json")
const REPORT_PATH = path.join(ROOT_DIR, "parity/report.json")
const PARITY_MD_PATH = path.join(ROOT_DIR, "PARITY.md")

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

function scanSwiftAnnotationsAndPurity(): {
  annotations: SwiftParityAnnotation[]
  purityViolations: PurityViolation[]
  swiftFileCount: number
  swiftPublicSymbolCount: number
} {
  const files = walkSwiftFiles(SOURCES_DIR)
  const annotations: SwiftParityAnnotation[] = []
  const purityViolations: PurityViolation[] = []
  let swiftPublicSymbolCount = 0

  const annotationRe = /^\s*\/\/\s*parity:\s*(\S+)(?:\s+\[([^\]]+)\])?/
  const swiftDeclRe =
    /^\s*(?:public|open)\s+(?:static\s+|class\s+|final\s+|indirect\s+|nonisolated\s+|async\s+)*(?:func|struct|enum|class|actor|protocol|typealias|let|var)\s+([A-Za-z_][\w]*)/
  const importRe = /^\s*(?:@preconcurrency\s+)?(?:@_implementationOnly\s+)?import\s+([A-Za-z_][\w]*)/

  for (const absPath of files) {
    const rel = path.relative(ROOT_DIR, absPath).split(path.sep).join("/")
    const relFromSources = path.relative(SOURCES_DIR, absPath).split(path.sep)
    const target = relFromSources[0] ?? "Unknown"
    const purity = SWIFT_TARGET_PURITY[target]

    const lines = fs.readFileSync(absPath, "utf8").split("\n")
    let ifGuardDepth = 0

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]!
      const trimmed = line.trim()

      if (trimmed.startsWith("#if ")) {
        ifGuardDepth++
      } else if (trimmed.startsWith("#endif")) {
        ifGuardDepth = Math.max(0, ifGuardDepth - 1)
      }

      if (swiftDeclRe.test(line)) {
        swiftPublicSymbolCount++
      }

      // Cross-platform purity check
      if (purity) {
        const impMatch = line.match(importRe)
        if (impMatch) {
          const mod = impMatch[1]!
          if (purity === "pure" && FORBIDDEN_PURE_IMPORTS.has(mod)) {
            purityViolations.push({
              target,
              file: rel,
              line: i + 1,
              importedModule: mod,
              rule: `pure target '${target}' must not import OS-specific module '${mod}'`,
            })
          } else if (purity === "portable" && OS_SPECIFIC_IMPORTS.has(mod)) {
            purityViolations.push({
              target,
              file: rel,
              line: i + 1,
              importedModule: mod,
              rule: `portable target '${target}' must use OpenCodePlatform instead of importing '${mod}'`,
            })
          } else if ((purity === "platform" || purity === "host") && OS_SPECIFIC_IMPORTS.has(mod) && ifGuardDepth === 0) {
            purityViolations.push({
              target,
              file: rel,
              line: i + 1,
              importedModule: mod,
              rule: `OS-specific import '${mod}' in '${target}' must be wrapped in #if os(...) or #if canImport(...)`,
            })
          }
        }
      }

      const annMatch = line.match(annotationRe)
      if (annMatch) {
        const upstreamId = annMatch[1]!
        const metaRaw = annMatch[2] ?? ""
        const meta: Record<string, string> = {}
        for (const pair of metaRaw.split(/\s+/).filter(Boolean)) {
          const eq = pair.indexOf("=")
          if (eq > 0) {
            meta[pair.slice(0, eq)] = pair.slice(eq + 1)
          }
        }
        const status = (meta.status ?? "implemented") as ParityStatus

        // Look ahead up to 5 lines for the annotated Swift declaration
        let swiftSymbol: string | undefined
        for (let look = i + 1; look < Math.min(lines.length, i + 6); look++) {
          const dm = lines[look]!.match(swiftDeclRe)
          if (dm) {
            swiftSymbol = dm[1]
            break
          }
        }

        annotations.push({
          upstreamId,
          status,
          recordedHash: meta.hash,
          reason: meta.reason,
          swiftFile: rel,
          swiftLine: i + 1,
          swiftTarget: target,
          swiftSymbol,
        })
      }
    }
  }

  return {
    annotations,
    purityViolations,
    swiftFileCount: files.length,
    swiftPublicSymbolCount,
  }
}

const manifest = (await Bun.file(MANIFEST_PATH).json()) as UpstreamManifest
const symbolMap = new Map<string, UpstreamSymbol>(manifest.symbols.map((s) => [s.id, s]))

const { annotations, purityViolations, swiftFileCount, swiftPublicSymbolCount } =
  scanSwiftAnnotationsAndPurity()

const dangling: SwiftParityAnnotation[] = []
const drifted: Array<{ annotation: SwiftParityAnnotation; currentHash: string }> = []
const mappedById = new Map<string, SwiftParityAnnotation>()

for (const ann of annotations) {
  const upstream = symbolMap.get(ann.upstreamId)
  if (!upstream) {
    dangling.push(ann)
    continue
  }
  mappedById.set(ann.upstreamId, ann)
  if (ann.recordedHash && ann.recordedHash !== upstream.bodyHash) {
    drifted.push({ annotation: ann, currentHash: upstream.bodyHash })
  }
}

interface PackageAudit {
  package: string
  swiftTarget: string
  tier: string
  files: number
  lines: number
  totalSymbols: number
  totalFunctions: number
  implementedSymbols: number
  implementedFunctions: number
  partialSymbols: number
  stubSymbols: number
  excludedSymbols: number
  driftedSymbols: number
}

const packageAudits: PackageAudit[] = []
for (const spec of TRACKED_PACKAGES) {
  const pkgSymbols = manifest.symbols.filter((s) => s.package === spec.upstreamPackage)
  const meta = manifest.summary.byPackage[spec.upstreamPackage] ?? { files: 0, symbols: 0, functions: 0, lines: 0 }
  let implementedSymbols = 0
  let implementedFunctions = 0
  let partialSymbols = 0
  let stubSymbols = 0
  let excludedSymbols = 0
  let driftedSymbols = 0

  for (const sym of pkgSymbols) {
    const ann = mappedById.get(sym.id)
    if (!ann) continue
    const isFn = isFunctionLikeKind(sym.kind)
    if (ann.status === "implemented" || ann.status === "adapted") {
      implementedSymbols++
      if (isFn) implementedFunctions++
    } else if (ann.status === "partial") {
      partialSymbols++
    } else if (ann.status === "stub") {
      stubSymbols++
    } else if (ann.status === "excluded") {
      excludedSymbols++
    }
    if (ann.recordedHash && ann.recordedHash !== sym.bodyHash) {
      driftedSymbols++
    }
  }

  packageAudits.push({
    package: spec.upstreamPackage,
    swiftTarget: spec.swiftTarget,
    tier: spec.tier,
    files: meta.files,
    lines: meta.lines,
    totalSymbols: pkgSymbols.length,
    totalFunctions: pkgSymbols.filter((s) => isFunctionLikeKind(s.kind)).length,
    implementedSymbols,
    implementedFunctions,
    partialSymbols,
    stubSymbols,
    excludedSymbols,
    driftedSymbols,
  })
}

// Compute snapshot test coverage if available
let differentialVectors = 0
let differentialFunctions = 0
const snapshotsPath = path.join(ROOT_DIR, "Tests/OpenCodeParityTests/Fixtures/oracle-snapshots.json")
if (fs.existsSync(snapshotsPath)) {
  const snap = await Bun.file(snapshotsPath).json()
  differentialVectors = snap.vectorCount ?? 0
  differentialFunctions = new Set((snap.cases ?? []).map((c: { fn: string }) => c.fn)).size
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
  swiftWorkspace: {
    swiftFiles: swiftFileCount,
    publicSymbols: swiftPublicSymbolCount,
    parityAnnotations: annotations.length,
  },
  differentialParity: {
    verifiedFunctions: differentialFunctions,
    verifiedVectors: differentialVectors,
  },
  totals,
  danglingAnnotations: dangling,
  driftedAnnotations: drifted,
  purityViolations,
  packages: packageAudits,
}

await Bun.write(REPORT_PATH, JSON.stringify(report, null, 2) + "\n")

// Generate PARITY.md dashboard
function pct(num: number, den: number): string {
  if (den === 0) return "0.0%"
  return `${((num / den) * 100).toFixed(1)}%`
}

const mdLines: string[] = [
  "# swift-opencode Parity Dashboard",
  "",
  `> Auto-generated by \`./scripts/parity.sh audit\` against \`anomalyco/opencode\` commit \`${manifest.upstream.commit.slice(0, 12)}\` (\`${manifest.upstream.branch}\`, ${manifest.upstream.commitDate}).`,
  "",
  "## Summary",
  "",
  `| Metric | Count |`,
  `| --- | ---: |`,
  `| Tracked upstream packages | ${packageAudits.length} |`,
  `| Tracked upstream source files | ${totals.files} |`,
  `| Tracked upstream LOC | ${totals.lines.toLocaleString()} |`,
  `| Upstream exported symbols (implemented / total) | ${totals.implementedSymbols} / ${totals.totalSymbols} (${pct(totals.implementedSymbols, totals.totalSymbols)}) |`,
  `| Upstream functions (implemented / total) | ${totals.implementedFunctions} / ${totals.totalFunctions} (${pct(totals.implementedFunctions, totals.totalFunctions)}) |`,
  `| Differential oracle-verified functions | ${differentialFunctions} (${differentialVectors} test vectors) |`,
  `| Upstream code drift alerts | ${drifted.length} |`,
  `| Dangling parity annotations | ${dangling.length} |`,
  `| Cross-platform purity violations | ${purityViolations.length} |`,
  "",
  "## Package Parity Matrix",
  "",
  "| Upstream Package | Swift Target | Tier | Files | LOC | Functions (Impl/Total) | Symbols (Impl/Total) | Drift |",
  "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
]

for (const p of packageAudits) {
  mdLines.push(
    `| \`packages/${p.package}\` | \`${p.swiftTarget}\` | \`${p.tier}\` | ${p.files} | ${p.lines.toLocaleString()} | ${p.implementedFunctions}/${p.totalFunctions} (${pct(p.implementedFunctions, p.totalFunctions)}) | ${p.implementedSymbols}/${p.totalSymbols} (${pct(p.implementedSymbols, p.totalSymbols)}) | ${p.driftedSymbols} |`,
  )
}

mdLines.push(
  "",
  "## Implemented Parity Mappings",
  "",
  "| Upstream Symbol | Status | Swift Location | Hash |",
  "| --- | --- | --- | --- |",
)

for (const ann of annotations.sort((a, b) => a.upstreamId.localeCompare(b.upstreamId))) {
  const current = symbolMap.get(ann.upstreamId)?.bodyHash ?? "missing"
  const hashStatus = !ann.recordedHash
    ? `\`${current}\` (unpinned)`
    : ann.recordedHash === current
      ? `\`${ann.recordedHash}\` (synced)`
      : `\`${ann.recordedHash}\` -> \`${current}\` (**DRIFT**)`
  mdLines.push(
    `| \`${ann.upstreamId}\` | \`${ann.status}\` | \`${ann.swiftFile}:${ann.swiftLine}\` | ${hashStatus} |`,
  )
}

mdLines.push(
  "",
  "## Out-of-Scope Web/Electron Packages",
  "",
  `Not targeted for the Swift native port (web/SolidJS/Electron GUI & build helpers): ${manifest.summary.excludedWebToolingPackages.map((p) => `\`${p}\``).join(", ")}.`,
  "",
)

await Bun.write(PARITY_MD_PATH, mdLines.join("\n"))

// Terminal output
console.log("=== Code-Level Parity Audit ===")
console.log(`Upstream commit: ${manifest.upstream.commit.slice(0, 12)} (${manifest.upstream.branch})`)
console.log(
  `Functions:       ${totals.implementedFunctions}/${totals.totalFunctions} (${pct(totals.implementedFunctions, totals.totalFunctions)})`,
)
console.log(
  `All symbols:     ${totals.implementedSymbols}/${totals.totalSymbols} (${pct(totals.implementedSymbols, totals.totalSymbols)})`,
)
console.log(`Diff vectors:    ${differentialVectors} across ${differentialFunctions} functions`)
console.log(`Drift alerts:    ${drifted.length}`)
console.log(`Dangling refs:   ${dangling.length}`)
console.log(`Purity errors:   ${purityViolations.length}`)
console.log("Wrote parity/report.json and PARITY.md")

if (dangling.length > 0) {
  console.error("\nDangling parity annotations:")
  for (const d of dangling) console.error(`  ${d.swiftFile}:${d.swiftLine} -> ${d.upstreamId}`)
}
if (drifted.length > 0) {
  console.error("\nUpstream drift detected (source hash changed):")
  for (const d of drifted) {
    console.error(
      `  ${d.annotation.swiftFile}:${d.annotation.swiftLine} ${d.annotation.upstreamId}: recorded=${d.annotation.recordedHash} upstream=${d.currentHash}`,
    )
  }
}
if (purityViolations.length > 0) {
  console.error("\nCross-platform purity violations:")
  for (const v of purityViolations) {
    console.error(`  ${v.file}:${v.line} [${v.target}] ${v.rule}`)
  }
}

if (dangling.length > 0 || purityViolations.length > 0 || (process.argv.includes("--fail-on-drift") && drifted.length > 0)) {
  process.exit(1)
}
