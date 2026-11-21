// Differential oracle for psychoscript (Code Mode's language), run as a child process of `oracle.ts`.
//
// `oracle.ts` registers a Bun plugin that replaces the `effect` module with lightweight stubs whenever
// upstream/opencode has no node_modules. A Bun plugin's virtual modules are process-global, so psychoscript (whose
// `psychoscript/effect` entry needs the real `effect` ^4.1 from upstream/psychoscript/node_modules) cannot be imported
// in that process. This script runs in a clean Bun process instead and imports the real upstream psychoscript TypeScript
// sources (`upstream/psychoscript/src/index.ts` for the Promise-based root API, and
// `upstream/psychoscript/src/effect/index.ts` for the Effect API used by `packages/codemode`).
//
// Protocol: NDJSON requests `{ id, fn, args }` on stdin, NDJSON responses `{ id, ok, value, error }` on stdout,
// the same contract as `oracle.ts`.
//
// Vector function `psychoscript/src/runtime.ts#execute`:
//   args[0]: program source (string)
//   args[1]: optional `{ mode?: "promise" | "effect", timeoutMs?, maxOutputBytes?, translate?: { functions?, promises? } }`
// When `mode` is absent or `"promise"`, the program runs via v0.2.1's Promise-based `Runtime.make(...).execute(program)`.
// When `mode` is `"effect"`, the program runs via `psychoscript/effect`'s `Runtime.make(...).execute(program)` with a
// per-run `Counter` service (exercising `packages/codemode`'s entry point and v0.2.1's Effect-from-plain-host-fn).
// Mirrored exactly by `PsychoscriptParity` in `Sources/OpenCodeParityRunner/main.swift` and
// `Tests/OpenCodeParityTests/PsychoscriptParity.swift`.
//
// Canonical outcome (see `canonicalOutcome`):
//   { ok: true,  value, logs, warnings[, truncated] }
//   { ok: false, error: { kind, message[, location][, suggestions] }, logs[, truncated] }
import path from "path"

const ROOT_DIR = path.resolve(import.meta.dir, "../..")
const PSYCHOSCRIPT_DIR = path.join(ROOT_DIR, "upstream/psychoscript")
const PSYCHOSCRIPT_SRC = path.join(PSYCHOSCRIPT_DIR, "src")

// Resolve `effect` exactly as psychoscript's own sources do, so the host functions below share its module instance.
const effectPath = Bun.resolveSync("effect", PSYCHOSCRIPT_SRC)
const { Context, Effect } = (await import(effectPath)) as typeof import("effect")
const promiseApi = await import(path.join(PSYCHOSCRIPT_SRC, "index.ts"))
const effectApi = await import(path.join(PSYCHOSCRIPT_SRC, "effect/index.ts"))

const { Host, Runtime } = promiseApi
const { Host: EffectHost, Runtime: EffectRuntime } = effectApi

export const PSYCHOSCRIPT_EXECUTE = "psychoscript/src/runtime.ts#execute"

type Options = {
  mode?: "promise" | "effect"
  timeoutMs?: number
  maxOutputBytes?: number
  translate?: { functions?: "error" | "drop"; promises?: "error" | "await" }
}

class Counter extends Context.Service<Counter, { readonly next: () => number }>()("Counter") {}

const makeCounter = () => {
  let n = 0
  return { next: () => ++n }
}

const makeNamedFn = (f: (args: ReadonlyArray<unknown>) => unknown, name: string, length: number) =>
  Object.defineProperty(Object.defineProperty(f, "name", { value: name }), "length", { value: length })

// Fixed Promise-API host globals shared by corpus programs. Keep in sync with Swift `PsychoscriptParity.promiseGlobals()`.
const promiseGlobals = () => {
  function plainGreet(who: unknown) {
    return `hi:${String(who)}`
  }
  const anonPair = Object.defineProperty((a: unknown, b: unknown) => [a ?? null, b ?? null], "name", { value: "" })
  return {
    // sync: doubles a number.
    double: Host.fn(([n]: ReadonlyArray<unknown>) => Number(n) * 2),
    // sync: returns its first argument as it crossed (exercises the copy in both directions).
    echo: Host.fn(([v]: ReadonlyArray<unknown>) => v ?? null),
    // async: the program gets a promise at once.
    asyncDouble: Host.fn(async ([n]: ReadonlyArray<unknown>) => Number(n) * 2, { type: "async" }),
    // sync: fails with a host failure of its own kind, message and suggestions.
    lookup: Host.fn(([name]: ReadonlyArray<unknown>) => {
      if (name === "a" || name === "b") return `item:${String(name)}`
      throw Host.fail("NotFound", `No item ${String(name)}`, ["a", "b"])
    }),
    // a plain object of host functions acts as a namespace.
    math2: {
      add: Host.fn(([a, b]: ReadonlyArray<unknown>) => Number(a) + Number(b)),
    },
    // v0.2.1 host fn name & length preservation.
    namedFn: Host.fn(makeNamedFn((args) => args.length, "original", 2)),
    declaredFn: Host.fn(function customAdd(args: ReadonlyArray<unknown>) {
      return Number(args[0]) + 1
    }),
    // v0.2.0 Promise-based sync host functions returning Promises / rejecting / throwing.
    later: Host.fn(async ([n]: ReadonlyArray<unknown>) => Number(n) + 1),
    refuse: Host.fn(() => Promise.reject(Host.fail("Refused", "no", ["retry"]))),
    boom: Host.fn(() => {
      throw new Error("boom")
    }),
    // plain host functions in globals and inside returned sync-thenable objects.
    plainGreet,
    box: Host.fn(
      ([label]: ReadonlyArray<unknown>) => ({
        read: () => `box:${String(label)}`,
        anon: anonPair,
      }),
      { type: "sync-thenable" },
    ),
  }
}

