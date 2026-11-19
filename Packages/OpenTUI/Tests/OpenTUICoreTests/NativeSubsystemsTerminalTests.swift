import Synchronization
import Testing
@testable import OpenTUICore

@Suite("NativeSubsystemsTerminal")
struct NativeSubsystemsTerminalTests {
    // MARK: - 1. NativeANSI (native/src/ansi.zig)

    @Test("NativeANSI RGBA packing, unpacking, intents, and fallback palette")
    func nativeAnsiColorHelpers() {
        #expect(NativeANSI.ANSI16_RGB.count == 16)
        #expect(NativeANSI.ANSI_256_CUBE_LEVELS == [0, 95, 135, 175, 215, 255])

        #expect(NativeANSI.rgbaComponentToU8(-0.5) == 0)
        #expect(NativeANSI.rgbaComponentToU8(0.0) == 0)
        #expect(NativeANSI.rgbaComponentToU8(0.5) == 128)
        #expect(NativeANSI.rgbaComponentToU8(1.0) == 255)
        #expect(NativeANSI.rgbaComponentToU8(1.5) == 255)
        #expect(NativeANSI.rgbaComponentToU8(.nan) == 0)
        #expect(NativeANSI.rgbaComponentToU8(.infinity) == 0)

        #expect(NativeANSI.u8ToComponent(0) == 0.0)
        #expect(NativeANSI.u8ToComponent(255) == 1.0)

        let rgb = NativeANSI.rgbColor(10, 20, 30, 200)
        #expect(NativeANSI.red(rgb) == 10)
        #expect(NativeANSI.green(rgb) == 20)
        #expect(NativeANSI.blue(rgb) == 30)
        #expect(NativeANSI.alpha(rgb) == 200)
        #expect(NativeANSI.intent(rgb) == .rgb)
        #expect(NativeANSI.slot(rgb) == 0)
        #expect(NativeANSI.rgbaToRgb24(rgb) == 0x0A141E)

        let fromF = NativeANSI.rgbaFromFloats(1.0, 0.0, 0.5, 1.0)
        #expect(NativeANSI.red(fromF) == 255)
        #expect(NativeANSI.green(fromF) == 0)
        #expect(NativeANSI.blue(fromF) == 128)
        #expect(NativeANSI.alpha(fromF) == 255)
        #expect(NativeANSI.redF(fromF) == 1.0)
        #expect(NativeANSI.greenF(fromF) == 0.0)
        #expect(NativeANSI.alphaF(fromF) == 1.0)

        let idx = NativeANSI.indexedColor(42, 0x11, 0x22, 0x33)
        #expect(NativeANSI.intent(idx) == .indexed)
        #expect(NativeANSI.slot(idx) == 42)
        #expect(NativeANSI.alpha(idx) == 255)
        #expect(NativeANSI.getMeta(idx) == NativeANSI.packMeta(intent: .indexed, slot: 42))

        let def = NativeANSI.defaultColor(255, 255, 255, 255)
        #expect(NativeANSI.intent(def) == .default)
        #expect(NativeANSI.slot(def) == 0)

        let retagged = NativeANSI.withMeta(rgb, meta: NativeANSI.packMeta(intent: .indexed, slot: 7))
        #expect(NativeANSI.intent(retagged) == .indexed)
        #expect(NativeANSI.slot(retagged) == 7)
        #expect(NativeANSI.red(retagged) == 10)

        let opaque = NativeANSI.u8RgbToRgba(1, 2, 3)
        #expect(NativeANSI.alpha(opaque) == 255)

        let c0 = NativeANSI.fallbackAnsi256Color(0)
        #expect(NativeANSI.rgbaToRgb24(c0) == 0x000000)
        let c15 = NativeANSI.fallbackAnsi256Color(15)
        #expect(NativeANSI.rgbaToRgb24(c15) == 0xFFFFFF)
        let c196 = NativeANSI.fallbackAnsi256Color(196) // cube (5,0,0) = (255,0,0)
        #expect(NativeANSI.rgbaToRgb24(c196) == 0xFF0000)
        let c232 = NativeANSI.fallbackAnsi256Color(232) // gray 8
        #expect(NativeANSI.rgbaToRgb24(c232) == 0x080808)

        let dist = NativeANSI.colorDistanceSquared(
            NativeANSI.u8RgbToRgba(10, 20, 30),
            NativeANSI.u8RgbToRgba(13, 24, 30)
        )
        #expect(dist == 25.0)

        // HSV -> RGB across sectors and negative hue wrap
        let hsvRed = NativeANSI.hsvToRgb(h: 0, s: 1, v: 1)
        #expect(NativeANSI.rgbaToRgb24(hsvRed) == 0xFF0000)
        let hsvGreen = NativeANSI.hsvToRgb(h: 120, s: 1, v: 1)
        #expect(NativeANSI.rgbaToRgb24(hsvGreen) == 0x00FF00)
        let hsvBlue = NativeANSI.hsvToRgb(h: 240, s: 1, v: 1)
        #expect(NativeANSI.rgbaToRgb24(hsvBlue) == 0x0000FF)
        let hsvWrap = NativeANSI.hsvToRgb(h: -120, s: 1, v: 1)
        #expect(NativeANSI.rgbaToRgb24(hsvWrap) == 0x0000FF)
    }

