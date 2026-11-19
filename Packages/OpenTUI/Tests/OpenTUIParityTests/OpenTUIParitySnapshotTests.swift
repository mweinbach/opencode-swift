import Testing
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables

@Suite("Offline OpenTUI Upstream Oracle Parity Snapshots")
struct OpenTUIParitySnapshotTests {
    enum SnapshotError: Error {
        case unknownFunction(String)
    }

    private static func rgbaToJSON(_ rgba: RGBA) -> SnapshotJSON {
        let (r, g, b, a) = rgba.toInts()
        return .object([
            "ints": .array([.int(Int64(r)), .int(Int64(g)), .int(Int64(b)), .int(Int64(a))]),
            "buffer": .array(rgba.buffer.map { .int(Int64($0)) }),
            "meta": .int(Int64(rgba.meta)),
            "intent": .string(rgba.intent.rawValue),
            "slot": .int(Int64(rgba.slot)),
            "string": .string(rgba.description),
        ])
    }

    private static func strokeInput(_ val: SnapshotJSON) -> KeyStrokeInput {
        let o = val.obj!
        return KeyStrokeInput(
            name: o["name"]!.str!,
            ctrl: o["ctrl"]?.bool,
            shift: o["shift"]?.bool,
            meta: o["meta"]?.bool,
            super: o["super"]?.bool,
            hyper: o["hyper"]?.bool
        )
    }

    private static func strokeToJSON(_ s: NormalizedKeyStroke) -> SnapshotJSON {
        .object([
            "name": .string(s.name),
            "ctrl": .bool(s.ctrl),
            "shift": .bool(s.shift),
            "meta": .bool(s.meta),
            "super": .bool(s.`super`),
            "hyper": s.hyper.map { .bool($0) } ?? .null,
        ])
    }

    private static func layoutVal(_ v: SnapshotJSON) -> LayoutOptionValue {
        switch v {
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string("__undefined__"): return .undefined
        case .string(let s): return .string(s)
        case .null: return .null
        default: return .null
        }
    }

    private final class NoOpThemeModeHost: RendererThemeModeHost {
        func queryThemeColors() -> Bool { false }
    }

    private static func keyBindingFromJSON(_ v: SnapshotJSON) -> KeyBinding<String> {
        let o = v.obj ?? [:]
        return KeyBinding(
            name: o["name"]?.str ?? "",
            ctrl: o["ctrl"]?.bool ?? false,
            shift: o["shift"]?.bool ?? false,
            meta: o["meta"]?.bool ?? false,
            super: o["super"]?.bool ?? false,
            action: o["action"]?.str ?? ""
        )
    }

