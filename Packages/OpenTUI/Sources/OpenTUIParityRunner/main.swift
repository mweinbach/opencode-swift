#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#endif

import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables

enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var str: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var int: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    var dbl: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var arr: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var obj: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    var bytes: [UInt8]? {
        guard case .array(let a) = self else { return nil }
        return a.compactMap(\.int).map { UInt8(clamping: $0) }
    }

    var layoutOptionValue: LayoutOptionValue {
        switch self {
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string("__undefined__"): return .undefined
        case .string(let s): return .string(s)
        case .null: return .null
        default: return .null
        }
    }
}

struct ParityRequest: Decodable {
    let id: String
    let fn: String
    let args: [JSONValue]
}

struct ParityResponse: Encodable {
    let id: String
    let ok: Bool
    let value: JSONValue?
    let error: String?
}

enum DispatchError: Error, CustomStringConvertible {
    case unknownFunction(String)
    case invalidArguments(String)

    var description: String {
        switch self {
        case .unknownFunction(let f): "Unknown function: \(f)"
        case .invalidArguments(let m): "Invalid arguments: \(m)"
        }
    }
}

func rgbaToJSON(_ rgba: RGBA) -> JSONValue {
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

func strokeInputFromJSON(_ val: JSONValue) throws -> KeyStrokeInput {
    guard let o = val.obj, let name = o["name"]?.str else {
        throw DispatchError.invalidArguments("Expected KeyStrokeInput object")
    }
    return KeyStrokeInput(
        name: name,
        ctrl: o["ctrl"]?.bool,
        shift: o["shift"]?.bool,
        meta: o["meta"]?.bool,
        super: o["super"]?.bool,
        hyper: o["hyper"]?.bool
    )
}

func normalizedStrokeToJSON(_ s: NormalizedKeyStroke) -> JSONValue {
    var out: [String: JSONValue] = [
        "name": .string(s.name),
        "ctrl": .bool(s.ctrl),
        "shift": .bool(s.shift),
        "meta": .bool(s.meta),
        "super": .bool(s.`super`),
    ]
    out["hyper"] = s.hyper.map { .bool($0) } ?? .null
    return .object(out)
}

func jsonToKeymapValue(_ v: JSONValue) -> KeymapValue {
    switch v {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(Int(i))
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .array(let a): return .array(a.map(jsonToKeymapValue))
    case .object(let o): return .object(o.mapValues(jsonToKeymapValue))
    }
}

private final class NoOpThemeModeHost: RendererThemeModeHost {
    func queryThemeColors() -> Bool { false }
}

func keyBindingFromJSON(_ v: JSONValue) -> KeyBinding<String> {
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

func makeDefaultCompiler() -> DefaultCompilerService<String, BasicKeymapEvent> {
    let env = CompilerEnvironment<String, BasicKeymapEvent>(bindingParsers: [defaultBindingParser])
    let notify = KeymapNotifier()
    let conditions = createConditionService(readData: { [:] }, notify: notify)
    return createCompilerService(environment: env, notify: notify, conditions: conditions)
}

func dispatch(_ fn: String, _ args: [JSONValue]) throws -> JSONValue {
    switch fn {
    // MARK: RGBA.ts
    case "core/src/lib/RGBA.ts#normalizeIndexedColorIndex":
        guard let i = args.first?.int else { throw DispatchError.invalidArguments("Expected int") }
        return .int(Int64(try normalizeIndexedColorIndex(i)))

    case "core/src/lib/RGBA.ts#ansi256IndexToRgb":
        guard let i = args.first?.int else { throw DispatchError.invalidArguments("Expected int") }
        let rgb = try ansi256IndexToRgb(i)
        return .array([.int(Int64(rgb.r)), .int(Int64(rgb.g)), .int(Int64(rgb.b))])

    case "core/src/lib/RGBA.ts#RGBA.fromValues":
        let r = args[0].dbl ?? 0
        let g = args[1].dbl ?? 0
        let b = args[2].dbl ?? 0
        let a = args.count > 3 ? (args[3].dbl ?? 1.0) : 1.0
        return rgbaToJSON(RGBA.fromValues(r, g, b, a))

    case "core/src/lib/RGBA.ts#RGBA.fromInts":
        let r = args[0].dbl ?? 0
        let g = args[1].dbl ?? 0
        let b = args[2].dbl ?? 0
        let a = args.count > 3 ? (args[3].dbl ?? 255.0) : 255.0
        return rgbaToJSON(RGBA.fromInts(r, g, b, a))

    case "core/src/lib/RGBA.ts#RGBA.fromIndex":
        guard let idx = args.first?.int else { throw DispatchError.invalidArguments("Expected index") }
        let snap = args.count > 1 ? args[1].str : nil
        return rgbaToJSON(try RGBA.fromIndex(idx, snapshot: snap))

    case "core/src/lib/RGBA.ts#RGBA.defaultForeground":
        return rgbaToJSON(RGBA.defaultForeground(snapshot: args.first?.str))

    case "core/src/lib/RGBA.ts#RGBA.defaultBackground":
        return rgbaToJSON(RGBA.defaultBackground(snapshot: args.first?.str))

    case "core/src/lib/RGBA.ts#hexToRgb":
        guard let hex = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return rgbaToJSON(hexToRgb(hex))

    case "core/src/lib/RGBA.ts#rgbToHex":
        let r = args[0].int ?? 0
        let g = args[1].int ?? 0
        let b = args[2].int ?? 0
        let a = args.count > 3 ? (args[3].int ?? 255) : 255
        return .string(rgbToHex(RGBA.fromInts(r, g, b, a)))

    case "core/src/lib/RGBA.ts#hsvToRgb":
        guard let h = args[0].dbl, let s = args[1].dbl, let v = args[2].dbl else {
            throw DispatchError.invalidArguments("Expected h, s, v")
        }
        return rgbaToJSON(hsvToRgb(h, s, v))

    case "core/src/lib/RGBA.ts#parseColor":
        guard let str = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return rgbaToJSON(parseColor(str))

    // MARK: TextAttributes / utils.ts
    case "core/src/types.ts#getBaseAttributes":
        guard let attr = args.first?.int else { throw DispatchError.invalidArguments("Expected uint32") }
        return .int(Int64(getBaseAttributes(UInt32(truncatingIfNeeded: attr))))

    case "core/src/utils.ts#createTextAttributes":
        let o = args.first?.obj ?? [:]
        let result = createTextAttributes(
            bold: o["bold"]?.bool ?? false,
            italic: o["italic"]?.bool ?? false,
            underline: o["underline"]?.bool ?? false,
            dim: o["dim"]?.bool ?? false,
            blink: o["blink"]?.bool ?? false,
            inverse: o["inverse"]?.bool ?? false,
            reverse: o["reverse"]?.bool ?? false,
            hidden: o["hidden"]?.bool ?? false,
            strikethrough: o["strikethrough"]?.bool ?? false
        )
        return .int(Int64(result))

    case "core/src/utils.ts#attributesWithLink":
        guard let base = args[0].int, let linkId = args[1].int else {
            throw DispatchError.invalidArguments("Expected base, linkId")
        }
        return .int(Int64(attributesWithLink(UInt32(truncatingIfNeeded: base), linkId: UInt32(truncatingIfNeeded: linkId))))

    case "core/src/utils.ts#getLinkId":
        guard let attr = args.first?.int else { throw DispatchError.invalidArguments("Expected attr") }
        return .int(Int64(getLinkId(UInt32(truncatingIfNeeded: attr))))

    // MARK: border.ts
    case "core/src/lib/border.ts#isValidBorderStyle":
        return .bool(isValidBorderStyle(args.first?.str))

    case "core/src/lib/border.ts#parseBorderStyle":
        let fb = args.count > 1 ? (args[1].str.flatMap(BorderStyle.init(rawValue:)) ?? .single) : .single
        return .string(parseBorderStyle(args.first?.str, fallback: fb).rawValue)

    case "core/src/lib/border.ts#getBorderFromSides":
        guard let o = args.first?.obj else { throw DispatchError.invalidArguments("Expected sides object") }
        let spec = getBorderFromSides(
            BorderSidesConfig(
                top: o["top"]?.bool ?? false,
                right: o["right"]?.bool ?? false,
                bottom: o["bottom"]?.bool ?? false,
                left: o["left"]?.bool ?? false
            )
        )
        switch spec {
        case .enabled(let b): return .bool(b)
        case .sides(let arr): return .array(arr.map { .string($0.rawValue) })
        }

    case "core/src/lib/border.ts#getBorderSides":
        let spec: BorderSpec
        if let b = args.first?.bool {
            spec = .enabled(b)
        } else if let arr = args.first?.arr {
            spec = .sides(arr.compactMap(\.str).compactMap(BorderSide.init(rawValue:)))
        } else {
            spec = .enabled(false)
        }
        let res = getBorderSides(spec)
        return .object([
            "top": .bool(res.top),
            "right": .bool(res.right),
            "bottom": .bool(res.bottom),
            "left": .bool(res.left),
        ])

    case "core/src/lib/border.ts#borderCharsToArray":
        guard let styleName = args.first?.str, let style = BorderStyle(rawValue: styleName) else {
            throw DispatchError.invalidArguments("Expected BorderStyle name")
        }
        return .array(borderCharsToArray(BorderChars.forStyle(style)).map { .int(Int64($0)) })

    // MARK: ansi.ts
    case "core/src/ansi.ts#ANSI":
        guard let op = args.first?.str else { throw DispatchError.invalidArguments("Expected ANSI op") }
        switch op {
        case "switchToAlternateScreen": return .string(ANSI.switchToAlternateScreen)
        case "switchToMainScreen": return .string(ANSI.switchToMainScreen)
        case "reset": return .string(ANSI.reset)
        case "clearScreen": return .string(ANSI.clearScreen)
        case "scrollDown": return .string(ANSI.scrollDown(args[1].int ?? 0))
        case "scrollIntoHistory": return .string(ANSI.scrollIntoHistory(args[1].int ?? 0))
        case "moveCursor": return .string(ANSI.moveCursor(row: args[1].int ?? 1, col: args[2].int ?? 1))
        case "moveCursorAndClear": return .string(ANSI.moveCursorAndClear(row: args[1].int ?? 1, col: args[2].int ?? 1))
        case "setRgbBackground": return .string(ANSI.setRgbBackground(r: args[1].int ?? 0, g: args[2].int ?? 0, b: args[3].int ?? 0))
        default: throw DispatchError.invalidArguments("Unknown ANSI op: \(op)")
        }

    // MARK: render-geometry.ts
    case "core/src/lib/render-geometry.ts#calculateRenderGeometry":
        guard let modeStr = args[0].str,
              let mode = RenderGeometryScreenMode(rawValue: modeStr),
              let w = args[1].int,
              let h = args[2].int,
              let f = args[3].int else {
            throw DispatchError.invalidArguments("Expected mode, width, height, footerHeight")
        }
        let g = calculateRenderGeometry(screenMode: mode, terminalWidth: w, terminalHeight: h, footerHeight: f)
        return .object([
            "effectiveFooterHeight": .int(Int64(g.effectiveFooterHeight)),
            "renderOffset": .int(Int64(g.renderOffset)),
            "renderWidth": .int(Int64(g.renderWidth)),
            "renderHeight": .int(Int64(g.renderHeight)),
        ])

    // MARK: objects-in-viewport.ts
    case "core/src/lib/objects-in-viewport.ts#getObjectsInViewport":
        guard let vpObj = args[0].obj, let itemsArr = args[1].arr else {
            throw DispatchError.invalidArguments("Expected viewport, objects")
        }
        let vp = ViewportBounds(
            x: vpObj["x"]?.int ?? 0,
            y: vpObj["y"]?.int ?? 0,
            width: vpObj["width"]?.int ?? 0,
            height: vpObj["height"]?.int ?? 0
        )
        let items: [ViewportItem] = itemsArr.compactMap { v in
            guard let o = v.obj, let id = o["id"]?.str else { return nil }
            return ViewportItem(
                id: id,
                screenX: o["screenX"]?.int ?? 0,
                screenY: o["screenY"]?.int ?? 0,
                width: o["width"]?.int ?? 0,
                height: o["height"]?.int ?? 0,
                zIndex: o["zIndex"]?.int ?? 0
            )
        }
        let dir = args.count > 2 ? (args[2].str.flatMap(ViewportDirection.init(rawValue:)) ?? .column) : .column
        let pad = args.count > 3 ? (args[3].int ?? 10) : 10
        let minTrigger = args.count > 4 ? (args[4].int ?? 16) : 16
        let visible = getObjectsInViewport(viewport: vp, objects: items, direction: dir, padding: pad, minTriggerSize: minTrigger)
        return .array(visible.map { .string($0.id) })

    // MARK: validate-dir-name.ts
    case "core/src/lib/validate-dir-name.ts#isValidDirectoryName":
        guard let name = args.first?.str else { return .bool(false) }
        return .bool(isValidDirectoryName(name))

    // MARK: paste.ts
    case "core/src/lib/paste.ts#decodePasteBytes":
        guard let bytes = args.first?.bytes else { throw DispatchError.invalidArguments("Expected byte array") }
        return .string(decodePasteBytes(bytes))

    case "core/src/lib/paste.ts#stripAnsiSequences":
        guard let text = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .string(stripAnsiSequences(text))

    // MARK: terminal-capability-detection.ts
    case "core/src/lib/terminal-capability-detection.ts#isCapabilityResponse":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .bool(isCapabilityResponse(s))

    case "core/src/lib/terminal-capability-detection.ts#isExplicitWidthReport":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .bool(isExplicitWidthReport(s))

    case "core/src/lib/terminal-capability-detection.ts#isPixelResolutionResponse":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .bool(isPixelResolutionResponse(s))

    case "core/src/lib/terminal-capability-detection.ts#parsePixelResolution":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        if let res = parsePixelResolution(s) {
            return .object(["width": .int(Int64(res.width)), "height": .int(Int64(res.height))])
        }
        return .null

    // MARK: detect-links.ts
    case "core/src/lib/detect-links.ts#normalizeMarkdownLinkTarget":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .string(normalizeMarkdownLinkTarget(s))

    case "core/src/lib/detect-links.ts#detectLinks":
        guard let chunksArr = args[0].arr, let content = args[1].str else {
            throw DispatchError.invalidArguments("Expected chunks, content")
        }
        let chunks: [TextChunk] = chunksArr.compactMap { item in
            guard let o = item.obj, let text = o["text"]?.str else { return nil }
            let link = o["link"]?.obj?["url"]?.str.map { TextChunkLink(url: $0) }
            return TextChunk(text: text, link: link)
        }
        let result = detectLinks(chunks, context: DetectLinksContext(content: content, highlights: []))
        return .array(result.map { c in
            .object([
                "text": .string(c.text),
                "url": c.link.map { .string($0.url) } ?? .null,
            ])
        })

    // MARK: scroll-chain.ts & scroll-acceleration.ts
    case "core/src/lib/scroll-chain.ts#wheelDirection":
        let dir = args[0].str.flatMap(WheelDirection.init(rawValue:))
        let shift = args.count > 1 ? (args[1].bool ?? false) : false
        return wheelDirection(direction: dir, shift: shift).map { .string($0.rawValue) } ?? .null

    case "core/src/lib/scroll-acceleration.ts#MacOSScrollAccel.tick":
        guard let arr = args.first?.arr else { throw DispatchError.invalidArguments("Expected timestamp array") }
        var accel = MacOSScrollAccel()
        let out: [JSONValue] = arr.map { v in
            let ts = v.dbl ?? 0
            let val = (accel.tick(now: ts) * 1e6).rounded() / 1e6
            if val.rounded(.towardZero) == val {
                return .int(Int64(val))
            }
            return .double(val)
        }
        return .array(out)

    // MARK: renderable.validations.ts
    case "core/src/lib/renderable.validations.ts#isValidPercentage":
        return .bool(isValidPercentage(args[0].layoutOptionValue))
    case "core/src/lib/renderable.validations.ts#isMarginType":
        return .bool(isMarginType(args[0].layoutOptionValue))
    case "core/src/lib/renderable.validations.ts#isPaddingType":
        return .bool(isPaddingType(args[0].layoutOptionValue))
    case "core/src/lib/renderable.validations.ts#isPositionType":
        return .bool(isPositionType(args[0].layoutOptionValue))
    case "core/src/lib/renderable.validations.ts#isPositionTypeType":
        return .bool(isPositionTypeType(args[0].layoutOptionValue))
    case "core/src/lib/renderable.validations.ts#isOverflowType":
        return .bool(isOverflowType(args[0].layoutOptionValue))
    case "core/src/lib/renderable.validations.ts#isDimensionType":
        return .bool(isDimensionType(args[0].layoutOptionValue))
    case "core/src/lib/renderable.validations.ts#isFlexBasisType":
        return .bool(isFlexBasisType(args[0].layoutOptionValue))
    case "core/src/lib/renderable.validations.ts#isSizeType":
        return .bool(isSizeType(args[0].layoutOptionValue))

    // MARK: yoga.options.ts
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

    // MARK: keymap/src/services/keys.ts
    case "keymap/src/services/keys.ts#normalizeBindingTokenName":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .string(try normalizeBindingTokenName(s))

    case "keymap/src/services/keys.ts#normalizeKeyName":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .string(try normalizeKeyName(s))

    case "keymap/src/services/keys.ts#normalizeKeyStroke":
        return normalizedStrokeToJSON(try normalizeKeyStroke(try strokeInputFromJSON(args[0])))

    case "keymap/src/services/keys.ts#createKeyMatch":
        return .string(try createKeyMatch(try strokeInputFromJSON(args[0])))

    case "keymap/src/services/keys.ts#createTextKeyMatch":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .string(try createTextKeyMatch(s))

    case "keymap/src/services/keys.ts#stringifyKeyStroke":
        return .string(try stringifyKeyStroke(.stroke(try strokeInputFromJSON(args[0]))))

    case "keymap/src/services/keys.ts#stringifyKeySequence":
        guard let arr = args.first?.arr else { throw DispatchError.invalidArguments("Expected stroke array") }
        let inputs = try arr.map { KeyStringifyInput.stroke(try strokeInputFromJSON($0)) }
        let opts: StringifyOptions? = args.count > 1 ? args[1].obj.map {
            StringifyOptions(preferDisplay: $0["preferDisplay"]?.bool, separator: $0["separator"]?.str)
        } : nil
        return .string(try stringifyKeySequence(inputs, options: opts))

    case "keymap/src/services/keys.ts#createKeySequencePart":
        let stroke = try strokeInputFromJSON(args[0])
        let opts = args.count > 1 ? args[1].obj : nil
        let part = try createKeySequencePart(
            stroke,
            display: opts?["display"]?.str,
            match: opts?["match"]?.str,
            tokenName: opts?["tokenName"]?.str
        )
        return .object([
            "stroke": normalizedStrokeToJSON(part.stroke),
            "display": .string(part.display),
            "match": .string(part.match),
            "tokenName": part.tokenName.map { .string($0) } ?? .null,
        ])

    // MARK: keymap compiler & command normalization
    case "keymap/src/services/primitives/command-normalization.ts#normalizeCommandName":
        guard let s = args.first?.str else { throw DispatchError.invalidArguments("Expected string") }
        return .string(try normalizeCommandName(s))

    case "keymap/src/services/compiler.ts#createCompilerService":
        guard let binding = args.first?.str else { throw DispatchError.invalidArguments("Expected binding string") }
        let compiler = makeDefaultCompiler()
        let parts = try compiler.parseKeySequence(.string(binding))
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
        return .bool(sameCompiledData(jsonToKeymapValue(args[0]), jsonToKeymapValue(args[1]), moves: &moves))

    case "core/src/renderables/text-table-width.ts#allocateProportionalColumnWidths":
        guard let arr = args[0].arr, let target = args[1].int, let minW = args[2].int else {
            throw DispatchError.invalidArguments("Expected widths, targetWidth, minWidth")
        }
        let widths = arr.compactMap(\.int)
        return .array(allocateProportionalColumnWidths(widths, targetWidth: target, minWidth: minW).map { .int(Int64($0)) })

    case "core/src/syntax-style.ts#convertThemeToStyles":
        guard let arr = args.first?.arr else { throw DispatchError.invalidArguments("Expected theme array") }
        let theme: [ThemeTokenStyle] = arr.compactMap { item -> ThemeTokenStyle? in
            guard let o = item.obj, let scopes = o["scope"]?.arr?.compactMap(\.str), let st = o["style"]?.obj else {
                return nil
            }
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
        var out: [String: JSONValue] = [:]
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
        return .bool(QrSegment.isNumeric(args[0].str ?? ""))

    case "qrcode/src/lib/qrcode.ts#QrSegment.isAlphanumeric":
        return .bool(QrSegment.isAlphanumeric(args[0].str ?? ""))

    case "qrcode/src/lib/qrcode.ts#encodeTextBytes":
        guard let text = args[0].str, let encStr = args[1].str, let enc = ByteEncoding(rawValue: encStr) else {
            throw DispatchError.invalidArguments("Expected text, encoding")
        }
        return .array(try encodeTextBytes(text, encoding: enc).map { .int(Int64($0)) })

    case "qrcode/src/lib/qrcode.ts#QRCode.encodeText":
        guard let text = args[0].str, let eclStr = args[1].str, let ecl = ErrorCorrectionLevel(rawValue: eclStr) else {
            throw DispatchError.invalidArguments("Expected text, ecl")
        }
        let q = try QRCode.encodeText(text, ecl: ecl)
        return .object([
            "version": .int(Int64(q.version)),
            "size": .int(Int64(q.size)),
            "mask": .int(Int64(q.mask)),
            "matrix": .array(q.toMatrix().map { row in .array(row.map { .bool($0) }) }),
        ])

    case "qrcode/src/lib/qrcode.render.ts#matrixToTerminal":
        guard let text = args[0].str,
              let eclStr = args[1].str,
              let ecl = ErrorCorrectionLevel(rawValue: eclStr),
              let border = args[2].int else {
            throw DispatchError.invalidArguments("Expected text, ecl, border, invert")
        }
        let invert = args.count > 3 ? (args[3].bool ?? false) : false
        let q = try QRCode.encodeText(text, ecl: ecl)
        return .string(try q.toTerminalString(options: TerminalRenderOptions(border: border, ansi: false, invert: invert)))

    // MARK: Phase 3 Core Pure Functions
    case "core/src/lib/keybinding.internal.ts#getKeyBindingKey":
        return .string(getKeyBindingKey(keyBindingFromJSON(args[0])))

    case "core/src/lib/keybinding.internal.ts#mergeKeyBindings":
        let defaults = (args[0].arr ?? []).map(keyBindingFromJSON)
        let custom = (args[1].arr ?? []).map(keyBindingFromJSON)
        let merged = mergeKeyBindings(defaults, custom)
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
        return extToFiletype(args[0].str ?? "").map { .string($0) } ?? .null

    case "core/src/lib/tree-sitter/resolve-ft.ts#pathToFiletype":
        return pathToFiletype(args[0].str ?? "").map { .string($0) } ?? .null

    case "core/src/lib/tree-sitter/resolve-ft.ts#infoStringToFiletype":
        return infoStringToFiletype(args[0].str ?? "").map { .string($0) } ?? .null

    case "core/src/renderer-theme-mode.ts#RendererThemeMode.handleSequence":
        let host = NoOpThemeModeHost()
        let tm = RendererThemeMode(host: host, clock: ManualClock())
        let res = tm.handleSequence(args[0].str ?? "")
        return .object([
            "handled": .bool(res.handled),
            "changedMode": res.changedMode.map { .string($0.rawValue) } ?? .null,
            "themeMode": tm.themeMode.map { .string($0.rawValue) } ?? .null,
        ])

    case "core/src/lib/terminal-palette.ts#applyPaletteReplies":
        var colors = emptyTerminalColors(size: args[0].int ?? 16)
        let matched = applyPaletteReplies(&colors, sequence: args[1].str ?? "")
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
        guard let easeName = args[0].str, let ease = EasingName(rawValue: easeName), let times = args[1].arr else {
            throw DispatchError.invalidArguments("Expected ease, times")
        }
        let target = AnimationState(["x": 0.0])
        let tl = createTimeline(options: TimelineOptions(duration: 1000.0, autoplay: true))
        tl.add(target, options: AnimationOptions(duration: 1000.0, ease: ease, properties: ["x": 100.0]), startTime: 0.0)
        var samples: [JSONValue] = []
        var prev = 0.0
        for item in times {
            let t = item.dbl ?? 0.0
            tl.update(deltaTime: t - prev)
            prev = t
            let raw = target["x"] ?? 0.0
            let rounded = (raw * 1e4).rounded() / 1e4
            if rounded.rounded(.towardZero) == rounded {
                samples.append(.int(Int64(rounded)))
            } else {
                samples.append(.double(rounded))
            }
        }
        return .array(samples)

    // MARK: Phase 4 Complete Parity Functions
    case "qrcode/src/lib/qrcode.encoding.ts#shiftJisCodeForCharacter":
        return shiftJisCodeForCharacter(args[0].str ?? "").map { .int(Int64($0)) } ?? .null

    case "qrcode/src/lib/qrcode.encoding.ts#isKanjiModeShiftJisValue":
        return .bool(isKanjiModeShiftJisValue(args[0].int ?? 0))

    case "qrcode/src/lib/qrcode.encoding.ts#encodingForKnownEci":
        return encodingForKnownEci(args[0].int ?? 0).map { .string($0.rawValue) } ?? .null

    case "qrcode/src/lib/qrcode.ts#QrSegment.isKanji":
        return .bool(QrSegment.isKanji(args[0].str ?? ""))

    case "core/src/audio-stream/icy/metadata.ts#parseIcyMetadata":
        let bytes = Array((args[0].str ?? "").utf8)
        if let dict = parseIcyMetadata(bytes, encoding: .utf8) {
            return .object(dict.mapValues { .string($0) })
        }
        return .null

    case "keymap/src/html.ts#normalizeHtmlKeyName":
        return .string(normalizeHtmlKeyName(args[0].str ?? ""))

    default:
        throw DispatchError.unknownFunction(fn)
    }
}

@main
struct OpenTUIParityRunnerMain {
    static func main() {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        while let line = readLine(strippingNewline: true) {
            if line.allSatisfy(\.isWhitespace) { continue }
            let data = Data(line.utf8)
            do {
                let req = try decoder.decode(ParityRequest.self, from: data)
                do {
                    let result = try dispatch(req.fn, req.args)
                    let resp = ParityResponse(id: req.id, ok: true, value: result, error: nil)
                    let out = try encoder.encode(resp)
                    print(String(decoding: out, as: UTF8.self))
                } catch {
                    let resp = ParityResponse(id: req.id, ok: false, value: nil, error: String(describing: error))
                    let out = try encoder.encode(resp)
                    print(String(decoding: out, as: UTF8.self))
                }
            } catch {
                let resp = ParityResponse(id: "decode-error", ok: false, value: nil, error: String(describing: error))
                if let out = try? encoder.encode(resp) {
                    print(String(decoding: out, as: UTF8.self))
                }
            }
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(CRT)
            fflush(nil)
            #endif
        }
    }
}
