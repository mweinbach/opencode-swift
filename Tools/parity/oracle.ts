import path from "path"
import fs from "fs"

const ROOT_DIR = path.resolve(import.meta.dir, "../..")
const UPSTREAM_DIR = path.join(ROOT_DIR, "upstream/opencode")
const OPENTUI_DIR = path.join(ROOT_DIR, "upstream/opentui")

// If upstream/opencode does not have node_modules installed, provide minimal runtime stubs
// for Effect/platform/ORM module imports while resolving workspace packages (@opencode/util/*,
// @opencode/schema/*, @opentui/core) directly to their real upstream TypeScript source files
// so we execute the exact upstream TypeScript modules without requiring `bun install` in upstream/.
const hasUpstreamNodeModules = fs.existsSync(path.join(UPSTREAM_DIR, "node_modules/effect"))
if (!hasUpstreamNodeModules) {
  const makeSchema = (
    tag: string,
    extra: Record<string, unknown> = {},
  ): Record<string, unknown> & ((...args: unknown[]) => unknown) => {
    const fn = (...args: unknown[]) => {
      if (args.length === 1 && args[0] && typeof args[0] === "object" && "_tag" in (args[0] as object)) {
        return args[0]
      }
      return makeSchema(tag, extra)
    }
    const node = Object.assign(fn, {
      _tag: tag,
      fields: {},
      guards: new Proxy({}, { get: () => () => false }),
      ...extra,
      check() {
        return node
      },
      annotate() {
        return node
      },
      annotateKey() {
        return node
      },
      annotateMerge() {
        return node
      },
      make(v: unknown) {
        return v
      },
      mapFields(mapper: (f: Record<string, unknown>) => Record<string, unknown>) {
        return makeSchema(tag, { ...extra, fields: mapper((node.fields as Record<string, unknown>) ?? {}) })
      },
      pipe(...fns: unknown[]) {
        return fns.reduce<unknown>((acc, f) => (typeof f === "function" ? f(acc) : acc), node)
      },
    })
    return node
  }

  const makeSchemaClass = (fields: Record<string, unknown> = {}) => {
    const C = class {
      static fields = fields
      constructor(props?: Record<string, unknown>) {
        if (props) Object.assign(this, props)
      }
      static annotate() {
        return C
      }
      static annotateKey() {
        return C
      }
      static check() {
        return C
      }
      static make(v: unknown) {
        return v
      }
      static extend() {
        return (_extFields?: Record<string, unknown>) => makeSchemaClass({ ...fields, ...(_extFields ?? {}) })
      }
      static pipe(...fns: unknown[]) {
        return fns.reduce<unknown>((acc, fn) => (typeof fn === "function" ? fn(acc) : acc), C)
      }
    }
    return C
  }

  const makeChainable = (extra: Record<string, unknown> = {}) => {
    const target: Record<string, unknown> = {
      ...extra,
      pipe(...fns: unknown[]) {
        return fns.reduce<unknown>((acc, fn) => (typeof fn === "function" ? fn(acc) : acc), proxy)
      },
    }
    const proxy: Record<string, unknown> = new Proxy(target, {
      get(t, prop, receiver) {
        if (prop in t) return Reflect.get(t, prop, receiver)
        if (prop === "then" || typeof prop === "symbol") return undefined
        return () => proxy
      },
    })
    return proxy
  }

  const dummyLayer = makeChainable({ _isLayer: true })

  Bun.plugin({
    name: "opencode-effect-lightweight-fallback",
    setup(build) {
      build.onResolve({ filter: /^@opencode\/util\/(.+)$/ }, (args) => {
        const sub = args.path.slice("@opencode/util/".length)
        if (sub === "effect/app-node" || sub === "global" || sub === "process" || sub === "effect-flock") {
          return undefined
        }
        const direct = path.join(UPSTREAM_DIR, "packages/util/src", `${sub}.ts`)
        if (fs.existsSync(direct)) return { path: direct }
        const idx = path.join(UPSTREAM_DIR, "packages/util/src", sub, "index.ts")
        if (fs.existsSync(idx)) return { path: idx }
        return undefined
      })
      build.onResolve({ filter: /^@opencode\/schema\/(.+)$/ }, (args) => {
        const sub = args.path.slice("@opencode/schema/".length)
        const direct = path.join(UPSTREAM_DIR, "packages/schema/src", `${sub}.ts`)
        if (fs.existsSync(direct)) return { path: direct }
        const idx = path.join(UPSTREAM_DIR, "packages/schema/src", sub, "index.ts")
        if (fs.existsSync(idx)) return { path: idx }
        return undefined
      })
      build.onResolve({ filter: /^@opentui\/core$/ }, () => ({
        path: path.join(OPENTUI_DIR, "packages/core/src/lib/RGBA.ts"),
      }))

      build.module("effect", () => {
        const decodeUnknownOption = (schema: { _tag?: string }) => (input: unknown) => {
          if (schema?._tag === "FromJsonString") {
            if (typeof input !== "string") return { _tag: "None" }
            try {
              return { _tag: "Some", value: JSON.parse(input) }
            } catch {
              return { _tag: "None" }
            }
          }
          return { _tag: "Some", value: input }
        }
        const decodeUnknownSync = (schema: { _tag?: string }) => (input: unknown) => {
          if (schema?._tag === "FromJsonString") {
            if (typeof input !== "string") throw new Error("Expected JSON string")
            return JSON.parse(input)
          }
          return input
        }
        const encodeSync = (schema: { _tag?: string }) => (input: unknown) => {
          if (schema?._tag === "FromJsonString") return JSON.stringify(input)
          return input
        }
        const makeTaggedError = () => (tag: string, fields: unknown) =>
          class TaggedErrorBase extends Error {
            readonly _tag = tag
            static fields = fields ?? {}
            constructor(props?: Record<string, unknown>) {
              super()
              if (props) Object.assign(this, props)
            }
            static annotate() {
              return this
            }
            static pipe(...fns: unknown[]) {
              return fns.reduce<unknown>((acc, fn) => (typeof fn === "function" ? fn(acc) : acc), this)
            }
          }

        const Schema = new Proxy(
          {
            TaggedError: makeTaggedError,
            TaggedErrorClass: makeTaggedError,
            ErrorClass: makeTaggedError,
            Class: () => (_id: string, fields: Record<string, unknown>) => makeSchemaClass(fields ?? {}),
            Literals: (literals: readonly unknown[]) => makeSchema("Literals", { literals }),
            Literal: (literal: unknown) => makeSchema("Literal", { literal }),
            tag: (value: unknown) => makeSchema("Tag", { literal: value }),
            String: makeSchema("String"),
            NonEmptyString: makeSchema("NonEmptyString"),
            Number: makeSchema("Number"),
            Int: makeSchema("Int"),
            Finite: makeSchema("Finite"),
            Boolean: makeSchema("Boolean"),
            Null: makeSchema("Null"),
            Undefined: makeSchema("Undefined"),
            Void: makeSchema("Void"),
            Unknown: makeSchema("Unknown"),
            Any: makeSchema("Any"),
            Json: makeSchema("Json"),
            Uint8Array: makeSchema("Uint8Array"),
            DateTimeUtc: makeSchema("DateTimeUtc"),
            NumberFromString: makeSchema("NumberFromString"),
            Defect: () => makeSchema("Defect"),
            optional: (inner: unknown) => makeSchema("Optional", { inner }),
            optionalKey: (inner: unknown) => makeSchema("OptionalKey", { inner }),
            NullOr: (inner: unknown) => makeSchema("NullOr", { inner }),
            UndefinedOr: (inner: unknown) => makeSchema("UndefinedOr", { inner }),
            NullishOr: (inner: unknown) => makeSchema("NullishOr", { inner }),
            Array: (inner: unknown) => makeSchema("Array", { inner }),
            NonEmptyArray: (inner: unknown) => makeSchema("NonEmptyArray", { inner }),
            ArrayEnsure: (inner: unknown) => makeSchema("ArrayEnsure", { inner }),
            Tuple: (items: unknown) => makeSchema("Tuple", { items }),
            Record: (k: unknown, v: unknown) => makeSchema("Record", { k, v }),
            Struct: (fields: Record<string, unknown>) => makeSchema("Struct", { fields: fields ?? {} }),
            StructWithRest: (base: { fields?: Record<string, unknown> }, _rest: unknown) =>
              makeSchema("StructWithRest", { schema: base, fields: base?.fields ?? {} }),
            Union: (members: unknown) => makeSchema("Union", { members }),
            TemplateLiteral: (parts: unknown) => makeSchema("TemplateLiteral", { parts }),
            suspend: (fn: unknown) => makeSchema("Suspend", { fn }),
            declare: () => makeSchema("Declare"),
            brand: () => (s: unknown) => s,
            annotate: () => (s: unknown) => s,
            decodeTo: () => (s: unknown) => s,
            catchDecoding: () => (s: unknown) => s,
            withDecodingDefault: () => (s: unknown) => s,
            withConstructorDefault: () => (s: unknown) => s,
            toTaggedUnion: () => (s: unknown) => s,
            toType: (s: unknown) => s,
            is: () => () => true,
            isSchema: () => false,
            fromJsonString: (inner: unknown) => makeSchema("FromJsonString", { inner }),
            decodeUnknownOption,
            decodeUnknownSync,
            decodeUnknownEffect: () => (input: unknown) => input,
            encodeSync,
          },
          {
            get(target, prop, receiver) {
              if (prop in target) return Reflect.get(target, prop, receiver)
              return makeSchema(String(prop))
            },
          },
        )

        const Layer = new Proxy(
          { isLayer: () => true, empty: dummyLayer },
          {
            get(target, prop, receiver) {
              if (prop in target) return Reflect.get(target, prop, receiver)
              return () => dummyLayer
            },
          },
        )

        const Duration = new Proxy({}, { get: () => () => 0 })
        const Effect = new Proxy(
          {
            fn: () => (impl: unknown) => impl,
            fnUntraced: (impl: unknown) => impl,
            gen: () => makeChainable(),
            suspend: (impl: unknown) => impl,
            succeed: (value: unknown) => value,
            fail: (error: unknown) => error,
            void: makeChainable(),
            isEffect: () => false,
            Service: () => () => class {},
          },
          {
            get(target, prop, receiver) {
              if (prop in target) return Reflect.get(target, prop, receiver)
              return () => makeChainable()
            },
          },
        )

        return {
          exports: {
            Array: {},
            Brand: { nominal: () => (v: unknown) => v },
            Cache: {},
            Cause: {},
            Chunk: {},
            Clock: {},
            Config: {},
            Console: {},
            Context: {
              Service: () => (key: string) =>
                class {
                  static readonly key = key
                  static of(value: unknown) {
                    return value
                  }
                  static use(fn: unknown) {
                    return fn
                  }
                },
              Reference: (key: string, opts?: unknown) => ({ key, opts }),
            },
            Data: {
              TaggedError: () => () => class extends Error {},
              taggedEnum: () => makeChainable(),
            },
            DateTime: { makeUnsafe: (v: unknown) => v, toEpochMillis: (v: unknown) => v },
            Deferred: {},
            Duration,
            Effect,
            Equal: {},
            Exit: {},
            Fiber: {},
            FiberMap: {},
            FiberSet: {},
            FileSystem: { FileSystem: { key: "FileSystem" } },
            Function: {},
            Hash: {},
            HashMap: {},
            HashSet: {},
            Latch: {},
            Layer,
            Logger: {},
            LogLevel: {},
            ManagedRuntime: {},
            Match: {},
            Metric: {},
            MutableHashMap: {},
            Option: {
              some: (value: unknown) => ({ _tag: "Some", value }),
              none: () => ({ _tag: "None" }),
              isNone: (o: { _tag?: string } | null | undefined) => o?._tag === "None",
              isSome: (o: { _tag?: string } | null | undefined) => o?._tag === "Some",
              getOrUndefined: (o: { _tag?: string; value?: unknown } | null | undefined) =>
                o?._tag === "Some" ? o.value : undefined,
              getOrElse: (o: { _tag?: string; value?: unknown } | null | undefined, fb: () => unknown) =>
                o?._tag === "Some" ? o.value : fb(),
              filter: () => (o: unknown) => o,
            },
            Path: { Path: { key: "Path" } },
            PlatformError: {},
            Pool: {},
            Predicate: { isNotNullish: (v: unknown) => v != null },
            PubSub: {},
            Queue: {},
            Random: {},
            RcMap: {},
            Record: {
              map: (obj: Record<string, unknown>, fn: (v: unknown, k: string) => unknown) =>
                Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, fn(v, k)])),
            },
            Redacted: {},
            Ref: {},
            Result: {
              succeed: (value: unknown) => ({ _tag: "Success", success: value, value }),
              fail: (error: unknown) => ({ _tag: "Failure", failure: error, error }),
              isSuccess: (r: { _tag?: string } | null | undefined) => r?._tag === "Success",
              isFailure: (r: { _tag?: string } | null | undefined) => r?._tag === "Failure",
            },
            Runtime: {},
            Schedule: new Proxy({}, { get: () => () => makeChainable() }),
            Schema,
            SchemaGetter: {
              transform: (fn: unknown) => fn,
              transformOptional: (fn: unknown) => fn,
              passthrough: () => ({}),
              forbidden: () => ({}),
            },
            SchemaParser: {
              make: () => (v: unknown) => v,
              decodeUnknownOption,
              decodeUnknownSync,
              encodeSync,
            },
            SchemaTransformation: { transform: () => ({}), transformOptional: () => ({}) },
            Scope: {},
            Semaphore: { make: () => ({}), makeUnsafe: () => ({}) },
            ServiceMap: {},
            Stream: {},
            Struct: {
              keys: (obj: Record<string, unknown> | undefined) => Object.keys(obj ?? {}),
              omit: (obj: Record<string, unknown> | undefined, keys: readonly string[]) =>
                Object.fromEntries(Object.entries(obj ?? {}).filter(([k]) => !keys.includes(k))),
              pick: (obj: Record<string, unknown> | undefined, keys: readonly string[]) =>
                Object.fromEntries(Object.entries(obj ?? {}).filter(([k]) => keys.includes(k))),
            },
            SubscriptionRef: {},
            SynchronizedRef: {},
            Tracer: {},
            Tuple: {},
            Types: {},
          },
          loader: "object",
        }
      })
      build.module("effect/http", () => ({
        exports: {
          FetchHttpClient: { Fetch: { key: "Fetch" }, layer: dummyLayer },
          Headers: {},
          HttpClient: { HttpClient: { key: "HttpClient" }, transformResponse: (c: unknown) => c },
          HttpClientError: { HttpClientError: class extends Error {} },
          HttpClientRequest: {},
          HttpClientResponse: {},
          HttpMiddleware: { make: (fn: unknown) => fn },
          HttpServerRequest: { HttpServerRequest: {} },
          HttpServerResponse: {},
        },
        loader: "object",
      }))
      build.module("effect/http-api", () => ({
        exports: {
          HttpApiEndpoint: {
            get: () => makeChainable(),
            post: () => makeChainable(),
            put: () => makeChainable(),
            patch: () => makeChainable(),
            delete: () => makeChainable(),
          },
          HttpApiGroup: { make: () => makeChainable() },
          HttpApiMiddleware: {},
          HttpApiSchema: {
            StreamSse: () => makeSchema("StreamSse"),
            NoContent: makeSchema("NoContent"),
            asUint8Array: () => (s: unknown) => s,
            status: () => (s: unknown) => s,
          },
          OpenApi: { annotations: () => ({}) },
        },
        loader: "object",
      }))
      build.module("effect/process", () => ({
        exports: { ChildProcess: {} },
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
      // Faithful enough for upstream's frontmatter checks: parse the YAML block (Bun's YAML parser throws on
      // invalid YAML such as an unquoted `key: a: b`, as gray-matter's js-yaml does), so code that relies on
      // `matter()` throwing (core/src/config/markdown.ts#isValidYaml) behaves as it does upstream.
      build.module("gray-matter", () => ({
        exports: {
          default: (input: string) => {
            const m = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)([\s\S]*)$/.exec(input)
            if (!m) return { data: {}, content: input }
            const data = m[1]!.trim() === "" ? {} : (Bun.YAML.parse(m[1]!) ?? {})
            return { data, content: m[2] ?? "" }
          },
        },
        loader: "object",
      }))
      build.module("jsonc-parser", () => ({
        exports: { parse: (s: string) => JSON.parse(s), modify: () => [], applyEdits: (s: string) => s },
        loader: "object",
      }))
      build.module("drizzle-orm", () => ({
        exports: {
          eq: () => ({}),
          and: () => ({}),
          or: () => ({}),
          desc: () => ({}),
          asc: () => ({}),
          sql: Object.assign(() => ({}), { raw: () => ({}) }),
          inArray: () => ({}),
          notInArray: () => ({}),
          isNull: () => ({}),
          isNotNull: () => ({}),
          ne: () => ({}),
          lt: () => ({}),
          lte: () => ({}),
          gt: () => ({}),
          gte: () => ({}),
          exists: () => ({}),
          notExists: () => ({}),
          like: () => ({}),
          count: () => ({}),
          max: () => ({}),
          min: () => ({}),
          sum: () => ({}),
          getTableColumns: () => ({}),
        },
        loader: "object",
      }))
      build.module("drizzle-orm/sqlite-core", () => ({
        exports: {
          sqliteTable: () => ({}),
          customType: () => () => makeChainable(),
          text: () => makeChainable(),
          integer: () => makeChainable(),
          real: () => makeChainable(),
          blob: () => makeChainable(),
          index: () => makeChainable(),
          uniqueIndex: () => makeChainable(),
          primaryKey: () => makeChainable(),
        },
        loader: "object",
      }))
      build.module("@opencode/client/effect/service", () => ({
        exports: { Service: { Info: makeSchema("ServiceInfo") } },
        loader: "object",
      }))
      build.module("@opencode/util/effect/app-node", () => ({
        exports: {
          makeLocationNode: () => ({}),
          makeGlobalNode: () => ({}),
          makeAppNode: () => ({}),
          tags: { values: new Proxy({}, { get: (_t, k) => String(k) }) },
        },
        loader: "object",
      }))
      build.module("@opencode/util/global", () => ({
        exports: { Global: { Service: class { static key = "Global" }, node: {} } },
        loader: "object",
      }))
      build.module("@opencode/util/process", () => ({
        exports: { AppProcess: { Service: class { static key = "AppProcess" }, node: {} } },
        loader: "object",
      }))
      build.module("@opencode/util/effect-flock", () => ({
        exports: { EffectFlock: {} },
        loader: "object",
      }))
      build.module("@opencode/plugin/effect/plugin", () => ({
        exports: {},
        loader: "object",
      }))
      build.module("@opencode/plugin/effect", () => ({
        exports: {},
        loader: "object",
      }))
    },
  })
}

