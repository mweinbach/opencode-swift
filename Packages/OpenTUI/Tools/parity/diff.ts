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
const filterArg = process.argv.find((a) => a.startsWith("--filter="))?.slice("--filter=".length)

const vectorFiles = fs.readdirSync(VECTORS_DIR).filter((f) => f.endsWith(".json")).sort()
const suites: VectorSuite[] = []
for (const file of vectorFiles) {
  const parsed = (await Bun.file(path.join(VECTORS_DIR, file)).json()) as VectorSuite[]
  for (const suite of parsed) {
    if (!filterArg || suite.fn.includes(filterArg)) suites.push(suite)
  }
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
const snapshotEntries: Array<{
  fn: string
  name: string
  args: unknown[]
  compare: string
  expectedOk: boolean
  expectedValue: unknown
}> = []

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

if (writeSnapshots) {
  if (failed > 0) {
    console.error("Refusing to write OpenTUI snapshots while differential checks fail.")
    process.exit(1)
  }
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

if (failed > 0) process.exit(1)
