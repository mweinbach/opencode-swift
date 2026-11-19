import path from "path"
import fs from "fs"

const PKG_DIR = path.resolve(import.meta.dir, "../..")
const UPSTREAM_DIR = fs.existsSync(path.join(PKG_DIR, "upstream/opentui"))
  ? path.join(PKG_DIR, "upstream/opentui")
  : path.resolve(PKG_DIR, "../../upstream/opentui")

// Silence upstream console.warn noise for intentionally invalid color/border fallback vectors
console.warn = () => {}

// Allow importing pure functions from core/src/utils.ts without pulling native FFI Renderable runtime
Bun.plugin({
  name: "opentui-pure-oracle-stub",
  setup(build) {
    build.onResolve({ filter: /Renderable\.js$/ }, () => ({ path: "renderable-stub", namespace: "stub" }))
    build.onLoad({ filter: /.*/, namespace: "stub" }, () => ({
      exports: { Renderable: class {} },
      loader: "object",
    }))
  },
})

const rgbaMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/RGBA.ts"))
const borderMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/border.ts"))
const ansiMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/ansi.ts"))
const typesMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/types.ts"))
const utilsMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/utils.ts"))
const geomMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/render-geometry.ts"))
const vpMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/objects-in-viewport.ts"))
const vdMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/validate-dir-name.ts"))
const pasteMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/paste.ts"))
const capsMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/terminal-capability-detection.ts"))
const linksMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/detect-links.ts"))
const scrollAccelMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/scroll-acceleration.ts"))
const scrollChainMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/scroll-chain.ts"))
const validationsMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/renderable.validations.ts"))
const yogaOptionsMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/yoga.options.ts"))
const syntaxStyleMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/syntax-style.ts"))
const tableWidthMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/renderables/text-table-width.ts"))
const qrcodeMod = await import(path.join(UPSTREAM_DIR, "packages/qrcode/src/lib/qrcode.ts"))
const qrcodeEncodingMod = await import(path.join(UPSTREAM_DIR, "packages/qrcode/src/lib/qrcode.encoding.ts"))
const icyMetaMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/audio-stream/icy/metadata.ts"))
const htmlKeymapMod = await import(path.join(UPSTREAM_DIR, "packages/keymap/src/html.ts"))
const keybindingMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/keybinding.internal.ts"))
const resolveFtMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/tree-sitter/resolve-ft.ts"))
const themeModeMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/renderer-theme-mode.ts"))
const paletteMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/lib/terminal-palette.ts"))
const timelineMod = await import(path.join(UPSTREAM_DIR, "packages/core/src/animation/Timeline.ts"))
const keysMod = await import(path.join(UPSTREAM_DIR, "packages/keymap/src/services/keys.ts"))
const valuesMod = await import(path.join(UPSTREAM_DIR, "packages/keymap/src/services/values.ts"))
const cmdNormMod = await import(path.join(UPSTREAM_DIR, "packages/keymap/src/services/primitives/command-normalization.ts"))
const compilerMod = await import(path.join(UPSTREAM_DIR, "packages/keymap/src/services/compiler.ts"))
const defaultParserMod = await import(path.join(UPSTREAM_DIR, "packages/keymap/src/addons/universal/default-parser.ts"))

const upstreamCompiler = compilerMod.createCompilerService(
  {
    bindingParsers: { values: () => [defaultParserMod.defaultBindingParser] },
    tokens: new Map(),
    patterns: new Map(),
    bindingExpanders: { values: () => [] },
    bindingTransformers: { values: () => [] },
    bindingFields: new Map(),
    layerFields: new Map(),
    customMatchers: new Map(),
  } as unknown as Parameters<typeof compilerMod.createCompilerService>[0],
  { error: () => {}, warn: () => {} } as unknown as Parameters<typeof compilerMod.createCompilerService>[1],
  { resolve: () => ({}) } as unknown as Parameters<typeof compilerMod.createCompilerService>[2],
  { warnUnknownToken: () => {} } as unknown as Parameters<typeof compilerMod.createCompilerService>[3],
)

