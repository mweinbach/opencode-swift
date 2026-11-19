// MARK: - parse.keypress.ts Public API

/// Key event lifecycle action, matching `packages/core/src/lib/parse.keypress.ts`.
// parity: core/src/lib/parse.keypress.ts#KeyEventType [status=implemented hash=004778495019]
public enum KeyEventType: String, Equatable, Hashable, Sendable, Codable {
    case press
    case `repeat`
    case release
}

/// Decoder source of a `ParsedKey`.
public enum ParsedKeySource: String, Equatable, Hashable, Sendable, Codable {
    case raw
    case kitty
}

/// Decoded terminal keypress event, matching `packages/core/src/lib/parse.keypress.ts`.
// parity: core/src/lib/parse.keypress.ts#ParsedKey [status=implemented hash=354a725b5db9]
public struct ParsedKey: Equatable, Hashable, Sendable, Codable {
    public var name: String
    public var ctrl: Bool
    public var meta: Bool
    public var shift: Bool
    public var option: Bool
    public var sequence: String
    public var number: Bool
    public var raw: String
    public var eventType: KeyEventType
    public var source: ParsedKeySource
    public var code: String?
    public var `super`: Bool?
    public var hyper: Bool?
    public var capsLock: Bool?
    public var numLock: Bool?
    /// Kitty's base-layout codepoint as a Unicode scalar value (e.g. 99 means `"c"`).
    public var baseCode: UInt32?
    public var repeated: Bool?

    public init(
        name: String,
        ctrl: Bool = false,
        meta: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        sequence: String,
        number: Bool = false,
        raw: String,
        eventType: KeyEventType = .press,
        source: ParsedKeySource = .raw,
        code: String? = nil,
        `super`: Bool? = nil,
        hyper: Bool? = nil,
        capsLock: Bool? = nil,
        numLock: Bool? = nil,
        baseCode: UInt32? = nil,
        repeated: Bool? = nil
    ) {
        self.name = name
        self.ctrl = ctrl
        self.meta = meta
        self.shift = shift
        self.option = option
        self.sequence = sequence
        self.number = number
        self.raw = raw
        self.eventType = eventType
        self.source = source
        self.code = code
        self.`super` = `super`
        self.hyper = hyper
        self.capsLock = capsLock
        self.numLock = numLock
        self.baseCode = baseCode
        self.repeated = repeated
    }
}

/// Options for one-shot keypress parsing.
// parity: core/src/lib/parse.keypress.ts#ParseKeypressOptions [status=implemented hash=8dfb7bb21131]
public struct ParseKeypressOptions: Equatable, Hashable, Sendable, Codable {
    public var useKittyKeyboard: Bool

    public init(useKittyKeyboard: Bool = false) {
        self.useKittyKeyboard = useKittyKeyboard
    }
}

/// The input parser's key names: Kitty's functional keys, linefeed, space, and the SS3 keypad keys' names.
// parity: core/src/lib/parse.keypress.ts#terminalNamedSingleStrokeKeys [status=implemented hash=6fc5e8ec90b6]
public let terminalNamedSingleStrokeKeys: [String] = {
    var seen: Set<String> = []
    var result: [String] = []
    func add(_ key: String) {
        if seen.insert(key).inserted {
            result.append(key)
        }
    }
    add("linefeed")
    add("space")
    for code in kittyKeyMap.keys.sorted() {
        if let name = kittyKeyMap[code] {
            add(name)
        }
    }
    for ch in keypadKeyNames {
        add(String(ch))
    }
    return result
}()

/// Decodes `input` as one complete input with the streaming stdin parser and returns its first event
/// if that is a key, otherwise `nil`.
// parity: core/src/lib/parse.keypress.ts#parseKeypress [status=implemented hash=b4c51f281770]
public func parseKeypress(_ input: String = "", options: ParseKeypressOptions = ParseKeypressOptions()) -> ParsedKey? {
    parseKeypress(Array(input.utf8), options: options)
}

/// Decodes raw `bytes` as one complete input with the streaming stdin parser and returns its first event
/// if that is a key, otherwise `nil`.
public func parseKeypress(_ bytes: [UInt8], options: ParseKeypressOptions = ParseKeypressOptions()) -> ParsedKey? {
    var parser = StdinParser(
        options: StdinParserOptions(
            protocolContext: StdinParserProtocolContext(
                kittyKeyboardEnabled: options.useKittyKeyboard
            )
        )
    )
    parser.push(bytes, nowMs: 0)
    // Far past the escape timeout, so a lone ESC ends as Escape.
    parser.flushTimeout(nowMs: 1e12)
    guard case .key(_, let key) = parser.read() else {
        return nil
    }
    return key
}

// MARK: - Low-Level Engine Types (native/src/input-parser.zig)

/// Protocol expectations supplied by the host terminal session.
// parity: native/src/input-parser.zig#Expectations [status=implemented hash=16306c4ab578]
public struct InputParserExpectations: Equatable, Hashable, Sendable {
    public var replies: Bool
    public var kittyKeyboard: Bool
    public var cursorPosition: Bool
    /// The host waits for the DA1 reply that ends its query batch, so replies need no deadline.
    public var sentinel: Bool
    /// The terminal confirmed Kitty disambiguate, so a raw ESC is a key typed by a mapping, read by the read boundary.
    public var escapePrefix: Bool
    /// The current Kitty keyboard push's `CSI ? u` is unanswered.
    public var kittyQuery: Bool

    public init(
        replies: Bool = false,
        kittyKeyboard: Bool = false,
        cursorPosition: Bool = false,
        sentinel: Bool = false,
        escapePrefix: Bool = false,
        kittyQuery: Bool = false
    ) {
        self.replies = replies
        self.kittyKeyboard = kittyKeyboard
        self.cursorPosition = cursorPosition
        self.sentinel = sentinel
        self.escapePrefix = escapePrefix
        self.kittyQuery = kittyQuery
    }
}

/// Kitty's modifier bitmask (the wire parameter minus one).
// parity: native/src/input-parser.zig#Modifiers [status=implemented hash=7ff261c3d137]
public struct InputParserModifiers: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = InputParserModifiers(rawValue: 1 << 0)
    public static let alt = InputParserModifiers(rawValue: 1 << 1)
    public static let ctrl = InputParserModifiers(rawValue: 1 << 2)
    public static let `super` = InputParserModifiers(rawValue: 1 << 3)
    public static let hyper = InputParserModifiers(rawValue: 1 << 4)
    public static let meta = InputParserModifiers(rawValue: 1 << 5)
    public static let capsLock = InputParserModifiers(rawValue: 1 << 6)
    public static let numLock = InputParserModifiers(rawValue: 1 << 7)
}

/// Discriminator of a low-level `NativeInputEvent`.
// parity: native/src/input-parser.zig#Kind [status=implemented hash=b205c6b32f73]
public enum InputEventKind: UInt8, Equatable, Hashable, Sendable {
    case key = 1
    case mouse = 2
    case paste = 3
    case focus = 4
    case reply = 5
}

/// Key press/repeat/release action emitted by the low-level parser.
// parity: native/src/input-parser.zig#KeyAction [status=implemented hash=630b000e2731]
public enum InputKeyAction: UInt8, Equatable, Hashable, Sendable {
    case press = 1
    case `repeat` = 2
    case release = 3
}

/// Mouse action emitted by the low-level parser.
// parity: native/src/input-parser.zig#MouseAction [status=implemented hash=eb66979a6ebc]
public enum InputMouseAction: UInt8, Equatable, Hashable, Sendable {
    case down = 1
    case up = 2
    case move = 3
    case drag = 4
    case scroll = 5
}

/// Reply protocol emitted by the low-level parser.
// parity: native/src/input-parser.zig#Protocol [status=implemented hash=d53d71119ae1]
public enum InputProtocol: UInt8, Equatable, Hashable, Sendable {
    case csi = 1
    case ss3 = 2
    case osc = 3
    case dcs = 4
    case apc = 5
}

/// Bit flags carried on `NativeInputEvent.flags`.
// parity: native/src/input-parser.zig#flags [status=implemented hash=a173c61ed8ca]
public enum InputEventFlags {
    public static let keyKitty: UInt8 = 1
    public static let keyTextTruncated: UInt8 = 2
    public static let keyTyped: UInt8 = 4
    public static let pasteStart: UInt8 = 1
    public static let pasteEnd: UInt8 = 2
    public static let replyFragment: UInt8 = 1
    public static let replyCursorPosition: UInt8 = 2
}

/// Canonical Unicode scalar / Kitty functional key codes used by the low-level parser.
// parity: native/src/input-parser.zig#key [status=implemented hash=44a26959a214]
public enum InputKeyCode {
    public static let escape: UInt32 = 27
    public static let enter: UInt32 = 13
    public static let tab: UInt32 = 9
    public static let backspace: UInt32 = 127
    public static let insert: UInt32 = 57348
    public static let delete: UInt32 = 57349
    public static let left: UInt32 = 57350
    public static let right: UInt32 = 57351
    public static let up: UInt32 = 57352
    public static let down: UInt32 = 57353
    public static let pageUp: UInt32 = 57354
    public static let pageDown: UInt32 = 57355
    public static let home: UInt32 = 57356
    public static let end: UInt32 = 57357
    public static let menu: UInt32 = 57363
    public static let f1: UInt32 = 57364
    public static let kp0: UInt32 = 57399
    public static let kpBegin: UInt32 = 57427
    public static let functionalFirst: UInt32 = 57344
    public static let functionalLast: UInt32 = 57454

    public static func f(_ number: UInt32) -> UInt32 {
        precondition(number >= 1 && number <= 35)
        return f1 + number - 1
    }
}

/// Low-level event record matching `ot_input_event` / `input-parser.zig#Event`.
// parity: native/src/input-parser.zig#Event [status=implemented hash=3d3e879eeb0a]
public struct NativeInputEvent: Equatable, Hashable, Sendable {
    public var kind: UInt8
    public var action: UInt8
    public var modifiers: UInt8
    public var flags: UInt8
    public var code: UInt32
    public var baseCode: UInt32
    public var x: UInt16
    public var y: UInt16
    public var rawOffset: UInt32
    public var rawLen: UInt32
    public var textOffset: UInt32
    public var textLen: UInt32

    public init(
        kind: UInt8 = 0,
        action: UInt8 = 0,
        modifiers: UInt8 = 0,
        flags: UInt8 = 0,
        code: UInt32 = 0,
        baseCode: UInt32 = 0,
        x: UInt16 = 0,
        y: UInt16 = 0,
        rawOffset: UInt32 = 0,
        rawLen: UInt32 = 0,
        textOffset: UInt32 = 0,
        textLen: UInt32 = 0
    ) {
        self.kind = kind
        self.action = action
        self.modifiers = modifiers
        self.flags = flags
        self.code = code
        self.baseCode = baseCode
        self.x = x
        self.y = y
        self.rawOffset = rawOffset
        self.rawLen = rawLen
        self.textOffset = textOffset
        self.textLen = textLen
    }
}

private struct ByteSpan {
    let offset: UInt32
    let len: UInt32
}

/// Caller-owned records and payload buffer populated by `NativeInputParserEngine.feed`.
// parity: native/src/input-parser.zig#Sink [status=implemented hash=92db3eb27fd4]
public struct InputParserSink: Sendable {
    public static let eventsPerByteMax: Int = 4
    public static let payloadPerByteMax: Int = 4096 + 256 + 32

    public let eventCapacity: Int
    public let payloadCapacity: Int
    public private(set) var events: [NativeInputEvent]
    public private(set) var payload: [UInt8]

    public var count: Int { events.count }
    public var payloadLen: Int { payload.count }

    public init(eventCapacity: Int = 64, payloadCapacity: Int = 16 * 1024) {
        self.eventCapacity = eventCapacity
        self.payloadCapacity = payloadCapacity
        self.events = []
        self.events.reserveCapacity(eventCapacity)
        self.payload = []
        self.payload.reserveCapacity(payloadCapacity)
    }

