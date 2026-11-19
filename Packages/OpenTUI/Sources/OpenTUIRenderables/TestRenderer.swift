import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout

// MARK: - KeyCodes & MockInput (core/src/testing/mock-keys.ts)

/// Converts UTF-8 string into raw paste bytes, matching `testing/mock-keys.ts#pasteBytes`.
public func pasteBytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

/// Standard ANSI/VT key escape sequences for headless keyboard input simulation.
public enum KeyCodes {
    public static let `return` = "\r"
    public static let linefeed = "\n"
    public static let tab = "\t"
    public static let backspace = "\u{08}"
    public static let delete = "\u{1B}[3~"
    public static let home = "\u{1B}[H"
    public static let end = "\u{1B}[F"
    public static let escape = "\u{1B}"

    public static let arrowUp = "\u{1B}[A"
    public static let arrowDown = "\u{1B}[B"
    public static let arrowRight = "\u{1B}[C"
    public static let arrowLeft = "\u{1B}[D"

    public static let f1 = "\u{1B}OP"
    public static let f2 = "\u{1B}OQ"
    public static let f3 = "\u{1B}OR"
    public static let f4 = "\u{1B}OS"
    public static let f5 = "\u{1B}[15~"
    public static let f6 = "\u{1B}[17~"
    public static let f7 = "\u{1B}[18~"
    public static let f8 = "\u{1B}[19~"
    public static let f9 = "\u{1B}[20~"
    public static let f10 = "\u{1B}[21~"
    public static let f11 = "\u{1B}[23~"
    public static let f12 = "\u{1B}[24~"

    fileprivate static let namedValues: [String: String] = [
        "RETURN": `return`,
        "LINEFEED": linefeed,
        "TAB": tab,
        "BACKSPACE": backspace,
        "DELETE": delete,
        "HOME": home,
        "END": end,
        "ESCAPE": escape,
        "ARROW_UP": arrowUp,
        "ARROW_DOWN": arrowDown,
        "ARROW_RIGHT": arrowRight,
        "ARROW_LEFT": arrowLeft,
        "F1": f1,
        "F2": f2,
        "F3": f3,
        "F4": f4,
        "F5": f5,
        "F6": f6,
        "F7": f7,
        "F8": f8,
        "F9": f9,
        "F10": f10,
        "F11": f11,
        "F12": f12,
    ]
}

/// Modifier flags accepted by `MockInput.pressKey` and convenience key methods.
public struct MockKeyModifiers: Equatable, Hashable, Sendable {
    public var shift: Bool
    public var ctrl: Bool
    public var meta: Bool
    public var `super`: Bool
    public var hyper: Bool

    public init(
        shift: Bool = false,
        ctrl: Bool = false,
        meta: Bool = false,
        `super`: Bool = false,
        hyper: Bool = false
    ) {
        self.shift = shift
        self.ctrl = ctrl
        self.meta = meta
        self.`super` = `super`
        self.hyper = hyper
    }

    public var hasAny: Bool {
        shift || ctrl || meta || `super` || hyper
    }

    fileprivate var bitMask: Int {
        var mask = 0
        if shift { mask |= 1 }
        if meta { mask |= 2 }
        if ctrl { mask |= 4 }
        if `super` { mask |= 8 }
        if hyper { mask |= 16 }
        return mask
    }
}

public struct MockKeysOptions: Equatable, Hashable, Sendable {
    public var kittyKeyboard: Bool
    public var otherModifiersMode: Bool

    public init(kittyKeyboard: Bool = false, otherModifiersMode: Bool = false) {
        self.kittyKeyboard = kittyKeyboard
        self.otherModifiersMode = otherModifiersMode
    }
}

/// Deterministic keyboard input driver feeding ANSI, Kitty, and modifyOtherKeys sequences
/// directly into a `CliRenderer`, matching `core/src/testing/mock-keys.ts`.
public final class MockInput: @unchecked Sendable {
    private static let kittyKeyCodeByName: [String: UInt32] = {
        var map: [String: UInt32] = [:]
        // Prefer the lower legacy codepoint when a key name appears twice (escape, return, tab, backspace).
        for (code, name) in kittyKeyMap.sorted(by: { $0.key > $1.key }) {
            map[name] = code
        }
        return map
    }()