    @Test("NativeANSI writer helpers and TextAttributes bit packing")
    func nativeAnsiWritersAndAttributes() throws {
        var buf = NativeTerminalByteBuffer()
        try NativeANSI.ANSI.moveToOutput(&buf, x: 12, y: 5)
        try NativeANSI.ANSI.fgColorOutput(&buf, r: 1, g: 2, b: 3)
        try NativeANSI.ANSI.bgIndexedColorOutput(&buf, index: 196)
        try NativeANSI.ANSI.fgDefaultOutput(&buf)
        try NativeANSI.ANSI.bgDefaultOutput(&buf)
        try NativeANSI.ANSI.cursorColorOutputWriter(&buf, r: 0x0A, g: 0xB0, b: 0xFF)
        try NativeANSI.ANSI.setTerminalBgColorOutput(&buf, r: 0x10, g: 0x20, b: 0x30)
        try NativeANSI.ANSI.setMousePointerOutput(&buf, shape: "pointer")
        try NativeANSI.ANSI.setTerminalTitleOutput(&buf, title: "OpenTUI")

        let expected =
            "\u{1B}[5;12H"
            + "\u{1B}[38;2;1;2;3m"
            + "\u{1B}[48;5;196m"
            + "\u{1B}[39m"
            + "\u{1B}[49m"
            + "\u{1B}]12;#0ab0ff\u{07}"
            + "\u{1B}]11;rgb:10/20/30\u{07}"
            + "\u{1B}]22;pointer\u{1B}\\"
            + "\u{1B}]0;OpenTUI\u{07}"
        #expect(buf.string == expected)

        // OSC 66 explicit width clamps w at 7 and pads with trailing spaces
        var osc66 = NativeTerminalByteBuffer()
        try NativeANSI.ANSI.explicitWidthOutput(&osc66, width: 9, text: "X")
        #expect(osc66.string == "\u{1B}]66;w=7;X\u{1B}\\  ")

        // TextAttributes packing & emission
        let base = UInt32(NativeANSI.TextAttributes.BOLD | NativeANSI.TextAttributes.UNDERLINE)
        let withLink = NativeANSI.TextAttributes.setLinkId(base, linkId: 42)
        #expect(NativeANSI.TextAttributes.hasLink(withLink))
        #expect(NativeANSI.TextAttributes.getLinkId(withLink) == 42)
        #expect(NativeANSI.TextAttributes.getBaseAttributes(withLink) == (NativeANSI.TextAttributes.BOLD | NativeANSI.TextAttributes.UNDERLINE))

        var attrBuf = NativeTerminalByteBuffer()
        try NativeANSI.TextAttributes.applyAttributesOutputWriter(&attrBuf, attributes: withLink)
        #expect(attrBuf.string == "\u{1B}[1m\u{1B}[4m")
    }

