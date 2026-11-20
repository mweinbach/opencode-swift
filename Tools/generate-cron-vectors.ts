#!/usr/bin/env bun
// Generates golden differential test vectors for `CoreAutomation.Cron` and `CoreAutomation.Service`
// directly from upstream OpenCode's pinned Effect 4.1.0 `Cron` & `DateTime` implementation.
//
// Usage:
//   bun Tools/generate-cron-vectors.ts           # print JSON summary
//   bun Tools/generate-cron-vectors.ts --write   # write Tests/OpenCodeCoreTests/CronVectorsData.swift

import fs from "fs"
import path from "path"
import { pathToFileURL } from "url"

const ROOT_DIR = path.resolve(import.meta.dir, "..")
const OUTPUT_PATH = path.join(ROOT_DIR, "Tests/OpenCodeCoreTests/CronVectorsData.swift")

// Locate the exact Effect 4.1.0 package used by upstream opencode (from upstream/psychoscript or bun cache).
function resolveEffectPath(): string {
  const candidates = [
    path.join(ROOT_DIR, "upstream/opencode/node_modules/effect/dist/index.js"),
    path.join(ROOT_DIR, "upstream/psychoscript/node_modules/effect/dist/index.js"),
    path.join(process.env.HOME ?? "", ".bun/install/cache/effect@4.1.0@@@1/dist/index.js"),
  ]
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate
  }
  throw new Error(`Could not locate effect@4.1.0 in: ${candidates.join(", ")}`)
}

const effectMod = await import(pathToFileURL(resolveEffectPath()).href)
const { Cron, DateTime, Option, Result } = effectMod

const HOUR = 60 * 60_000
const cronNext = Option.liftThrowable(Cron.next)

// Exact mirror of upstream `packages/core/src/automation.ts#nextCron`
function nextCron(cron: unknown, now: number, from = now): number | undefined {
  const next = cronNext(cron, new Date(from))
  if (Option.isNone(next)) return undefined
  const at = next.value.getTime()
  return at > now ? at : nextCron(cron, now, at + HOUR)
}

interface ValidCase {
  label: string
  expression: string
  tz: string
  nowISO: string
}

interface InvalidCase {
  label: string
  expression: string
  tz?: string
  nowISO?: string
}