    private static let valueToKittyName: [String: String] = [
        "\u{08}": "backspace",
        "\r": "return",
        "\n": "return",
        "\t": "tab",
        "\u{1B}": "escape",
        "\u{1B}[A": "up",
        "\u{1B}[B": "down",
        "\u{1B}[C": "right",
        "\u{1B}[D": "left",
        "\u{1B}[H": "home",
        "\u{1B}[F": "end",
        "\u{1B}[3~": "delete",
    ]

    private static let valueToModifyOtherKeysCode: [String: UInt32] = [
        "\u{08}": 127,
        "\r": 13,
        "\n": 13,
        "\t": 9,
        "\u{1B}": 27,
        " ": 32,
    ]

    private static let specialCtrlMap: [Character: String] = [
        "[": "\u{1B}",
        "\\": "\u{1C}",
        "]": "\u{1D}",
        "^": "\u{1E}",
        "_": "\u{1F}",
        "?": "\u{7F}",
        "/": "\u{1F}",
        "-": "\u{1F}",
        ".": "\u{1E}",
        ",": "\u{1C}",
        "@": "\u{00}",
        " ": "\u{00}",
    ]

    private unowned let renderer: CliRenderer
    private let useKittyKeyboard: Bool
    private let effectiveOtherModifiersMode: Bool

    public init(renderer: CliRenderer, options: MockKeysOptions = MockKeysOptions()) {
        self.renderer = renderer
        self.useKittyKeyboard = options.kittyKeyboard
        self.effectiveOtherModifiersMode = options.otherModifiersMode && !options.kittyKeyboard
    }

    private func resolveKeyInput(_ key: String) -> (keyValue: String, keyName: String?) {
        if let mapped = KeyCodes.namedValues[key] {
            return (mapped, key.lowercased())
        }
        return (key, nil)
    }

    private func encodeKittySequence(codepoint: UInt32, modifiers: MockKeyModifiers?) -> String {
        let modMask = modifiers?.bitMask ?? 0
        if modMask == 0 {
            return "\u{1B}[\(codepoint)u"
        }
        return "\u{1B}[\(codepoint);\(modMask + 1)u"
    }

    private func encodeModifyOtherKeysSequence(charCode: UInt32, modifiers: MockKeyModifiers?) -> String {
        let modMask = modifiers?.bitMask ?? 0
        if modMask == 0 {
            if let scalar = Unicode.Scalar(charCode) {
                return String(scalar)
            }
            return ""
        }
        return "\u{1B}[27;\(modMask + 1);\(charCode)~"
    }