// Fixed Effect-API host globals (`psychoscript/effect`, mirroring `packages/codemode` & `test/effect-api.test.ts`).
// Keep in sync with Swift `PsychoscriptParity.effectGlobals()`.
const effectGlobals = () => {
  function read(p: unknown) {
    if (p === "missing") return Effect.fail(EffectHost.fail("NotFound", `no ${String(p)}`))
    if (p === "die") return Effect.die(new Error("plain-boom"))
    return Effect.map(Counter, (c) => `${String(p)}:${c.next()}`)
  }
  return {
    double: EffectHost.fn(([n]: ReadonlyArray<unknown>) => Number(n) * 2),
    echo: EffectHost.fn(([v]: ReadonlyArray<unknown>) => v ?? null),
    asyncDouble: EffectHost.fn(([n]: ReadonlyArray<unknown>) => Effect.succeed(Number(n) * 2), { type: "async" }),
    lookup: EffectHost.fn(([name]: ReadonlyArray<unknown>) => {
      if (name === "a" || name === "b") return `item:${String(name)}`
      throw EffectHost.fail("NotFound", `No item ${String(name)}`, ["a", "b"])
    }),
    math2: {
      add: EffectHost.fn(([a, b]: ReadonlyArray<unknown>) => Number(a) + Number(b)),
    },
    // v0.2.1: EffectHost.fn preserves the wrapped function's own name and length.
    effectNamed: EffectHost.fn(makeNamedFn((args) => Effect.succeed(args.length), "original", 2)),
    effectDeclared: EffectHost.fn(function named(_a: ReadonlyArray<unknown>) {
      return Effect.succeed(1)
    }),
    // Services + Effect failures, defects, and sync throws.
    effectNext: EffectHost.fn(() => Effect.map(Counter, (c) => c.next()), { type: "async", idempotent: true }),
    effectFail: EffectHost.fn(() => Effect.fail(EffectHost.fail("NotFound", "no such thing", ["try another"]))),
    effectTypedFail: EffectHost.fn(() => Effect.fail(new Error("tagged"))),
    effectDie: EffectHost.fn(() => Effect.die(new Error("kaboom"))),
    effectThrown: EffectHost.fn(() =>
      Effect.sync(() => {
        throw new Error("thrown")
      }),
    ),
    // v0.2.1: plain functions inside results and among globals returning Effects.
    fsBox: {
      file: EffectHost.fn(
        ([p]: ReadonlyArray<unknown>) => ({
          text: () => read(p),
          size: () => Effect.succeed(3),
        }),
        { type: "sync-thenable" },
      ),
      Glob: EffectHost.fn(
        ([pattern]: ReadonlyArray<unknown>) => ({
          scan: () => Effect.succeed([String(pattern)]),
        }),
        { constructible: true },
      ),
      read,
    },
  }
}

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
  const limits = {
    ...(options.timeoutMs !== undefined ? { timeoutMs: options.timeoutMs } : {}),
    ...(options.maxOutputBytes !== undefined ? { maxOutputBytes: options.maxOutputBytes } : {}),
  }
  if (options.mode === "effect") {
    const runtime = EffectRuntime.make({
      globals: effectGlobals,
      limits,
      ...(options.translate ? { translate: options.translate } : {}),
    })
    const result = await Effect.runPromise(Effect.provideService(runtime.execute(program), Counter, makeCounter()))
    return canonicalOutcome(result)
  }
  const runtime = Runtime.make({
    globals: promiseGlobals,
    limits,
    ...(options.translate ? { translate: options.translate } : {}),
  })
  const result = await runtime.execute(program)
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
