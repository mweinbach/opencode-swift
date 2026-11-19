import path from "path"
import fs from "fs"

const ROOT_DIR = path.resolve(import.meta.dir, "../..")
const UPSTREAM_DIR = path.join(ROOT_DIR, "upstream/opencode")

// If upstream/opencode does not have node_modules installed, provide minimal runtime stubs
// for Effect/platform module imports so we execute the exact upstream TypeScript files
// directly (bom.ts, patch.ts, execute-output.ts, fs-util.ts, npm.ts, etc.) without
// requiring a full `bun install` in upstream/.
const hasUpstreamNodeModules = fs.existsSync(path.join(UPSTREAM_DIR, "node_modules/effect"))
if (!hasUpstreamNodeModules) {
  const schemaLeaf = (tag: string) => ({ _tag: tag, pipe: () => ({ _tag: tag }) })
  const dummyLayer = { _isLayer: true, pipe: () => ({ _isLayer: true }) }
  Bun.plugin({
    name: "opencode-effect-lightweight-fallback",
    setup(build) {
      build.module("effect", () => ({
        exports: {
          Brand: { nominal: () => (v: unknown) => v },
          Clock: {},
          Context: {
            Service: () => (key: string) =>
              class {
                static readonly key = key
                static of(value: unknown) {
                  return value
                }
              },
          },
          Effect: {
            fn: () => (impl: unknown) => impl,
            fnUntraced: (impl: unknown) => impl,
            gen: (impl: unknown) => impl,
            suspend: (impl: unknown) => impl,
            tryPromise: () => ({ pipe: () => ({}) }),
            orElseSucceed: () => () => ({}),
            map: () => () => ({}),
            succeed: (value: unknown) => value,
            fail: (error: unknown) => error,
          },
          FileSystem: { FileSystem: { key: "FileSystem" } },
          Function: {},
          Layer: {
            effect: () => dummyLayer,
            succeed: () => dummyLayer,
            isLayer: () => true,
            empty: dummyLayer,
          },
          Option: {
            some: (value: unknown) => ({ _tag: "Some", value }),
            none: () => ({ _tag: "None" }),
            isNone: (o: { _tag?: string } | null | undefined) => o?._tag === "None",
            isSome: (o: { _tag?: string } | null | undefined) => o?._tag === "Some",
          },
          Path: { Path: { key: "Path" } },
          Result: {
            succeed: (value: unknown) => ({ _tag: "Success", success: value, value }),
            fail: (error: unknown) => ({ _tag: "Failure", failure: error, error }),
            isSuccess: (r: { _tag?: string } | null | undefined) => r?._tag === "Success",
            isFailure: (r: { _tag?: string } | null | undefined) => r?._tag === "Failure",
          },
          Schedule: {},
          Schema: {
            TaggedError: () => (tag: string, _fields: unknown) =>
              class TaggedErrorBase extends Error {
                readonly _tag = tag
                constructor(props?: Record<string, unknown>) {
                  super()
                  if (props) Object.assign(this, props)
                }
              },
            Literals: (values: unknown) => ({ _tag: "Literals", values, pipe: () => ({}) }),
            String: schemaLeaf("String"),
            Number: schemaLeaf("Number"),
            Unknown: schemaLeaf("Unknown"),
            Defect: () => schemaLeaf("Defect"),
            optional: (inner: unknown) => ({ _tag: "Optional", inner, pipe: () => ({}) }),
            Array: (inner: unknown) => ({ _tag: "Array", inner, pipe: () => ({}) }),
            Record: (k: unknown, v: unknown) => ({ _tag: "Record", k, v, pipe: () => ({}) }),
            Struct: (fields: unknown) => ({ _tag: "Struct", fields, pipe: () => ({}) }),
            fromJsonString: (inner: unknown) => ({ _tag: "FromJsonString", inner }),
            decodeUnknownOption: (schema: { _tag?: string }) => (input: unknown) => {
              if (schema?._tag === "FromJsonString") {
                if (typeof input !== "string") return { _tag: "None" }
                try {
                  return { _tag: "Some", value: JSON.parse(input) }
                } catch {
                  return { _tag: "None" }
                }
              }
              return { _tag: "Some", value: input }
            },
            decodeUnknownSync: () => (input: unknown) => input,
            encodeSync: () => (input: unknown) => input,
          },
          Scope: {},
        },
        loader: "object",
      }))
      build.module("effect/http", () => ({
        exports: {
          FetchHttpClient: { Fetch: { key: "Fetch" }, layer: dummyLayer },
          HttpClient: { HttpClient: { key: "HttpClient" }, transformResponse: (c: unknown) => c },
        },
        loader: "object",
      }))
      build.module("@effect/platform-node/NodeFileSystem", () => ({
        exports: { layer: dummyLayer },
        loader: "object",
      }))
      build.module("@effect/platform-node/NodePath", () => ({
        exports: { layer: dummyLayer },
        loader: "object",
      }))
      build.module("mime-types", () => ({
        exports: { lookup: () => false },
        loader: "object",
      }))
      build.module("glob", () => ({
        exports: { glob: async () => [] },
        loader: "object",
      }))
      build.module("minimatch", () => ({
        exports: { minimatch: () => false },
        loader: "object",
      }))
    },
  })
}

const activityCalendarMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/activity-calendar.ts"))
const artifactMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/artifact.ts"))
const base64Mod = await import(path.join(UPSTREAM_DIR, "packages/util/src/base64.ts"))
const binaryMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/binary.ts"))
const bomMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/bom.ts"))
const durationMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/duration.ts"))
const encodeMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/encode.ts"))
const executeOutputMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/execute-output.ts"))
const fsUtilMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/fs-util.ts"))
const hashMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/hash.ts"))
const npmMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/npm.ts"))
const patchMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/patch.ts"))
const pathMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/path.ts"))
const qrMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/qr.ts"))
const mentionMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/session-mention.ts"))
const titleFallbackMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/session-title-fallback.ts"))
const sessionTurnMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/session-turn.ts"))
const textBoundaryMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/text-boundary.ts"))
const uuidMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/uuid.ts"))
const identifierMod = await import(path.join(UPSTREAM_DIR, "packages/schema/src/identifier.ts"))

function normalizeUndefinedToNull(value: unknown): unknown {
  if (value === undefined) return null
  if (value instanceof Uint8Array) return Array.from(value)
  if (Array.isArray(value)) return value.map(normalizeUndefinedToNull)
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = normalizeUndefinedToNull((value as Record<string, unknown>)[key])
    }
    return out
  }
  return value
}

interface RawSessionTurnMessage {
  id: string
  type: string
  time: {
    created: number
    firstToken?: number | null
    streamed?: number | null
    completed?: number | null
  }
  tokens?: { output: number; reasoning: number } | null
}

function normalizeSessionTurnMessage(raw: RawSessionTurnMessage) {
  return {
    id: raw.id,
    type: raw.type,
    time: {
      created: raw.time.created,
      ...(raw.time.firstToken != null ? { firstToken: raw.time.firstToken } : {}),
      ...(raw.time.streamed != null ? { streamed: raw.time.streamed } : {}),
      ...(raw.time.completed != null ? { completed: raw.time.completed } : {}),
    },
    ...(raw.tokens != null ? { tokens: raw.tokens } : {}),
  }
}

function normalizeSessionTurnOptions(raw: { index?: number | null; legacy?: boolean | null } | null | undefined) {
  if (!raw) return undefined
  return {
    ...(raw.index != null ? { index: raw.index } : {}),
    ...(raw.legacy != null ? { legacy: raw.legacy } : {}),
  }
}