    public mutating func clear() {
        events.removeAll(keepingCapacity: true)
        payload.removeAll(keepingCapacity: true)
    }

    public func hasRoomForOneByte() -> Bool {
        (eventCapacity - events.count) >= Self.eventsPerByteMax &&
            (payloadCapacity - payload.count) >= Self.payloadPerByteMax
    }

    public func raw(for record: NativeInputEvent) -> ArraySlice<UInt8> {
        let start = Int(record.rawOffset)
        let end = start + Int(record.rawLen)
        return payload[start..<end]
    }

    public func text(for record: NativeInputEvent) -> ArraySlice<UInt8> {
        let start = Int(record.textOffset)
        let end = start + Int(record.textLen)
        return payload[start..<end]
    }

    fileprivate mutating func copy(_ parts: [ArraySlice<UInt8>]) -> ByteSpan {
        let offset = UInt32(payload.count)
        for part in parts {
            payload.append(contentsOf: part)
        }
        return ByteSpan(offset: offset, len: UInt32(payload.count) - offset)
    }

    fileprivate mutating func copyBytes(_ bytes: [UInt8]) -> ByteSpan {
        let offset = UInt32(payload.count)
        payload.append(contentsOf: bytes)
        return ByteSpan(offset: offset, len: UInt32(bytes.count))
    }

    fileprivate mutating func push(_ event: NativeInputEvent) {
        events.append(event)
    }

    fileprivate mutating func startPaste(start: Bool) {
        let payloadOffset = UInt32(payload.count)
        push(
            NativeInputEvent(
                kind: InputEventKind.paste.rawValue,
                action: 0,
                modifiers: 0,
                flags: start ? InputEventFlags.pasteStart : 0,
                code: 0,
                baseCode: 0,
                x: 0,
                y: 0,
                rawOffset: payloadOffset,
                rawLen: 0,
                textOffset: payloadOffset,
                textLen: 0
            )
        )
    }

    fileprivate mutating func appendPaste(_ bytes: ArraySlice<UInt8>) {
        if bytes.isEmpty { return }
        if events.isEmpty {
            startPaste(start: false)
        }
        let lastIndex = events.count - 1
        payload.append(contentsOf: bytes)
        events[lastIndex].textLen += UInt32(bytes.count)
    }

    fileprivate mutating func endPaste() {
        if events.isEmpty {
            startPaste(start: false)
        }
        let lastIndex = events.count - 1
        events[lastIndex].flags |= InputEventFlags.pasteEnd
    }
}

// MARK: - Low-Level Streaming Input Parser Engine (native/src/input-parser.zig)

/// Allocation-minimal, clock-free streaming terminal input parser implementing legacy xterm/VT/SS3,
/// Kitty keyboard protocol, X10 + SGR mouse, bracketed paste, terminal replies/CPR/pixel-size queries,
/// 8-bit Alt, split UTF-8, and ESC timeout flushing.
// parity: native/src/input-parser.zig#InputParser [status=implemented hash=33c8ec597e46]
public struct NativeInputParserEngine: Sendable {
    public static let timeoutNs: UInt64 = 20_000_000
    public static let unitBytesMax: Int = 4096
    public static let sequenceBytesMax: Int = 256
    public static let replyPrefixBytesMax: Int = 8
    public static let paramsMax: Int = 16
    public static let subparamsMax: Int = 8
    public static let mouseButtonNone: UInt32 = 255

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let pasteEndMarker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // "\x1b[201~"
    private static let pasteStartTail: [UInt8] = [0x32, 0x30, 0x30, 0x7E] // "200~"
    private static let pasteStartDigits: [UInt8] = [0x32, 0x30, 0x30] // "200"

    private enum State: Sendable, Equatable {
        case ground
        case expired
        case utf8(expected: UInt8, alt: Bool)
        case escape(alt: Bool)
        case recover(introducer: UInt8)
        case recoverSgr
        case csi(alt: Bool, deferred: Bool, held: Bool, recovered: Bool)
        case ss3(alt: Bool)
        case x10(alt: Bool, recovered: Bool)
        case string(kind: InputProtocol, escaped: Bool, deferred: Bool, recovered: Bool)
        case discard(string: Bool, escaped: Bool, osc: Bool)
        case paste(matched: Int)
    }

    private struct Wire {
        var b0: UInt8
        var b1: UInt8
        var len: Int

        static func of(escaped: Bool, byte: UInt8) -> Wire {
            if escaped {
                return Wire(b0: esc, b1: byte, len: 2)
            } else {
                return Wire(b0: byte, b1: 0, len: 1)
            }
        }

        var bytes: [UInt8] {
            len == 2 ? [b0, b1] : [b0]
        }
    }

    private struct DecodedKey {
        var code: UInt32
        var mods: InputParserModifiers = []
        var action: InputKeyAction = .press
        var flags: UInt8 = 0
        var base: UInt32 = 0
        var text: [UInt8] = []
    }

    private struct DecodedMouse {
        var action: InputMouseAction
        var button: UInt32
        var x: UInt16 = 0
        var y: UInt16 = 0
        var mods: InputParserModifiers = []
    }

    private struct Fields {
        var values: [[UInt32]]
        var present: [UInt8]
        var subcounts: [UInt8]
        var count: Int

        init() {
            self.values = Array(
                repeating: Array(repeating: 0, count: NativeInputParserEngine.subparamsMax),
                count: NativeInputParserEngine.paramsMax
            )
            self.present = Array(repeating: 0, count: NativeInputParserEngine.paramsMax)
            self.subcounts = Array(repeating: 0, count: NativeInputParserEngine.paramsMax)
            self.count = 0
        }

        static func parse(_ params: ArraySlice<UInt8>) -> Fields? {
            var fields = Fields()
            if params.isEmpty { return fields }
            var field = 0
            var sub = 0
            fields.count = 1
            fields.subcounts[0] = 1
            for b in params {
                switch b {
                case 0x30...0x39:
                    if field < NativeInputParserEngine.paramsMax && sub < NativeInputParserEngine.subparamsMax {
                        let bit: UInt8 = 1 << UInt8(sub)
                        let previous = (fields.present[field] & bit) != 0 ? fields.values[field][sub] : 0
                        fields.values[field][sub] = saturatingAdd(
                            saturatingMul(previous, 10),
                            UInt32(b - 0x30)
                        )
                        fields.present[field] |= bit
                    }
                case 0x3B: // ';'
                    field += 1
                    sub = 0
                    if field < NativeInputParserEngine.paramsMax {
                        fields.count += 1
                        fields.subcounts[field] = 1
                    }
                case 0x3A: // ':'
                    sub += 1
                    if field < NativeInputParserEngine.paramsMax && sub < NativeInputParserEngine.subparamsMax {
                        fields.subcounts[field] += 1
                    }
                default:
                    return nil
                }
            }
            return fields
        }

        func get(_ field: Int, _ sub: Int) -> UInt32? {
            guard field < count, sub < Int(subcounts[field]) else { return nil }
            let bit: UInt8 = 1 << UInt8(sub)
            guard (present[field] & bit) != 0 else { return nil }
            return values[field][sub]
        }

        func single(_ field: Int) -> UInt32? {
            guard field < count, subcounts[field] == 1 else { return nil }
            return get(field, 0)
        }
    }

    private struct Shape {
        var semicolons: Int
        var segments: Int
        var first: UInt32?

        static func of(_ params: ArraySlice<UInt8>, kitty: Bool) -> Shape? {
            let fields = splitBytes(params, separator: 0x3B) // ';'
            let first = fields[0]
            let colonIndex = first.firstIndex(of: 0x3A)
            let head: ArraySlice<UInt8> = colonIndex.map { first[..<$0] } ?? first
            if head.isEmpty || !allDigits(head) { return nil }
            if head.count != first.count && !(kitty && allOf(first, set: digitOrColonSet)) {
                return nil
            }
            var shape = Shape(semicolons: 0, segments: 0, first: parseDigits(head))
            if fields.count > 1 {
                for fieldIndex in 1..<fields.count {
                    shape.semicolons += 1
                    if shape.semicolons > 2 { return nil }
                    let parts = splitBytes(fields[fieldIndex], separator: 0x3A) // ':'
                    var count = 0
                    for partIndex in 0..<parts.count {
                        let part = parts[partIndex]
                        count += 1
                        if count > 3 { return nil }
                        let hasMore = (partIndex + 1) < parts.count
                        if !allDigits(part) || (hasMore && part.isEmpty) { return nil }
                    }
                    shape.segments = count
                }
            }
            if shape.semicolons == 0 { return nil }
            return shape
        }
    }

    private struct ModsAndAction {
        let mods: InputParserModifiers
        let action: InputKeyAction
        let hasEvent: Bool
    }

    private static let digitOrSemicolonSet: [UInt8] = Array("0123456789;".utf8)
    private static let digitSemicolonDollarSet: [UInt8] = Array("0123456789;$".utf8)
    private static let digitOrColonSet: [UInt8] = Array("0123456789:".utf8)
    private static let sentinelIntroducers: [UInt8] = Array("[]P_".utf8)
    private static let escapePrefixCsiChars: [UInt8] = Array("0123456789?>ABCDEFHIOPQS".utf8)

    private var state: State = .ground
    public private(set) var expect: InputParserExpectations = InputParserExpectations()
    private var unit: [UInt8] = Array(repeating: 0, count: unitBytesMax)
    private var unitLen: Int = 0
    private var sinceNs: UInt64 = 0
    private var x10Button: UInt8 = 0
    private var buttonsHeld: UInt8 = 0
    public private(set) var discardedCount: UInt32 = 0
    private var batchLeft: Int = 0

    public init(expect: InputParserExpectations = InputParserExpectations()) {
        self.expect = expect
    }

    /// Parses bytes arriving at `nowNs`, writing records into `sink` and returning how many bytes were consumed.
    /// Passing an empty slice only performs timeout expiration.
    public mutating func feed(_ bytes: ArraySlice<UInt8>, nowNs: UInt64, sink: inout InputParserSink) -> Int {
        guard sink.hasRoomForOneByte() else { return 0 }
        // A new batch never extends a unit whose deadline already passed.
        expire(nowNs: nowNs, sink: &sink)
        // A deferred paste start continues only into a read that begins with the rest of its marker and more.
        if case .csi(_, let deferred, _, _) = state, deferred, pastePrefix() {
            let tailStart = unitLen - 2
            let rest = Self.pasteStartTail[tailStart...]
            if bytes.count > rest.count && Self.startsWith(bytes, prefix: rest) {
                state = .csi(alt: false, deferred: false, held: false, recovered: false)
            }
        }
        var consumed = 0
        let baseIndex = bytes.startIndex
        let total = bytes.count
        while consumed < total {
            if !sink.hasRoomForOneByte() { break }
            let remaining = bytes[(baseIndex + consumed)...]
            let run = pasteRun(remaining, sink: sink)
            if run > 0 {
                let end = baseIndex + consumed + run
                sink.appendPaste(bytes[(baseIndex + consumed)..<end])
                consumed += run
                continue
            }
            batchLeft = total - consumed - 1
            step(bytes[baseIndex + consumed], sink: &sink)
            consumed += 1
        }
        if consumed > 0 {
            sinceNs = nowNs
        }
        return consumed
    }

    /// Timestamp in nanoseconds when the host should call `feed` with empty bytes, or `nil`.
    public func deadlineNs() -> UInt64? {
        if expect.escapePrefix {
            let dueNow: Bool
            switch state {
            case .escape:
                dueNow = (batchLeft == 0)
            case .csi(_, _, let held, let recovered):
                dueNow = held && recovered && !expect.sentinel
            case .string(_, _, let deferred, let recovered):
                dueNow = recovered && deferred && !expect.sentinel
            default:
                dueNow = false
            }
            return dueNow ? sinceNs : nil
        }

        let waits: Bool
        switch state {
        case .ground, .expired, .paste, .utf8:
            waits = false
        case .csi(_, let deferred, _, _):
            waits = !deferred || !deferrable()
        case .string(_, _, let deferred, _):
            waits = !expect.sentinel || !(deferred || awaitedString())
        case .discard(let isString, _, _):
            waits = !expect.sentinel || !(isString && awaitedString())
        case .escape, .recover, .recoverSgr, .ss3, .x10:
            waits = true
        }
        return waits ? Self.saturatingAdd(sinceNs, Self.timeoutNs) : nil
    }