const validCases: ValidCase[] = [
  // Basic 5-field expressions in UTC
  { label: "every minute UTC", expression: "* * * * *", tz: "UTC", nowISO: "2026-06-15T12:34:00.000Z" },
  { label: "every minute mid-second UTC", expression: "* * * * *", tz: "UTC", nowISO: "2026-06-15T12:34:45.500Z" },
  { label: "every 5 minutes UTC", expression: "*/5 * * * *", tz: "UTC", nowISO: "2026-06-15T12:34:00.000Z" },
  { label: "every 15 minutes on boundary", expression: "*/15 * * * *", tz: "UTC", nowISO: "2026-06-15T12:30:00.000Z" },
  { label: "step from offset 5/10", expression: "5/10 * * * *", tz: "UTC", nowISO: "2026-06-15T12:04:00.000Z" },
  { label: "step from offset wrap 5/10", expression: "5/10 * * * *", tz: "UTC", nowISO: "2026-06-15T12:55:00.000Z" },
  { label: "range with step 10-40/10", expression: "10-40/10 * * * *", tz: "UTC", nowISO: "2026-06-15T12:35:00.000Z" },
  { label: "comma list minutes", expression: "3,17,42 * * * *", tz: "UTC", nowISO: "2026-06-15T12:17:00.000Z" },
  { label: "wildcard plus list *,5", expression: "*,5 9 * * *", tz: "UTC", nowISO: "2026-06-15T09:00:00.000Z" },
  { label: "*/1 equals wildcard", expression: "*/1 * * * *", tz: "UTC", nowISO: "2026-06-15T12:00:00.000Z" },
  { label: "midnight daily UTC", expression: "0 0 * * *", tz: "UTC", nowISO: "2026-06-15T00:00:00.000Z" },
  { label: "weekday 9am mon-fri", expression: "0 9 * * 1-5", tz: "UTC", nowISO: "2026-06-12T09:00:00.000Z" }, // Friday -> Monday
  { label: "weekday aliases MON-FRI", expression: "30 8 * * MON-FRI", tz: "UTC", nowISO: "2026-06-13T10:00:00.000Z" }, // Saturday -> Monday
  { label: "weekday 7 normalized to Sunday", expression: "0 10 * * 7", tz: "UTC", nowISO: "2026-06-13T10:00:00.000Z" }, // Saturday -> Sunday
  { label: "weekday range 5-7 includes Sun/Fri/Sat", expression: "0 10 * * 5-7", tz: "UTC", nowISO: "2026-06-14T10:00:00.000Z" }, // Sun -> Fri
  { label: "month aliases jan,jun,dec", expression: "0 0 1 jan,jun,dec *", tz: "UTC", nowISO: "2026-06-01T00:00:00.000Z" },
  { label: "month range mar-nov/3", expression: "15 6 1 mar-nov/3 *", tz: "UTC", nowISO: "2026-06-01T06:15:00.000Z" },
  { label: "day-of-month AND weekday OR semantics (15 and Mon)", expression: "0 9 15 * 1", tz: "UTC", nowISO: "2026-06-01T09:00:00.000Z" },
  { label: "day-of-month wildcard-step AND weekday (*/2 and Mon)", expression: "0 9 */2 * 1", tz: "UTC", nowISO: "2026-06-01T09:00:00.000Z" },
  { label: "day-of-month AND weekday wildcard-step (1-15 and */2)", expression: "0 9 1-15 * */2", tz: "UTC", nowISO: "2026-06-01T09:00:00.000Z" },
  { label: "31st of month skips 30-day months", expression: "0 12 31 * *", tz: "UTC", nowISO: "2026-03-31T12:00:00.000Z" }, // skips Apr -> May 31
  { label: "Feb 29 leap year jump", expression: "0 0 29 2 *", tz: "UTC", nowISO: "2024-02-29T00:00:00.000Z" }, // -> 2028-02-29
  { label: "Feb 29 from non-leap year", expression: "0 0 29 2 *", tz: "UTC", nowISO: "2026-01-01T00:00:00.000Z" }, // -> 2028-02-29
  { label: "year rollover Dec 31 23:59", expression: "0 0 1 1 *", tz: "UTC", nowISO: "2026-12-31T23:59:00.000Z" },
  { label: "6-field fixed second 30", expression: "30 15 9 * * *", tz: "UTC", nowISO: "2026-06-15T09:15:29.000Z" },
  { label: "6-field fixed second 45 rollover", expression: "45 59 23 * * *", tz: "UTC", nowISO: "2026-06-15T23:59:45.000Z" },
  { label: "6-field fixed second 0 matches 5-field", expression: "0 30 14 8-14 * *", tz: "UTC", nowISO: "2026-06-01T00:00:00.000Z" },

  // Timezone conversions (non-UTC, half-hour, 45-min, fixed offset)
  { label: "America/New_York winter EST", expression: "0 9 * * *", tz: "America/New_York", nowISO: "2026-01-15T13:59:00.000Z" },
  { label: "America/New_York summer EDT", expression: "0 9 * * *", tz: "America/New_York", nowISO: "2026-07-15T12:59:00.000Z" },
  { label: "Europe/Paris CET", expression: "30 8 * * 1-5", tz: "Europe/Paris", nowISO: "2026-01-15T07:00:00.000Z" },
  { label: "Asia/Tokyo JST day boundary", expression: "0 0 * * *", tz: "Asia/Tokyo", nowISO: "2026-06-15T14:59:00.000Z" },
  { label: "Asia/Kolkata +05:30 half-hour offset", expression: "0 9 * * *", tz: "Asia/Kolkata", nowISO: "2026-06-15T03:29:00.000Z" },
  { label: "Pacific/Chatham +12:45/+13:45 offset", expression: "15 10 * * *", tz: "Pacific/Chatham", nowISO: "2026-06-15T00:00:00.000Z" },
  { label: "fixed offset +05:30", expression: "30 9 * * *", tz: "+05:30", nowISO: "2026-06-15T03:59:00.000Z" },
  { label: "fixed offset -04:00", expression: "0 18 * * *", tz: "-04:00", nowISO: "2026-06-15T21:59:00.000Z" },

  // DST Spring Forward gap (America/New_York 2026-03-08 02:00 -> 03:00, transition at 07:00Z)
  { label: "NY spring forward before gap 02:30 slot", expression: "30 2 * * *", tz: "America/New_York", nowISO: "2026-03-08T06:55:00.000Z" },
  { label: "NY spring forward */15 across gap", expression: "*/15 * * * *", tz: "America/New_York", nowISO: "2026-03-08T06:50:00.000Z" },
  { label: "NY spring forward at 07:00Z (03:00 EDT)", expression: "*/15 * * * *", tz: "America/New_York", nowISO: "2026-03-08T07:00:00.000Z" },
  { label: "NY spring forward 02:00 exact gap start", expression: "0 2 * * *", tz: "America/New_York", nowISO: "2026-03-08T06:30:00.000Z" },
  { label: "NY spring forward 03:00 after gap", expression: "0 3 * * *", tz: "America/New_York", nowISO: "2026-03-08T06:30:00.000Z" },
  { label: "NY spring forward daily 9am across DST", expression: "0 9 * * *", tz: "America/New_York", nowISO: "2026-03-07T14:00:00.000Z" },

  // DST Fall Back overlap (America/New_York 2026-11-01 01:00-01:59 runs twice: 05:00Z EDT then 06:00Z EST)
  { label: "NY fall back */10 at 01:50 EDT (05:50Z)", expression: "*/10 * * * *", tz: "America/New_York", nowISO: "2026-11-01T05:50:00.000Z" },
  { label: "NY fall back 01:30 from 01:00 EDT (05:00Z)", expression: "30 1 * * *", tz: "America/New_York", nowISO: "2026-11-01T05:00:00.000Z" },
  { label: "NY fall back 01:30 after 01:30 EDT (05:30Z) no double fire", expression: "30 1 * * *", tz: "America/New_York", nowISO: "2026-11-01T05:30:00.000Z" },
  { label: "NY fall back */10 inside second 1am hour (06:15Z = 01:15 EST)", expression: "*/10 * * * *", tz: "America/New_York", nowISO: "2026-11-01T06:15:00.000Z" },
  { label: "NY fall back */10 at 06:00Z (01:00 EST)", expression: "*/10 * * * *", tz: "America/New_York", nowISO: "2026-11-01T06:00:00.000Z" },
  { label: "NY fall back 01:45 from 06:15Z (01:15 EST)", expression: "45 1 * * *", tz: "America/New_York", nowISO: "2026-11-01T06:15:00.000Z" },
  { label: "NY fall back daily 9am across fall back", expression: "0 9 * * *", tz: "America/New_York", nowISO: "2026-10-31T13:00:00.000Z" },

  // Europe/London DST transitions (2026-03-29 01:00->02:00, 2026-10-25 02:00->01:00)
  { label: "London spring forward 01:30 gap", expression: "30 1 * * *", tz: "Europe/London", nowISO: "2026-03-29T00:30:00.000Z" },
  { label: "London fall back 01:30 overlap at 00:30Z", expression: "30 1 * * *", tz: "Europe/London", nowISO: "2026-10-25T00:30:00.000Z" },
  { label: "London fall back */20 inside second 1am (01:10Z)", expression: "*/20 * * * *", tz: "Europe/London", nowISO: "2026-10-25T01:10:00.000Z" },

  // Southern hemisphere & 30-min DST (Australia/Lord_Howe 30-min DST!)
  { label: "Lord Howe 30-min spring forward 02:15 gap", expression: "15 2 * * *", tz: "Australia/Lord_Howe", nowISO: "2026-10-03T15:00:00.000Z" },
  { label: "Lord Howe 30-min fall back overlap", expression: "45 1 * * *", tz: "Australia/Lord_Howe", nowISO: "2026-04-04T14:45:00.000Z" },
  { label: "Australia/Sydney fall back 02:30 overlap", expression: "30 2 * * *", tz: "Australia/Sydney", nowISO: "2026-04-04T15:30:00.000Z" },
]