    // MARK: - 2. NativeTerminalState (native/src/terminal.zig)

    @Test("NativeTerminalState environment overrides and capability responses")
    func nativeTerminalCapabilitiesAndEnv() throws {
        let term = NativeTerminalState(
            options: .init(
                remoteMode: .local,
                envMap: [
                    "TERM": "xterm-256color",
                    "COLORTERM": "truecolor",
                    "TERM_PROGRAM": "ghostty",
                    "TERM_PROGRAM_VERSION": "1.3.0",
                ]
            )
        )
        #expect(term.getCapabilities().rgb)
        #expect(term.getCapabilities().ansi256)
        #expect(term.getCapabilities().unicode == .unicodeWide)
        #expect(term.notificationProtocol == .osc777)
        #expect(term.getTerminalName() == "ghostty")
        #expect(term.getTerminalVersion() == "1.3.0")
        #expect(term.synchronizedOutput())

        // Query emission & capability response parsing for kitty
        let kitty = NativeTerminalState()
        var tty = NativeTerminalByteBuffer()
        try kitty.queryTerminalSend(into: &tty)
        #expect(tty.string.contains(NativeANSI.ANSI.xtversion))
        #expect(tty.string.contains(NativeANSI.ANSI.oscThemeQueries))
        #expect(tty.string.contains(NativeANSI.ANSI.primaryDeviceAttrs))

        let reply =
            "\u{1B}[?1016;2$y\u{1B}[?2027;1$y\u{1B}[?2031;2$y\u{1B}[?1004;1$y\u{1B}[?2026;2$y"
            + "\u{1B}[4;10R"
            + "\u{1B}P>|kitty(0.40.1)\u{1B}\\"
            + "\u{1B}[?0u"
            + "\u{1B}_Gi=31337;OK\u{1B}\\"
            + "\u{1B}]99;i=opentui-notifications:p=?:p=title;\u{1B}\\"
            + "\u{1B}]7501;?:states=ok\u{1B}\\"
            + "\u{1B}[?62;c"
        kitty.processCapabilityResponse(reply)

        let caps = kitty.getCapabilities()
        #expect(caps.sgrPixels)
        #expect(caps.colorSchemeUpdates)
        #expect(caps.focusTracking)
        #expect(caps.sync)
        #expect(caps.kittyKeyboard)
        #expect(caps.kittyGraphics)
        #expect(caps.explicitWidth)
        #expect(caps.scaledText)
        #expect(caps.programStatus)
        #expect(caps.rgb)
        #expect(kitty.notificationProtocol == .osc99)
        #expect(kitty.getTerminalName() == "kitty")
        #expect(kitty.getTerminalVersion() == "0.40.1")
        #expect(kitty.getCursorPosition() == .init(x: 10, y: 4, visible: true))
        #expect(kitty.refusesForcedSixel())

        // Explicit width probe pair on row 2
        let probeTerm = NativeTerminalState()
        var probeOut = NativeTerminalByteBuffer()
        try probeTerm.queryExplicitWidth(into: &probeOut)
        #expect(probeOut.string.contains(NativeANSI.ANSI.explicitWidthQuery))
        probeTerm.processCapabilityResponse("\u{1B}[2;2R\u{1B}[2;3R")
        #expect(probeTerm.getCapabilities().explicitWidth)
        #expect(probeTerm.getCapabilities().scaledText)
    }