function serializeRGBA(c: InstanceType<typeof rgbaMod.RGBA>) {
  return {
    ints: c.toInts(),
    buffer: Array.from(c.buffer),
    meta: c.meta,
    intent: c.intent,
    slot: c.slot,
    string: c.toString(),
  }
}

function normalize(value: unknown): unknown {
  if (value === undefined) return null
  if (value instanceof Uint8Array || value instanceof Uint16Array || value instanceof Uint32Array) {
    return Array.from(value)
  }
  if (Array.isArray(value)) return value.map(normalize)
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(value as Record<string, unknown>).sort()) {
      out[k] = normalize((value as Record<string, unknown>)[k])
    }
    return out
  }
  return value
}

function invoke(fn: string, args: unknown[]): unknown {
  switch (fn) {
    // RGBA.ts
    case "core/src/lib/RGBA.ts#normalizeIndexedColorIndex":
      return rgbaMod.normalizeIndexedColorIndex(args[0] as number)
    case "core/src/lib/RGBA.ts#ansi256IndexToRgb":
      return Array.from(rgbaMod.ansi256IndexToRgb(args[0] as number))
    case "core/src/lib/RGBA.ts#RGBA.fromValues":
      return serializeRGBA(
        rgbaMod.RGBA.fromValues(args[0] as number, args[1] as number, args[2] as number, (args[3] as number | undefined) ?? 1),
      )
    case "core/src/lib/RGBA.ts#RGBA.fromInts":
      return serializeRGBA(
        rgbaMod.RGBA.fromInts(args[0] as number, args[1] as number, args[2] as number, (args[3] as number | undefined) ?? 255),
      )
    case "core/src/lib/RGBA.ts#RGBA.fromIndex":
      return serializeRGBA(rgbaMod.RGBA.fromIndex(args[0] as number, (args[1] as string | undefined) ?? undefined))
    case "core/src/lib/RGBA.ts#RGBA.defaultForeground":
      return serializeRGBA(rgbaMod.RGBA.defaultForeground((args[0] as string | undefined) ?? undefined))
    case "core/src/lib/RGBA.ts#RGBA.defaultBackground":
      return serializeRGBA(rgbaMod.RGBA.defaultBackground((args[0] as string | undefined) ?? undefined))
    case "core/src/lib/RGBA.ts#hexToRgb":
      return serializeRGBA(rgbaMod.hexToRgb(args[0] as string))
    case "core/src/lib/RGBA.ts#rgbToHex":
      return rgbaMod.rgbToHex(
        rgbaMod.RGBA.fromInts(args[0] as number, args[1] as number, args[2] as number, (args[3] as number | undefined) ?? 255),
      )
    case "core/src/lib/RGBA.ts#hsvToRgb":
      return serializeRGBA(rgbaMod.hsvToRgb(args[0] as number, args[1] as number, args[2] as number))
    case "core/src/lib/RGBA.ts#parseColor":
      return serializeRGBA(rgbaMod.parseColor(args[0] as string))

    // TextAttributes & utils.ts
    case "core/src/types.ts#getBaseAttributes":
      return typesMod.getBaseAttributes(args[0] as number)
    case "core/src/utils.ts#createTextAttributes":
      return utilsMod.createTextAttributes((args[0] as Record<string, boolean>) ?? {})
    case "core/src/utils.ts#attributesWithLink":
      return utilsMod.attributesWithLink(args[0] as number, args[1] as number) >>> 0
    case "core/src/utils.ts#getLinkId":
      return utilsMod.getLinkId(args[0] as number)

    // border.ts
    case "core/src/lib/border.ts#isValidBorderStyle":
      return borderMod.isValidBorderStyle(args[0])
    case "core/src/lib/border.ts#parseBorderStyle":
      return args.length > 1
        ? borderMod.parseBorderStyle(args[0], args[1] as "single" | "double" | "rounded" | "heavy")
        : borderMod.parseBorderStyle(args[0])
    case "core/src/lib/border.ts#getBorderFromSides":
      return borderMod.getBorderFromSides(args[0] as { top: boolean; right: boolean; bottom: boolean; left: boolean })
    case "core/src/lib/border.ts#getBorderSides":
      return borderMod.getBorderSides(args[0] as boolean | ("top" | "right" | "bottom" | "left")[])
    case "core/src/lib/border.ts#borderCharsToArray":
      return Array.from(borderMod.borderCharsToArray(borderMod.BorderChars[args[0] as keyof typeof borderMod.BorderChars]))

    // ansi.ts
    case "core/src/ansi.ts#ANSI": {
      const op = args[0] as string
      const entry = (ansiMod.ANSI as Record<string, unknown>)[op]
      if (typeof entry === "function") {
        return (entry as (...rest: unknown[]) => unknown)(...args.slice(1))
      }
      return entry
    }

    // render-geometry.ts
    case "core/src/lib/render-geometry.ts#calculateRenderGeometry":
      return geomMod.calculateRenderGeometry(
        args[0] as "alternate-screen" | "main-screen" | "split-footer",
        args[1] as number,
        args[2] as number,
        args[3] as number,
      )

    // objects-in-viewport.ts
    case "core/src/lib/objects-in-viewport.ts#getObjectsInViewport": {
      const visible = vpMod.getObjectsInViewport(
        args[0] as { x: number; y: number; width: number; height: number },
        args[1] as Array<{ id: string; screenX: number; screenY: number; width: number; height: number; zIndex: number }>,
        (args[2] as "row" | "column" | undefined) ?? "column",
        (args[3] as number | undefined) ?? 10,
        (args[4] as number | undefined) ?? 16,
      )
      return visible.map((v) => v.id)
    }

    // validate-dir-name.ts
    case "core/src/lib/validate-dir-name.ts#isValidDirectoryName":
      return vdMod.isValidDirectoryName(args[0] as string)

    // paste.ts
    case "core/src/lib/paste.ts#decodePasteBytes":
      return pasteMod.decodePasteBytes(new Uint8Array(args[0] as number[]))
    case "core/src/lib/paste.ts#stripAnsiSequences":
      return pasteMod.stripAnsiSequences(args[0] as string)

    // terminal-capability-detection.ts
    case "core/src/lib/terminal-capability-detection.ts#isCapabilityResponse":
      return capsMod.isCapabilityResponse(args[0] as string)
    case "core/src/lib/terminal-capability-detection.ts#isExplicitWidthReport":
      return capsMod.isExplicitWidthReport(args[0] as string)
    case "core/src/lib/terminal-capability-detection.ts#isPixelResolutionResponse":
      return capsMod.isPixelResolutionResponse(args[0] as string)
    case "core/src/lib/terminal-capability-detection.ts#parsePixelResolution":
      return capsMod.parsePixelResolution(args[0] as string) ?? null

    // detect-links.ts
    case "core/src/lib/detect-links.ts#normalizeMarkdownLinkTarget":
      return linksMod.normalizeMarkdownLinkTarget(args[0] as string)
    case "core/src/lib/detect-links.ts#detectLinks": {
      const rawChunks = (args[0] as Array<{ text: string; link?: { url: string } }>).map((c) => ({
        __isChunk: true as const,
        text: c.text,
        ...(c.link ? { link: c.link } : {}),
      }))
      const result = linksMod.detectLinks(rawChunks, {
        content: args[1] as string,
        highlights: (args[2] as Array<[number, number, string]>) ?? [],
      })
      return result.map((c) => ({ text: c.text, url: c.link?.url ?? null }))
    }

    // scroll-chain.ts & scroll-acceleration.ts
    case "core/src/lib/scroll-chain.ts#wheelDirection":
      return (
        scrollChainMod.wheelDirection({
          scroll: args[0] ? { direction: args[0] as "up" | "down" | "left" | "right" } : undefined,
          modifiers: { shift: Boolean(args[1]) },
        }) ?? null
      )
    case "core/src/lib/scroll-acceleration.ts#MacOSScrollAccel.tick": {
      const accel = new scrollAccelMod.MacOSScrollAccel()
      const timestamps = args[0] as number[]
      return timestamps.map((ts) => Math.round(accel.tick(ts) * 1e6) / 1e6)
    }

    // renderable.validations.ts
    case "core/src/lib/renderable.validations.ts#isValidPercentage":
      return validationsMod.isValidPercentage(args[0] === "__undefined__" ? undefined : args[0])
    case "core/src/lib/renderable.validations.ts#isMarginType":
      return validationsMod.isMarginType(args[0] === "__undefined__" ? undefined : args[0])
    case "core/src/lib/renderable.validations.ts#isPaddingType":
      return validationsMod.isPaddingType(args[0] === "__undefined__" ? undefined : args[0])
    case "core/src/lib/renderable.validations.ts#isPositionType":
      return validationsMod.isPositionType(args[0] === "__undefined__" ? undefined : args[0])
    case "core/src/lib/renderable.validations.ts#isPositionTypeType":
      return validationsMod.isPositionTypeType(args[0] === "__undefined__" ? undefined : args[0])
    case "core/src/lib/renderable.validations.ts#isOverflowType":
      return validationsMod.isOverflowType(args[0] === "__undefined__" ? undefined : args[0])
    case "core/src/lib/renderable.validations.ts#isDimensionType":
      return validationsMod.isDimensionType(args[0] === "__undefined__" ? undefined : args[0])
    case "core/src/lib/renderable.validations.ts#isFlexBasisType":
      return validationsMod.isFlexBasisType(args[0] === "__undefined__" ? undefined : args[0])
    case "core/src/lib/renderable.validations.ts#isSizeType":
      return validationsMod.isSizeType(args[0] === "__undefined__" ? undefined : args[0])

    // yoga.options.ts
    case "core/src/lib/yoga.options.ts#parseAlign":
      return yogaOptionsMod.parseAlign((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseAlign>[0])
    case "core/src/lib/yoga.options.ts#parseAlignItems":
      return yogaOptionsMod.parseAlignItems((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseAlignItems>[0])
    case "core/src/lib/yoga.options.ts#parseAlignContent":
      return yogaOptionsMod.parseAlignContent((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseAlignContent>[0])
    case "core/src/lib/yoga.options.ts#parseBoxSizing":
      return yogaOptionsMod.parseBoxSizing((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseBoxSizing>[0])
    case "core/src/lib/yoga.options.ts#parseDimension":
      return yogaOptionsMod.parseDimension((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseDimension>[0])
    case "core/src/lib/yoga.options.ts#parseDirection":
      return yogaOptionsMod.parseDirection((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseDirection>[0])
    case "core/src/lib/yoga.options.ts#parseDisplay":
      return yogaOptionsMod.parseDisplay((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseDisplay>[0])
    case "core/src/lib/yoga.options.ts#parseEdge":
      return yogaOptionsMod.parseEdge((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseEdge>[0])
    case "core/src/lib/yoga.options.ts#parseFlexDirection":
      return yogaOptionsMod.parseFlexDirection((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseFlexDirection>[0])
    case "core/src/lib/yoga.options.ts#parseGutter":
      return yogaOptionsMod.parseGutter((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseGutter>[0])
    case "core/src/lib/yoga.options.ts#parseJustify":
      return yogaOptionsMod.parseJustify((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseJustify>[0])
    case "core/src/lib/yoga.options.ts#parseOverflow":
      return yogaOptionsMod.parseOverflow((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseOverflow>[0])
    case "core/src/lib/yoga.options.ts#parsePositionType":
      return yogaOptionsMod.parsePositionType((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parsePositionType>[0])
    case "core/src/lib/yoga.options.ts#parseWrap":
      return yogaOptionsMod.parseWrap((args[0] ?? undefined) as Parameters<typeof yogaOptionsMod.parseWrap>[0])

    // keymap/src/services/keys.ts
    case "keymap/src/services/keys.ts#normalizeBindingTokenName":
      return keysMod.normalizeBindingTokenName(args[0] as string)
    case "keymap/src/services/keys.ts#normalizeKeyName":
      return keysMod.normalizeKeyName(args[0] as string)
    case "keymap/src/services/keys.ts#normalizeKeyStroke": {
      const s = keysMod.normalizeKeyStroke(args[0] as Parameters<typeof keysMod.normalizeKeyStroke>[0])
      return { name: s.name, ctrl: s.ctrl, shift: s.shift, meta: s.meta, super: s.super, hyper: s.hyper ?? null }
    }
    case "keymap/src/services/keys.ts#createKeyMatch":
      return keysMod.createKeyMatch(args[0] as Parameters<typeof keysMod.createKeyMatch>[0])
    case "keymap/src/services/keys.ts#createTextKeyMatch":
      return keysMod.createTextKeyMatch(args[0] as string)
    case "keymap/src/services/keys.ts#stringifyKeyStroke":
      return keysMod.stringifyKeyStroke(args[0] as Parameters<typeof keysMod.stringifyKeyStroke>[0])
    case "keymap/src/services/keys.ts#stringifyKeySequence":
      return keysMod.stringifyKeySequence(
        args[0] as Parameters<typeof keysMod.stringifyKeySequence>[0],
        args[1] as Parameters<typeof keysMod.stringifyKeySequence>[1],
      )
    case "keymap/src/services/keys.ts#createKeySequencePart": {
      const p = keysMod.createKeySequencePart(
        args[0] as Parameters<typeof keysMod.createKeySequencePart>[0],
        args[1] as Parameters<typeof keysMod.createKeySequencePart>[1],
      )
      return {
        stroke: {
          name: p.stroke.name,
          ctrl: p.stroke.ctrl,
          shift: p.stroke.shift,
          meta: p.stroke.meta,
          super: p.stroke.super,
          hyper: p.stroke.hyper ?? null,
        },
        display: p.display,
        match: p.match,
        tokenName: p.tokenName ?? null,
      }
    }

    // keymap compiler & command normalization
    case "keymap/src/services/primitives/command-normalization.ts#normalizeCommandName":
      return cmdNormMod.normalizeCommandName(args[0] as string)
    case "keymap/src/services/compiler.ts#createCompilerService": {
      const parts = upstreamCompiler.parseKeySequence(args[0] as string)
      return parts.map((p) => ({
        display: p.display,
        match: p.match,
        name: p.stroke.name,
        ctrl: p.stroke.ctrl,
        shift: p.stroke.shift,
        meta: p.stroke.meta,
        super: p.stroke.super,
      }))
    }
    case "keymap/src/services/values.ts#sameCompiledData":
      return valuesMod.sameCompiledData(args[0], args[1], new Set(), [])

    // text-table-width.ts
    case "core/src/renderables/text-table-width.ts#allocateProportionalColumnWidths":
      return tableWidthMod.allocateProportionalColumnWidths(args[0] as number[], args[1] as number, args[2] as number)

    // syntax-style.ts
    case "core/src/syntax-style.ts#convertThemeToStyles": {
      const res = syntaxStyleMod.convertThemeToStyles(args[0] as Parameters<typeof syntaxStyleMod.convertThemeToStyles>[0])
      const out: Record<string, unknown> = {}
      for (const [k, v] of Object.entries(res)) {
        out[k] = {
          fg: v.fg ? rgbaMod.rgbToHex(v.fg) : null,
          bg: v.bg ? rgbaMod.rgbToHex(v.bg) : null,
          bold: v.bold ?? null,
          italic: v.italic ?? null,
          underline: v.underline ?? null,
          dim: v.dim ?? null,
          strikethrough: v.strikethrough ?? null,
        }
      }
      return out
    }

    // qrcode
    case "qrcode/src/lib/qrcode.ts#QrSegment.isNumeric":
      return qrcodeMod.QrSegment.isNumeric(args[0] as string)
    case "qrcode/src/lib/qrcode.ts#QrSegment.isAlphanumeric":
      return qrcodeMod.QrSegment.isAlphanumeric(args[0] as string)
    case "qrcode/src/lib/qrcode.ts#encodeTextBytes":
      return Array.from(qrcodeMod.encodeTextBytes(args[0] as string, args[1] as "utf-8" | "iso-8859-1" | "shift-jis"))
    case "qrcode/src/lib/qrcode.ts#QRCode.encodeText": {
      const eclMap: Record<string, typeof qrcodeMod.ErrorCorrectionLevel.L> = {
        L: qrcodeMod.ErrorCorrectionLevel.L,
        M: qrcodeMod.ErrorCorrectionLevel.M,
        Q: qrcodeMod.ErrorCorrectionLevel.Q,
        H: qrcodeMod.ErrorCorrectionLevel.H,
      }
      const q = qrcodeMod.QRCode.encodeText(args[0] as string, eclMap[args[1] as string]!)
      return {
        version: q.version,
        size: q.size,
        mask: q.mask,
        matrix: q.toMatrix(),
      }
    }
    case "qrcode/src/lib/qrcode.render.ts#matrixToTerminal": {
      const eclMap: Record<string, typeof qrcodeMod.ErrorCorrectionLevel.L> = {
        L: qrcodeMod.ErrorCorrectionLevel.L,
        M: qrcodeMod.ErrorCorrectionLevel.M,
        Q: qrcodeMod.ErrorCorrectionLevel.Q,
        H: qrcodeMod.ErrorCorrectionLevel.H,
      }
      const q = qrcodeMod.QRCode.encodeText(args[0] as string, eclMap[args[1] as string]!)
      return q.toTerminalString({ border: args[2] as number, invert: Boolean(args[3]) })
    }

    // phase 3 core pure functions
    case "core/src/lib/keybinding.internal.ts#getKeyBindingKey":
      return keybindingMod.getKeyBindingKey(args[0] as Parameters<typeof keybindingMod.getKeyBindingKey>[0])
    case "core/src/lib/keybinding.internal.ts#mergeKeyBindings": {
      const merged = keybindingMod.mergeKeyBindings(
        args[0] as Parameters<typeof keybindingMod.mergeKeyBindings>[0],
        args[1] as Parameters<typeof keybindingMod.mergeKeyBindings>[1],
      )
      return merged.map((b) => ({
        name: b.name,
        ctrl: Boolean(b.ctrl),
        shift: Boolean(b.shift),
        meta: Boolean(b.meta),
        super: Boolean(b.super),
        action: b.action,
      }))
    }
    case "core/src/lib/keybinding.internal.ts#keyBindingToString":
      return keybindingMod.keyBindingToString(args[0] as Parameters<typeof keybindingMod.keyBindingToString>[0])
    case "core/src/lib/tree-sitter/resolve-ft.ts#extToFiletype":
      return resolveFtMod.extToFiletype(args[0] as string) ?? null
    case "core/src/lib/tree-sitter/resolve-ft.ts#pathToFiletype":
      return resolveFtMod.pathToFiletype(args[0] as string) ?? null
    case "core/src/lib/tree-sitter/resolve-ft.ts#infoStringToFiletype":
      return resolveFtMod.infoStringToFiletype(args[0] as string) ?? null
    case "core/src/renderer-theme-mode.ts#RendererThemeMode.handleSequence": {
      const clock = {
        now: () => 0,
        setTimeout: () => ({}),
        clearTimeout: () => {},
        setInterval: () => ({}),
        clearInterval: () => {},
      }
      const tm = new themeModeMod.RendererThemeMode({ queryThemeColors: () => false }, clock as never)
      const res = tm.handleSequence(args[0] as string)
      return { handled: res.handled, changedMode: res.changedMode ?? null, themeMode: tm.themeMode ?? null }
    }
    case "core/src/lib/terminal-palette.ts#applyPaletteReplies": {
      const colors = paletteMod.emptyTerminalColors(args[0] as number)
      const matched = paletteMod.applyPaletteReplies(colors, args[1] as string)
      return {
        matched,
        defaultForeground: colors.defaultForeground,
        defaultBackground: colors.defaultBackground,
        slot1: colors.palette[1] ?? null,
      }
    }
    case "core/src/lib/terminal-palette.ts#buildTerminalPaletteSignature": {
      const input = args[0] as { defaultForeground?: string | null; defaultBackground?: string | null; palette?: (string | null)[] } | null
      if (!input) {
        return paletteMod.buildTerminalPaletteSignature(null)
      }
      const colors = paletteMod.emptyTerminalColors(16)
      colors.defaultForeground = input.defaultForeground ?? null
      colors.defaultBackground = input.defaultBackground ?? null
      if (input.palette) {
        for (let i = 0; i < input.palette.length; i++) colors.palette[i] = input.palette[i] ?? null
      }
      return paletteMod.buildTerminalPaletteSignature(colors)
    }
    case "core/src/animation/Timeline.ts#createTimeline": {
      const ease = args[0] as string
      const times = args[1] as number[]
      const target = { x: 0 }
      const tl = timelineMod.createTimeline({ duration: 1000, autoplay: true })
      tl.add(target, { x: 100, duration: 1000, ease: ease as never }, 0)
      const samples: number[] = []
      let prev = 0
      for (const t of times) {
        tl.update(t - prev)
        prev = t
        samples.push(Math.round(target.x * 1e4) / 1e4)
      }
      return samples
    }

    // phase 4 complete parity functions
    case "qrcode/src/lib/qrcode.encoding.ts#shiftJisCodeForCharacter": {
      try {
        return qrcodeEncodingMod.shiftJisCodeForCharacter(args[0] as string)
      } catch {
        return null
      }
    }
    case "qrcode/src/lib/qrcode.encoding.ts#isKanjiModeShiftJisValue":
      return qrcodeEncodingMod.isKanjiModeShiftJisValue(args[0] as number)
    case "qrcode/src/lib/qrcode.encoding.ts#encodingForKnownEci":
      return qrcodeEncodingMod.encodingForKnownEci(args[0] as number)
    case "qrcode/src/lib/qrcode.ts#QrSegment.isKanji":
      return qrcodeMod.QrSegment.isKanji(args[0] as string)
    case "core/src/audio-stream/icy/metadata.ts#parseIcyMetadata": {
      const bytes = new TextEncoder().encode(args[0] as string)
      return icyMetaMod.parseIcyMetadata(bytes, new TextDecoder("utf-8"))
    }
    case "keymap/src/html.ts#normalizeHtmlKeyName":
      return htmlKeymapMod.normalizeHtmlKeyName(args[0] as string)

    default:
      throw new Error(`Unknown OpenTUI oracle function: ${fn}`)
  }
}

const input = await Bun.stdin.text()
for (const line of input.split("\n")) {
  if (!line.trim()) continue
  const req = JSON.parse(line) as { id: string; fn: string; args: unknown[] }
  try {
    const value = normalize(invoke(req.fn, req.args))
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