const invalidCases: InvalidCase[] = [
  { label: "empty expression", expression: "" },
  { label: "too few segments (4)", expression: "* * * *" },
  { label: "too many segments (7)", expression: "0 0 0 * * * *" },
  { label: "@hourly alias unsupported", expression: "@hourly" },
  { label: "@daily alias unsupported", expression: "@daily" },
  { label: "L modifier unsupported", expression: "0 0 L * *" },
  { label: "W modifier unsupported", expression: "0 0 15W * *" },
  { label: "# modifier unsupported", expression: "0 0 * * 5#3" },
  { label: "? wildcard unsupported", expression: "0 0 ? * MON" },
  { label: "minute out of range 60", expression: "60 * * * *" },
  { label: "hour out of range 24", expression: "0 24 * * *" },
  { label: "day out of range 0", expression: "0 0 0 * *" },
  { label: "day out of range 32", expression: "0 0 32 * *" },
  { label: "month out of range 13", expression: "0 0 1 13 *" },
  { label: "weekday out of range 8", expression: "0 0 * * 8" },
  { label: "step zero", expression: "*/0 * * * *" },
  { label: "step non-integer", expression: "*/abc * * * *" },
  { label: "step exceeds max", expression: "*/60 * * * *" },
  { label: "step exceeds hour max", expression: "0 */24 * * *" },
  { label: "reversed range", expression: "30-10 * * * *" },
  { label: "reversed weekday alias mon-sun", expression: "0 9 * * mon-sun" },
  { label: "unknown month alias", expression: "0 0 1 foo *" },
  { label: "negative value", expression: "-5 * * * *" },
  { label: "sub-minute 6-field wildcard seconds", expression: "* * * * * *", tz: "UTC" },
  { label: "sub-minute 6-field step seconds", expression: "*/30 * * * * *", tz: "UTC" },
  { label: "sub-minute 6-field list seconds", expression: "0,30 * * * * *", tz: "UTC" },
  { label: "never runs Feb 31", expression: "0 0 31 2 *", tz: "UTC", nowISO: "2026-01-01T00:00:00.000Z" },
  { label: "never runs Apr 31", expression: "0 0 31 4 *", tz: "UTC", nowISO: "2026-01-01T00:00:00.000Z" },
  { label: "unknown timezone", expression: "0 9 * * *", tz: "Mars/Olympus_Mons" },
]

