import path from "path"
import fs from "fs"

export interface VectorCase {
  readonly name: string
  readonly args: unknown[]
  readonly compare?: "exact" | "expect_error" | "uuid_v4" | "identifier_prefix_12" | "identifier_shape"
}

export interface VectorSuite {
  readonly fn: string
  readonly description?: string
  readonly cases: readonly VectorCase[]
}

interface RunnerResponse {
  readonly id: string
  readonly ok: boolean
  readonly value: unknown
  readonly error: string | null
}

const ROOT_DIR = path.resolve(import.meta.dir, "../..")
const VECTORS_DIR = path.join(ROOT_DIR, "parity/vectors")
const SNAPSHOTS_PATH = path.join(ROOT_DIR, "Tests/OpenCodeParityTests/Fixtures/oracle-snapshots.json")

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

function validateInvariant(
  mode: NonNullable<VectorCase["compare"]>,
  upstream: RunnerResponse,
  swift: RunnerResponse,
): { pass: boolean; detail?: string } {
  if (mode === "expect_error") {
    const pass = !upstream.ok && !swift.ok
    return {
      pass,
      detail: pass
        ? undefined
        : `expected both to error, got upstream.ok=${upstream.ok} swift.ok=${swift.ok}`,
    }
  }

  if (!upstream.ok || !swift.ok) {
    return {
      pass: false,
      detail: `execution error: upstream=${JSON.stringify(upstream)} swift=${JSON.stringify(swift)}`,
    }
  }

  if (mode === "exact") {
    const pass = deepEqual(upstream.value, swift.value)
    return {
      pass,
      detail: pass
        ? undefined
        : `expected ${JSON.stringify(upstream.value)}, got ${JSON.stringify(swift.value)}`,
    }
  }

  if (mode === "uuid_v4") {
    const re = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    const uOk = typeof upstream.value === "string" && re.test(upstream.value)
    const sOk = typeof swift.value === "string" && re.test(swift.value)
    return {
      pass: uOk && sOk,
      detail: uOk && sOk ? undefined : `invalid uuid_v4: upstream=${upstream.value} swift=${swift.value}`,
    }
  }

  if (mode === "identifier_prefix_12") {
    const re = /^[0-9a-f]{12}[0-9A-Za-z]{14}$/
    const u = String(upstream.value)
    const s = String(swift.value)
    const shapeOk = re.test(u) && re.test(s)
    const prefixMatch = u.slice(0, 12) === s.slice(0, 12)
    return {
      pass: shapeOk && prefixMatch,
      detail:
        shapeOk && prefixMatch
          ? undefined
          : `identifier mismatch: upstream=${u} (prefix ${u.slice(0, 12)}) vs swift=${s} (prefix ${s.slice(0, 12)})`,
    }
  }

  if (mode === "identifier_shape") {
    const re = /^[0-9a-f]{12}[0-9A-Za-z]{14}$/
    const u = String(upstream.value)
    const s = String(swift.value)
    const ok = re.test(u) && re.test(s)
    return {
      pass: ok,
      detail: ok ? undefined : `invalid identifier shape: upstream=${u} swift=${s}`,
    }
  }

  return { pass: false, detail: `unknown compare mode ${mode}` }
}

async function runNDJSONProcess(cmd: string[], lines: string[]): Promise<Map<string, RunnerResponse>> {
  const proc = Bun.spawn(cmd, {
    cwd: ROOT_DIR,
    stdin: new Blob([lines.join("\n") + "\n"]),
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  if (exitCode !== 0) {
    throw new Error(`Command ${cmd.join(" ")} exited with ${exitCode}:\n${stderr}`)
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
  const buildProc = Bun.spawn(["swift", "build", "--product", "opencode-parity-runner"], {
    cwd: ROOT_DIR,
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
    cwd: ROOT_DIR,
    stdout: "pipe",
    stderr: "pipe",
  })
  const binDir = (await new Response(binPathProc.stdout).text()).trim()
  await binPathProc.exited
  const candidate = path.join(binDir, process.platform === "win32" ? "opencode-parity-runner.exe" : "opencode-parity-runner")
  if (!fs.existsSync(candidate)) {
    throw new Error(`Expected Swift parity runner at ${candidate}`)
  }
  return candidate
}

const writeSnapshots = process.argv.includes("--write-snapshots")
const filterArg = process.argv.find((a) => a.startsWith("--filter="))?.slice("--filter=".length)

const vectorFiles = fs
  .readdirSync(VECTORS_DIR)
  .filter((f) => f.endsWith(".json"))
  .sort()

const suites: VectorSuite[] = []
for (const file of vectorFiles) {
  const parsed = (await Bun.file(path.join(VECTORS_DIR, file)).json()) as VectorSuite[]
  for (const suite of parsed) {
    if (!filterArg || suite.fn.includes(filterArg)) {
      suites.push(suite)
    }
  }
}

interface FlatCase {
  id: string
  fn: string
  caseName: string
  args: unknown[]
  compare: NonNullable<VectorCase["compare"]>
}

const flatCases: FlatCase[] = []
let seq = 0
for (const suite of suites) {
  for (const tc of suite.cases) {
    seq++
    flatCases.push({
      id: `v${seq}`,
      fn: suite.fn,
      caseName: tc.name,
      args: tc.args,
      compare: tc.compare ?? "exact",
    })
  }
}

const ndjson = flatCases.map((c) => JSON.stringify({ id: c.id, fn: c.fn, args: c.args }))

console.log(`Building Swift parity runner and evaluating ${flatCases.length} vectors across ${suites.length} functions...`)
const swiftBin = await findSwiftBinary()

const [upstreamResults, swiftResults] = await Promise.all([
  runNDJSONProcess(["bun", path.join(ROOT_DIR, "Tools/parity/oracle.ts")], ndjson),
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
  const u = upstreamResults.get(c.id) ?? { id: c.id, ok: false, value: null, error: "missing upstream response" }
  const s = swiftResults.get(c.id) ?? { id: c.id, ok: false, value: null, error: "missing swift response" }
  const check = validateInvariant(c.compare, u, s)

  const stat = fnStats.get(c.fn) ?? { passed: 0, failed: 0 }
  if (check.pass) {
    passed++
    stat.passed++
  } else {
    failed++
    stat.failed++
    failures.push(`  FAIL [${c.fn}] "${c.caseName}": ${check.detail}`)
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

console.log("\n=== Function-Level Differential Parity (Upstream TS vs Swift) ===")
for (const [fn, stat] of fnStats.entries()) {
  const total = stat.passed + stat.failed
  const badge = stat.failed === 0 ? "PASS" : "FAIL"
  console.log(`  [${badge}] ${fn.padEnd(56)} ${stat.passed}/${total}`)
}

if (failures.length > 0) {
  console.log("\nFailures:")
  for (const f of failures) console.log(f)
}

const fnPassedCount = Array.from(fnStats.values()).filter((s) => s.failed === 0).length
console.log(
  `\nSummary: ${fnPassedCount}/${fnStats.size} functions PASS, ${passed}/${flatCases.length} vectors PASS (${((passed / Math.max(1, flatCases.length)) * 100).toFixed(1)}%)`,
)

if (writeSnapshots) {
  if (failed > 0) {
    console.error("Refusing to write snapshots while differential checks fail.")
    process.exit(1)
  }
  const lock = await Bun.file(path.join(ROOT_DIR, "upstream.lock.json")).json()
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
  console.log(`Wrote ${snapshotEntries.length} golden oracle snapshots -> Tests/OpenCodeParityTests/Fixtures/oracle-snapshots.json`)
}

if (failed > 0) {
  process.exit(1)
}
