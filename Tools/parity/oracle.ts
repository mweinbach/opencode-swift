import path from "path"
import fs from "fs"

const ROOT_DIR = path.resolve(import.meta.dir, "../..")
const UPSTREAM_DIR = path.join(ROOT_DIR, "upstream/opencode")

// If upstream/opencode does not have node_modules installed, provide a minimal runtime stub
// for pure-module imports of "effect" (e.g. Bom.readFile / Bom.syncFile wrappers in bom.ts)
// so we execute the exact upstream TypeScript files without requiring a full bun install.
const hasUpstreamNodeModules = fs.existsSync(path.join(UPSTREAM_DIR, "node_modules/effect"))
if (!hasUpstreamNodeModules) {
  Bun.plugin({
    name: "opencode-effect-lightweight-fallback",
    setup(build) {
      build.module("effect", () => ({
        exports: {
          Effect: { fn: () => (impl: unknown) => impl },
          Result: {
            succeed: (value: unknown) => ({ _tag: "Success", value }),
            fail: (error: unknown) => ({ _tag: "Failure", error }),
          },
          Schema: {},
        },
        loader: "object",
      }))
    },
  })
}

const base64Mod = await import(path.join(UPSTREAM_DIR, "packages/util/src/base64.ts"))
const binaryMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/binary.ts"))
const bomMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/bom.ts"))
const durationMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/duration.ts"))
const encodeMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/encode.ts"))
const hashMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/hash.ts"))
const pathMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/path.ts"))
const mentionMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/session-mention.ts"))
const titleFallbackMod = await import(path.join(UPSTREAM_DIR, "packages/util/src/session-title-fallback.ts"))
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

function invoke(fn: string, args: unknown[]): unknown {
  switch (fn) {
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

    // hash.ts
    case "util/src/hash.ts#Hash.fast":
      return hashMod.Hash.fast(args[0] as string)
    case "util/src/hash.ts#Hash.sha256":
      return hashMod.Hash.sha256(args[0] as string)

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