// packages/util
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

// packages/schema & packages/protocol
const identifierMod = await import(path.join(UPSTREAM_DIR, "packages/schema/src/identifier.ts"))
const tokenUsageMod = await import(path.join(UPSTREAM_DIR, "packages/schema/src/token-usage.ts"))
const eventSchemaMod = await import(path.join(UPSTREAM_DIR, "packages/schema/src/event.ts"))
const eventManifestMod = await import(path.join(UPSTREAM_DIR, "packages/schema/src/event-manifest.ts"))
const protocolEventMod = await import(path.join(UPSTREAM_DIR, "packages/protocol/src/groups/event.ts"))
const protocolServerMod = await import(path.join(UPSTREAM_DIR, "packages/protocol/src/groups/server.ts"))
const protocolPtyMod = await import(path.join(UPSTREAM_DIR, "packages/protocol/src/groups/pty.ts"))
const protocolPersistentPtyMod = await import(path.join(UPSTREAM_DIR, "packages/protocol/src/groups/persistent-pty.ts"))
const protocolMcpMod = await import(path.join(UPSTREAM_DIR, "packages/protocol/src/groups/mcp.ts"))

// packages/theme & packages/tui
const themeColorMod = await import(path.join(UPSTREAM_DIR, "packages/theme/src/tui/color.ts"))
const themeExpandMod = await import(path.join(UPSTREAM_DIR, "packages/theme/src/tui/expand.ts"))
const themeV1MigrateMod = await import(path.join(UPSTREAM_DIR, "packages/theme/src/tui/v1-migrate.ts"))
const tuiColorMod = await import(path.join(UPSTREAM_DIR, "packages/tui/src/theme/color.ts"))