    public func pressKey(_ key: String, modifiers: MockKeyModifiers? = nil) {
        if useKittyKeyboard {
            var (keyValue, keyName) = resolveKeyInput(key)
            if let mapped = Self.valueToKittyName[keyValue] {
                keyName = mapped
            }
            if let name = keyName, name.hasPrefix("arrow_") {
                keyName = String(name.dropFirst(6))
            }
            if let name = keyName, let kittyCode = Self.kittyKeyCodeByName[name] {
                renderer.feedInput(encodeKittySequence(codepoint: kittyCode, modifiers: modifiers))
                return
            }
            if keyValue.unicodeScalars.count == 1,
               let first = keyValue.unicodeScalars.first,
               first.value != 0x1B
            {
                renderer.feedInput(encodeKittySequence(codepoint: first.value, modifiers: modifiers))
                return
            }
        }

        if effectiveOtherModifiersMode, let modifiers, modifiers.hasAny {
            let (keyValue, _) = resolveKeyInput(key)
            var charCode: UInt32? = Self.valueToModifyOtherKeysCode[keyValue]
            if charCode == nil,
               keyValue.unicodeScalars.count == 1,
               let first = keyValue.unicodeScalars.first,
               first.value != 0x1B
            {
                charCode = first.value
            }
            if let code = charCode {
                renderer.feedInput(encodeModifyOtherKeysSequence(charCode: code, modifiers: modifiers))
                return
            }
        }

        var keyCode = resolveKeyInput(key).keyValue
        if let modifiers, modifiers.hasAny {
            if keyCode.hasPrefix("\u{1B}[") && keyCode.count > 2 {
                let modifier = 1 + modifiers.bitMask
                if modifier > 1 {
                    let inner = keyCode.dropFirst(2)
                    if inner.hasSuffix("~") {
                        let digits = inner.dropLast()
                        if !digits.isEmpty && digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                            keyCode = "\u{1B}[\(digits);\(modifier)~"
                        }
                    } else if let ending = keyCode.last {
                        keyCode = "\u{1B}[1;\(modifier)\(ending)"
                    }
                }
            } else if keyCode.unicodeScalars.count == 1, let ch = keyCode.first {
                if ch == "\t" && modifiers.shift {
                    keyCode = modifiers.meta ? "\u{1B}\u{1B}[Z" : "\u{1B}[Z"
                    renderer.feedInput(keyCode)
                    return
                }

                if ch == "\u{08}" && (modifiers.ctrl || modifiers.`super` || modifiers.hyper) {
                    let modifier = 1 + modifiers.bitMask
                    keyCode = "\u{1B}[27;\(modifier);127~"
                } else if modifiers.ctrl {
                    let scalar = ch.unicodeScalars.first!.value
                    if scalar >= 0x61 && scalar <= 0x7A { // 'a'...'z'
                        keyCode = String(Unicode.Scalar(scalar - 96)!)
                    } else if scalar >= 0x41 && scalar <= 0x5A { // 'A'...'Z'
                        keyCode = String(Unicode.Scalar(scalar - 64)!)
                    } else if let mapped = Self.specialCtrlMap[ch] {
                        keyCode = mapped
                    }
                    if modifiers.meta {
                        keyCode = "\u{1B}\(keyCode)"
                    }
                } else {
                    var str = keyCode
                    if modifiers.shift, let scalar = str.unicodeScalars.first?.value, scalar >= 0x61 && scalar <= 0x7A {
                        str = String(Unicode.Scalar(scalar - 32)!)
                    }
                    keyCode = modifiers.meta ? "\u{1B}\(str)" : str
                }
            } else if modifiers.meta && !keyCode.hasPrefix("\u{1B}") {
                keyCode = "\u{1B}\(keyCode)"
            }
        }

        renderer.feedInput(keyCode)
    }

    public func pressKeys(_ keys: [String]) {
        for key in keys {
            let resolved = resolveKeyInput(key).keyValue
            renderer.feedInput(resolved)
        }
    }

    public func typeText(_ text: String) {
        for ch in text {
            renderer.feedInput(String(ch))
        }
    }

    public func pressEnter(modifiers: MockKeyModifiers? = nil) {
        pressKey(KeyCodes.return, modifiers: modifiers)
    }

    public func pressReturn(modifiers: MockKeyModifiers? = nil) {
        pressKey(KeyCodes.return, modifiers: modifiers)
    }

    public func pressEscape(modifiers: MockKeyModifiers? = nil) {
        pressKey(KeyCodes.escape, modifiers: modifiers)
    }

    public func pressTab(modifiers: MockKeyModifiers? = nil) {
        pressKey(KeyCodes.tab, modifiers: modifiers)
    }

    public func pressBackspace(modifiers: MockKeyModifiers? = nil) {
        pressKey(KeyCodes.backspace, modifiers: modifiers)
    }

    public func pressArrow(_ direction: ScrollDirection, modifiers: MockKeyModifiers? = nil) {
        switch direction {
        case .up: pressKey(KeyCodes.arrowUp, modifiers: modifiers)
        case .down: pressKey(KeyCodes.arrowDown, modifiers: modifiers)
        case .left: pressKey(KeyCodes.arrowLeft, modifiers: modifiers)
        case .right: pressKey(KeyCodes.arrowRight, modifiers: modifiers)
        }
    }

    public func pressCtrlC() {
        pressKey("c", modifiers: MockKeyModifiers(ctrl: true))
    }

    public func pasteBracketedText(_ text: String) {
        pressKeys([ANSI.bracketedPasteStart, text, ANSI.bracketedPasteEnd])
    }

    /// Advances the renderer's `ManualClock` (if used) past the 20ms escape disambiguation window
    /// and flushes any pending ESC key.
    public func flushTimeouts() {
        if let manualClock = renderer.clock as? ManualClock {
            manualClock.advance(by: 25)
        } else {
            renderer.flushInputTimeout()
        }
    }
}