    /// Updates protocol expectations without emitting; the next `feed` re-evaluates any deferred unit.
    public mutating func setExpectations(_ newExpect: InputParserExpectations) {
        self.expect = newExpect
    }

    /// Drops the pending unit and mouse button state while keeping expectations.
    /// With `keepReply: true`, a CSI unit that may begin a reply is kept deferred without a deadline.
    public mutating func reset(keepReply: Bool) {
        x10Button = 0
        buttonsHeld = 0
        if keepReply, case .csi(_, _, let existingHeld, _) = state, (replyShaped() || sentinelHeld()) {
            let held = existingHeld || sentinelHeld()
            state = .csi(alt: false, deferred: true, held: held, recovered: false)
            return
        }
        state = .ground
        unitLen = 0
    }

    // MARK: - Core State Machine

    private func pasteRun(_ bytes: ArraySlice<UInt8>, sink: InputParserSink) -> Int {
        guard case .paste(let matched) = state, matched == 0 else { return 0 }
        let run: Int
        if let escIndex = bytes.firstIndex(of: Self.esc) {
            run = escIndex - bytes.startIndex
        } else {
            run = bytes.count
        }
        let room = sink.payloadCapacity - sink.payloadLen - InputParserSink.payloadPerByteMax
        return min(run, max(0, room))
    }

    private mutating func expire(nowNs: UInt64, sink: inout InputParserSink) {
        guard let deadline = deadlineNs(), nowNs >= deadline else { return }
        switch state {
        case .escape(let alt):
            escapeKey(alt: alt, sink: &sink)
        case .recover(let introducer):
            if expect.sentinel {
                begin(heldUnit(introducer), introducer: introducer)
            } else {
                state = .ground
                let raw = [introducer]
                emitKey(
                    sink: &sink,
                    raw: raw,
                    code: UInt32(introducer),
                    mods: [],
                    flags: InputEventFlags.keyTyped,
                    text: raw
                )
            }
        case .recoverSgr:
            state = .ground
            emitReply(sink: &sink, raw: unit[1..<unitLen], protocol: .csi, replyFlags: InputEventFlags.replyFragment)
        case .csi(let alt, let deferred, _, _):
            if !deferred && deferrable() {
                state = .csi(alt: alt, deferred: true, held: sentinelHeld() || kittyHeld(), recovered: false)
            } else {
                cutShort(alt: alt, protocol: .csi, start: 0, sink: &sink)
            }
        case .ss3(let alt):
            cutShort(alt: alt, protocol: .ss3, start: 0, sink: &sink)
        case .x10(let alt, let recovered):
            cutShort(alt: alt, protocol: .csi, start: recovered ? 1 : 0, sink: &sink)
        case .string(let kind, let escaped, _, let recovered):
            if expect.sentinel && unitLen == 2 {
                state = .string(kind: kind, escaped: escaped, deferred: true, recovered: recovered)
            } else {
                cutShort(alt: false, protocol: kind, start: 0, sink: &sink)
            }
        case .discard:
            state = .ground
        case .ground, .expired, .utf8, .paste:
            break
        }
    }

    private mutating func step(_ byte: UInt8, sink: inout InputParserSink) {
        var pending: UInt8? = byte
        while let b = pending {
            pending = nil
            switch state {
            case .ground:
                ground(b, alt: false, wire: .of(escaped: false, byte: b), sink: &sink)

            case .expired:
                if b == 0x5B && (batchLeft > 0 || !expect.escapePrefix) {
                    state = .recover(introducer: b)
                } else if (expect.sentinel || (expect.escapePrefix && b == 0x5F && batchLeft > 0))
                    && Self.sentinelIntroducers.contains(b)
                {
                    if expect.escapePrefix {
                        begin(heldUnit(b), introducer: b)
                    } else {
                        state = .recover(introducer: b)
                    }
                } else {
                    state = .ground
                    pending = b
                }

            case .utf8(let expected, let alt):
                if Self.utf8Continues(lead: unit[0], count: unitLen, byte: b) {
                    appendUnit(b)
                    if unitLen == Int(expected) {
                        utf8Complete(alt: alt, sink: &sink)
                    }
                } else {
                    utf8Fallback(alt: alt, sink: &sink)
                    pending = b
                }

            case .escape(let alt):
                pending = escapeByte(b, alt: alt, sink: &sink)

            case .recover(let introducer):
                if let nextState = recovered(introducer: introducer, byte: b) {
                    begin(nextState, introducer: introducer)
                    if case .recoverSgr = nextState {
                        appendUnit(b)
                    } else {
                        pending = b
                    }
                } else {
                    state = .ground
                    let raw = [introducer]
                    emitKey(
                        sink: &sink,
                        raw: raw,
                        code: UInt32(introducer),
                        mods: [],
                        flags: InputEventFlags.keyTyped,
                        text: raw
                    )
                    pending = b
                }

            case .recoverSgr:
                pending = recoverSgrByte(b, sink: &sink)

            case .csi(let alt, let deferred, let held, let recovered):
                if !deferred {
                    sequenceByte(b, alt: alt, isCsi: true, sink: &sink)
                } else if !continuesDeferred(b, replyOnly: held) {
                    cutShort(alt: alt, protocol: .csi, start: 0, sink: &sink)
                    pending = b
                } else if !held && b == 0x3F { // '?'
                    appendUnit(b)
                    state = .csi(alt: alt, deferred: deferred, held: true, recovered: recovered)
                } else if !held || b == 0x3C || b == 0x4D { // '<' or 'M'
                    state = .csi(alt: alt, deferred: false, held: false, recovered: false)
                    pending = b
                } else if b >= 0x40 {
                    appendUnit(b)
                    state = .ground
                    dispatchCsi(alt: alt, replyOnly: true, sink: &sink)
                } else {
                    sequenceByte(b, alt: alt, isCsi: true, sink: &sink)
                }

            case .ss3(let alt):
                sequenceByte(b, alt: alt, isCsi: false, sink: &sink)

            case .x10(let alt, let recovered):
                if b >= 0x01 && b <= 0x1F {
                    cutShort(alt: alt, protocol: .csi, start: recovered ? 1 : 0, sink: &sink)
                    ground(b, alt: false, wire: .of(escaped: false, byte: b), sink: &sink)
                } else {
                    appendUnit(b)
                    if unitLen == 6 {
                        state = .ground
                        dispatchX10(alt: alt, sink: &sink)
                    }
                }

            case .string(let kind, let escaped, let deferred, let recovered):
                if deferred || (expect.sentinel && unitLen == 2 && Self.beginsReply(introducer: unit[1], byte: b)) {
                    if let complete = Self.continuesPrefix(introducer: unit[1], payload: unit[2..<unitLen], byte: b) {
                        appendUnit(b)
                        state = .string(kind: kind, escaped: escaped, deferred: !complete, recovered: recovered)
                    } else {
                        cutShort(alt: false, protocol: kind, start: 0, sink: &sink)
                        pending = b
                    }
                } else {
                    pending = stringByte(b, kind: kind, escaped: escaped, sink: &sink)
                }

            case .discard(let isString, let escaped, let isOsc):
                pending = discardByte(b, isString: isString, escaped: escaped, isOsc: isOsc)

            case .paste(let matched):
                pasteByte(b, matched: matched, sink: &sink)
            }
        }

        // With `escapePrefix`, an ESC that ends the read is the Escape key at once, as a timeout would give it.
        if expect.escapePrefix && batchLeft == 0, case .escape(let alt) = state {
            escapeKey(alt: alt, sink: &sink)
        }
    }

    private mutating func escapeKey(alt: Bool, sink: inout InputParserSink) {
        let raw: [UInt8] = alt ? [Self.esc, Self.esc] : [Self.esc]
        emitKey(sink: &sink, raw: raw, code: InputKeyCode.escape, mods: alt ? .alt : [])
        state = (alt && !expect.escapePrefix) ? .ground : .expired
    }

    private mutating func ground(_ b: UInt8, alt: Bool, wire: Wire, sink: inout InputParserSink) {
        let mods: InputParserModifiers = alt ? .alt : []
        let ctrl: InputParserModifiers = alt ? [.alt, .ctrl] : .ctrl
        let raw = wire.bytes
        switch b {
        case Self.esc:
            escape()
        case 0x0D, 0x0A: // '\r', '\n'
            emitKey(sink: &sink, raw: raw, code: InputKeyCode.enter, mods: mods)
        case 0x09: // '\t'
            emitKey(sink: &sink, raw: raw, code: InputKeyCode.tab, mods: mods)
        case 0x7F, 0x08:
            emitKey(sink: &sink, raw: raw, code: InputKeyCode.backspace, mods: mods)
        case 0x00:
            emitKey(sink: &sink, raw: raw, code: 0x20, mods: ctrl)
        case 0x01...0x07, 0x0B, 0x0C, 0x0E...0x1A:
            emitKey(sink: &sink, raw: raw, code: UInt32(0x61) + UInt32(b) - 1, mods: ctrl)
        case 0x1C...0x1F:
            emitKey(sink: &sink, raw: raw, code: UInt32(0x5C) + UInt32(b) - 0x1C, mods: ctrl)
        case 0x20...0x7E:
            emitKey(
                sink: &sink,
                raw: raw,
                code: UInt32(b),
                mods: mods,
                flags: InputEventFlags.keyTyped,
                text: alt ? [] : raw
            )
        case 0xC2...0xDF:
            beginUtf8(lead: b, expected: 2, alt: alt)
        case 0xE0...0xEF:
            beginUtf8(lead: b, expected: 3, alt: alt)
        case 0xF0...0xF4:
            beginUtf8(lead: b, expected: 4, alt: alt)
        default:
            eightBit(b, wire: wire, sink: &sink)
        }
    }

    private mutating func eightBit(_ b: UInt8, wire: Wire, sink: inout InputParserSink) {
        let ascii = b & 0x7F
        if ascii == Self.esc {
            emitKey(sink: &sink, raw: wire.bytes, code: InputKeyCode.escape, mods: .alt)
            return
        }
        ground(ascii, alt: true, wire: wire, sink: &sink)
    }

    private mutating func beginUtf8(lead: UInt8, expected: UInt8, alt: Bool) {
        unit[0] = lead
        unitLen = 1
        state = .utf8(expected: expected, alt: alt)
    }

    private mutating func utf8Complete(alt: Bool, sink: inout InputParserSink) {
        state = .ground
        let slice = unit[0..<unitLen]
        let scalar = Self.utf8DecodeValid(slice)
        let text: [UInt8] = alt ? [] : Self.utf8EncodeScalar(scalar)
        let raw: [UInt8] = alt ? ([Self.esc] + Array(slice)) : Array(slice)
        emitKey(
            sink: &sink,
            raw: raw,
            code: scalar,
            mods: alt ? .alt : [],
            flags: InputEventFlags.keyTyped,
            text: text
        )
    }

    private mutating func utf8Fallback(alt: Bool, sink: inout InputParserSink) {
        state = .ground
        let buffered = Array(unit[0..<unitLen])
        unitLen = 0
        for (index, b) in buffered.enumerated() {
            eightBit(b, wire: .of(escaped: alt && index == 0, byte: b), sink: &sink)
        }
    }