function invoke(fn: string, args: unknown[]): unknown {
  switch (fn) {
    // activity-calendar.ts
    case "util/src/activity-calendar.ts#activityCalendar":
      return activityCalendarMod.activityCalendar(
        args[0] as {
          activity: readonly { date: string; steps: number }[]
          from: number
          to: number
          maxWeeks: number
        },
      )

    // artifact.ts
    case "util/src/artifact.ts#artifactMime":
      return artifactMod.artifactMime(args[0] as string) ?? null
    case "util/src/artifact.ts#artifactKind":
      return artifactMod.artifactKind(args[0] as string)

    // base64.ts
    case "util/src/base64.ts#bytesToBase64":
      return base64Mod.bytesToBase64(new Uint8Array(args[0] as number[]))
    case "util/src/base64.ts#base64ToBytes":
      return Array.from(base64Mod.base64ToBytes(args[0] as string))

    // binary.ts
    case "util/src/binary.ts#Binary.search":
      return binaryMod.Binary.search(args[0] as string[], args[1] as string, (x: string) => x)
    case "util/src/binary.ts#Binary.insert":
      return binaryMod.Binary.insert([...(args[0] as string[])], args[1] as string, (x: string) => x)

    // bom.ts
    case "util/src/bom.ts#split":
      return bomMod.split(args[0] as string)
    case "util/src/bom.ts#join":
      return bomMod.join(args[0] as string, args[1] as boolean)
    case "util/src/bom.ts#has":
      return bomMod.has(new Uint8Array(args[0] as number[]))
    case "util/src/bom.ts#decodeBytes":
      return bomMod.decodeBytes(new Uint8Array(args[0] as number[]))
    case "util/src/bom.ts#syncBytes": {
      const res = bomMod.syncBytes(new Uint8Array(args[0] as number[]), args[1] as boolean)
      return { text: res.text, bytes: res.bytes ? Array.from(res.bytes) : null }
    }

    // duration.ts
    case "util/src/duration.ts#duration":
      return durationMod.duration(args[0] as number)

    // encode.ts
    case "util/src/encode.ts#base64Encode":
      return encodeMod.base64Encode(args[0] as string)
    case "util/src/encode.ts#base64Decode":
      return encodeMod.base64Decode(args[0] as string)
    case "util/src/encode.ts#checksum":
      return encodeMod.checksum(args[0] as string) ?? null
    case "util/src/encode.ts#sampledChecksum":
      return args.length > 1
        ? (encodeMod.sampledChecksum(args[0] as string, args[1] as number) ?? null)
        : (encodeMod.sampledChecksum(args[0] as string) ?? null)

    // execute-output.ts
    case "util/src/execute-output.ts#formatExecuteOutput": {
      const res = executeOutputMod.formatExecuteOutput(args[0] as string)
      return { json: res.json ?? null, rest: res.rest ?? null, text: res.text }
    }

    // fs-util.ts
    case "util/src/fs-util.ts#FSUtil.windowsPath":
      return fsUtilMod.FSUtil.windowsPath(args[0] as string)
    case "util/src/fs-util.ts#FSUtil.contains":
      return fsUtilMod.FSUtil.contains(args[0] as string, args[1] as string)
    case "util/src/fs-util.ts#FSUtil.overlaps":
      return fsUtilMod.FSUtil.overlaps(args[0] as string, args[1] as string)

    // hash.ts
    case "util/src/hash.ts#Hash.fast":
      return hashMod.Hash.fast(args[0] as string)
    case "util/src/hash.ts#Hash.sha256":
      return hashMod.Hash.sha256(args[0] as string)

    // npm.ts
    case "util/src/npm.ts#sanitize":
      return npmMod.sanitize(args[0] as string)

    // patch.ts
    case "util/src/patch.ts#parse": {
      const res = patchMod.parse(args[0] as string) as {
        _tag: string
        success?: unknown
        value?: unknown
        failure?: { _tag: string; message: string }
        error?: { _tag: string; message: string }
      }
      if (res._tag === "Success") {
        const hunks = (res.success ?? res.value) as Array<
          | { type: "add"; path: string; contents: string }
          | { type: "delete"; path: string }
          | {
              type: "update"
              path: string
              movePath?: string
              chunks: Array<{
                oldLines: string[]
                newLines: string[]
                changeContext?: string
                endOfFile?: boolean
              }>
            }
        >
        return {
          ok: true,
          hunks: hunks.map((h) => {
            if (h.type === "add") return { type: "add", path: h.path, contents: h.contents }
            if (h.type === "delete") return { type: "delete", path: h.path }
            return {
              type: "update",
              path: h.path,
              movePath: h.movePath ?? null,
              chunks: h.chunks.map((c) => ({
                oldLines: [...c.oldLines],
                newLines: [...c.newLines],
                changeContext: c.changeContext ?? null,
                endOfFile: c.endOfFile ?? null,
              })),
            }
          }),
        }
      }
      const err = (res.failure ?? res.error)!
      return { ok: false, tag: err._tag, message: err.message }
    }
    case "util/src/patch.ts#derive": {
      const rawChunks = args[1] as Array<{
        oldLines: string[]
        newLines: string[]
        changeContext?: string | null
        endOfFile?: boolean | null
      }>
      const chunks = rawChunks.map((c) => ({
        oldLines: c.oldLines,
        newLines: c.newLines,
        ...(c.changeContext != null ? { changeContext: c.changeContext } : {}),
        ...(c.endOfFile != null ? { endOfFile: c.endOfFile } : {}),
      }))
      return patchMod.derive(args[0] as string, chunks, args[2] as string)
    }
    case "util/src/patch.ts#joinBom":
      return patchMod.joinBom(args[0] as string, args[1] as boolean)

    // path.ts
    case "util/src/path.ts#getFilename":
      return pathMod.getFilename((args[0] ?? undefined) as string | undefined)
    case "util/src/path.ts#getDirectory":
      return pathMod.getDirectory((args[0] ?? undefined) as string | undefined)
    case "util/src/path.ts#getFilenameTruncated":
      return args.length > 1
        ? pathMod.getFilenameTruncated((args[0] ?? undefined) as string | undefined, args[1] as number)
        : pathMod.getFilenameTruncated((args[0] ?? undefined) as string | undefined)
    case "util/src/path.ts#truncateMiddle":
      return args.length > 1
        ? pathMod.truncateMiddle(args[0] as string, args[1] as number)
        : pathMod.truncateMiddle(args[0] as string)
    case "util/src/path.ts#comparablePath":
      return pathMod.comparablePath(args[0] as string)
    case "util/src/path.ts#containsDirectory":
      return pathMod.containsDirectory(args[0] as string, args[1] as string)
    case "util/src/path.ts#sameDirectory":
      return pathMod.sameDirectory(args[0] as string, args[1] as string)
    case "util/src/path.ts#encodeFilePath":
      return pathMod.encodeFilePath(args[0] as string)
    case "util/src/path.ts#isLineRangeHash":
      return pathMod.isLineRangeHash(args[0] as string)
    case "util/src/path.ts#parsePathLineSuffix":
      return pathMod.parsePathLineSuffix(args[0] as string)

    // qr.ts
    case "util/src/qr.ts#encode":
      return qrMod.encode(args[0] as string)
    case "util/src/qr.ts#renderSVG": {
      const raw = (args[1] ?? undefined) as
        | { border?: number | null; blackColor?: string | null; whiteColor?: string | null }
        | undefined
      const opts = raw
        ? {
            ...(raw.border != null ? { border: raw.border } : {}),
            ...(raw.blackColor != null ? { blackColor: raw.blackColor } : {}),
            ...(raw.whiteColor != null ? { whiteColor: raw.whiteColor } : {}),
          }
        : undefined
      return qrMod.renderSVG(args[0] as string, opts)
    }
    case "util/src/qr.ts#renderUnicodeCompact": {
      const raw = (args[1] ?? undefined) as { border?: number | null } | undefined
      const opts = raw && raw.border != null ? { border: raw.border } : undefined
      return qrMod.renderUnicodeCompact(args[0] as string, opts)
    }

    // session-mention.ts
    case "util/src/session-mention.ts#sessionMentions":
      return mentionMod.sessionMentions(args[0] as string)
    case "util/src/session-mention.ts#parseSessionMention":
      return mentionMod.parseSessionMention(args[0] as string) ?? null
    case "util/src/session-mention.ts#serializeSessionMention":
      return mentionMod.serializeSessionMention(args[0] as { id: `ses_${string}` })

    // session-title-fallback.ts
    case "util/src/session-title-fallback.ts#withTimestampedFallback": {
      const raw = args[0] as { title?: string | null; parentID?: string | null; time: { created: number } }
      return titleFallbackMod.withTimestampedFallback({
        title: raw.title ?? undefined,
        parentID: raw.parentID ?? undefined,
        time: raw.time,
      })
    }
    case "util/src/session-title-fallback.ts#displayLabel": {
      const raw = args[0] as { title?: string | null; parentID?: string | null }
      return titleFallbackMod.displayLabel({
        title: raw.title ?? undefined,
        parentID: raw.parentID ?? undefined,
      })
    }
    case "util/src/session-title-fallback.ts#isFallbackTitle":
      return titleFallbackMod.isFallbackTitle((args[0] ?? undefined) as string | undefined)
    case "util/src/session-title-fallback.ts#isExactRootFallback": {
      const raw = args[0] as { title?: string | null; time: { created: number } }
      return titleFallbackMod.isExactRootFallback({
        title: raw.title ?? undefined,
        time: raw.time,
      })
    }

    // session-turn.ts
    case "util/src/session-turn.ts#duration": {
      const messages = (args[0] as RawSessionTurnMessage[]).map(normalizeSessionTurnMessage)
      const message = normalizeSessionTurnMessage(args[1] as RawSessionTurnMessage)
      const opts = normalizeSessionTurnOptions(args[2] as { index?: number | null; legacy?: boolean | null } | null)
      return sessionTurnMod.duration(messages, message, opts)
    }
    case "util/src/session-turn.ts#tokensPerSecond": {
      const messages = (args[0] as RawSessionTurnMessage[]).map(normalizeSessionTurnMessage)
      const message = normalizeSessionTurnMessage(args[1] as RawSessionTurnMessage)
      const opts = normalizeSessionTurnOptions(args[2] as { index?: number | null; legacy?: boolean | null } | null)
      return sessionTurnMod.tokensPerSecond(messages, message, opts) ?? null
    }
    case "util/src/session-turn.ts#legacy": {
      const messages = (args[0] as RawSessionTurnMessage[]).map(normalizeSessionTurnMessage)
      return sessionTurnMod.legacy(messages)
    }

    // text-boundary.ts
    case "util/src/text-boundary.ts#head":
      return textBoundaryMod.head(args[0] as string, args[1] as number)
    case "util/src/text-boundary.ts#tail":
      return textBoundaryMod.tail(args[0] as string, args[1] as number)
    case "util/src/text-boundary.ts#utf8Tail":
      return textBoundaryMod.utf8Tail(new Uint8Array(args[0] as number[]), args[1] as number)

    // uuid.ts
    case "util/src/uuid.ts#uuid":
      return uuidMod.uuid()

    // schema/identifier.ts
    case "schema/src/identifier.ts#create":
      return identifierMod.create(args[0] as boolean, args[1] as number)
    case "schema/src/identifier.ts#ascending":
      return identifierMod.ascending()
    case "schema/src/identifier.ts#descending":
      return identifierMod.descending()

    default:
      throw new Error(`Unknown oracle function: ${fn}`)
  }
}

const input = await Bun.stdin.text()
for (const line of input.split("\n")) {
  if (!line.trim()) continue
  const req = JSON.parse(line) as { id: string; fn: string; args: unknown[] }
  try {
    const raw = invoke(req.fn, req.args)
    const value = normalizeUndefinedToNull(raw)
    process.stdout.write(JSON.stringify({ id: req.id, ok: true, value, error: null }) + "\n")
  } catch (err) {
    process.stdout.write(
      JSON.stringify({
        id: req.id,
        ok: false,
        value: null,
        error: err instanceof Error ? err.message : String(err),
      }) + "\n",
    )
  }
}