// MARK: - MockMouse (core/src/testing/mock-mouse.ts)

public enum MockMouseButtons {
    public static let left: Int = 0
    public static let middle: Int = 1
    public static let right: Int = 2
    public static let wheelUp: Int = 64
    public static let wheelDown: Int = 65
    public static let wheelLeft: Int = 66
    public static let wheelRight: Int = 67
}

public enum MockMouseAction: String, Equatable, Hashable, Sendable {
    case down
    case up
    case move
    case drag
    case scroll
}

/// Deterministic SGR mouse driver feeding `\x1b[<b;x;yM/m` sequences into `CliRenderer`,
/// matching `core/src/testing/mock-mouse.ts`.
public final class MockMouse: @unchecked Sendable {
    private unowned let renderer: CliRenderer
    private var currentPosition: (x: Int, y: Int) = (0, 0)
    private var pressedButtonsOrder: [Int] = []

    public init(renderer: CliRenderer) {
        self.renderer = renderer
    }

    public func generateMouseSequence(
        type: MockMouseAction,
        x: Int,
        y: Int,
        button: Int = MockMouseButtons.left,
        modifiers: MouseModifiers = MouseModifiers()
    ) -> String {
        var buttonCode = button
        switch type {
        case .move:
            buttonCode = 32 | 3
        case .drag:
            let held = pressedButtonsOrder.first ?? button
            buttonCode = held | 32
        case .down, .up, .scroll:
            break
        }

        if modifiers.shift { buttonCode |= 4 }
        if modifiers.alt { buttonCode |= 8 }
        if modifiers.ctrl { buttonCode |= 16 }

        let ansiX = x + 1
        let ansiY = y + 1
        let suffix: String
        switch type {
        case .up, .move, .drag:
            suffix = "m"
        case .down, .scroll:
            suffix = "M"
        }

        return "\u{1B}[<\(buttonCode);\(ansiX);\(ansiY)\(suffix)"
    }

    public func emitMouseEvent(
        type: MockMouseAction,
        x: Int,
        y: Int,
        button: Int = MockMouseButtons.left,
        modifiers: MouseModifiers = MouseModifiers(),
        delayMs: Double = 0
    ) {
        let sequence = generateMouseSequence(type: type, x: x, y: y, button: button, modifiers: modifiers)
        renderer.feedInput(sequence)
        currentPosition = (x: x, y: y)

        if type == .down && button < 64 {
            if !pressedButtonsOrder.contains(button) {
                pressedButtonsOrder.append(button)
            }
        } else if type == .up {
            pressedButtonsOrder.removeAll { $0 == button }
        }

        if delayMs > 0, let manualClock = renderer.clock as? ManualClock {
            manualClock.advance(by: delayMs)
        }
    }

    public func moveTo(
        x: Int,
        y: Int,
        button: Int = MockMouseButtons.left,
        modifiers: MouseModifiers = MouseModifiers(),
        delayMs: Double = 0
    ) {
        if let held = pressedButtonsOrder.first {
            emitMouseEvent(type: .drag, x: x, y: y, button: held, modifiers: modifiers, delayMs: delayMs)
        } else {
            emitMouseEvent(type: .move, x: x, y: y, button: button, modifiers: modifiers, delayMs: delayMs)
        }
    }