    private mutating func escapeByte(_ b: UInt8, alt: Bool, sink: inout InputParserSink) -> UInt8? {
        if alt {
            switch b {
            case 0x5B: // '['
                begin(.csi(alt: true, deferred: false, held: false, recovered: false), introducer: b)
            case 0x4F: // 'O'
                begin(.ss3(alt: true), introducer: b)
            case Self.esc:
                emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
            default:
                emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
                state = .escape(alt: false)
                return b
            }
            return nil
        }

        switch b {
        case 0x5B: // '['
            begin(.csi(alt: false, deferred: false, held: false, recovered: false), introducer: b)
        case 0x4F: // 'O'
            begin(.ss3(alt: false), introducer: b)
        case Self.esc:
            state = .escape(alt: true)
        case 0x5D: // ']'
            begin(.string(kind: .osc, escaped: false, deferred: false, recovered: false), introducer: b)
        case 0x50: // 'P'
            begin(.string(kind: .dcs, escaped: false, deferred: false, recovered: false), introducer: b)
        case 0x5F: // '_'
            begin(.string(kind: .apc, escaped: false, deferred: false, recovered: false), introducer: b)
        case 0x42, 0x46: // 'B', 'F' (Terminal.app Option+Left / Option+Right)
            state = .ground
            let wire = Wire.of(escaped: true, byte: b)
            emitKey(
                sink: &sink,
                raw: wire.bytes,
                code: b == 0x42 ? InputKeyCode.left : InputKeyCode.right,
                mods: .alt
            )
        default:
            state = .ground
            ground(b, alt: true, wire: .of(escaped: true, byte: b), sink: &sink)
        }
        return nil
    }

    private mutating func recoverSgrByte(_ b: UInt8, sink: inout InputParserSink) -> UInt8? {
        switch b {
        case 0x30...0x39, 0x3B: // '0'...'9', ';'
            if unitLen < Self.sequenceBytesMax {
                appendUnit(b)
                return nil
            }
        case 0x4D, 0x6D: // 'M', 'm'
            state = .ground
            appendUnit(b)
            let fullUnit = unit[0..<unitLen]
            if let mouse = Self.sgrMouse(params: unit[3..<(unitLen - 1)], pressed: b == 0x4D, held: buttonsHeld) {
                emitMouse(sink: &sink, raw: fullUnit, mouse: mouse)
            } else {
                emitReply(sink: &sink, raw: unit[1..<unitLen], protocol: .csi, replyFlags: InputEventFlags.replyFragment)
            }
            return nil
        default:
            break
        }
        state = .ground
        emitReply(sink: &sink, raw: unit[1..<unitLen], protocol: .csi, replyFlags: InputEventFlags.replyFragment)
        return b
    }

    private mutating func sequenceByte(_ b: UInt8, alt: Bool, isCsi: Bool, sink: inout InputParserSink) {
        let proto: InputProtocol = isCsi ? .csi : .ss3
        if b == Self.esc {
            cutShort(alt: alt, protocol: proto, start: 0, sink: &sink)
            escape()
        } else if b < 0x20 || b == 0x7F {
            cutShort(alt: alt, protocol: proto, start: 0, sink: &sink)
            ground(b, alt: false, wire: .of(escaped: false, byte: b), sink: &sink)
        } else if isCsi && unitLen == 2 && b == 0x4D { // 'M'
            appendUnit(b)
            state = .x10(alt: alt, recovered: false)
        } else if isCsi && unitLen == 2 && b == 0x5B { // '['
            appendUnit(b)
        } else if (b >= 0x40 && b <= 0x7E)
            || (isCsi && b == 0x24 && unitLen > 2 && Self.allDigits(unit[2..<unitLen]))
        {
            appendUnit(b)
            let replyOnly: Bool
            if isCsi, case .csi(_, _, _, let recovered) = state {
                replyOnly = recovered
            } else {
                replyOnly = false
            }
            state = .ground
            if isCsi {
                dispatchCsi(alt: alt, replyOnly: replyOnly, sink: &sink)
            } else {
                dispatchSs3(alt: alt, sink: &sink)
            }
        } else if unitLen >= Self.sequenceBytesMax {
            state = .discard(string: false, escaped: false, osc: false)
            discardedCount = Self.saturatingAdd(discardedCount, 1)
        } else {
            appendUnit(b)
        }
    }

    private mutating func stringByte(_ b: UInt8, kind: InputProtocol, escaped: Bool, sink: inout InputParserSink) -> UInt8? {
        if escaped {
            if b == 0x5C { // '\\'
                appendUnit(b)
                state = .ground
                emitReply(sink: &sink, raw: unit[0..<unitLen], protocol: kind, replyFlags: 0)
                return nil
            }
            unitLen -= 1
            emitReply(sink: &sink, raw: unit[0..<unitLen], protocol: kind, replyFlags: InputEventFlags.replyFragment)
            escape()
            return b
        }

        if b == Self.bel && kind == .osc {
            state = .ground
            if unitLen < Self.unitBytesMax {
                appendUnit(b)
                emitReply(sink: &sink, raw: unit[0..<unitLen], protocol: .osc, replyFlags: 0)
            } else {
                discardedCount = Self.saturatingAdd(discardedCount, 1)
            }
        } else if b == Self.esc {
            if unitLen + 2 <= Self.unitBytesMax {
                appendUnit(b)
                state = .string(kind: kind, escaped: true, deferred: false, recovered: false)
            } else {
                state = .discard(string: true, escaped: true, osc: kind == .osc)
                discardedCount = Self.saturatingAdd(discardedCount, 1)
            }
        } else if unitLen >= Self.unitBytesMax {
            state = .discard(string: true, escaped: false, osc: kind == .osc)
            discardedCount = Self.saturatingAdd(discardedCount, 1)
        } else {
            appendUnit(b)
        }
        return nil
    }

    private mutating func discardByte(_ b: UInt8, isString: Bool, escaped: Bool, isOsc: Bool) -> UInt8? {
        if !isString {
            if b == Self.esc {
                escape()
            } else if b >= 0x40 && b <= 0x7E {
                state = .ground
            }
            return nil
        }
        if escaped {
            if b == 0x5C { // '\\'
                state = .ground
                return nil
            }
            escape()
            return b
        }
        if b == Self.bel && isOsc {
            state = .ground
        } else if b == Self.esc {
            state = .discard(string: true, escaped: true, osc: isOsc)
        }
        return nil
    }

    private mutating func pasteByte(_ b: UInt8, matched: Int, sink: inout InputParserSink) {
        if b == Self.pasteEndMarker[matched] {
            if matched + 1 == Self.pasteEndMarker.count {
                sink.endPaste()
                state = .ground
            } else {
                state = .paste(matched: matched + 1)
            }
            return
        }
        if matched > 0 {
            sink.appendPaste(Self.pasteEndMarker[0..<matched])
        }
        if b == Self.esc {
            state = .paste(matched: 1)
        } else {
            sink.appendPaste([b][...])
            state = .paste(matched: 0)
        }
    }

    private mutating func appendUnit(_ byte: UInt8) {
        unit[unitLen] = byte
        unitLen += 1
    }

    private mutating func begin(_ newState: State, introducer: UInt8) {
        unit[0] = Self.esc
        unit[1] = introducer
        unitLen = 2
        state = newState
    }

    private mutating func escape() {
        unitLen = 0
        state = .escape(alt: false)
    }

    private mutating func cutShort(alt: Bool, protocol proto: InputProtocol, start: Int, sink: inout InputParserSink) {
        let typed: Bool
        switch state {
        case .csi(_, _, _, let recovered):
            typed = recovered && Self.allDigits(unit[2..<unitLen])
        case .string(_, _, let deferred, let recovered):
            typed = recovered && deferred
        default:
            typed = false
        }
        state = .ground
        if alt {
            emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
        }
        if !typed {
            emitReply(sink: &sink, raw: unit[start..<unitLen], protocol: proto, replyFlags: InputEventFlags.replyFragment)
            return
        }
        let introducer = unit[1]
        let introducerBytes = [introducer]
        emitKey(
            sink: &sink,
            raw: introducerBytes,
            code: UInt32(introducer),
            mods: [],
            flags: InputEventFlags.keyTyped,
            text: introducerBytes
        )
        if proto == .apc && expect.escapePrefix {
            let tail = Array(unit[2..<unitLen])
            for c in tail {
                ground(c, alt: false, wire: .of(escaped: false, byte: c), sink: &sink)
            }
        } else if unitLen > 2 {
            emitReply(sink: &sink, raw: unit[2..<unitLen], protocol: proto, replyFlags: InputEventFlags.replyFragment)
        }
    }

    private mutating func dispatchCsi(alt: Bool, replyOnly: Bool, sink: inout InputParserSink) {
        let fullUnit = unit[0..<unitLen]
        let params = unit[2..<(unitLen - 1)]
        let finalByte = unit[unitLen - 1]

        if finalByte == 0x7E && params.elementsEqual(Self.pasteStartDigits) { // '~' and "200"
            if alt {
                emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
            }
            state = .paste(matched: 0)
            sink.startPaste(start: true)
            return
        }

        if params.isEmpty && (finalByte == 0x49 || finalByte == 0x4F) { // 'I' or 'O'
            if alt {
                emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
            }
            let span = sink.copy([fullUnit])
            sink.push(
                Self.makeEvent(
                    kind: .focus,
                    action: finalByte == 0x49 ? 1 : 0,
                    modifiers: [],
                    code: 0,
                    raw: span,
                    text: ByteSpan(offset: UInt32(sink.payloadLen), len: 0)
                )
            )
            return
        }

        if !params.isEmpty && params[params.startIndex] == 0x3C { // '<'
            let mouse: DecodedMouse?
            if finalByte == 0x4D || finalByte == 0x6D { // 'M' or 'm'
                mouse = Self.sgrMouse(
                    params: params[(params.startIndex + 1)...],
                    pressed: finalByte == 0x4D,
                    held: buttonsHeld
                )
            } else {
                mouse = nil
            }
            if alt {
                emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
            }
            if let value = mouse {
                emitMouse(sink: &sink, raw: fullUnit, mouse: value)
            } else {
                emitReply(sink: &sink, raw: fullUnit, protocol: .csi, replyFlags: 0)
            }
            return
        }

        var cursorReport = false
        let decoded: DecodedKey?
        if !params.isEmpty && params[params.startIndex] == 0x5B { // '['
            decoded = replyOnly ? nil : Self.bracketKey(params: params[(params.startIndex + 1)...], finalByte: finalByte)
        } else if let fields = Fields.parse(params) {
            cursorReport = (finalByte == 0x52 && fields.count == 2 && fields.single(0) != nil && fields.single(1) != nil)
            decoded = replyOnly ? nil : csiKey(fields: fields, params: params, finalByte: finalByte)
        } else {
            decoded = nil
        }

        if let value = decoded {
            emitDecodedKey(sink: &sink, alt: alt, unit: fullUnit, value: value)
            return
        }
        if alt {
            emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
        }
        emitReply(
            sink: &sink,
            raw: fullUnit,
            protocol: .csi,
            replyFlags: cursorReport ? InputEventFlags.replyCursorPosition : 0
        )
    }

    private func csiKey(fields: Fields, params: ArraySlice<UInt8>, finalByte: UInt8) -> DecodedKey? {
        switch finalByte {
        case 0x75: // 'u'
            return Self.kittyKey(fields: fields, params: params)
        case 0x7E: // '~'
            return Self.tildeKey(fields: fields)
        case 0x24, 0x5E, 0x40: // '$', '^', '@'
            guard fields.count == 1, var value = Self.tildeKey(fields: fields) else { return nil }
            switch finalByte {
            case 0x24: value.mods = .shift
            case 0x5E: value.mods = .ctrl
            default: value.mods = [.shift, .ctrl]
            }
            return value
        case 0x52: // 'R'
            if expect.kittyKeyboard { return nil }
            switch fields.count {
            case 0:
                return DecodedKey(code: InputKeyCode.f(3))
            case 2:
                if !expect.cursorPosition, fields.single(0) == 1, let modParam = fields.single(1), modParam > 1 {
                    return DecodedKey(code: InputKeyCode.f(3), mods: Self.modsFromParam(modParam))
                }
                return nil
            default:
                return nil
            }
        case 0x41...0x48, 0x50, 0x51, 0x53, 0x5A, 0x61...0x65: // 'A'...'H', 'P', 'Q', 'S', 'Z', 'a'...'e'
            return Self.letterKey(letter: finalByte, fields: fields)
        default:
            return nil
        }
    }