const evaluatedValid = validCases.map((c) => {
  const zone = DateTime.zoneMakeNamedUnsafe(c.tz)
  const parsed = Result.getOrThrow(Cron.parse(c.expression, zone))
  const nowMs = Date.parse(c.nowISO)
  const next1 = nextCron(parsed, nowMs)
  if (next1 === undefined) {
    throw new Error(`Expected valid next1 for ${c.label}: ${c.expression}`)
  }
  const next2 = nextCron(parsed, next1)
  if (next2 === undefined) {
    throw new Error(`Expected valid next2 for ${c.label}: ${c.expression}`)
  }
  return {
    ...c,
    nowMs,
    next1Ms: next1,
    next1ISO: new Date(next1).toISOString(),
    next2Ms: next2,
    next2ISO: new Date(next2).toISOString(),
  }
})

// Mirror exact Automation.create validation error resolution in `packages/core/src/automation.ts`
const evaluatedInvalid = invalidCases.map((c) => {
  const tz = c.tz ?? "UTC"
  const zoneOpt = DateTime.zoneMakeNamed(tz)
  let expectedError: string
  if (Option.isNone(zoneOpt)) {
    expectedError = `Unknown time zone: ${tz}`
  } else {
    const parsed = Cron.parse(c.expression, zoneOpt.value)
    if (Result.isFailure(parsed)) {
      expectedError = parsed.failure.message
    } else if (parsed.success.seconds.size !== 1) {
      expectedError = "cron must run at most once a minute"
    } else {
      const nowMs = Date.parse(c.nowISO ?? "2026-01-01T00:00:00.000Z")
      const next = nextCron(parsed.success, nowMs)
      if (next === undefined) {
        expectedError = `cron never runs: ${c.expression}`
      } else {
        throw new Error(`Expected invalid case to fail: ${c.label}`)
      }
    }
  }
  return {
    label: c.label,
    expression: c.expression,
    tz,
    nowMs: Date.parse(c.nowISO ?? "2026-01-01T00:00:00.000Z"),
    expectedError,
  }
})

function swiftEscape(s: string): string {
  return JSON.stringify(s)
}

const swiftSource = `// GENERATED BY Tools/generate-cron-vectors.ts FROM UPSTREAM effect@4.1.0 (opencode@85951cb)
// Do not edit by hand; re-run: bun Tools/generate-cron-vectors.ts --write

enum CronVectorsData {
    struct ValidVector: Sendable {
        let label: String
        let expression: String
        let tz: String
        let nowMs: Int64
        let next1Ms: Int64
        let next1ISO: String
        let next2Ms: Int64
        let next2ISO: String
    }

    struct InvalidVector: Sendable {
        let label: String
        let expression: String
        let tz: String
        let nowMs: Int64
        let expectedError: String
    }

    static let validVectors: [ValidVector] = [
${evaluatedValid
  .map(
    (v) =>
      `        ValidVector(label: ${swiftEscape(v.label)}, expression: ${swiftEscape(v.expression)}, tz: ${swiftEscape(v.tz)}, nowMs: ${v.nowMs}, next1Ms: ${v.next1Ms}, next1ISO: ${swiftEscape(v.next1ISO)}, next2Ms: ${v.next2Ms}, next2ISO: ${swiftEscape(v.next2ISO)}),`,
  )
  .join("\n")}
    ]

    static let invalidVectors: [InvalidVector] = [
${evaluatedInvalid
  .map(
    (v) =>
      `        InvalidVector(label: ${swiftEscape(v.label)}, expression: ${swiftEscape(v.expression)}, tz: ${swiftEscape(v.tz)}, nowMs: ${v.nowMs}, expectedError: ${swiftEscape(v.expectedError)}),`,
  )
  .join("\n")}
    ]
}
`

if (process.argv.includes("--write")) {
  fs.writeFileSync(OUTPUT_PATH, swiftSource, "utf8")
  console.log(`Wrote ${evaluatedValid.length} valid and ${evaluatedInvalid.length} invalid cron vectors to ${OUTPUT_PATH}`)
} else {
  console.log(JSON.stringify({ valid: evaluatedValid.length, invalid: evaluatedInvalid.length, sample: evaluatedValid.slice(0, 3), invalidSample: evaluatedInvalid.slice(0, 5) }, null, 2))
}