    @Test("NativeTerminalState modes, notifications, clipboard sizing, and multiplexers")
    func nativeTerminalModesNotificationsClipboard() throws {
        let term = NativeTerminalState()
        term.replySentinel = true
        var tty = NativeTerminalByteBuffer()

        try term.enterAltScreen(into: &tty)
        #expect(term.state.altScreen)
        try term.setMouseMode(into: &tty, enable: true, enableMovement: false)
        #expect(term.state.mouse)
        #expect(tty.string.contains(NativeANSI.ANSI.disableAnyEventTracking))
        #expect(tty.string.contains(NativeANSI.ANSI.enableSGRMouseMode))

        try term.setBracketedPaste(into: &tty, enable: true)
        try term.setFocusTracking(into: &tty, enable: true)
        try term.setKittyKeyboard(into: &tty, enable: true, flags: 5)
        #expect(term.kittyQueryOutstanding())
        term.processCapabilityResponse("\u{1B}[?5u")
        #expect(!term.kittyQueryOutstanding())
        #expect(term.state.kittyConfirmed)

        // Restore modes on focus-in
        var restoreBuf = NativeTerminalByteBuffer()
        try term.restoreTerminalModes(into: &restoreBuf)
        #expect(restoreBuf.string.contains(NativeANSI.ANSI.enableMouseTracking))
        #expect(restoreBuf.string.contains(NativeANSI.ANSI.focusSet))
        #expect(restoreBuf.string.contains(NativeANSI.ANSI.bracketedPasteSet))
        #expect(restoreBuf.string.contains(NativeANSI.ANSI.csiUPop))

        // Reset input/output modes
        var resetBuf = NativeTerminalByteBuffer()
        try term.resetInputModes(into: &resetBuf)
        try term.resetOutputModes(into: &resetBuf)
        try term.exitAltScreen(into: &resetBuf)
        #expect(!term.state.altScreen)
        #expect(!term.state.mouse)
        #expect(!term.state.kittyKeyboard)

        // Cursor & pointer accessors
        term.setCursorPosition(x: 0, y: 0, visible: false)
        #expect(term.getCursorPosition() == .init(x: 1, y: 1, visible: false))
        term.setCursorStyle(.line, blinking: true)
        #expect(term.getCursorStyle() == .init(style: .line, blinking: true))
        let red = NativeANSI.rgbColor(255, 0, 0, 255)
        term.setCursorColor(red)
        #expect(term.getCursorColor() == red)
        term.setMousePointerStyle(.neswResize)
        #expect(term.getMousePointer() == .neswResize)
        #expect(term.getMousePointer().toName() == "nesw-resize")

        // Notifications: OSC 9 digit guard + OSC 777 + OSC 99 + tmux passthrough
        let osc9Term = NativeTerminalState()
        osc9Term.setHostEnvVar(key: "OPENTUI_NOTIFICATION_PROTOCOL", value: "osc9")
        var nBuf = NativeTerminalByteBuffer()
        let wrote9 = try osc9Term.writeNotification(into: &nBuf, message: "100% done")
        #expect(wrote9)
        #expect(nBuf.string == "\u{1B}]9; 100% done\u{1B}\\")

        // tmux passthrough + clipboardSequenceSize exactness
        let tmuxTerm = NativeTerminalState()
        tmuxTerm.processCapabilityResponse("\u{1B}P>|tmux 3.6a\u{1B}\\")
        #expect(tmuxTerm.isXtversionTmux())
        #expect(tmuxTerm.isInTmux())
        #expect(tmuxTerm.getCapabilities().unicode == .unicode)

        let payload = Array("hello clipboard".utf8)
        let expectedSize = try tmuxTerm.clipboardSequenceSize(payloadLen: payload.count)
        var clipBuf = NativeTerminalByteBuffer()
        try tmuxTerm.writeClipboardSequence(into: &clipBuf, target: .clipboard, payloadBytes: payload)
        #expect(clipBuf.bytes.count == expectedSize)

        // GNU screen chunked passthrough size exactness
        let screenTerm = NativeTerminalState(options: .init(envMap: ["STY": "1234.pts-0"]))
        #expect(screenTerm.isInScreen())
        let largePayload = Array(repeating: UInt8(ascii: "A"), count: 300)
        let expectedScreenSize = try screenTerm.clipboardSequenceSize(payloadLen: largePayload.count)
        var screenClipBuf = NativeTerminalByteBuffer()
        try screenTerm.writeClipboardSequence(into: &screenClipBuf, target: .clipboard, payloadBytes: largePayload)
        #expect(screenClipBuf.bytes.count == expectedScreenSize)

        // Payload overflow check
        #expect(throws: NativeTerminalClipboardError.clipboardPayloadTooLarge) {
            _ = try screenTerm.clipboardSequenceSize(payloadLen: NativeTerminalState.CLIPBOARD_PAYLOAD_SIZE_MAX + 1)
        }