    private mutating func dispatchSs3(alt: Bool, sink: inout InputParserSink) {
        let fullUnit = unit[0..<unitLen]
        if let value = Self.ss3Key(finalByte: unit[unitLen - 1], params: unit[2..<(unitLen - 1)]) {
            emitDecodedKey(sink: &sink, alt: alt, unit: fullUnit, value: value)
            return
        }
        if alt {
            emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
        }
        emitReply(sink: &sink, raw: fullUnit, protocol: .ss3, replyFlags: 0)
    }

    private mutating func dispatchX10(alt: Bool, sink: inout InputParserSink) {
        let fullUnit = unit[0..<unitLen]
        let code = UInt32(unit[3] &- 32)
        var mouse: DecodedMouse
        if (code & 0xE3) == 3 {
            mouse = DecodedMouse(action: .up, button: UInt32(x10Button))
        } else if let decoded = Self.mouseKind(code: code, release: false, held: buttonsHeld) {
            mouse = decoded
        } else {
            return
        }
        mouse.mods = Self.mouseModifiers(code)
        // Coordinates are one-based after the offset; xterm's 0 wraps on u8 to cell 223.
        mouse.x = UInt16(unit[4] &- 33)
        mouse.y = UInt16(unit[5] &- 33)
        if alt {
            emitKey(sink: &sink, raw: [Self.esc], code: InputKeyCode.escape, mods: [])
        }
        emitMouse(sink: &sink, raw: fullUnit, mouse: mouse)
    }

    private mutating func emitMouse(sink: inout InputParserSink, raw: ArraySlice<UInt8>, mouse: DecodedMouse) {
        if mouse.button < 3 {
            let bit: UInt8 = 1 << UInt8(mouse.button)
            if mouse.action == .down { buttonsHeld |= bit }
            if mouse.action == .up { buttonsHeld &= ~bit }
        }
        if mouse.action == .down {
            x10Button = UInt8(mouse.button)
        }
        if mouse.action == .up {
            x10Button = buttonsHeld == 0 ? 0 : UInt8(buttonsHeld.trailingZeroBitCount)
        }
        let span = sink.copy([raw])
        var value = Self.makeEvent(
            kind: .mouse,
            action: mouse.action.rawValue,
            modifiers: mouse.mods,
            code: mouse.button,
            raw: span,
            text: ByteSpan(offset: UInt32(sink.payloadLen), len: 0)
        )
        value.x = mouse.x
        value.y = mouse.y
        sink.push(value)
    }

    // MARK: - Deferral & Recovery Predicates

    private func deferrable() -> Bool {
        let params = unit[2..<unitLen]
        if sentinelHeld() { return true }
        if params.isEmpty {
            if case .csi(let alt, _, _, _) = state {
                return !alt
            }
            return false
        }
        if kittyHeld() { return true }
        if params[params.startIndex] == 0x3C { // '<'
            return Self.allOf(params[(params.startIndex + 1)...], set: Self.digitOrSemicolonSet)
        }
        return pastePrefix()
            || (expect.replies && replyShaped())
            || (expect.kittyKeyboard && params[params.startIndex] != 0x3F && Shape.of(params, kitty: true) != nil)
    }

    private func pastePrefix() -> Bool {
        guard case .csi(let alt, _, _, let recovered) = state else { return false }
        return !alt && !recovered && Self.startsWith(Self.pasteStartDigits[...], prefix: unit[2..<unitLen])
    }

    private func replyShaped() -> Bool {
        let params = unit[2..<unitLen]
        guard !params.isEmpty else { return false }
        switch params[params.startIndex] {
        case 0x3C: // '<'
            return false
        case 0x3F: // '?'
            return Self.allOf(params[(params.startIndex + 1)...], set: Self.digitSemicolonDollarSet)
        default:
            guard let shape = Shape.of(params, kitty: false) else { return false }
            return shape.semicolons == 1 || (shape.semicolons == 2 && shape.first == 4)
        }
    }

    private func awaitedString() -> Bool {
        unitLen >= 3 && Self.beginsReply(introducer: unit[1], byte: unit[2])
    }

    private func kittyHeld() -> Bool {
        expect.kittyQuery && unitLen > 2 && unit[2] == 0x3F && Self.allDigits(unit[3..<unitLen])
    }

    private func sentinelHeld() -> Bool {
        expect.sentinel && Self.allDigits(unit[2..<unitLen])
    }

    private func recovered(introducer: UInt8, byte b: UInt8) -> State? {
        if introducer == 0x5B && b == 0x3C { return .recoverSgr }
        if expect.escapePrefix {
            return Self.escapePrefixCsiChars.contains(b)
                ? .csi(alt: false, deferred: false, held: false, recovered: true)
                : nil
        }
        if introducer == 0x5B && b == 0x4D { // 'M'
            return .x10(alt: false, recovered: true)
        }
        if introducer == 0x5B && b == 0x3F && expect.kittyQuery && batchLeft >= 2 {
            return heldUnit(0x5B)
        }
        if !expect.sentinel || !Self.beginsReply(introducer: introducer, byte: b) { return nil }
        return heldUnit(introducer)
    }

    private func heldUnit(_ introducer: UInt8) -> State {
        switch introducer {
        case 0x5B: return .csi(alt: false, deferred: true, held: true, recovered: true)
        case 0x5D: return .string(kind: .osc, escaped: false, deferred: true, recovered: true)
        case 0x50: return .string(kind: .dcs, escaped: false, deferred: true, recovered: true)
        case 0x5F: return .string(kind: .apc, escaped: false, deferred: true, recovered: true)
        default: return .ground
        }
    }

    private func continuesDeferred(_ b: UInt8, replyOnly: Bool) -> Bool {
        let params = unit[2..<unitLen]
        let digit = Self.isDigit(b)
        if params.isEmpty {
            return (b == 0x3C && batchLeft >= 1)
                || (b == 0x4D && batchLeft >= 3)
                || (expect.kittyQuery && b == 0x3F && batchLeft >= 2)
                || (expect.sentinel && Self.beginsReply(introducer: 0x5B, byte: b))
        }
        if Self.allDigits(params) {
            return expect.sentinel && (digit || b == 0x3B)
        }
        var fieldEnd = params.endIndex
        while fieldEnd > params.startIndex && params[fieldEnd - 1] == 0x24 { // '$'
            fieldEnd -= 1
        }
        let hasDigit = fieldEnd > params.startIndex && Self.isDigit(params[fieldEnd - 1])
        switch params[params.startIndex] {
        case 0x3C: // '<'
            return digit || b == 0x3B || b == 0x4D || b == 0x6D
        case 0x3F: // '?'
            if digit || b == 0x3B || b == 0x24 { return true }
            if params.contains(0x24) { return hasDigit && b == 0x79 } // 'y'
            switch b {
            case 0x63: // 'c'
                return hasDigit || params.contains(0x3B)
            case 0x6E, 0x75: // 'n', 'u'
                return hasDigit
            default:
                return false
            }
        default:
            let kitty = expect.kittyKeyboard && !replyOnly
            guard let shape = Shape.of(params, kitty: kitty) else { return false }
            if digit || b == 0x3A || b == 0x3B { return true }
            if !hasDigit { return false }
            let kittyFinal = b == 0x75
                || (shape.semicolons == 1 && shape.segments > 1 && (b == 0x7E || (b >= 0x41 && b <= 0x5A)))
            let replyFinal = (shape.semicolons == 1 && b == 0x52)
                || (shape.semicolons == 2 && shape.first == 4 && b == 0x74)
            return (kitty && kittyFinal) || (expect.replies && replyFinal)
        }
    }

    // MARK: - Emission Helpers

    private static func makeEvent(
        kind: InputEventKind,
        action: UInt8,
        modifiers: InputParserModifiers,
        code: UInt32,
        raw: ByteSpan,
        text: ByteSpan
    ) -> NativeInputEvent {
        NativeInputEvent(
            kind: kind.rawValue,
            action: action,
            modifiers: modifiers.rawValue,
            flags: 0,
            code: code,
            baseCode: 0,
            x: 0,
            y: 0,
            rawOffset: raw.offset,
            rawLen: raw.len,
            textOffset: text.offset,
            textLen: text.len
        )
    }

    private func emitKey(
        sink: inout InputParserSink,
        raw: [UInt8],
        code: UInt32,
        mods: InputParserModifiers,
        action: InputKeyAction = .press,
        flags: UInt8 = 0,
        base: UInt32 = 0,
        text: [UInt8] = []
    ) {
        let rawSpan = sink.copyBytes(raw)
        let textSpan = sink.copyBytes(text)
        var value = Self.makeEvent(
            kind: .key,
            action: action.rawValue,
            modifiers: mods,
            code: code,
            raw: rawSpan,
            text: textSpan
        )
        value.flags = flags
        value.baseCode = base
        sink.push(value)
    }

    private func emitDecodedKey(
        sink: inout InputParserSink,
        alt: Bool,
        unit: ArraySlice<UInt8>,
        value: DecodedKey
    ) {
        let rawSpan: ByteSpan
        if alt {
            rawSpan = sink.copy([[Self.esc][...], unit])
        } else {
            rawSpan = sink.copy([unit])
        }
        let textSpan = sink.copyBytes(value.text)
        let mods: InputParserModifiers = alt ? value.mods.union(.alt) : value.mods
        var record = Self.makeEvent(
            kind: .key,
            action: value.action.rawValue,
            modifiers: mods,
            code: value.code,
            raw: rawSpan,
            text: textSpan
        )
        record.flags = value.flags
        record.baseCode = value.base
        sink.push(record)
    }

    private func emitReply(
        sink: inout InputParserSink,
        raw: ArraySlice<UInt8>,
        protocol proto: InputProtocol,
        replyFlags: UInt8
    ) {
        let span = sink.copy([raw])
        var value = Self.makeEvent(
            kind: .reply,
            action: 0,
            modifiers: [],
            code: UInt32(proto.rawValue),
            raw: span,
            text: ByteSpan(offset: UInt32(sink.payloadLen), len: 0)
        )
        value.flags = replyFlags
        sink.push(value)
    }

    // MARK: - Key & Mouse Decoders

    private static func isDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    private static func isAlphabetic(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func isControl(_ cp: UInt32) -> Bool {
        cp < 0x20 || (cp >= 0x7F && cp < 0xA0)
    }

    private static func isScalar(_ cp: UInt32) -> Bool {
        cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF)
    }

    private static func allDigits(_ bytes: ArraySlice<UInt8>) -> Bool {
        for b in bytes where !isDigit(b) {
            return false
        }
        return true
    }

    private static func allOf(_ bytes: ArraySlice<UInt8>, set: [UInt8]) -> Bool {
        for b in bytes where !set.contains(b) {
            return false
        }
        return true
    }

    private static func startsWith(_ bytes: ArraySlice<UInt8>, prefix: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        var i = bytes.startIndex
        var j = prefix.startIndex
        while j < prefix.endIndex {
            if bytes[i] != prefix[j] { return false }
            i += 1
            j += 1
        }
        return true
    }