    public func pressDown(
        x: Int,
        y: Int,
        button: Int = MockMouseButtons.left,
        modifiers: MouseModifiers = MouseModifiers(),
        delayMs: Double = 0
    ) {
        emitMouseEvent(type: .down, x: x, y: y, button: button, modifiers: modifiers, delayMs: delayMs)
    }

    public func release(
        x: Int,
        y: Int,
        button: Int = MockMouseButtons.left,
        modifiers: MouseModifiers = MouseModifiers(),
        delayMs: Double = 0
    ) {
        emitMouseEvent(type: .up, x: x, y: y, button: button, modifiers: modifiers, delayMs: delayMs)
    }

    public func click(
        x: Int,
        y: Int,
        button: Int = MockMouseButtons.left,
        modifiers: MouseModifiers = MouseModifiers(),
        delayMs: Double = 10
    ) {
        emitMouseEvent(type: .down, x: x, y: y, button: button, modifiers: modifiers, delayMs: delayMs)
        emitMouseEvent(type: .up, x: x, y: y, button: button, modifiers: modifiers, delayMs: 0)
    }

    public func doubleClick(
        x: Int,
        y: Int,
        button: Int = MockMouseButtons.left,
        modifiers: MouseModifiers = MouseModifiers(),
        delayMs: Double = 10
    ) {
        click(x: x, y: y, button: button, modifiers: modifiers, delayMs: delayMs)
        if delayMs > 0, let manualClock = renderer.clock as? ManualClock {
            manualClock.advance(by: delayMs)
        }
        click(x: x, y: y, button: button, modifiers: modifiers, delayMs: delayMs)
    }

    public func drag(
        startX: Int,
        startY: Int,
        endX: Int,
        endY: Int,
        button: Int = MockMouseButtons.left,
        modifiers: MouseModifiers = MouseModifiers(),
        steps: Int = 5,
        delayMs: Double = 10
    ) {
        pressDown(x: startX, y: startY, button: button, modifiers: modifiers)
        let stepCount = max(1, steps)
        let dx = Double(endX - startX) / Double(stepCount)
        let dy = Double(endY - startY) / Double(stepCount)

        for i in 1...stepCount {
            let cx = Int((Double(startX) + dx * Double(i)).rounded(.toNearestOrAwayFromZero))
            let cy = Int((Double(startY) + dy * Double(i)).rounded(.toNearestOrAwayFromZero))
            emitMouseEvent(type: .drag, x: cx, y: cy, button: button, modifiers: modifiers, delayMs: delayMs)
        }

        release(x: endX, y: endY, button: button, modifiers: modifiers)
    }

    public func scroll(
        x: Int,
        y: Int,
        direction: ScrollDirection,
        modifiers: MouseModifiers = MouseModifiers(),
        delayMs: Double = 0
    ) {
        let button: Int
        switch direction {
        case .up: button = MockMouseButtons.wheelUp
        case .down: button = MockMouseButtons.wheelDown
        case .left: button = MockMouseButtons.wheelLeft
        case .right: button = MockMouseButtons.wheelRight
        }
        emitMouseEvent(type: .scroll, x: x, y: y, button: button, modifiers: modifiers, delayMs: delayMs)
    }

    public func getCurrentPosition() -> (x: Int, y: Int) {
        currentPosition
    }

    public func getPressedButtons() -> [Int] {
        pressedButtonsOrder
    }
}

// MARK: - TestRecorder (core/src/testing/test-recorder.ts)

public struct RecordBuffersOptions: Equatable, Hashable, Sendable {
    public var fg: Bool
    public var bg: Bool
    public var attributes: Bool

    public init(fg: Bool = false, bg: Bool = false, attributes: Bool = false) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }
}

public struct RecordedBuffers: Equatable, Sendable {
    public var fg: [RGBA]?
    public var bg: [RGBA]?
    public var attributes: [UInt32]?

    public init(fg: [RGBA]? = nil, bg: [RGBA]? = nil, attributes: [UInt32]? = nil) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }
}

public struct RecordedFrame: Equatable, Sendable {
    public var frame: String
    public var timestamp: Double
    public var frameNumber: Int
    public var buffers: RecordedBuffers?