        // Flush input portable hook
        let flushed = Mutex(false)
        NativeTerminalState.setFlushInputHook { flushed.withLock { $0 = true } }
        NativeTerminalState.flushInput()
        NativeTerminalState.setFlushInputHook(nil)
        #expect(flushed.withLock { $0 })
    }

    // MARK: - 3. NativeBufferBridge (native/src/buffer.zig)

    @Test("NativeBufferBridge validation, leases, snapshot resolution, and quadrants")
    func nativeBufferBridgeOperations() throws {
        // Color & text validation
        try NativeBufferBridge.validateColor(NativeANSI.rgbColor(1, 2, 3, 255))
        try NativeBufferBridge.validateColor(NativeANSI.indexedColor(12, 1, 2, 3))
        try NativeBufferBridge.validateColor(NativeANSI.defaultColor(0, 0, 0, 255))
        let badMetaColor = NativeANSI.packRGBA8(r: 1, g: 2, b: 3, a: 255, meta: 0x00FF_0001)
        #expect(throws: NativeBufferBridge.ColorValidationError.invalidOptions) {
            try NativeBufferBridge.validateColor(badMetaColor)
        }

        try NativeBufferBridge.validateTextInput("Hello 🌍")
        #expect(throws: NativeBufferBridge.TextValidationError.invalidUnicode) {
            try NativeBufferBridge.validateTextInput([0xFF, 0xFE])
        }
        #expect(throws: NativeBufferBridge.TextValidationError.textLimit) {
            try NativeBufferBridge.validateTextInput(Array(repeating: UInt8(ascii: "a"), count: NativeBufferBridge.textBytesMax + 1))
        }

        // Vec3f / Vec4f / BorderSides / rgbaEqual
        let v3 = NativeBufferBridge.Vec3f(1, 2, 3) + NativeBufferBridge.Vec3f(4, 5, 6)
        #expect(v3 == NativeBufferBridge.Vec3f(5, 7, 9))
        let v4 = NativeBufferBridge.Vec4f(1, 2, 3, 4) * 2
        #expect(v4 == NativeBufferBridge.Vec4f(2, 4, 6, 8))
        let sides = NativeBufferBridge.BorderSides(top: true, right: false, bottom: true, left: true)
        #expect(sides.packedBits == 0b1101)
        #expect(sides.toBorderSidesConfig() == BorderSidesConfig(top: true, right: false, bottom: true, left: true))
        #expect(NativeBufferBridge.rgbaEqual(NativeANSI.u8RgbToRgba(9, 8, 7), NativeANSI.rgbColor(9, 8, 7, 255)))

        // OptimizedBuffer + BufferLease + BufferSnapshot
        let buf = try NativeBufferBridge.OptimizedBuffer(width: 4, height: 2)
        buf.drawText("Hi", x: 0, y: 0, fg: NativeANSI.u8RgbToRgba(255, 255, 255))
        buf.setCell(x: 0, y: 1, cell: .init(char: packImageCell(id: 1, fallback: 3)))

        var leaseCount: UInt32 = 0
        var leaseBytes: UInt64 = 0
        var lease = try NativeBufferBridge.BufferLease.acquireChecked(
            target: buf,
            count: &leaseCount,
            bytes: &leaseBytes
        )
        #expect(leaseCount == 1)
        #expect(leaseBytes > 0)
        #expect(lease.isCurrent())

        let snap = try lease.snapshot()
        let size = try snap.getRealCharSize(addLineBreaks: true)
        var resolved = Array(repeating: UInt8(0), count: Int(size))
        var cellLengths = Array(repeating: UInt8(0), count: 8)
        let written = try snap.writeResolvedCells(into: &resolved, addLineBreaks: true, cellLengths: &cellLengths)
        #expect(written == size)
        let resolvedStr = String(decoding: resolved, as: UTF8.self)
        #expect(resolvedStr == "Hi  \n▄   \n")
        #expect(cellLengths[0] == 1)
        #expect(cellLengths[4] == 3) // UTF-8 length of U+2584 '▄'

        // Resizing while leased retires old storage and makes lease stale
        try buf.resize(width: 5, height: 2)
        #expect(!lease.isCurrent())
        #expect(throws: NativeBufferBridge.LeaseError.staleLease) {
            _ = try lease.snapshot()
        }
        lease.releaseChecked(count: &leaseCount, bytes: &leaseBytes)
        #expect(leaseCount == 0)
        #expect(leaseBytes == 0)

        // Quadrant rendering
        #expect(NativeBufferBridge.quadrantChars.count == 16)
        let black = NativeANSI.u8RgbToRgba(0, 0, 0)
        let white = NativeANSI.u8RgbToRgba(255, 255, 255)
        let topHalf = NativeBufferBridge.QuadrantResult.renderQuadrantBlock([black, black, white, white])
        #expect(topHalf.char == 0x2580) // Upper Half Block ▀
        #expect(topHalf.fg == black)
        #expect(topHalf.bg == white)
    }

    // MARK: - 4 & 5. NativeRendererOutput + NativeRendererBridge (renderer-output.zig & renderer.zig)

    @Test("NativeRendererOutput UTF-16 chunking, StdoutOutput, and FeedBackend with uploads")
    func nativeRendererOutputAndFeedBackend() throws {
        let sample = Array("Aé東😀".utf8)
        let expectedPrefixLens = [0, 1, 1, 3, 3, 3, 6, 6, 6, 6, 10]
        for (end, expectedLen) in expectedPrefixLens.enumerated() {
            #expect(NativeRendererOutput.completeUtf8Prefix(Array(sample[0..<end])).count == expectedLen)
        }

        // Surrogate pair never split across a 2-unit UTF-16 output buffer
        let emojiInput = Array("A😀B".utf8)
        let first = try NativeRendererOutput.utf8ToUtf16Chunk(outputCapacity: 2, input: emojiInput)
        #expect(first.chunk == .init(inputLen: 1, outputLen: 1))
        #expect(first.units == [UInt16(UInt8(ascii: "A"))])
        let second = try NativeRendererOutput.utf8ToUtf16Chunk(outputCapacity: 2, input: Array(emojiInput[1...]))
        #expect(second.chunk == .init(inputLen: 4, outputLen: 2))
        #expect(second.units == [0xD83D, 0xDE00])

        #expect(throws: NativeRendererOutput.OutputError.invalidUtf8) {
            _ = try NativeRendererOutput.utf8ToUtf16Chunk(outputCapacity: 8, input: [0xF0, 0x9F])
        }

        let stdout = NativeRendererOutput.StdoutOutput(windowsConsole: true)
        #expect(stdout.supportsDirectWrite())
        let consumed = try stdout.writeSome("A😀")
        #expect(consumed == 5)
        #expect(stdout.capturedUtf16Units == [0x0041, 0xD83D, 0xDE00])

        // FeedBackend bridging NativeSpanFeed + image upload trimming
        let feed = NativeSpanFeed.create(
            NativeSpanFeedOptions(chunkSize: 32, initialChunks: 1, maxBytes: 32, growthPolicy: .block)
        )
        var received: [[UInt8]] = []
        _ = feed.onData { received.append($0) }

        let backend = NativeRendererOutput.FeedBackend(feed: feed)
        #expect(backend.prepareFrame() == .ok)
        backend.beginFrame()
        try backend.frameWrite("HEAD")
        backend.beginUpload(waited: false)
        try backend.frameWrite(Array(repeating: UInt8(ascii: "U"), count: 16))
        backend.endUpload(placementId: 7)
        backend.beginUpload(waited: false)
        try backend.frameWrite(Array(repeating: UInt8(ascii: "V"), count: 24)) // exceeds 32-byte limit -> trimmed/cut
        backend.endUpload(placementId: 8)
        #expect(backend.lastUploadWaits())
        try backend.frameWrite("TAIL")
        #expect(backend.endFrame() == .ok)
        #expect(received.count == 1)
        #expect(String(decoding: received[0], as: UTF8.self) == "HEAD" + String(repeating: "U", count: 16) + "TAIL")
        #expect(backend.uploads.count == 2)
        #expect(backend.uploads[0].state == .kept)
        #expect(backend.uploads[1].state == .deferred)
    }

    @Test("NativeRendererBridge end-to-end AnsiDiffRenderer + NativeTerminalState + FeedBackend")
    func nativeRendererBridgeEndToEnd() throws {
        let terminal = NativeTerminalState(
            options: .init(envMap: ["COLORTERM": "truecolor", "TERM": "xterm-256color"])
        )
        terminal.setCursorPosition(x: 3, y: 2, visible: true)
        terminal.setCursorStyle(.underline, blinking: true)

        let renderer = AnsiDiffRenderer(width: 8, height: 2)
        NativeRendererBridge.applyTerminalState(terminal, to: renderer)
        #expect(renderer.capabilities.rgb)
        #expect(renderer.cursorState.x == 3)
        #expect(renderer.cursorState.y == 2)
        #expect(renderer.cursorState.style == .underline)
        #expect(renderer.cursorState.blinking)

        renderer.nextBuffer.drawText("OK", x: 0, y: 0, fg: NativeANSI.u8RgbToRgba(0, 255, 0))

        let feed = NativeSpanFeed.create()
        var frames: [String] = []
        _ = feed.onData { frames.append(String(decoding: $0, as: UTF8.self)) }
        let backend = NativeRendererBridge.FeedBackend(feed: feed)

        let status = NativeRendererBridge.renderFrame(renderer: renderer, backend: backend, force: true)
        #expect(status == .rendered)
        #expect(frames.count == 1)
        #expect(frames[0].contains("OK"))

        let statsSnapshot = NativeRendererBridge.RenderStatsSnapshot(from: renderer.stats, lastFrameTime: 1.5)
        #expect(statsSnapshot.frameCount == 1)
        #expect(statsSnapshot.cellsUpdated > 0)
        #expect(statsSnapshot.toNativeRenderStats().nativeFrameCount == 1)

        // FrameWork merge + SplitFooterTransition + SplitRender
        let sceneWork = NativeRendererBridge.FrameWork(
            workFrameId: 1,
            paintVisits: 10,
            fullPathReasons: NativeRendererBridge.FrameWork.fullPathForced
        )
        let encodeWork = NativeRendererBridge.FrameWork(
            rowsCompared: 2,
            rowsDiffed: 1,
            fullPathReasons: NativeRendererBridge.FrameWork.fullPathImages,
            damageRows: 1
        )
        let merged = sceneWork.merge(encodeWork)
        #expect(merged.paintVisits == 10)
        #expect(merged.rowsCompared == 2)
        #expect(merged.fullPathReasons == (NativeRendererBridge.FrameWork.fullPathForced | NativeRendererBridge.FrameWork.fullPathImages))

        var transition = NativeRendererBridge.SplitFooterTransition(
            mode: .viewportScroll,
            sourceTopLine: 5,
            sourceHeight: 3,
            targetTopLine: 4,
            targetHeight: 4,
            scrollLines: 1
        )
        transition.clear()
        #expect(transition.mode == .none)
        #expect(transition.scrollLines == 0)

        let splitSnap = NativeRendererBridge.SplitSnapshot(snapshot: renderer.currentBuffer, rowColumns: 8)
        let splitRender = NativeRendererBridge.SplitRender(snapshots: [splitSnap], pinnedRenderOffset: 2)
        #expect(splitRender.snapshots.count == 1)
        #expect(splitRender.pinnedRenderOffset == 2)
    }
}