    private static func splitBytes(_ bytes: ArraySlice<UInt8>, separator: UInt8) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        var i = start
        while i < bytes.endIndex {
            if bytes[i] == separator {
                result.append(bytes[start..<i])
                start = i + 1
            }
            i += 1
        }
        result.append(bytes[start..<bytes.endIndex])
        return result
    }

    private static func saturatingAdd(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt32.max : value
    }

    private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : value
    }

    private static func saturatingMul(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? UInt32.max : value
    }

    private static func parseDigits(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var value: UInt32 = 0
        for b in bytes {
            value = saturatingAdd(saturatingMul(value, 10), UInt32(b - 0x30))
        }
        return value
    }

    private static func beginsReply(introducer: UInt8, byte b: UInt8) -> Bool {
        switch introducer {
        case 0x5B: return b == 0x3F || isDigit(b) // '[': '?' or digit
        case 0x5D: return isDigit(b) // ']': digit
        case 0x50: return b == 0x3E || isDigit(b) // 'P': '>' or digit
        case 0x5F: return b == 0x47 // '_': 'G'
        default: return false
        }
    }

    private static func continuesPrefix(introducer: UInt8, payload: ArraySlice<UInt8>, byte b: UInt8) -> Bool? {
        if payload.count + 1 >= replyPrefixBytesMax { return nil }
        switch introducer {
        case 0x5D: // ']'
            if allDigits(payload) {
                if isDigit(b) { return false }
                if b == 0x3B && !payload.isEmpty { return true }
            }
        case 0x50: // 'P'
            if payload.isEmpty && (b == 0x3E || isDigit(b)) { return false }
            if payload.count == 1 && payload[payload.startIndex] == 0x3E && b == 0x7C { return true } // ">|"
            if payload.count == 1 && isDigit(payload[payload.startIndex]) && (b == 0x2B || b == 0x24) { return false }
            if payload.count == 2
                && isDigit(payload[payload.startIndex])
                && (payload[payload.startIndex + 1] == 0x2B || payload[payload.startIndex + 1] == 0x24)
                && b == 0x72
            {
                return true
            }
        case 0x5F: // '_'
            if payload.isEmpty && b == 0x47 { return false } // 'G'
            if payload.count == 1 && isAlphabetic(b) { return false }
            if payload.count == 2 && b == 0x3D { return true } // '='
        default:
            break
        }
        return nil
    }

    private static func utf8Continues(lead: UInt8, count: Int, byte b: UInt8) -> Bool {
        let low: UInt8
        let high: UInt8
        if count > 1 {
            low = 0x80
            high = 0xBF
        } else {
            switch lead {
            case 0xE0:
                low = 0xA0; high = 0xBF
            case 0xED:
                low = 0x80; high = 0x9F
            case 0xF0:
                low = 0x90; high = 0xBF
            case 0xF4:
                low = 0x80; high = 0x8F
            default:
                low = 0x80; high = 0xBF
            }
        }
        return b >= low && b <= high
    }

    private static func utf8DecodeValid(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        let i = bytes.startIndex
        switch bytes.count {
        case 2:
            return (UInt32(bytes[i] & 0x1F) << 6) | UInt32(bytes[i + 1] & 0x3F)
        case 3:
            return (UInt32(bytes[i] & 0x0F) << 12)
                | (UInt32(bytes[i + 1] & 0x3F) << 6)
                | UInt32(bytes[i + 2] & 0x3F)
        case 4:
            return (UInt32(bytes[i] & 0x07) << 18)
                | (UInt32(bytes[i + 1] & 0x3F) << 12)
                | (UInt32(bytes[i + 2] & 0x3F) << 6)
                | UInt32(bytes[i + 3] & 0x3F)
        default:
            return UInt32(bytes[i])
        }
    }

    private static func utf8EncodeScalar(_ scalar: UInt32) -> [UInt8] {
        if scalar < 0x80 {
            return [UInt8(scalar)]
        } else if scalar < 0x800 {
            return [
                UInt8(0xC0 | (scalar >> 6)),
                UInt8(0x80 | (scalar & 0x3F)),
            ]
        } else if scalar < 0x10000 {
            return [
                UInt8(0xE0 | (scalar >> 12)),
                UInt8(0x80 | ((scalar >> 6) & 0x3F)),
                UInt8(0x80 | (scalar & 0x3F)),
            ]
        } else {
            return [
                UInt8(0xF0 | (scalar >> 18)),
                UInt8(0x80 | ((scalar >> 12) & 0x3F)),
                UInt8(0x80 | ((scalar >> 6) & 0x3F)),
                UInt8(0x80 | (scalar & 0x3F)),
            ]
        }
    }

    private static func modsFromParam(_ value: UInt32) -> InputParserModifiers {
        let adjusted = value > 0 ? value - 1 : 0
        guard adjusted <= 255 else { return [] }
        return InputParserModifiers(rawValue: UInt8(adjusted))
    }

    private static func modsAndAction(_ fields: Fields) -> ModsAndAction {
        let eventType = fields.get(1, 1)
        let action: InputKeyAction
        switch eventType ?? 1 {
        case 2: action = .repeat
        case 3: action = .release
        default: action = .press
        }
        return ModsAndAction(
            mods: modsFromParam(fields.get(1, 0) ?? 1),
            action: action,
            hasEvent: eventType != nil
        )
    }

    private static func functionalKey(_ code: UInt32) -> UInt32? {
        switch code {
        case 27, 57344: return InputKeyCode.escape
        case 13, 57345: return InputKeyCode.enter
        case 9, 57346: return InputKeyCode.tab
        case 8, 127, 57347: return InputKeyCode.backspace
        case 57348...InputKeyCode.functionalLast: return code
        default: return nil
        }
    }

    private static func keypadText(_ code: UInt32) -> UInt8? {
        switch code {
        case InputKeyCode.kp0...(InputKeyCode.kp0 + 9):
            return UInt8(0x30 + (code - InputKeyCode.kp0))
        case 57409: return 0x2E // '.'
        case 57410: return 0x2F // '/'
        case 57411: return 0x2A // '*'
        case 57412: return 0x2D // '-'
        case 57413: return 0x2B // '+'
        case 57415: return 0x3D // '='
        case 57416: return 0x2C // ','
        default: return nil
        }
    }

    private static func codeKey(code: UInt32, mods: InputParserModifiers) -> DecodedKey? {
        if code < InputKeyCode.functionalFirst, let functional = functionalKey(code) {
            return DecodedKey(code: functional, mods: mods)
        }
        if code == 0 || !isScalar(code) || isControl(code) { return nil }
        return DecodedKey(
            code: code,
            mods: mods,
            flags: InputEventFlags.keyTyped,
            text: utf8EncodeScalar(code)
        )
    }

    private static func kittyKey(fields: Fields, params: ArraySlice<UInt8>) -> DecodedKey? {
        guard let code = fields.get(0, 0) else { return nil }
        let shape = modsAndAction(fields)
        var value = DecodedKey(
            code: code,
            mods: shape.mods,
            action: shape.action,
            flags: InputEventFlags.keyKitty
        )

        let paramFields = splitBytes(params, separator: 0x3B) // ';'
        if paramFields.count >= 3 {
            let scalars = splitBytes(paramFields[2], separator: 0x3A) // ':'
            for digits in scalars {
                let scalar = parseDigits(digits)
                if scalar == 0 || !isScalar(scalar) || isControl(scalar) { continue }
                value.text.append(contentsOf: utf8EncodeScalar(scalar))
            }
        }

        if code == 0 {
            return value.text.isEmpty ? nil : value
        }
        if let functional = functionalKey(code) {
            value.code = functional
            if value.text.isEmpty, let kpChar = keypadText(functional) {
                value.text.append(kpChar)
            }
            return value
        }
        if !isScalar(code) || isControl(code) { return nil }
        if let base = fields.get(0, 2), base != 0 && isScalar(base) {
            value.base = base
        }
        if value.text.isEmpty {
            var scalar = code
            if shape.mods.contains(.shift) {
                let shifted = fields.get(0, 1) ?? 0
                if shifted != 0 && isScalar(shifted) && !isControl(shifted) {
                    scalar = shifted
                } else if let uppercase = upper(code) {
                    scalar = uppercase
                }
            }
            value.text.append(contentsOf: utf8EncodeScalar(scalar))
        }
        return value
    }

    private static func tildeKey(fields: Fields) -> DecodedKey? {
        guard let number = fields.get(0, 0) else { return nil }
        let shape = modsAndAction(fields)
        let code: UInt32
        switch number {
        case 1, 7: code = InputKeyCode.home
        case 2: code = InputKeyCode.insert
        case 3: code = InputKeyCode.delete
        case 4, 8: code = InputKeyCode.end
        case 5: code = InputKeyCode.pageUp
        case 6: code = InputKeyCode.pageDown
        case 11...15: code = InputKeyCode.f(number - 10)
        case 17...21: code = InputKeyCode.f(number - 11)
        case 23...26: code = InputKeyCode.f(number - 12)
        case 28: code = InputKeyCode.f(15)
        case 29: code = InputKeyCode.menu
        case 31...34: code = InputKeyCode.f(number - 14)
        case 27:
            guard let charCode = fields.get(2, 0) else { return nil }
            return codeKey(code: charCode, mods: shape.mods)
        case InputKeyCode.kpBegin:
            code = InputKeyCode.kpBegin
        default:
            return nil
        }
        return DecodedKey(
            code: code,
            mods: shape.mods,
            action: shape.action,
            flags: shape.hasEvent ? InputEventFlags.keyKitty : 0
        )
    }

    private static func letterKey(letter: UInt8, fields: Fields) -> DecodedKey? {
        var value: DecodedKey
        switch fields.count {
        case 0:
            value = DecodedKey(code: 0)
        case 1:
            value = DecodedKey(code: 0, mods: modsFromParam(fields.get(0, 0) ?? 1))
        case 2:
            guard (fields.get(0, 0) ?? 1) == 1 else { return nil }
            let shape = modsAndAction(fields)
            value = DecodedKey(
                code: 0,
                mods: shape.mods,
                action: shape.action,
                flags: shape.hasEvent ? InputEventFlags.keyKitty : 0
            )
        default:
            return nil
        }

        switch letter {
        case 0x41, 0x61: value.code = InputKeyCode.up // 'A', 'a'
        case 0x42, 0x62: value.code = InputKeyCode.down // 'B', 'b'
        case 0x43, 0x63: value.code = InputKeyCode.right // 'C', 'c'
        case 0x44, 0x64: value.code = InputKeyCode.left // 'D', 'd'
        case 0x45, 0x65: value.code = InputKeyCode.kpBegin // 'E', 'e'
        case 0x46: value.code = InputKeyCode.end // 'F'
        case 0x48: value.code = InputKeyCode.home // 'H'
        case 0x50: value.code = InputKeyCode.f(1) // 'P'
        case 0x51: value.code = InputKeyCode.f(2) // 'Q'
        case 0x53: value.code = InputKeyCode.f(4) // 'S'
        case 0x5A: value.code = InputKeyCode.tab // 'Z'
        default: return nil
        }

        if letter == 0x5A || (letter >= 0x61 && letter <= 0x65) {
            value.mods.insert(.shift)
        }
        return value
    }

    private static func bracketKey(params: ArraySlice<UInt8>, finalByte: UInt8) -> DecodedKey? {
        if params.isEmpty && finalByte >= 0x41 && finalByte <= 0x45 {
            return DecodedKey(code: InputKeyCode.f(UInt32(finalByte - 0x41 + 1)))
        }
        if finalByte != 0x7E { return nil } // '~'
        guard let fields = Fields.parse(params) else { return nil }
        return tildeKey(fields: fields)
    }

    private static func ss3Key(finalByte: UInt8, params: ArraySlice<UInt8>) -> DecodedKey? {
        guard allDigits(params) else { return nil }
        var value = DecodedKey(
            code: 0,
            mods: modsFromParam(params.isEmpty ? 1 : parseDigits(params))
        )
        let keypad: UInt8?
        switch finalByte {
        case 0x58: keypad = 0x3D // 'X' -> '='
        case 0x6A: keypad = 0x2A // 'j' -> '*'
        case 0x6B: keypad = 0x2B // 'k' -> '+'
        case 0x6C: keypad = 0x2C // 'l' -> ','
        case 0x6D: keypad = 0x2D // 'm' -> '-'
        case 0x6E: keypad = 0x2E // 'n' -> '.'
        case 0x6F: keypad = 0x2F // 'o' -> '/'
        case 0x70...0x79: keypad = 0x30 + (finalByte - 0x70) // 'p'...'y' -> '0'...'9'
        default: keypad = nil
        }
        if let ch = keypad {
            value.code = UInt32(ch)
            value.text = [ch]
            return value
        }

        switch finalByte {
        case 0x41, 0x61: value.code = InputKeyCode.up
        case 0x42, 0x62: value.code = InputKeyCode.down
        case 0x43, 0x63: value.code = InputKeyCode.right
        case 0x44, 0x64: value.code = InputKeyCode.left
        case 0x45, 0x65: value.code = InputKeyCode.kpBegin
        case 0x46: value.code = InputKeyCode.end
        case 0x48: value.code = InputKeyCode.home
        case 0x4D: value.code = InputKeyCode.enter
        case 0x50...0x53: value.code = InputKeyCode.f(UInt32(finalByte - 0x50 + 1))
        default: return nil
        }
        if finalByte >= 0x61 && finalByte <= 0x65 {
            value.mods.insert(.ctrl)
        }
        return value
    }

    private static func mouseModifiers(_ code: UInt32) -> InputParserModifiers {
        var mods: InputParserModifiers = []
        if (code & 4) != 0 { mods.insert(.shift) }
        if (code & 8) != 0 { mods.insert(.alt) }
        if (code & 16) != 0 { mods.insert(.ctrl) }
        return mods
    }

    private static func mouseKind(code: UInt32, release: Bool, held: UInt8) -> DecodedMouse? {
        let low = code & 3
        let button: UInt32
        if (code & 128) != 0 {
            button = 8 + low
        } else if low == 3 {
            button = mouseButtonNone
        } else {
            button = low
        }

        if (code & 32) != 0 {
            if button != mouseButtonNone && (code & 64) == 0 {
                return DecodedMouse(action: .drag, button: button)
            }
            if (code & 64) != 0 && held != 0 {
                return DecodedMouse(action: .drag, button: UInt32(held.trailingZeroBitCount))
            }
            return DecodedMouse(action: .move, button: mouseButtonNone)
        }
        if (code & 64) != 0 {
            if release { return nil }
            return DecodedMouse(action: .scroll, button: low)
        }
        if button == mouseButtonNone { return nil }
        return DecodedMouse(action: release ? .up : .down, button: button)
    }

    private static func sgrMouse(params: ArraySlice<UInt8>, pressed: Bool, held: UInt8) -> DecodedMouse? {
        guard let fields = Fields.parse(params), fields.count == 3 else { return nil }
        guard let code = fields.single(0),
              let column = fields.single(1),
              let row = fields.single(2)
        else { return nil }
        guard var mouse = mouseKind(code: code, release: !pressed, held: held) else { return nil }
        mouse.mods = mouseModifiers(code)
        let adjCol = column > 0 ? column - 1 : 0
        let adjRow = row > 0 ? row - 1 : 0
        mouse.x = adjCol > UInt32(UInt16.max) ? UInt16.max : UInt16(adjCol)
        mouse.y = adjRow > UInt32(UInt16.max) ? UInt16.max : UInt16(adjRow)
        return mouse
    }

    /// Single-scalar uppercase for scripts keyboards type, matching `input-parser.zig#upper`.
    internal static func upper(_ scalar: UInt32) -> UInt32? {
        switch scalar {
        case 0x61...0x7A, 0xE0...0xF6, 0xF8...0xFE, 0x3B1...0x3C1, 0x3C3...0x3CB, 0x430...0x44F, 0xFF41...0xFF5A:
            return scalar - 32
        case 0xB5: return 0x39C
        case 0xFF: return 0x178
        case 0x131: return 0x49 // 'I'
        case 0x17F: return 0x53 // 'S'
        case 0x3AC: return 0x386
        case 0x3AD...0x3AF: return scalar - 37
        case 0x3C2: return 0x3A3
        case 0x3CC: return 0x38C
        case 0x3CD, 0x3CE: return scalar - 63
        case 0x450...0x45F: return scalar - 80
        case 0x561...0x586: return scalar - 48
        case 0x100...0x12F, 0x132...0x137, 0x14A...0x177, 0x460...0x481, 0x48A...0x4BF, 0x4D0...0x52F,
             0x1E00...0x1E95, 0x1EA0...0x1EFF:
            return (scalar & 1) == 1 ? scalar - 1 : nil
        case 0x139...0x148, 0x179...0x17E, 0x4C1...0x4CE:
            return (scalar & 1) == 0 ? scalar - 1 : nil
        default:
            return nil
        }
    }
}

