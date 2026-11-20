// Differential oracle for psychoscript (Code Mode's language), run as a child process of `oracle.ts`.
//
// `oracle.ts` registers a Bun plugin that replaces the `effect` module with lightweight stubs whenever
// upstream/opencode has no node_modules. A Bun plugin's virtual modules are process-global, so psychoscript (which
// needs the real `effect` ^4.1 from upstream/psychoscript/node_modules) cannot be imported in that process. This
// script runs in a clean Bun process instead and imports the real upstream psychoscript TypeScript source
// (`upstream/psychoscript/src/index.ts`) with its real dependencies.
//
// Protocol: NDJSON requests `{ id, fn, args }` on stdin, NDJSON responses `{ id, ok, value, error }` on stdout,
// the same contract as `oracle.ts`.
//
// Vector function `psychoscript/src/runtime.ts#execute`:
//   args[0]: program source (string)
//   args[1]: optional `{ timeoutMs?, maxOutputBytes?, translate?: { functions?, promises? } }`
// The program runs via `Runtime.make({ globals, limits, translate }).execute(program)` with the fixed host globals
// below (mirrored exactly by `PsychoscriptParity` in `Sources/OpenCodeParityRunner/main.swift` and
// `Tests/OpenCodeParityTests/PsychoscriptParity.swift`).
//
// Canonical outcome (see `canonicalOutcome`):
//   { ok: true,  value, logs, warnings[, truncated] }
//   { ok: false, error: { kind, message[, location][, suggestions] }, logs[, truncated] }
// Normalization (documented, deliberately small):
//   - `metadata` is dropped: these programs never write run metadata, so it is always `null` on both sides.
//   - `value` absent/undefined becomes `null` (NDJSON cannot carry `undefined`).
//   - `logs`/`warnings` absent become `[]`; warnings keep only `kind`, `message` (plus `location`/`suggestions`).
// Nothing timing-dependent is normalized: corpus programs avoid `Date.now()`, `new Date()` without arguments,
// `Math.random()` and `crypto.randomUUID()`, and timeout cases use loops that never finish, so they time out
// deterministically with the fixed message `Execution timed out after <timeoutMs>ms.`.
import path from "path"

const ROOT_DIR = path.resolve(import.meta.dir, "../..")
const PSYCHOSCRIPT_DIR = path.join(ROOT_DIR, "upstream/psychoscript")
const PSYCHOSCRIPT_SRC = path.join(PSYCHOSCRIPT_DIR, "src")

// Resolve `effect` exactly as psychoscript's own sources do, so the host functions below share its module instance.
const effectPath = Bun.resolveSync("effect", PSYCHOSCRIPT_SRC)
const { Effect } = (await import(effectPath)) as typeof import("effect")
const psychoscript = await import(path.join(PSYCHOSCRIPT_SRC, "index.ts"))
const { Host, Runtime } = psychoscript

export const PSYCHOSCRIPT_EXECUTE = "psychoscript/src/runtime.ts#execute"

type Options = {
  timeoutMs?: number
  maxOutputBytes?: number
  translate?: { functions?: "error" | "drop"; promises?: "error" | "await" }
}

// Fixed host globals shared by every corpus program. Keep in sync with the Swift `PsychoscriptParity.globals()`.
const globals = () => ({
  // sync: doubles a number.
  double: Host.fn(([n]: ReadonlyArray<unknown>) => Number(n) * 2),
  // sync: returns its first argument as it crossed (exercises the copy in both directions).
  echo: Host.fn(([v]: ReadonlyArray<unknown>) => v ?? null),
  // async: the program gets a promise at once.
  asyncDouble: Host.fn(([n]: ReadonlyArray<unknown>) => Effect.succeed(Number(n) * 2), { type: "async" }),
  // sync: fails with a host failure of its own kind, message and suggestions.
  lookup: Host.fn(([name]: ReadonlyArray<unknown>) => {
    if (name === "a" || name === "b") return `item:${String(name)}`
    throw Host.fail("NotFound", `No item ${String(name)}`, ["a", "b"])
  }),
  // a plain object of host functions acts as a namespace.
  math2: {
    add: Host.fn(([a, b]: ReadonlyArray<unknown>) => Number(a) + Number(b)),
  },
})

type Diagnostic = {
  kind: string
  message: string
  location?: { line: number; column: number }
  suggestions?: ReadonlyArray<string>
}

const canonicalDiagnostic = (d: Diagnostic) => {
  const out: Record<string, unknown> = { kind: d.kind, message: d.message }
  if (d.location) out.location = { line: d.location.line, column: d.location.column }
  if (d.suggestions && d.suggestions.length > 0) out.suggestions = [...d.suggestions]
  return out
}

const canonicalOutcome = (r: any) => {
  const out: Record<string, unknown> = r.ok
    ? {
        ok: true,
        value: r.value === undefined ? null : JSON.parse(JSON.stringify(r.value)),
        logs: [...(r.logs ?? [])],
        warnings: (r.warnings ?? []).map(canonicalDiagnostic),
      }
    : { ok: false, error: canonicalDiagnostic(r.error), logs: [...(r.logs ?? [])] }
  if (r.truncated) out.truncated = true
  return out
}

export const executeProgram = async (program: string, options: Options = {}) => {
  const runtime = Runtime.make({
    globals,
    limits: {
      ...(options.timeoutMs !== undefined ? { timeoutMs: options.timeoutMs } : {}),
      ...(options.maxOutputBytes !== undefined ? { maxOutputBytes: options.maxOutputBytes } : {}),
    },
    ...(options.translate ? { translate: options.translate } : {}),
  })
  const result = await Effect.runPromise(runtime.execute(program))
  return canonicalOutcome(result)
}

const input = await Bun.stdin.text()
for (const line of input.split("\n")) {
  if (!line.trim()) continue
  const req = JSON.parse(line) as { id: string; fn: string; args: unknown[] }
  try {
    if (req.fn !== PSYCHOSCRIPT_EXECUTE) throw new Error(`Unknown psychoscript oracle function: ${req.fn}`)
    const value = await executeProgram(req.args[0] as string, (req.args[1] ?? {}) as Options)
    process.stdout.write(JSON.stringify({ id: req.id, ok: true, value, error: null }) + "\n")
  } catch (err) {
    process.stdout.write(
      JSON.stringify({ id: req.id, ok: false, value: null, error: err instanceof Error ? err.message : String(err) }) +
        "\n",
    )
  }
}