// packages/patchmark
const patchmarkEntitiesMod = await import(path.join(UPSTREAM_DIR, "packages/patchmark/src/entities.ts"))
const patchmarkHealMod = await import(path.join(UPSTREAM_DIR, "packages/patchmark/src/heal.ts"))
const patchmarkHtmlMod = await import(path.join(UPSTREAM_DIR, "packages/patchmark/src/html.ts"))
const patchmarkStreamMod = await import(path.join(UPSTREAM_DIR, "packages/patchmark/src/stream.ts"))

// packages/ai
const aiMistralToolIdMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/protocols/utils/mistral-tool-id.ts"))
const aiClaudeModelMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/protocols/utils/claude-model.ts"))
const aiImageSizingMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/protocols/utils/image-sizing.ts"))
const aiGeminiJsonSchemaMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/protocols/utils/gemini-json-schema.ts"))
const aiCacheMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/protocols/utils/cache.ts"))
const aiPartialJsonMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/protocols/utils/partial-json.ts"))
const aiMediaTypeMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/utils/media-type.ts"))
const aiProviderCodesMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/utils/provider-codes.ts"))
const aiEndpointMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/route/endpoint.ts"))
const aiSharedMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/protocols/shared.ts"))
const aiProviderErrorMod = await import(path.join(UPSTREAM_DIR, "packages/ai/src/provider-error.ts"))