    public init(frame: String, timestamp: Double, frameNumber: Int, buffers: RecordedBuffers? = nil) {
        self.frame = frame
        self.timestamp = timestamp
        self.frameNumber = frameNumber
        self.buffers = buffers
    }
}

/// Captures character frame history (and optional buffer snapshots) on each `CliRenderer` frame event,
/// matching `core/src/testing/test-recorder.ts`.
public final class TestRecorder: @unchecked Sendable {
    private unowned let renderer: CliRenderer
    private let recordBuffers: RecordBuffersOptions
    private let nowProvider: () -> Double

    private var frames: [RecordedFrame] = []
    private var recording: Bool = false
    private var frameNumber: Int = 0
    private var startTime: Double = 0
    private var frameListenerToken: CliRendererListenerToken? = nil

    public init(
        renderer: CliRenderer,
        recordBuffers: RecordBuffersOptions = RecordBuffersOptions(),
        now: (() -> Double)? = nil
    ) {
        self.renderer = renderer
        self.recordBuffers = recordBuffers
        self.nowProvider = now ?? { [weak renderer] in renderer?.clock.now() ?? 0 }
    }

    public func rec() {
        guard !recording else { return }
        recording = true
        frames.removeAll()
        frameNumber = 0
        startTime = nowProvider()
        frameListenerToken = renderer.onFrame { [weak self] _ in
            guard let self, self.recording else { return }
            self.captureFrame()
        }
    }

    public func stop() {
        guard recording else { return }
        recording = false
        if let token = frameListenerToken {
            renderer.off(token)
            frameListenerToken = nil
        }
    }

    public var recordedFrames: [RecordedFrame] {
        frames
    }

    public func clear() {
        frames.removeAll()
        frameNumber = 0
    }

    public var isRecording: Bool {
        recording
    }

    private func captureFrame() {
        let buffer = renderer.currentRenderBuffer
        let frame = renderer.captureCharFrame()
        var buffers: RecordedBuffers? = nil
        if recordBuffers.fg || recordBuffers.bg || recordBuffers.attributes {
            buffers = RecordedBuffers(
                fg: recordBuffers.fg ? buffer.fg : nil,
                bg: recordBuffers.bg ? buffer.bg : nil,
                attributes: recordBuffers.attributes ? buffer.attributes : nil
            )
        }
        let recorded = RecordedFrame(
            frame: frame,
            timestamp: nowProvider() - startTime,
            frameNumber: frameNumber,
            buffers: buffers
        )
        frameNumber += 1
        frames.append(recorded)
    }
}

// MARK: - TestRenderer (core/src/testing/test-renderer.ts & harness.ts)

public struct TestRendererOptions {
    public var width: Int
    public var height: Int
    public var kittyKeyboard: Bool
    public var otherModifiersMode: Bool
    public var screenMode: ScreenMode
    public var footerHeight: Int
    public var backgroundColor: RGBA
    public var useMouse: Bool
    public var autoFocus: Bool
    public var exitOnCtrlC: Bool
    public var widthMethod: WidthMethod
    public var rendererCapabilities: RendererCapabilities
    public var clock: ManualClock?
    public var debounceDelay: Double

    public init(
        width: Int = 80,
        height: Int = 24,
        kittyKeyboard: Bool = false,
        otherModifiersMode: Bool = false,
        screenMode: ScreenMode = .mainScreen,
        footerHeight: Int = 12,
        backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0),
        useMouse: Bool = true,
        autoFocus: Bool = true,
        exitOnCtrlC: Bool = false,
        widthMethod: WidthMethod = .unicode,
        rendererCapabilities: RendererCapabilities = RendererCapabilities(),
        clock: ManualClock? = nil,
        debounceDelay: Double = 100
    ) {
        self.width = width
        self.height = height
        self.kittyKeyboard = kittyKeyboard
        self.otherModifiersMode = otherModifiersMode
        self.screenMode = screenMode
        self.footerHeight = footerHeight
        self.backgroundColor = backgroundColor
        self.useMouse = useMouse
        self.autoFocus = autoFocus
        self.exitOnCtrlC = exitOnCtrlC
        self.widthMethod = widthMethod
        self.rendererCapabilities = rendererCapabilities
        self.clock = clock
        self.debounceDelay = debounceDelay
    }
}