// MARK: - High-Level StdinParser (core/src/lib/stdin-parser-native.ts)

/// Response protocol classification for non-key/mouse/paste terminal replies.
// parity: core/src/lib/stdin-parser-native.ts#StdinResponseProtocol [status=implemented hash=6b452df97743]
public enum StdinResponseProtocol: String, Equatable, Hashable, Sendable, Codable {
    case csi
    case cpr
    case osc
    case dcs
    case apc
    case unknown
}

/// Wire encoding used for a decoded mouse event.
public enum MouseEncoding: String, Equatable, Hashable, Sendable, Codable {
    case sgr
    case x10
}

/// Everything terminal stdin sends becomes exactly one of these events.
// parity: core/src/lib/stdin-parser-native.ts#StdinEvent [status=implemented hash=6cc5857ebdf0]
public enum StdinEvent: Equatable, Hashable, Sendable {
    case key(raw: String, key: ParsedKey)
    case mouse(raw: String, encoding: MouseEncoding, event: RawMouseEvent)
    case paste(bytes: [UInt8])
    case response(protocol: StdinResponseProtocol, sequence: String)
}

/// Active terminal protocol context informing disambiguation and reply deferral.
// parity: core/src/lib/stdin-parser-native.ts#StdinParserProtocolContext [status=implemented hash=f1b5b216d59d]
public struct StdinParserProtocolContext: Equatable, Hashable, Sendable, Codable {
    public var kittyKeyboardEnabled: Bool
    public var privateCapabilityRepliesActive: Bool
    public var pixelResolutionQueryActive: Bool
    public var explicitWidthCprActive: Bool
    public var startupCursorCprActive: Bool
    /// A query batch's DA1 reply is outstanding, so split replies wait for it without a deadline.
    public var replySentinelActive: Bool

    public init(
        kittyKeyboardEnabled: Bool = false,
        privateCapabilityRepliesActive: Bool = false,
        pixelResolutionQueryActive: Bool = false,
        explicitWidthCprActive: Bool = false,
        startupCursorCprActive: Bool = false,
        replySentinelActive: Bool = false
    ) {
        self.kittyKeyboardEnabled = kittyKeyboardEnabled
        self.privateCapabilityRepliesActive = privateCapabilityRepliesActive
        self.pixelResolutionQueryActive = pixelResolutionQueryActive
        self.explicitWidthCprActive = explicitWidthCprActive
        self.startupCursorCprActive = startupCursorCprActive
        self.replySentinelActive = replySentinelActive
    }
}

/// Configuration options for `StdinParser`.
// parity: core/src/lib/stdin-parser-native.ts#NativeStdinParserOptions [status=adapted hash=24e160ce25a0]
public struct StdinParserOptions: Equatable, Hashable, Sendable {
    public var protocolContext: StdinParserProtocolContext

    public init(protocolContext: StdinParserProtocolContext = StdinParserProtocolContext()) {
        self.protocolContext = protocolContext
    }
}

/// Pure-Swift streaming terminal stdin parser producing `StdinEvent` values from raw bytes.
// parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser [status=implemented hash=5c810fc74ffc]
public struct StdinParser: Sendable {
    private var engine: NativeInputParserEngine
    private var sink: InputParserSink
    private var events: [StdinEvent] = []
    private var readCursor: Int = 0
    public private(set) var protocolContext: StdinParserProtocolContext
    private var lastNs: UInt64 = 0
    private var pasteBuffer: [UInt8]? = nil
    private var suspended: Bool = false
    public private(set) var isDestroyed: Bool = false

    public init(options: StdinParserOptions = StdinParserOptions()) {
        self.protocolContext = options.protocolContext
        self.engine = NativeInputParserEngine(expect: Self.expectations(for: options.protocolContext))
        self.sink = InputParserSink()
    }

    /// Pending timeout deadline in nanoseconds, or `nil` when no partial unit is waiting on a timer.
    public var deadlineNs: UInt64? {
        guard !isDestroyed && !suspended else { return nil }
        return engine.deadlineNs()
    }

    /// Updates protocol expectations and re-evaluates any deferred unit.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.updateProtocolContext [status=implemented hash=8740cf767a19]
    public mutating func updateProtocolContext(_ context: StdinParserProtocolContext, nowMs: Double? = nil) {
        guard !isDestroyed else { return }
        protocolContext = context
        engine.setExpectations(Self.expectations(for: context))
        let ts = nowMs.map { toNs($0) } ?? lastNs
        feedBytes([], nowNs: ts)
    }

    /// Mutates protocol expectations in place and re-evaluates any deferred unit.
    public mutating func updateProtocolContext(nowMs: Double? = nil, _ mutate: (inout StdinParserProtocolContext) -> Void) {
        var next = protocolContext
        mutate(&next)
        updateProtocolContext(next, nowMs: nowMs)
    }

    /// Returns `true` while a bracketed paste has started and not yet ended.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.pasting [status=implemented hash=c79cbf017645]
    public var pasting: Bool {
        pasteBuffer != nil
    }

    /// Feeds raw terminal bytes into the streaming parser.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.push [status=implemented hash=a8c17cd38a54]
    public mutating func push(_ data: [UInt8], nowMs: Double? = nil) {
        guard !isDestroyed else { return }
        let ts = suspended ? lastNs : (nowMs.map { toNs($0) } ?? lastNs)
        feedBytes(data, nowNs: ts)
    }

    /// Convenience overload feeding a UTF-8 string into the streaming parser.
    public mutating func push(_ string: String, nowMs: Double? = nil) {
        push(Array(string.utf8), nowMs: nowMs)
    }

    /// Pops and returns the next buffered `StdinEvent`, or `nil` if empty.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.read [status=implemented hash=f872587a5c06]
    public mutating func read() -> StdinEvent? {
        guard !isDestroyed, readCursor < events.count else { return nil }
        let event = events[readCursor]
        readCursor += 1
        if readCursor == events.count {
            events.removeAll(keepingCapacity: true)
            readCursor = 0
        }
        return event
    }

    /// Drains all currently queued `StdinEvent` values in FIFO order.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.drain [status=implemented hash=582d3efa8b9b]
    public mutating func drain(_ onEvent: (StdinEvent) -> Void) {
        while !isDestroyed, let event = read() {
            onEvent(event)
        }
    }

    /// Resolves any partial unit whose escape/sequence timeout deadline has passed by `nowMs`.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.flushTimeout [status=implemented hash=ce1816f4e8dd]
    public mutating func flushTimeout(nowMs: Double) {
        guard !isDestroyed else { return }
        feedBytes([], nowNs: toNs(nowMs))
    }

    /// Advances the internal clock by `deltaMs` (defaulting to the 20 ms escape timeout) and flushes any expired unit.
    public mutating func advanceTimeout(byMs deltaMs: Double = 20) {
        guard !isDestroyed else { return }
        let deltaNs = UInt64(max(0.0, (deltaMs * 1_000_000.0).rounded()))
        let (next, overflow) = lastNs.addingReportingOverflow(deltaNs)
        feedBytes([], nowNs: overflow ? UInt64.max : next)
    }

    /// Freezes input time so a pending unit at suspension can still complete on resume.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.suspend [status=implemented hash=c92c67812472]
    public mutating func suspend() {
        guard !isDestroyed else { return }
        suspended = true
    }

    /// Resumes after feeding drained input; drops stale pending units except awaited reply prefixes.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.resume [status=implemented hash=5a1428796556]
    public mutating func resume() {
        guard !isDestroyed else { return }
        suspended = false
        engine.reset(keepReply: true)
        pasteBuffer = nil
    }