// packages/core
const coreWildcardMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/util/wildcard.ts"))
const coreCanonicalJsonMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/util/canonical-json.ts"))
const coreTokenMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/util/token.ts"))
const coreMimeMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/mime.ts"))
const coreMarkdownMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/config/markdown.ts"))
const coreManagedPolicyMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/managed-policy.ts"))
const coreFlagMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/flag.ts"))
const corePermissionMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/permission.ts"))

// packages/server
const serverRangeMod = await import(path.join(UPSTREAM_DIR, "packages/server/src/range.ts"))
const serverContentHeadersMod = await import(path.join(UPSTREAM_DIR, "packages/server/src/content-headers.ts"))
const serverCorsMod = await import(path.join(UPSTREAM_DIR, "packages/server/src/cors.ts"))
const serverMediaUriMod = await import(path.join(UPSTREAM_DIR, "packages/server/src/media-uri.ts"))
const serverRequestSiteMod = await import(path.join(UPSTREAM_DIR, "packages/server/src/request-site.ts"))

// packages/cli
const cliDatabasePathMod = await import(path.join(UPSTREAM_DIR, "packages/cli/src/database-path.ts"))
const cliUpdaterActionMod = await import(path.join(UPSTREAM_DIR, "packages/cli/src/services/updater-action.ts"))
const cliServiceConfigMod = await import(path.join(UPSTREAM_DIR, "packages/cli/src/services/service-config.ts"))
const cliNodeTargetMod = await import(path.join(UPSTREAM_DIR, "packages/cli/src/node/target.ts"))

