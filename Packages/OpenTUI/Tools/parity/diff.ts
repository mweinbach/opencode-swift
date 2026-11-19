import path from "path"
import fs from "fs"

export interface VectorCase {
  readonly name: string
  readonly args: unknown[]
  readonly compare?: "exact" | "expect_error"
}

export interface VectorSuite {
  readonly fn: string
  readonly cases: readonly VectorCase[]
}

interface RunnerResponse {
  readonly id: string
  readonly ok: boolean
  readonly value: unknown
  readonly error: string | null
}

interface SnapshotEntry {
  readonly fn: string
  readonly name: string
  readonly args: unknown[]
  readonly compare: string
  readonly expectedOk: boolean
  readonly expectedValue: unknown
}

interface SnapshotFile {
  readonly upstreamCommit?: unknown
  readonly generatedAt?: unknown
  readonly vectorCount?: unknown
  readonly cases?: unknown
}

const PKG_DIR = path.resolve(import.meta.dir, "../..")
const VECTORS_DIR = path.join(PKG_DIR, "parity/vectors")
const SNAPSHOTS_PATH = path.join(PKG_DIR, "Tests/OpenTUIParityTests/Fixtures/oracle-snapshots.json")

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical)
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(value as Record<string, unknown>).sort()) {
      out[k] = canonical((value as Record<string, unknown>)[k])
    }
    return out
  }
  return value
}

function deepEqual(a: unknown, b: unknown): boolean {
  return JSON.stringify(canonical(a)) === JSON.stringify(canonical(b))
}

function compareSnapshotEntry(index: number, existing: unknown, fresh: SnapshotEntry): string | null {
  if (existing === null || typeof existing !== "object" || Array.isArray(existing)) {
    return `case[${index}] [${fresh.fn}] "${fresh.name}": existing snapshot entry is not an object`
  }
  const ex = existing as Record<string, unknown>
  if (ex.fn !== fresh.fn) {
    return `case[${index}]: fn mismatch (snapshot=${JSON.stringify(ex.fn)} vs fresh=${JSON.stringify(fresh.fn)})`
  }
  if (ex.name !== fresh.name) {
    return `case[${index}] [${fresh.fn}]: name mismatch (snapshot=${JSON.stringify(ex.name)} vs fresh=${JSON.stringify(fresh.name)})`
  }
  if (ex.compare !== fresh.compare) {
    return `case[${index}] [${fresh.fn}] "${fresh.name}": compare mode mismatch (snapshot=${JSON.stringify(ex.compare)} vs fresh=${JSON.stringify(fresh.compare)})`
  }
  if (!deepEqual(ex.args, fresh.args)) {
    return `case[${index}] [${fresh.fn}] "${fresh.name}": args mismatch (snapshot=${JSON.stringify(ex.args)} vs fresh=${JSON.stringify(fresh.args)})`
  }
  if (ex.expectedOk !== fresh.expectedOk) {
    return `case[${index}] [${fresh.fn}] "${fresh.name}": expectedOk mismatch (snapshot=${JSON.stringify(ex.expectedOk)} vs fresh=${JSON.stringify(fresh.expectedOk)})`
  }
  if (!deepEqual(ex.expectedValue, fresh.expectedValue)) {
    return `case[${index}] [${fresh.fn}] "${fresh.name}": expectedValue mismatch (snapshot=${JSON.stringify(ex.expectedValue)} vs fresh=${JSON.stringify(fresh.expectedValue)})`
  }
  return null
}