    /// Resets parser state and clears all queued events and active paste buffers.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.reset [status=implemented hash=af75490d0ad1]
    public mutating func reset() {
        guard !isDestroyed else { return }
        engine.reset(keepReply: false)
        events.removeAll(keepingCapacity: true)
        readCursor = 0
        pasteBuffer = nil
    }

    /// Destroys the parser and discards all buffered state.
    // parity: core/src/lib/stdin-parser-native.ts#NativeStdinParser.destroy [status=implemented hash=f69aa9b7b5ff]
    public mutating func destroy() {
        if isDestroyed { return }
        isDestroyed = true
        events.removeAll()
        readCursor = 0
        pasteBuffer = nil
    }

    // MARK: - Internal Feed & Translation

    private static func expectations(for context: StdinParserProtocolContext) -> InputParserExpectations {
        let cursorPosition = context.explicitWidthCprActive || context.startupCursorCprActive
        let replies = context.privateCapabilityRepliesActive || context.pixelResolutionQueryActive || cursorPosition
        return InputParserExpectations(
            replies: replies,
            kittyKeyboard: context.kittyKeyboardEnabled,
            cursorPosition: cursorPosition,
            sentinel: context.replySentinelActive
        )
    }

    private func toNs(_ ms: Double) -> UInt64 {
        let scaled = ms * 1_000_000.0
        let ns: UInt64
        if scaled <= 0 || scaled.isNaN {
            ns = 0
        } else if scaled >= Double(UInt64.max) {
            ns = UInt64.max
        } else {
            ns = UInt64(scaled.rounded())
        }
        return ns > lastNs ? ns : lastNs
    }

    private mutating func feedBytes(_ bytes: [UInt8], nowNs: UInt64) {
        lastNs = nowNs
        var offset = 0
        repeat {
            sink.clear()
            let slice = bytes[offset...]
            let consumed = engine.feed(slice, nowNs: nowNs, sink: &sink)
            for i in 0..<sink.count {
                translate(sink.events[i])
            }
            if consumed == 0 && sink.count == 0 && offset < bytes.count {
                break
            }
            offset += consumed
        } while offset < bytes.count
    }

    private mutating func translate(_ record: NativeInputEvent) {
        let rawSlice = sink.raw(for: record)
        let textSlice = sink.text(for: record)
        guard let kind = InputEventKind(rawValue: record.kind) else { return }

        switch kind {
        case .key:
            let key = Self.translateKey(
                code: record.code,
                baseCode: record.baseCode,
                action: InputKeyAction(rawValue: record.action) ?? .press,
                modifiers: InputParserModifiers(rawValue: record.modifiers),
                flags: record.flags,
                rawBytes: rawSlice,
                textBytes: textSlice
            )
            events.append(.key(raw: key.raw, key: key))

        case .mouse:
            let sequence = Self.decodeLatin1(rawSlice)
            let encoding: MouseEncoding = (rawSlice.count >= 3 && rawSlice[rawSlice.startIndex + 2] == 0x3C) ? .sgr : .x10
            if let action = InputMouseAction(rawValue: record.action) {
                let mouseEvent = Self.translateMouse(
                    action: action,
                    code: record.code,
                    x: Int(record.x),
                    y: Int(record.y),
                    modifiers: InputParserModifiers(rawValue: record.modifiers),
                    encoding: encoding
                )
                events.append(.mouse(raw: sequence, encoding: encoding, event: mouseEvent))
            }

        case .paste:
            if (record.flags & InputEventFlags.pasteStart) != 0 {
                pasteBuffer = []
            }
            if !textSlice.isEmpty {
                if pasteBuffer == nil {
                    pasteBuffer = []
                }
                pasteBuffer?.append(contentsOf: textSlice)
            }
            if (record.flags & InputEventFlags.pasteEnd) != 0 {
                let bytes = pasteBuffer ?? []
                pasteBuffer = nil
                events.append(.paste(bytes: bytes))
            }

        case .focus:
            events.append(.response(protocol: .csi, sequence: Self.decodeLatin1(rawSlice)))

        case .reply:
            let proto: StdinResponseProtocol
            if (record.flags & InputEventFlags.replyCursorPosition) != 0 {
                proto = .cpr
            } else if (record.flags & InputEventFlags.replyFragment) != 0 {
                proto = .unknown
            } else if let wireProto = InputProtocol(rawValue: UInt8(truncatingIfNeeded: record.code)) {
                switch wireProto {
                case .csi: proto = .csi
                case .ss3: proto = .unknown
                case .osc: proto = .osc
                case .dcs: proto = .dcs
                case .apc: proto = .apc
                }
            } else {
                proto = .unknown
            }
            events.append(.response(protocol: proto, sequence: Self.decodeLatin1(rawSlice)))
        }
    }

    private static func decodeLatin1(_ bytes: ArraySlice<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for b in bytes {
            scalars.append(Unicode.Scalar(b))
        }
        return String(scalars)
    }

    private static func keyRaw(_ raw: ArraySlice<UInt8>) -> String {
        if raw.count == 1, let first = raw.first, first >= 0x80 {
            return "\u{1B}" + String(Unicode.Scalar(first & 0x7F))
        }
        return String(decoding: raw, as: UTF8.self)
    }

    /// Matches `/^\x1b\x1b?[[O]./s`.
    private static func isLegacySequence(_ raw: String) -> Bool {
        let scalars = Array(raw.unicodeScalars)
        var i = 0
        guard i < scalars.count, scalars[i].value == 0x1B else { return false }
        i += 1
        if i < scalars.count, scalars[i].value == 0x1B {
            i += 1
        }
        guard i < scalars.count else { return false }
        let intro = scalars[i].value
        guard intro == 0x5B || intro == 0x4F else { return false } // '[' or 'O'
        return (i + 1) < scalars.count
    }

    /// Core's `code` for Kitty and legacy sequences, matching `stdin-parser-native.ts#compatCode`.
    private static func compatCode(raw: String, code: UInt32, kitty: Bool) -> String? {
        let bytes = Array(raw.utf8)
        if kitty {
            guard bytes.last == 0x75, kittyKeyMap[code] != nil else { return nil } // 'u'
            var i = 0
            while i < bytes.count, bytes[i] == 0x1B { i += 1 }
            guard i > 0, i < bytes.count, bytes[i] == 0x5B else { return nil } // '['
            i += 1
            let digitStart = i
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            guard i > digitStart else { return nil }
            let digits = String(decoding: bytes[digitStart..<i], as: UTF8.self)
            return "[\(digits)u"
        }

        // /^\x1b+(O|\[\[?)(?:(\d+)(?:;\d+)?([~^$])|(?:1;)?\d*([a-zA-Z]))/
        var i = 0
        while i < bytes.count, bytes[i] == 0x1B { i += 1 }
        guard i > 0, i < bytes.count else { return nil }

        let introducer: String
        if bytes[i] == 0x4F { // 'O'
            introducer = "O"
            i += 1
        } else if bytes[i] == 0x5B { // '['
            if i + 1 < bytes.count && bytes[i + 1] == 0x5B {
                introducer = "[["
                i += 2
            } else {
                introducer = "["
                i += 1
            }
        } else {
            return nil
        }

        let afterIntro = i

        // Branch A: (\d+)(?:;\d+)?([~^$])
        var j = afterIntro
        let numStart = j
        while j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 { j += 1 }
        if j > numStart {
            let numStr = String(decoding: bytes[numStart..<j], as: UTF8.self)
            var k = j
            if k < bytes.count && bytes[k] == 0x3B { // ';'
                let modStart = k + 1
                var m = modStart
                while m < bytes.count, bytes[m] >= 0x30, bytes[m] <= 0x39 { m += 1 }
                if m > modStart {
                    k = m
                }
            }
            if k < bytes.count {
                let f = bytes[k]
                if f == 0x7E || f == 0x5E || f == 0x24 { // '~', '^', '$'
                    return introducer + numStr + String(Unicode.Scalar(f))
                }
            }
        }

        // Branch B: (?:1;)?\d*([a-zA-Z])
        j = afterIntro
        if j + 1 < bytes.count && bytes[j] == 0x31 && bytes[j + 1] == 0x3B { // "1;"
            j += 2
        }
        while j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 { j += 1 }
        if j < bytes.count {
            let f = bytes[j]
            if (f >= 0x41 && f <= 0x5A) || (f >= 0x61 && f <= 0x7A) {
                return introducer + String(Unicode.Scalar(f))
            }
        }

        return nil
    }

    private static func translateKey(
        code: UInt32,
        baseCode: UInt32,
        action: InputKeyAction,
        modifiers: InputParserModifiers,
        flags: UInt8,
        rawBytes: ArraySlice<UInt8>,
        textBytes: ArraySlice<UInt8>
    ) -> ParsedKey {
        let kitty = (flags & InputEventFlags.keyKitty) != 0
        let raw = keyRaw(rawBytes)
        let text = textBytes.isEmpty ? "" : String(decoding: textBytes, as: UTF8.self)
        let alt = modifiers.contains(.alt)
        let isSequence = kitty || isLegacySequence(raw)
        var shift = modifiers.contains(.shift)
        var name: String

        if code == 0 {
            name = text
        } else if let mapped = kittyKeyMap[code], (flags & InputEventFlags.keyTyped) == 0 {
            if code == InputKeyCode.enter && !kitty && raw.hasSuffix("\n") {
                name = "linefeed"
            } else {
                name = mapped
            }
        } else if code == 0x20 {
            name = "space"
        } else if let scalar = Unicode.Scalar(code) {
            name = String(scalar)
            if !isSequence && code >= 0x41 && code <= 0x5A {
                shift = true
                if !alt {
                    name = String(Unicode.Scalar(code + 32)!)
                }
            }
        } else {
            name = ""
        }

        let isNumber = name.utf8.count == 1
            && name.utf8.first! >= 0x30
            && name.utf8.first! <= 0x39

        return ParsedKey(
            name: name,
            ctrl: modifiers.contains(.ctrl),
            meta: alt || modifiers.contains(.meta),
            shift: shift,
            option: alt && isSequence,
            sequence: text.isEmpty ? raw : text,
            number: isNumber,
            raw: raw,
            eventType: action == .release ? .release : .press,
            source: kitty ? .kitty : .raw,
            code: compatCode(raw: raw, code: code, kitty: kitty),
            super: modifiers.contains(.super),
            hyper: modifiers.contains(.hyper),
            capsLock: modifiers.contains(.capsLock),
            numLock: modifiers.contains(.numLock),
            baseCode: baseCode != 0 ? baseCode : nil,
            repeated: action == .repeat ? true : nil
        )
    }

    private static let scrollDirections: [ScrollDirection] = [.up, .down, .left, .right]

    private static func translateMouse(
        action: InputMouseAction,
        code: UInt32,
        x: Int,
        y: Int,
        modifiers: InputParserModifiers,
        encoding: MouseEncoding
    ) -> RawMouseEvent {
        let type: MouseEventType
        switch action {
        case .down: type = .down
        case .up: type = .up
        case .move: type = .move
        case .drag: type = .drag
        case .scroll: type = .scroll
        }

        var button = Int(code)
        if code == NativeInputParserEngine.mouseButtonNone {
            button = encoding == .x10 ? -1 : 0
        }
        if type == .scroll {
            button = (encoding == .x10 || code == 3) ? 0 : Int(code)
        }

        let scroll: ScrollInfo? = type == .scroll
            ? ScrollInfo(direction: scrollDirections[Int(code & 3)], delta: 1)
            : nil

        return RawMouseEvent(
            type: type,
            button: button,
            x: x,
            y: y,
            modifiers: MouseModifiers(
                shift: modifiers.contains(.shift),
                alt: modifiers.contains(.alt),
                ctrl: modifiers.contains(.ctrl)
            ),
            scroll: scroll
        )
    }
}