// packages/latex
const latexRenderMod = await import(path.join(UPSTREAM_DIR, "packages/latex/src/render.ts"))
const latexParserMod = await import(path.join(UPSTREAM_DIR, "packages/latex/src/parser.ts"))

// packages/merman
const mermanDetectMod = await import(path.join(UPSTREAM_DIR, "packages/merman/src/detect.ts"))
const mermanFlowMod = await import(path.join(UPSTREAM_DIR, "packages/merman/src/flowchart/render.ts"))
const mermanSeqMod = await import(path.join(UPSTREAM_DIR, "packages/merman/src/sequence/diagram.ts"))
const mermanStateMod = await import(path.join(UPSTREAM_DIR, "packages/merman/src/state/diagram.ts"))
const mermanTimelineMod = await import(path.join(UPSTREAM_DIR, "packages/merman/src/timeline/diagram.ts"))
const mermanGitMod = await import(path.join(UPSTREAM_DIR, "packages/merman/src/gitgraph/diagram.ts"))
const mermanGanttMod = await import(path.join(UPSTREAM_DIR, "packages/merman/src/gantt/diagram.ts"))

// packages/core/src/shell/scan.ts
const coreShellScanMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/shell/scan.ts"))

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

    // MARK: - packages/theme & packages/tui color
    case "theme/src/tui/color.ts#oklchToHex": {
      const raw = args[0] as { l: number; c: number; h: number }
      return themeColorMod.oklchToHex(raw)
    }
    case "theme/src/tui/color.ts#rgbToOklch": {
      const res = themeColorMod.rgbToOklch(args[0] as number, args[1] as number, args[2] as number)
      // Round-trip through oklchToHex or compare normalized precision when needed; return exact color fields.
      return { l: res.l, c: res.c, h: res.h }
    }
    case "theme/src/tui/expand.ts#mergeTheme":
      return themeExpandMod.mergeTheme(...args)
    case "theme/src/tui/v1-migrate.ts#byte":
      return themeV1MigrateMod.byte(args[0] as number)
    case "tui/src/theme/color.ts#ansiToRgba":
      return themeV1MigrateMod.hex(tuiColorMod.ansiToRgba(args[0] as number))
    case "tui/src/theme/color.ts#tint": {
      const base = tuiColorMod.ansiToRgba(args[0] as number)
      const overlay = tuiColorMod.ansiToRgba(args[1] as number)
      return themeV1MigrateMod.hex(tuiColorMod.tint(base, overlay, args[2] as number))
    }

    // MARK: - packages/patchmark
    case "patchmark/src/entities.ts#decodeCodePoint":
      return patchmarkEntitiesMod.decodeCodePoint(args[0] as number)
    case "patchmark/src/entities.ts#decodeEntity":
      return patchmarkEntitiesMod.decodeEntity(args[0] as string)
    case "patchmark/src/entities.ts#unescapeString":
      return patchmarkEntitiesMod.unescapeString(args[0] as string)
    case "patchmark/src/entities.ts#normalizeURI":
      return patchmarkEntitiesMod.normalizeURI(args[0] as string)
    case "patchmark/src/heal.ts#computeTailHeal":
      return patchmarkHealMod.computeTailHeal(args[0] as string)
    case "patchmark/src/heal.ts#healStreamingInline":
      return patchmarkHealMod.healStreamingInline(args[0] as string)
    case "patchmark/src/html.ts#escapeHtml":
      return patchmarkHtmlMod.escapeHtml(args[0] as string)
    case "patchmark/src/html.ts#filterDisallowedRawHtml":
      return patchmarkHtmlMod.filterDisallowedRawHtml(args[0] as string)
    case "patchmark/src/stream.ts#splitPendingMarker":
      return patchmarkStreamMod.splitPendingMarker(args[0] as string)
    case "patchmark/src/html.ts#renderBlocksToHtml": {
      const md = args[0] as string
      const rawOpts = (args[1] ?? undefined) as { gfm?: boolean | null; math?: boolean | null } | undefined
      const opts = {
        gfm: rawOpts?.gfm ?? true,
        math: rawOpts?.math ?? false,
      }
      const stream = patchmarkStreamMod.createMarkdownStream(opts)
      stream.update(md, false)
      return patchmarkHtmlMod.renderBlocksToHtml(stream.getBlocks(), opts)
    }

    // MARK: - packages/ai
    case "ai/src/protocols/utils/mistral-tool-id.ts#valid":
      return aiMistralToolIdMod.valid.test(args[0] as string)
    case "ai/src/protocols/utils/mistral-tool-id.ts#hash":
      return aiMistralToolIdMod.hash(args[0] as string)
    case "ai/src/protocols/utils/claude-model.ts#claudeVersion":
      return aiClaudeModelMod.claudeVersion(args[0] as string) ?? null
    case "ai/src/protocols/utils/claude-model.ts#supportsThinkingBlockBinding": {
      const raw = args[0] as { id: string; supportsThinkingBlockBinding?: boolean | null }
      const model = {
        id: raw.id,
        ...(raw.supportsThinkingBlockBinding != null
          ? { compatibility: { supportsThinkingBlockBinding: raw.supportsThinkingBlockBinding } }
          : {}),
      }
      return aiClaudeModelMod.supportsThinkingBlockBinding(model)
    }
    case "ai/src/protocols/utils/image-sizing.ts#tier":
      return aiImageSizingMod.tier(args[0] as string) ?? null
    case "ai/src/protocols/utils/image-sizing.ts#fit": {
      const rawShape = args[0] as { aspect?: string | null; resolution?: string | null }
      const rawLimits = args[1] as {
        multiple: number
        minEdge?: number | null
        maxEdge?: number | null
        minPixels?: number | null
        maxPixels?: number | null
        maxRatio?: number | null
      }
      const shape = {
        ...(rawShape.aspect != null ? { aspect: rawShape.aspect } : {}),
        ...(rawShape.resolution != null ? { resolution: rawShape.resolution } : {}),
      }
      const limits = {
        multiple: rawLimits.multiple,
        ...(rawLimits.minEdge != null ? { minEdge: rawLimits.minEdge } : {}),
        ...(rawLimits.maxEdge != null ? { maxEdge: rawLimits.maxEdge } : {}),
        ...(rawLimits.minPixels != null ? { minPixels: rawLimits.minPixels } : {}),
        ...(rawLimits.maxPixels != null ? { maxPixels: rawLimits.maxPixels } : {}),
        ...(rawLimits.maxRatio != null ? { maxRatio: rawLimits.maxRatio } : {}),
      }
      return aiImageSizingMod.fit(shape, limits)
    }
    case "ai/src/protocols/utils/image-sizing.ts#nearest": {
      const rawShape = args[0] as { aspect?: string | null; resolution?: string | null }
      const sizes = args[1] as Array<{ width: number; height: number }>
      const shape = {
        ...(rawShape.aspect != null ? { aspect: rawShape.aspect } : {}),
        ...(rawShape.resolution != null ? { resolution: rawShape.resolution } : {}),
      }
      return aiImageSizingMod.nearest(shape, sizes)
    }
    case "ai/src/protocols/utils/gemini-json-schema.ts#normalize":
      return aiGeminiJsonSchemaMod.normalize(args[0] as Record<string, unknown>)
    case "ai/src/protocols/utils/cache.ts#openAIRequestTTL":
      return aiCacheMod.openAIRequestTTL((args[0] ?? undefined) as string | undefined)
    case "ai/src/protocols/utils/partial-json.ts#parseJSON":
      return args.length > 1
        ? aiPartialJsonMod.parseJSON(args[0] as string, args[1] as number)
        : aiPartialJsonMod.parseJSON(args[0] as string)
    case "ai/src/utils/media-type.ts#detectMediaType":
      return aiMediaTypeMod.detectMediaType(new Uint8Array(args[0] as number[])) ?? null
    case "ai/src/utils/media-type.ts#fileMediaType":
      return aiMediaTypeMod.fileMediaType(new Uint8Array(args[0] as number[]), args[1] as string) ?? null
    case "ai/src/utils/media-type.ts#mediaTypeExtension":
      return aiMediaTypeMod.mediaTypeExtension(args[0] as string) ?? null
    case "ai/src/utils/provider-codes.ts#awsErrorType":
      return aiProviderCodesMod.awsErrorType(args[0] ?? undefined)
    case "ai/src/utils/provider-codes.ts#providerCodes":
      return aiProviderCodesMod.providerCodes(args[0])
    case "ai/src/route/endpoint.ts#trimBaseUrl":
      return aiEndpointMod.trimBaseUrl(args[0] as string)
    case "ai/src/protocols/shared.ts#wrapSystemUpdate": {
      const texts = args[0] as string[]
      return aiSharedMod.wrapSystemUpdate(texts.map((text) => ({ text })))
    }
    case "ai/src/protocols/shared.ts#fitThinkingBudget": {
      const budget = args[0] as number
      const maxTokens = (args[1] ?? undefined) as number | undefined
      return args.length > 2
        ? aiSharedMod.fitThinkingBudget(budget, maxTokens, args[2] as number)
        : aiSharedMod.fitThinkingBudget(budget, maxTokens)
    }
    case "ai/src/protocols/shared.ts#promptCacheKey": {
      const raw = args[0] as {
        promptCacheKey?: string | null
        cache?: string | null
        capabilityPromptCacheKey?: boolean | null
      }
      const req = {
        model: {
          ...(raw.capabilityPromptCacheKey != null
            ? { capabilities: { promptCacheKey: raw.capabilityPromptCacheKey } }
            : {}),
        },
        ...(raw.cache != null ? { cache: raw.cache } : {}),
        ...(raw.promptCacheKey != null ? { promptCacheKey: raw.promptCacheKey } : {}),
      }
      return aiSharedMod.promptCacheKey(req) ?? null
    }
    case "ai/src/provider-error.ts#isContextOverflow":
      return aiProviderErrorMod.isContextOverflow(args[0] as string)

    // MARK: - packages/core
    case "core/src/util/wildcard.ts#match":
      return args.length > 2
        ? coreWildcardMod.match(args[0] as string, args[1] as string, args[2] as boolean)
        : coreWildcardMod.match(args[0] as string, args[1] as string)
    case "core/src/util/canonical-json.ts#canonicalJson":
      return coreCanonicalJsonMod.canonicalJson(args[0])
    case "core/src/util/token.ts#estimate":
      return coreTokenMod.estimate(args[0] as string)
    case "core/src/mime.ts#detect":
      return coreMimeMod.detect(new Uint8Array(args[0] as number[]))
    case "core/src/mime.ts#detectMedia":
      return coreMimeMod.detectMedia(new Uint8Array(args[0] as number[])) ?? null
    case "core/src/mime.ts#isTextual":
      return coreMimeMod.isTextual(args[0] as string)
    case "core/src/config/markdown.ts#sanitize":
      return coreMarkdownMod.sanitize(args[0] as string)
    case "core/src/managed-policy.ts#decision":
      return coreManagedPolicyMod.decision(
        args[0] as Array<{ action: string; resource: string; effect: string }>,
        args[1] as string,
        args[2] as string,
      )
    case "core/src/flag.ts#resolve": {
      const raw = args[0] as {
        entries: Array<{ experimental?: Record<string, boolean | null> | null }>
        channel: string
        overrides?: string | null
      }
      const entries = raw.entries.map((e) => ({
        type: "document" as const,
        info: {
          ...(e.experimental != null
            ? {
                experimental: Object.fromEntries(
                  Object.entries(e.experimental).filter(([, v]) => v != null),
                ),
              }
            : {}),
        },
      }))
      return coreFlagMod.resolve({
        entries,
        channel: raw.channel,
        ...(raw.overrides != null ? { overrides: raw.overrides } : {}),
      })
    }
    case "core/src/permission.ts#evaluate": {
      const action = args[0] as string
      const resource = args[1] as string
      const rulesets = args[2] as Array<Array<{ action: string; resource: string; effect: string }>>
      return corePermissionMod.evaluate(action, resource, ...rulesets)
    }

    // MARK: - packages/server
    case "server/src/range.ts#parse":
      return serverRangeMod.parse((args[0] ?? undefined) as string | undefined, args[1] as number) ?? null
    case "server/src/content-headers.ts#disposition":
      return serverContentHeadersMod.disposition(args[0] as string)
    case "server/src/content-headers.ts#download": {
      const raw = args[0] as { path?: string | null; mime: string }
      return serverContentHeadersMod.download({
        ...(raw.path != null ? { path: raw.path } : {}),
        mime: raw.mime,
      })
    }
    case "server/src/cors.ts#isAllowedCorsOrigin": {
      const origin = (args[0] ?? undefined) as string | undefined
      const rawOpts = (args[1] ?? undefined) as { cors?: string[] | null } | undefined
      const opts = rawOpts?.cors != null ? { cors: rawOpts.cors } : undefined
      return serverCorsMod.isAllowedCorsOrigin(origin, opts)
    }
    case "server/src/cors.ts#isAllowedRequestOrigin": {
      const origin = (args[0] ?? undefined) as string | undefined
      const host = (args[1] ?? undefined) as string | undefined
      const rawOpts = (args[2] ?? undefined) as { cors?: string[] | null } | undefined
      const opts = rawOpts?.cors != null ? { cors: rawOpts.cors } : undefined
      return serverCorsMod.isAllowedRequestOrigin(origin, host, opts)
    }
    case "server/src/media-uri.ts#wantsMediaRefs": {
      const headers = args[0] as Record<string, string>
      return serverMediaUriMod.wantsMediaRefs({ headers })
    }
    case "server/src/request-site.ts#rejected": {
      const req = args[0] as { url: string; headers: Record<string, string> }
      const rawOpts = (args[1] ?? undefined) as { cors?: string[] | null } | undefined
      const opts = rawOpts?.cors != null ? { cors: rawOpts.cors } : undefined
      return serverRequestSiteMod.rejected(req, opts)
    }

    // MARK: - packages/schema & packages/protocol
    case "schema/src/token-usage.ts#total":
      return tokenUsageMod.total(
        args[0] as { input: number; output: number; reasoning: number; cache: { read: number; write: number } },
      )
    case "schema/src/event.ts#versionedType":
      return eventSchemaMod.versionedType(args[0] as string, args[1] as number)
    case "schema/src/event-manifest.ts#isServer":
      return eventManifestMod.isServer({ type: args[0] as string })
    case "protocol/src/groups/event.ts#isOpenCodeEvent":
      return protocolEventMod.isOpenCodeEvent({ type: args[0] as string })
    case "protocol/src/groups/server.ts#isPairingConnectURL":
      return protocolServerMod.isPairingConnectURL(new URL(args[0] as string))
    case "protocol/src/groups/pty.ts#hasPtyConnectTicketURL":
      return protocolPtyMod.hasPtyConnectTicketURL(new URL(args[0] as string))
    case "protocol/src/groups/persistent-pty.ts#hasPersistentPtyConnectTicketURL":
      return protocolPersistentPtyMod.hasPersistentPtyConnectTicketURL(new URL(args[0] as string))
    case "protocol/src/groups/mcp.ts#hasMcpClientTicketURL":
      return protocolMcpMod.hasMcpClientTicketURL(new URL(args[0] as string))

    // MARK: - packages/cli
    case "cli/src/database-path.ts#databasePath": {
      const data = args[0] as string
      const env = (args[1] ?? {}) as Record<string, string | null>
      const prevDb = process.env.OPENCODE_DB
      const prevDisable = process.env.OPENCODE_DISABLE_CHANNEL_DB
      try {
        if (env.OPENCODE_DB != null) process.env.OPENCODE_DB = env.OPENCODE_DB
        else delete process.env.OPENCODE_DB
        if (env.OPENCODE_DISABLE_CHANNEL_DB != null) {
          process.env.OPENCODE_DISABLE_CHANNEL_DB = env.OPENCODE_DISABLE_CHANNEL_DB
        } else {
          delete process.env.OPENCODE_DISABLE_CHANNEL_DB
        }
        return cliDatabasePathMod.databasePath(data)
      } finally {
        if (prevDb !== undefined) process.env.OPENCODE_DB = prevDb
        else delete process.env.OPENCODE_DB
        if (prevDisable !== undefined) process.env.OPENCODE_DISABLE_CHANNEL_DB = prevDisable
        else delete process.env.OPENCODE_DISABLE_CHANNEL_DB
      }
    }
    case "cli/src/services/updater-action.ts#parseReleaseVersion":
      return cliUpdaterActionMod.parseReleaseVersion(args[0] as string) ?? null
    case "cli/src/services/updater-action.ts#action":
      return cliUpdaterActionMod.action(args[0] as string, args[1] as string, args[2] as "disable" | "notify" | "auto")
    case "cli/src/services/service-config.ts#filename":
      return cliServiceConfigMod.filename(args[0] as string)
    case "cli/src/services/service-config.ts#defaultPort":
      return cliServiceConfigMod.defaultPort(args[0] as string, args[1] as NodeJS.Platform)
    case "cli/src/services/service-config.ts#legacyFilename":
      return cliServiceConfigMod.legacyFilename(args[0] as string) ?? null
    case "cli/src/services/service-config.ts#versionBelongsToChannel":
      return cliServiceConfigMod.versionBelongsToChannel(
        (args[0] ?? undefined) as string | undefined,
        args[1] as string,
        args[2] as string,
      )
    case "cli/src/node/target.ts#nodeTarget":
      return cliNodeTargetMod.nodeTarget(args[0] as string, args[1] as string)

    // MARK: - packages/latex
    case "latex/src/render.ts#renderLatexToString":
      return latexRenderMod.renderLatexToString(
        args[0] as string,
        (args[1] ?? undefined) as { displayMode?: boolean; strict?: boolean } | undefined,
      )
    case "latex/src/parser.ts#expandLatexMacros":
      return latexParserMod.expandLatexMacros(
        args[0] as string,
        { macros: args[1] as Record<string, string> },
      )

    // MARK: - packages/merman
    case "merman/src/detect.ts#detectMermaidDiagram":
      return mermanDetectMod.detectMermaidDiagram(args[0] as string) ?? null
    case "merman/src/flowchart/render.ts#renderFlowchartDiagram":
      return mermanFlowMod.renderFlowchartDiagram(args[0] as string)
    case "merman/src/sequence/diagram.ts#renderSequenceDiagram":
      return mermanSeqMod.renderSequenceDiagram(args[0] as string)
    case "merman/src/state/diagram.ts#renderStateDiagram":
      return mermanStateMod.renderStateDiagram(args[0] as string)
    case "merman/src/timeline/diagram.ts#renderTimelineDiagram":
      return mermanTimelineMod.renderTimelineDiagram(args[0] as string)
    case "merman/src/gitgraph/diagram.ts#renderGitGraphDiagram":
      return mermanGitMod.renderGitGraphDiagram(args[0] as string)
    case "merman/src/gantt/diagram.ts#renderGanttDiagram":
      return mermanGanttMod.renderGanttDiagram(args[0] as string)

    // MARK: - packages/core/src/shell/scan.ts
    case "core/src/shell/scan.ts#scan": {
      const res = args.length > 1
        ? coreShellScanMod.scan(args[0] as string, { dialect: args[1] as "bash" | "zsh" | "posix" })
        : coreShellScanMod.scan(args[0] as string)
      if (res.kind === "opaque") return { kind: "opaque", reason: res.reason }
      return {
        kind: "scanned",
        commands: res.commands.map((c: { resource: string; words: string[]; rawWords: string[] }) => ({
          resource: c.resource,
          words: c.words,
          rawWords: c.rawWords,
        })),
      }
    }
    case "core/src/shell/scan.ts#scanPowerShell": {
      const res = coreShellScanMod.scanPowerShell(args[0] as string)
      if (res.kind === "opaque") return { kind: "opaque", reason: res.reason }
      return {
        kind: "scanned",
        commands: res.commands.map((c: { resource: string; words: string[]; rawWords: string[] }) => ({
          resource: c.resource,
          words: c.words,
          rawWords: c.rawWords,
        })),
      }
    }

    default:
      throw new Error(`Unknown oracle function: ${fn}`)
  }
}