    private static func toKeymapValue(_ v: SnapshotJSON) -> KeymapValue {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(Int(i))
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(toKeymapValue))
        case .object(let o): return .object(o.mapValues(toKeymapValue))
        }
    }

    private static func evaluate(_ fn: String, _ args: [SnapshotJSON]) throws -> SnapshotJSON {
        switch fn {
        case "core/src/lib/RGBA.ts#normalizeIndexedColorIndex":
            return .int(Int64(try normalizeIndexedColorIndex(args[0].int!)))
        case "core/src/lib/RGBA.ts#ansi256IndexToRgb":
            let c = try ansi256IndexToRgb(args[0].int!)
            return .array([.int(Int64(c.r)), .int(Int64(c.g)), .int(Int64(c.b))])
        case "core/src/lib/RGBA.ts#RGBA.fromValues":
            return rgbaToJSON(RGBA.fromValues(args[0].dbl!, args[1].dbl!, args[2].dbl!, args.count > 3 ? (args[3].dbl ?? 1.0) : 1.0))
        case "core/src/lib/RGBA.ts#RGBA.fromInts":
            return rgbaToJSON(RGBA.fromInts(args[0].dbl!, args[1].dbl!, args[2].dbl!, args.count > 3 ? (args[3].dbl ?? 255.0) : 255.0))
        case "core/src/lib/RGBA.ts#RGBA.fromIndex":
            return rgbaToJSON(try RGBA.fromIndex(args[0].int!, snapshot: args.count > 1 ? args[1].str : nil))
        case "core/src/lib/RGBA.ts#RGBA.defaultForeground":
            return rgbaToJSON(RGBA.defaultForeground(snapshot: args.first?.str))
        case "core/src/lib/RGBA.ts#RGBA.defaultBackground":
            return rgbaToJSON(RGBA.defaultBackground(snapshot: args.first?.str))
        case "core/src/lib/RGBA.ts#hexToRgb":
            return rgbaToJSON(hexToRgb(args[0].str!))
        case "core/src/lib/RGBA.ts#rgbToHex":
            return .string(rgbToHex(RGBA.fromInts(args[0].int!, args[1].int!, args[2].int!, args.count > 3 ? (args[3].int ?? 255) : 255)))
        case "core/src/lib/RGBA.ts#hsvToRgb":
            return rgbaToJSON(hsvToRgb(args[0].dbl!, args[1].dbl!, args[2].dbl!))
        case "core/src/lib/RGBA.ts#parseColor":
            return rgbaToJSON(parseColor(args[0].str!))
        case "core/src/types.ts#getBaseAttributes":
            return .int(Int64(getBaseAttributes(UInt32(truncatingIfNeeded: args[0].int!))))
        case "core/src/utils.ts#createTextAttributes":
            let o = args.first?.obj ?? [:]
            return .int(Int64(createTextAttributes(
                bold: o["bold"]?.bool ?? false, italic: o["italic"]?.bool ?? false,
                underline: o["underline"]?.bool ?? false, dim: o["dim"]?.bool ?? false,
                blink: o["blink"]?.bool ?? false, inverse: o["inverse"]?.bool ?? false,
                reverse: o["reverse"]?.bool ?? false, hidden: o["hidden"]?.bool ?? false,
                strikethrough: o["strikethrough"]?.bool ?? false
            )))
        case "core/src/utils.ts#attributesWithLink":
            return .int(Int64(attributesWithLink(UInt32(truncatingIfNeeded: args[0].int!), linkId: UInt32(truncatingIfNeeded: args[1].int!))))
        case "core/src/utils.ts#getLinkId":
            return .int(Int64(getLinkId(UInt32(truncatingIfNeeded: args[0].int!))))
        case "core/src/lib/border.ts#isValidBorderStyle":
            return .bool(isValidBorderStyle(args.first?.str))
        case "core/src/lib/border.ts#parseBorderStyle":
            let fb = args.count > 1 ? (args[1].str.flatMap(BorderStyle.init(rawValue:)) ?? .single) : .single
            return .string(parseBorderStyle(args.first?.str, fallback: fb).rawValue)
        case "core/src/lib/border.ts#getBorderFromSides":
            let o = args[0].obj!
            switch getBorderFromSides(BorderSidesConfig(top: o["top"]?.bool ?? false, right: o["right"]?.bool ?? false, bottom: o["bottom"]?.bool ?? false, left: o["left"]?.bool ?? false)) {
            case .enabled(let b): return .bool(b)
            case .sides(let s): return .array(s.map { .string($0.rawValue) })
            }
        case "core/src/lib/border.ts#getBorderSides":
            let spec: BorderSpec = args[0].bool.map(BorderSpec.enabled) ?? .sides((args[0].arr ?? []).compactMap(\.str).compactMap(BorderSide.init(rawValue:)))
            let r = getBorderSides(spec)
            return .object(["top": .bool(r.top), "right": .bool(r.right), "bottom": .bool(r.bottom), "left": .bool(r.left)])
        case "core/src/lib/border.ts#borderCharsToArray":
            return .array(borderCharsToArray(BorderChars.forStyle(BorderStyle(rawValue: args[0].str!)!)).map { .int(Int64($0)) })
        case "core/src/ansi.ts#ANSI":
            switch args[0].str! {
            case "switchToAlternateScreen": return .string(ANSI.switchToAlternateScreen)
            case "switchToMainScreen": return .string(ANSI.switchToMainScreen)
            case "reset": return .string(ANSI.reset)
            case "clearScreen": return .string(ANSI.clearScreen)
            case "scrollDown": return .string(ANSI.scrollDown(args[1].int!))
            case "scrollIntoHistory": return .string(ANSI.scrollIntoHistory(args[1].int!))
            case "moveCursor": return .string(ANSI.moveCursor(row: args[1].int!, col: args[2].int!))
            case "moveCursorAndClear": return .string(ANSI.moveCursorAndClear(row: args[1].int!, col: args[2].int!))
            case "setRgbBackground": return .string(ANSI.setRgbBackground(r: args[1].int!, g: args[2].int!, b: args[3].int!))
            default: throw SnapshotError.unknownFunction(fn)
            }
        case "core/src/lib/render-geometry.ts#calculateRenderGeometry":
            let g = calculateRenderGeometry(screenMode: RenderGeometryScreenMode(rawValue: args[0].str!)!, terminalWidth: args[1].int!, terminalHeight: args[2].int!, footerHeight: args[3].int!)
            return .object(["effectiveFooterHeight": .int(Int64(g.effectiveFooterHeight)), "renderOffset": .int(Int64(g.renderOffset)), "renderWidth": .int(Int64(g.renderWidth)), "renderHeight": .int(Int64(g.renderHeight))])
        case "core/src/lib/objects-in-viewport.ts#getObjectsInViewport":
            let vo = args[0].obj!
            let vp = ViewportBounds(x: vo["x"]!.int!, y: vo["y"]!.int!, width: vo["width"]!.int!, height: vo["height"]!.int!)
            let items = args[1].arr!.map { v -> ViewportItem in
                let o = v.obj!
                return ViewportItem(id: o["id"]!.str!, screenX: o["screenX"]!.int!, screenY: o["screenY"]!.int!, width: o["width"]!.int!, height: o["height"]!.int!, zIndex: o["zIndex"]!.int!)
            }
            let dir = args.count > 2 ? (args[2].str.flatMap(ViewportDirection.init(rawValue:)) ?? .column) : .column
            let pad = args.count > 3 ? (args[3].int ?? 10) : 10
            let minT = args.count > 4 ? (args[4].int ?? 16) : 16
            return .array(getObjectsInViewport(viewport: vp, objects: items, direction: dir, padding: pad, minTriggerSize: minT).map { .string($0.id) })
        case "core/src/lib/validate-dir-name.ts#isValidDirectoryName":
            return .bool(isValidDirectoryName(args[0].str!))
        case "core/src/lib/paste.ts#decodePasteBytes":
            let bytes = args[0].arr!.compactMap(\.int).map { UInt8(clamping: $0) }
            return .string(decodePasteBytes(bytes))
        case "core/src/lib/paste.ts#stripAnsiSequences":
            return .string(stripAnsiSequences(args[0].str!))
        case "core/src/lib/terminal-capability-detection.ts#isCapabilityResponse":
            return .bool(isCapabilityResponse(args[0].str!))
        case "core/src/lib/terminal-capability-detection.ts#isExplicitWidthReport":
            return .bool(isExplicitWidthReport(args[0].str!))
        case "core/src/lib/terminal-capability-detection.ts#isPixelResolutionResponse":
            return .bool(isPixelResolutionResponse(args[0].str!))
        case "core/src/lib/terminal-capability-detection.ts#parsePixelResolution":
            return parsePixelResolution(args[0].str!).map {
                .object(["width": .int(Int64($0.width)), "height": .int(Int64($0.height))])
            } ?? .null
        case "core/src/lib/detect-links.ts#normalizeMarkdownLinkTarget":
            return .string(normalizeMarkdownLinkTarget(args[0].str!))
        case "core/src/lib/detect-links.ts#detectLinks":
            let chunks = args[0].arr!.map { item -> TextChunk in
                let o = item.obj!
                let link = o["link"]?.obj?["url"]?.str.map { TextChunkLink(url: $0) }
                return TextChunk(text: o["text"]!.str!, link: link)
            }
            let out = detectLinks(chunks, context: DetectLinksContext(content: args[1].str!, highlights: []))
            return .array(out.map { .object(["text": .string($0.text), "url": $0.link.map { .string($0.url) } ?? .null]) })
        case "core/src/lib/scroll-chain.ts#wheelDirection":
            let dir = args[0].str.flatMap(WheelDirection.init(rawValue:))
            return wheelDirection(direction: dir, shift: args.count > 1 ? (args[1].bool ?? false) : false).map { .string($0.rawValue) } ?? .null
        case "core/src/lib/scroll-acceleration.ts#MacOSScrollAccel.tick":
            var accel = MacOSScrollAccel()
            return .array(args[0].arr!.map { v in
                let val = (accel.tick(now: v.dbl ?? 0) * 1e6).rounded() / 1e6
                return val.rounded(.towardZero) == val ? .int(Int64(val)) : .double(val)
            })
        case "core/src/lib/renderable.validations.ts#isValidPercentage":
            return .bool(isValidPercentage(layoutVal(args[0])))
        case "core/src/lib/renderable.validations.ts#isMarginType":
            return .bool(isMarginType(layoutVal(args[0])))
        case "core/src/lib/renderable.validations.ts#isPaddingType":
            return .bool(isPaddingType(layoutVal(args[0])))
        case "core/src/lib/renderable.validations.ts#isPositionType":
            return .bool(isPositionType(layoutVal(args[0])))
        case "core/src/lib/renderable.validations.ts#isPositionTypeType":
            return .bool(isPositionTypeType(layoutVal(args[0])))
        case "core/src/lib/renderable.validations.ts#isOverflowType":
            return .bool(isOverflowType(layoutVal(args[0])))
        case "core/src/lib/renderable.validations.ts#isDimensionType":
            return .bool(isDimensionType(layoutVal(args[0])))
        case "core/src/lib/renderable.validations.ts#isFlexBasisType":
            return .bool(isFlexBasisType(layoutVal(args[0])))
        case "core/src/lib/renderable.validations.ts#isSizeType":
            return .bool(isSizeType(layoutVal(args[0])))
        case "core/src/lib/yoga.options.ts#parseAlign":
            return .int(Int64(parseAlign(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseAlignItems":
            return .int(Int64(parseAlignItems(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseAlignContent":
            return .int(Int64(parseAlignContent(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseBoxSizing":
            return .int(Int64(parseBoxSizing(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseDimension":
            return .int(Int64(parseDimension(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseDirection":
            return .int(Int64(parseDirection(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseDisplay":
            return .int(Int64(parseDisplay(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseEdge":
            return .int(Int64(parseEdge(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseFlexDirection":
            return .int(Int64(parseFlexDirection(args.first?.str).yogaRawValue))
        case "core/src/lib/yoga.options.ts#parseGutter":
            return .int(Int64(parseGutter(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseJustify":
            return .int(Int64(parseJustify(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseOverflow":
            return .int(Int64(parseOverflow(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parsePositionType":
            return .int(Int64(parsePositionType(args.first?.str).rawValue))
        case "core/src/lib/yoga.options.ts#parseWrap":
            return .int(Int64(parseWrap(args.first?.str).rawValue))
        case "keymap/src/services/keys.ts#normalizeBindingTokenName":
            return .string(try normalizeBindingTokenName(args[0].str!))
        case "keymap/src/services/keys.ts#normalizeKeyName":
            return .string(try normalizeKeyName(args[0].str!))
        case "keymap/src/services/keys.ts#normalizeKeyStroke":
            return strokeToJSON(try normalizeKeyStroke(strokeInput(args[0])))
        case "keymap/src/services/keys.ts#createKeyMatch":
            return .string(try createKeyMatch(strokeInput(args[0])))
        case "keymap/src/services/keys.ts#createTextKeyMatch":
            return .string(try createTextKeyMatch(args[0].str!))
        case "keymap/src/services/keys.ts#stringifyKeyStroke":
            return .string(try stringifyKeyStroke(.stroke(strokeInput(args[0]))))
        case "keymap/src/services/keys.ts#stringifyKeySequence":
            let inputs = args[0].arr!.map { KeyStringifyInput.stroke(strokeInput($0)) }
            let opts = args.count > 1 ? args[1].obj.map { StringifyOptions(preferDisplay: $0["preferDisplay"]?.bool, separator: $0["separator"]?.str) } : nil
            return .string(try stringifyKeySequence(inputs, options: opts))
        case "keymap/src/services/keys.ts#createKeySequencePart":
            let opts = args.count > 1 ? args[1].obj : nil
            let p = try createKeySequencePart(strokeInput(args[0]), display: opts?["display"]?.str, match: opts?["match"]?.str, tokenName: opts?["tokenName"]?.str)
            return .object(["stroke": strokeToJSON(p.stroke), "display": .string(p.display), "match": .string(p.match), "tokenName": p.tokenName.map { .string($0) } ?? .null])
        case "keymap/src/services/primitives/command-normalization.ts#normalizeCommandName":
            return .string(try normalizeCommandName(args[0].str!))
        case "keymap/src/services/compiler.ts#createCompilerService":
            let env = CompilerEnvironment<String, BasicKeymapEvent>(bindingParsers: [defaultBindingParser])
            let notify = KeymapNotifier()
            let compiler = createCompilerService(environment: env, notify: notify, conditions: createConditionService(readData: { [:] }, notify: notify))
            let parts = try compiler.parseKeySequence(.string(args[0].str!))
            return .array(parts.map { p in
                .object([
                    "display": .string(p.display),
                    "match": .string(p.match),
                    "name": .string(p.stroke.name),
                    "ctrl": .bool(p.stroke.ctrl),
                    "shift": .bool(p.stroke.shift),
                    "meta": .bool(p.stroke.meta),
                    "super": .bool(p.stroke.`super`),
                ])
            })
        case "keymap/src/services/values.ts#sameCompiledData":
            var moves: [CompiledDataMove] = []
            return .bool(sameCompiledData(toKeymapValue(args[0]), toKeymapValue(args[1]), moves: &moves))
        case "core/src/renderables/text-table-width.ts#allocateProportionalColumnWidths":
            return .array(allocateProportionalColumnWidths(args[0].arr!.compactMap(\.int), targetWidth: args[1].int!, minWidth: args[2].int!).map { .int(Int64($0)) })
        case "core/src/syntax-style.ts#convertThemeToStyles":
            let theme: [ThemeTokenStyle] = args[0].arr!.compactMap { item -> ThemeTokenStyle? in
                guard let o = item.obj, let scopes = o["scope"]?.arr?.compactMap(\.str), let st = o["style"]?.obj else { return nil }
                return ThemeTokenStyle(
                    scope: scopes,
                    style: ThemeTokenStyle.Style(
                        foreground: st["foreground"]?.str.map { Color.string($0) },
                        background: st["background"]?.str.map { Color.string($0) },
                        bold: st["bold"]?.bool,
                        italic: st["italic"]?.bool,
                        underline: st["underline"]?.bool,
                        dim: st["dim"]?.bool,
                        strikethrough: st["strikethrough"]?.bool
                    )
                )
            }
            let converted = convertThemeToStyles(theme)
            var out: [String: SnapshotJSON] = [:]
            for (k, v) in converted {
                out[k] = .object([
                    "fg": v.fg.map { .string(rgbToHex($0)) } ?? .null,
                    "bg": v.bg.map { .string(rgbToHex($0)) } ?? .null,
                    "bold": v.bold.map { .bool($0) } ?? .null,
                    "italic": v.italic.map { .bool($0) } ?? .null,
                    "underline": v.underline.map { .bool($0) } ?? .null,
                    "dim": v.dim.map { .bool($0) } ?? .null,
                    "strikethrough": v.strikethrough.map { .bool($0) } ?? .null,
                ])
            }
            return .object(out)
        case "qrcode/src/lib/qrcode.ts#QrSegment.isNumeric":
            return .bool(QrSegment.isNumeric(args[0].str!))
        case "qrcode/src/lib/qrcode.ts#QrSegment.isAlphanumeric":
            return .bool(QrSegment.isAlphanumeric(args[0].str!))
        case "qrcode/src/lib/qrcode.ts#encodeTextBytes":
            return .array(try encodeTextBytes(args[0].str!, encoding: ByteEncoding(rawValue: args[1].str!)!).map { .int(Int64($0)) })
        case "qrcode/src/lib/qrcode.ts#QRCode.encodeText":
            let q = try QRCode.encodeText(args[0].str!, ecl: ErrorCorrectionLevel(rawValue: args[1].str!)!)
            return .object([
                "version": .int(Int64(q.version)),
                "size": .int(Int64(q.size)),
                "mask": .int(Int64(q.mask)),
                "matrix": .array(q.toMatrix().map { row in .array(row.map { .bool($0) }) }),
            ])
        case "qrcode/src/lib/qrcode.render.ts#matrixToTerminal":
            let q = try QRCode.encodeText(args[0].str!, ecl: ErrorCorrectionLevel(rawValue: args[1].str!)!)
            let invert = args.count > 3 ? (args[3].bool ?? false) : false
            return .string(try q.toTerminalString(options: TerminalRenderOptions(border: args[2].int!, ansi: false, invert: invert)))
        case "core/src/lib/keybinding.internal.ts#getKeyBindingKey":
            return .string(getKeyBindingKey(keyBindingFromJSON(args[0])))
        case "core/src/lib/keybinding.internal.ts#mergeKeyBindings":
            let merged = mergeKeyBindings(args[0].arr!.map(keyBindingFromJSON), args[1].arr!.map(keyBindingFromJSON))
            return .array(merged.map { b in
                .object([
                    "name": .string(b.name),
                    "ctrl": .bool(b.ctrl),
                    "shift": .bool(b.shift),
                    "meta": .bool(b.meta),
                    "super": .bool(b.`super`),
                    "action": .string(b.action),
                ])
            })
        case "core/src/lib/keybinding.internal.ts#keyBindingToString":
            return .string(keyBindingToString(keyBindingFromJSON(args[0])))
        case "core/src/lib/tree-sitter/resolve-ft.ts#extToFiletype":
            return extToFiletype(args[0].str!).map { .string($0) } ?? .null
        case "core/src/lib/tree-sitter/resolve-ft.ts#pathToFiletype":
            return pathToFiletype(args[0].str!).map { .string($0) } ?? .null
        case "core/src/lib/tree-sitter/resolve-ft.ts#infoStringToFiletype":
            return infoStringToFiletype(args[0].str!).map { .string($0) } ?? .null
        case "core/src/renderer-theme-mode.ts#RendererThemeMode.handleSequence":
            let host = NoOpThemeModeHost()
            let tm = RendererThemeMode(host: host, clock: ManualClock())
            let res = tm.handleSequence(args[0].str!)
            return .object([
                "handled": .bool(res.handled),
                "changedMode": res.changedMode.map { .string($0.rawValue) } ?? .null,
                "themeMode": tm.themeMode.map { .string($0.rawValue) } ?? .null,
            ])
        case "core/src/lib/terminal-palette.ts#applyPaletteReplies":
            var colors = emptyTerminalColors(size: args[0].int!)
            let matched = applyPaletteReplies(&colors, sequence: args[1].str!)
            return .object([
                "matched": .bool(matched),
                "defaultForeground": colors.defaultForeground.map { .string($0) } ?? .null,
                "defaultBackground": colors.defaultBackground.map { .string($0) } ?? .null,
                "slot1": (colors.palette.count > 1 ? colors.palette[1] : nil).map { .string($0) } ?? .null,
            ])
        case "core/src/lib/terminal-palette.ts#buildTerminalPaletteSignature":
            if let o = args[0].obj {
                var colors = emptyTerminalColors(size: 16)
                colors.defaultForeground = o["defaultForeground"]?.str
                colors.defaultBackground = o["defaultBackground"]?.str
                if let pal = o["palette"]?.arr {
                    for (idx, item) in pal.enumerated() where idx < colors.palette.count {
                        colors.palette[idx] = item.str
                    }
                }
                return .string(buildTerminalPaletteSignature(colors))
            }
            return .string(buildTerminalPaletteSignature(nil))
        case "core/src/animation/Timeline.ts#createTimeline":
            let ease = EasingName(rawValue: args[0].str!)!
            let target = AnimationState(["x": 0.0])
            let tl = createTimeline(options: TimelineOptions(duration: 1000.0, autoplay: true))
            tl.add(target, options: AnimationOptions(duration: 1000.0, ease: ease, properties: ["x": 100.0]), startTime: 0.0)
            var samples: [SnapshotJSON] = []
            var prev = 0.0
            for item in args[1].arr! {
                let t = item.dbl ?? 0.0
                tl.update(deltaTime: t - prev)
                prev = t
                let raw = target["x"] ?? 0.0
                let rounded = (raw * 1e4).rounded() / 1e4
                samples.append(rounded.rounded(.towardZero) == rounded ? .int(Int64(rounded)) : .double(rounded))
            }
            return .array(samples)
        case "qrcode/src/lib/qrcode.encoding.ts#shiftJisCodeForCharacter":
            return shiftJisCodeForCharacter(args[0].str!).map { .int(Int64($0)) } ?? .null
        case "qrcode/src/lib/qrcode.encoding.ts#isKanjiModeShiftJisValue":
            return .bool(isKanjiModeShiftJisValue(args[0].int!))
        case "qrcode/src/lib/qrcode.encoding.ts#encodingForKnownEci":
            return encodingForKnownEci(args[0].int!).map { .string($0.rawValue) } ?? .null
        case "qrcode/src/lib/qrcode.ts#QrSegment.isKanji":
            return .bool(QrSegment.isKanji(args[0].str!))
        case "core/src/audio-stream/icy/metadata.ts#parseIcyMetadata":
            if let dict = parseIcyMetadata(Array(args[0].str!.utf8), encoding: .utf8) {
                return .object(dict.mapValues { .string($0) })
            }
            return .null
        case "keymap/src/html.ts#normalizeHtmlKeyName":
            return .string(normalizeHtmlKeyName(args[0].str!))
        default:
            throw SnapshotError.unknownFunction(fn)
        }
    }

    @Test("All golden OpenTUI upstream oracle snapshots pass identically in Swift")
    func verifyAllGoldenSnapshots() throws {
        let snapshots = try OpenTUISnapshotLoader.load(relativeTo: #filePath)
        #expect(snapshots.cases.count == snapshots.vectorCount)
        #expect(!snapshots.cases.isEmpty)

        for tc in snapshots.cases {
            if tc.compare == "expect_error" {
                #expect(!tc.expectedOk)
                #expect(throws: (any Error).self, "Expected error for [\(tc.fn)] \(tc.name)") {
                    _ = try Self.evaluate(tc.fn, tc.args)
                }
                continue
            }
            let actual = try Self.evaluate(tc.fn, tc.args)
            #expect(actual == tc.expectedValue, "Mismatch for [\(tc.fn)] \(tc.name)")
        }
    }
}