async function runNDJSONProcess(cmd: string[], lines: string[]): Promise<Map<string, RunnerResponse>> {
  const proc = Bun.spawn(cmd, {
    cwd: PKG_DIR,
    stdin: new Blob([lines.join("\n") + "\n"]),
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  if (code !== 0) {
    throw new Error(`Command ${cmd.join(" ")} exited with ${code}:\n${stderr}`)
  }
  const map = new Map<string, RunnerResponse>()
  for (const line of stdout.split("\n")) {
    if (!line.trim()) continue
    const resp = JSON.parse(line) as RunnerResponse
    map.set(resp.id, resp)
  }
  return map
}

async function findSwiftBinary(): Promise<string> {
  const buildProc = Bun.spawn(["swift", "build", "--product", "opentui-parity-runner"], {
    cwd: PKG_DIR,
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr, code] = await Promise.all([
    new Response(buildProc.stdout).text(),
    new Response(buildProc.stderr).text(),
    buildProc.exited,
  ])
  if (code !== 0) {
    throw new Error(`swift build failed:\n${stdout}\n${stderr}`)
  }

  const binPathProc = Bun.spawn(["swift", "build", "--show-bin-path"], {
    cwd: PKG_DIR,
    stdout: "pipe",
    stderr: "pipe",
  })
  const binDir = (await new Response(binPathProc.stdout).text()).trim()
  await binPathProc.exited
  const candidate = path.join(
    binDir,
    process.platform === "win32" ? "opentui-parity-runner.exe" : "opentui-parity-runner",
  )
  if (!fs.existsSync(candidate)) {
    throw new Error(`Expected Swift OpenTUI parity runner at ${candidate}`)
  }
  return candidate
}

const writeSnapshots = process.argv.includes("--write-snapshots")
const checkSnapshots = process.argv.includes("--check-snapshots")
const filterArg = process.argv.find((a) => a.startsWith("--filter="))?.slice("--filter=".length)

if (writeSnapshots && checkSnapshots) {
  console.error("error: --write-snapshots and --check-snapshots are mutually exclusive.")
  process.exit(1)
}
if (checkSnapshots && filterArg) {
  console.error("error: --check-snapshots cannot be combined with --filter=.")
  process.exit(1)
}

if (!fs.existsSync(VECTORS_DIR)) {
  console.error(`error: missing vector directory at ${VECTORS_DIR}`)
  process.exit(1)
}

const vectorFiles = fs.readdirSync(VECTORS_DIR).filter((f) => f.endsWith(".json")).sort()
if (vectorFiles.length === 0) {
  console.error(`error: no vector JSON files found in ${VECTORS_DIR}`)
  process.exit(1)
}

const vectorErrors: string[] = []
const suites: VectorSuite[] = []
for (const file of vectorFiles) {
  const fullPath = path.join(VECTORS_DIR, file)
  let parsed: unknown
  try {
    parsed = JSON.parse(fs.readFileSync(fullPath, "utf8"))
  } catch (err) {
    vectorErrors.push(
      `Packages/OpenTUI/parity/vectors/${file}: failed to parse JSON (${err instanceof Error ? err.message : String(err)})`,
    )
    continue
  }

  if (!Array.isArray(parsed)) {
    vectorErrors.push(`Packages/OpenTUI/parity/vectors/${file}: expected top-level JSON array of vector suites`)
    continue
  }

  let fileCaseCount = 0
  for (let sIdx = 0; sIdx < parsed.length; sIdx++) {
    const suite = parsed[sIdx] as Partial<VectorSuite> | null
    if (!suite || typeof suite !== "object" || typeof suite.fn !== "string" || suite.fn.trim() === "") {
      vectorErrors.push(`Packages/OpenTUI/parity/vectors/${file}: suite[${sIdx}] is missing a valid 'fn' string`)
      continue
    }
    if (!Array.isArray(suite.cases)) {
      vectorErrors.push(`Packages/OpenTUI/parity/vectors/${file}: suite '${suite.fn}' is missing a 'cases' array`)
      continue
    }
    if (suite.cases.length === 0) {
      vectorErrors.push(`Packages/OpenTUI/parity/vectors/${file}: suite '${suite.fn}' has 0 cases`)
      continue
    }
    fileCaseCount += suite.cases.length
    if (!filterArg || suite.fn.includes(filterArg)) {
      suites.push(suite as VectorSuite)
    }
  }

  if (fileCaseCount === 0) {
    vectorErrors.push(`Packages/OpenTUI/parity/vectors/${file}: vector file has 0 cases`)
  }
}

if (vectorErrors.length > 0) {
  console.error("OpenTUI vector validation failed:")
  for (const err of vectorErrors) console.error(`  ${err}`)
  process.exit(1)
}

const flatCases: Array<{ id: string; fn: string; caseName: string; args: unknown[]; compare: "exact" | "expect_error" }> = []
let seq = 0
for (const suite of suites) {
  for (const tc of suite.cases) {
    seq++
    flatCases.push({
      id: `ot${seq}`,
      fn: suite.fn,
      caseName: tc.name,
      args: tc.args,
      compare: tc.compare ?? "exact",
    })
  }
}

if (flatCases.length === 0) {
  console.error(filterArg ? `error: no OpenTUI vector cases matched --filter=${filterArg}` : "error: no OpenTUI vector cases found.")
  process.exit(1)
}

const ndjson = flatCases.map((c) => JSON.stringify({ id: c.id, fn: c.fn, args: c.args }))

console.log(`Building Swift OpenTUI parity runner and evaluating ${flatCases.length} vectors across ${suites.length} functions...`)
const swiftBin = await findSwiftBinary()

const [upstreamResults, swiftResults] = await Promise.all([
  runNDJSONProcess(["bun", path.join(PKG_DIR, "Tools/parity/oracle.ts")], ndjson),
  runNDJSONProcess([swiftBin], ndjson),
])

let passed = 0
let failed = 0
const fnStats = new Map<string, { passed: number; failed: number }>()
const failures: string[] = []
const snapshotEntries: SnapshotEntry[] = []

for (const c of flatCases) {
  const u = upstreamResults.get(c.id) ?? { id: c.id, ok: false, value: null, error: "missing upstream" }
  const s = swiftResults.get(c.id) ?? { id: c.id, ok: false, value: null, error: "missing swift" }

  let ok = false
  let detail = ""
  if (c.compare === "expect_error") {
    ok = !u.ok && !s.ok
    if (!ok) detail = `expected error on both, got upstream.ok=${u.ok} swift.ok=${s.ok}`
  } else {
    ok = u.ok && s.ok && deepEqual(u.value, s.value)
    if (!ok) {
      detail =
        !u.ok || !s.ok
          ? `execution error: upstream=${JSON.stringify(u)} swift=${JSON.stringify(s)}`
          : `expected ${JSON.stringify(u.value)}, got ${JSON.stringify(s.value)}`
    }
  }

  const stat = fnStats.get(c.fn) ?? { passed: 0, failed: 0 }
  if (ok) {
    passed++
    stat.passed++
  } else {
    failed++
    stat.failed++
    failures.push(`  FAIL [${c.fn}] "${c.caseName}": ${detail}`)
  }
  fnStats.set(c.fn, stat)

  snapshotEntries.push({
    fn: c.fn,
    name: c.caseName,
    args: c.args,
    compare: c.compare,
    expectedOk: u.ok,
    expectedValue: u.value,
  })
}

console.log("\n=== OpenTUI Function-Level Differential Parity (Upstream TS vs Swift) ===")
for (const [fn, stat] of fnStats.entries()) {
  const total = stat.passed + stat.failed
  console.log(`  [${stat.failed === 0 ? "PASS" : "FAIL"}] ${fn.padEnd(56)} ${stat.passed}/${total}`)
}

if (failures.length > 0) {
  console.log("\nFailures:")
  for (const f of failures) console.log(f)
}

const fnPassCount = Array.from(fnStats.values()).filter((s) => s.failed === 0).length
console.log(
  `\nOpenTUI Summary: ${fnPassCount}/${fnStats.size} functions PASS, ${passed}/${flatCases.length} vectors PASS (${((passed / Math.max(1, flatCases.length)) * 100).toFixed(1)}%)`,
)

if (failed > 0) {
  if (writeSnapshots) {
    console.error("Refusing to write OpenTUI snapshots while differential checks fail.")
  }
  process.exit(1)
}

if (writeSnapshots) {
  const lock = await Bun.file(path.join(PKG_DIR, "upstream.lock.json")).json()
  fs.mkdirSync(path.dirname(SNAPSHOTS_PATH), { recursive: true })
  await Bun.write(
    SNAPSHOTS_PATH,
    JSON.stringify(
      {
        upstreamCommit: lock.commit,
        generatedAt: new Date().toISOString(),
        vectorCount: snapshotEntries.length,
        cases: snapshotEntries,
      },
      null,
      2,
    ) + "\n",
  )
  console.log(`Wrote ${snapshotEntries.length} golden OpenTUI oracle snapshots -> Packages/OpenTUI/Tests/OpenTUIParityTests/Fixtures/oracle-snapshots.json`)
}

if (checkSnapshots) {
  const relSnap = "Packages/OpenTUI/Tests/OpenTUIParityTests/Fixtures/oracle-snapshots.json"
  if (!fs.existsSync(SNAPSHOTS_PATH)) {
    console.error(`\nOpenTUI snapshot check FAIL: missing ${relSnap}`)
    console.error("Hint: run './Packages/OpenTUI/scripts/parity.sh snapshot' to generate golden oracle snapshots.")
    process.exit(1)
  }

  let existing: SnapshotFile
  try {
    existing = JSON.parse(fs.readFileSync(SNAPSHOTS_PATH, "utf8")) as SnapshotFile
  } catch (err) {
    console.error(
      `\nOpenTUI snapshot check FAIL: unable to parse ${relSnap} (${err instanceof Error ? err.message : String(err)})`,
    )
    process.exit(1)
  }

  const lock = await Bun.file(path.join(PKG_DIR, "upstream.lock.json")).json()
  const diffs: string[] = []

  if (existing.upstreamCommit !== lock.commit) {
    diffs.push(
      `upstreamCommit mismatch: snapshot=${JSON.stringify(existing.upstreamCommit)} vs upstream.lock.json=${JSON.stringify(lock.commit)}`,
    )
  }
  if (existing.vectorCount !== snapshotEntries.length) {
    diffs.push(`vectorCount mismatch: snapshot=${JSON.stringify(existing.vectorCount)} vs fresh=${snapshotEntries.length}`)
  }
  if (!Array.isArray(existing.cases)) {
    diffs.push("cases field is missing or not an array")
  } else {
    if (existing.cases.length !== snapshotEntries.length) {
      diffs.push(`cases.length mismatch: snapshot=${existing.cases.length} vs fresh=${snapshotEntries.length}`)
    }
    const compareLen = Math.min(existing.cases.length, snapshotEntries.length)
    for (let i = 0; i < compareLen; i++) {
      const diff = compareSnapshotEntry(i, existing.cases[i], snapshotEntries[i]!)
      if (diff) diffs.push(diff)
    }
  }

  if (diffs.length > 0) {
    console.error(
      `\nOpenTUI snapshot check FAIL: ${relSnap} is stale (${diffs.length} difference${diffs.length === 1 ? "" : "s"}):`,
    )
    for (const d of diffs.slice(0, 25)) {
      console.error(`  - ${d}`)
    }
    if (diffs.length > 25) {
      console.error(`  ... and ${diffs.length - 25} more difference(s)`)
    }
    console.error("Hint: run './Packages/OpenTUI/scripts/parity.sh snapshot' to refresh golden oracle snapshots.")
    process.exit(1)
  }

  console.log(
    `OpenTUI snapshot check PASS: ${relSnap} matches fresh oracle results (${snapshotEntries.length} vectors, commit ${String(lock.commit).slice(0, 12)})`,
  )
}