// psychoscript (Code Mode's language) needs the real `effect` package, which the stub plugin above would shadow in
// this process, so its requests (`psychoscript/...`) are forwarded in one batch to a clean child process running
// `psychoscript-oracle.ts` against the real upstream/psychoscript sources. See that file for the canonical outcome.
const PSYCHOSCRIPT_PREFIX = "psychoscript/"

async function runPsychoscriptOracle(lines: string[]): Promise<void> {
  if (lines.length === 0) return
  const proc = Bun.spawn(["bun", path.join(import.meta.dir, "psychoscript-oracle.ts")], {
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
    for (const line of lines) {
      const req = JSON.parse(line) as { id: string }
      process.stdout.write(
        JSON.stringify({ id: req.id, ok: false, value: null, error: `psychoscript oracle exited ${exitCode}: ${stderr}` }) +
          "\n",
      )
    }
    return
  }
  for (const line of stdout.split("\n")) {
    if (line.trim()) process.stdout.write(line + "\n")
  }
}

const input = await Bun.stdin.text()
const psychoscriptLines: string[] = []
for (const line of input.split("\n")) {
  if (!line.trim()) continue
  const req = JSON.parse(line) as { id: string; fn: string; args: unknown[] }
  if (req.fn.startsWith(PSYCHOSCRIPT_PREFIX)) {
    psychoscriptLines.push(line)
    continue
  }
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

await runPsychoscriptOracle(psychoscriptLines)