/// Headless deterministic test harness wrapping `CliRenderer`, `ManualClock`, `MockInput`,
/// `MockMouse`, `TestRecorder`, and captured ANSI output log.
public final class TestRenderer: @unchecked Sendable {
    public let renderer: CliRenderer
    public let clock: ManualClock
    public let mockInput: MockInput
    public let mockMouse: MockMouse
    public let recorder: TestRecorder

    public private(set) var outputLog: [String] = []

    public var root: RootRenderable { renderer.root }
    public var combinedOutput: String { outputLog.joined() }

    public init(options: TestRendererOptions = TestRendererOptions()) {
        let manualClock = options.clock ?? ManualClock()
        self.clock = manualClock

        let kittyConfig: KittyKeyboardOptions? = options.kittyKeyboard
            ? KittyKeyboardOptions(events: true)
            : nil

        let cliConfig = CliRendererConfig(
            width: options.width,
            height: options.height,
            screenMode: options.screenMode,
            footerHeight: options.footerHeight,
            externalOutputMode: .passthrough,
            consoleMode: .disabled,
            exitOnCtrlC: options.exitOnCtrlC,
            debounceDelay: options.debounceDelay,
            useMouse: options.useMouse,
            autoFocus: options.autoFocus,
            useKittyKeyboard: kittyConfig,
            backgroundColor: options.backgroundColor,
            widthMethod: options.widthMethod,
            rendererCapabilities: options.rendererCapabilities,
            clock: manualClock
        )

        self.renderer = CliRenderer(config: cliConfig)
        self.mockInput = MockInput(
            renderer: self.renderer,
            options: MockKeysOptions(
                kittyKeyboard: options.kittyKeyboard,
                otherModifiersMode: options.otherModifiersMode
            )
        )
        self.mockMouse = MockMouse(renderer: self.renderer)
        self.recorder = TestRecorder(renderer: self.renderer)

        self.renderer.outputWriter = { [weak self] chunk in
            self?.outputLog.append(chunk)
        }
    }

    public func clearOutputLog() {
        outputLog.removeAll()
    }

    public func renderOnce(force: Bool = false) {
        renderer.renderOnce(force: force)
    }

    public func captureCharFrame() -> String {
        renderer.captureCharFrame()
    }

    public func captureSpans() -> CapturedFrame {
        renderer.captureSpans()
    }

    public func resize(width: Int, height: Int) {
        renderer.resize(width: width, height: height)
    }

    public func advanceClock(by ms: Double) {
        clock.advance(by: ms)
    }

    public func destroy() {
        recorder.stop()
        renderer.destroy()
    }
}

/// Factory function matching upstream `createTestRenderer`.
public func createTestRenderer(options: TestRendererOptions = TestRendererOptions()) -> TestRenderer {
    TestRenderer(options: options)
}

/// Convenience factory matching `createTestRenderer(width:height:...)`.
public func createTestRenderer(
    width: Int = 80,
    height: Int = 24,
    kittyKeyboard: Bool = false,
    otherModifiersMode: Bool = false,
    screenMode: ScreenMode = .mainScreen,
    backgroundColor: RGBA = RGBA.fromInts(0, 0, 0, 0),
    useMouse: Bool = true,
    autoFocus: Bool = true,
    exitOnCtrlC: Bool = false,
    clock: ManualClock? = nil
) -> TestRenderer {
    TestRenderer(
        options: TestRendererOptions(
            width: width,
            height: height,
            kittyKeyboard: kittyKeyboard,
            otherModifiersMode: otherModifiersMode,
            screenMode: screenMode,
            backgroundColor: backgroundColor,
            useMouse: useMouse,
            autoFocus: autoFocus,
            exitOnCtrlC: exitOnCtrlC,
            clock: clock
        )
    )
}
