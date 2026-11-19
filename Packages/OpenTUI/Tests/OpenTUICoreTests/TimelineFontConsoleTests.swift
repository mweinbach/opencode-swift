import Testing
import OpenTUICore

// MARK: - Helpers

private func approx(_ a: Double, _ b: Double, tol: Double = 1e-12) -> Bool {
    abs(a - b) <= tol
}

private func rowText(in buffer: OptimizedBuffer, y: Int, xRange: Range<Int>? = nil) -> String {
    let range = xRange ?? (0..<buffer.width)
    var out = ""
    for x in range {
        guard let cell = buffer.cell(atX: x, y: y) else { continue }
        if let scalar = Unicode.Scalar(cell.scalar) {
            out.unicodeScalars.append(scalar)
        } else {
            out.append(" ")
        }
    }
    return out
}

private final class MockTimelineRenderer: TimelineRendererHost {
    var isDestroyed: Bool = false
    var targetFps: Double = 60.0
    var liveRequests: Int = 0
    var liveDrops: Int = 0
    var frameCallbacks: [ObjectIdentifier: (Double) -> Void] = [:]
    var tickCallbacks: [(fps: Double, active: Bool, callback: (Double) -> Void)] = []

    func requestLive() {
        liveRequests += 1
    }

    func dropLive() {
        liveDrops += 1
    }

    func setFrameCallback(_ id: ObjectIdentifier, callback: @escaping (Double) -> Void) {
        frameCallbacks[id] = callback
    }

    func removeFrameCallback(_ id: ObjectIdentifier) {
        frameCallbacks.removeValue(forKey: id)
    }

    func hasFrameCallback(_ id: ObjectIdentifier) -> Bool {
        frameCallbacks[id] != nil
    }

    func onAnimationTick(fps: Double, callback: @escaping (Double) -> Void) -> () -> Void {
        let index = tickCallbacks.count
        tickCallbacks.append((fps: fps, active: true, callback: callback))
        return { [weak self] in
            guard let self, index < self.tickCallbacks.count else { return }
            self.tickCallbacks[index].active = false
        }
    }

    func stepFrame(_ deltaTime: Double) {
        for cb in frameCallbacks.values {
            cb(deltaTime)
        }
    }

    func stepActiveTicks(_ deltaTime: Double) {
        for entry in tickCallbacks where entry.active {
            entry.callback(deltaTime)
        }
    }
}

// MARK: - Timeline Tests

@Suite("Timeline")
struct TimelineTests {
    @Test("All 31 easing curves satisfy boundary and analytic identities")
    func easingLibraryAccuracy() {
        #expect(EasingName.allCases.count == 31)

        for curve in EasingName.allCases {
            #expect(approx(curve.evaluate(0.0), 0.0, tol: 1e-12), "Expected \(curve)(0) == 0")
            #expect(approx(curve.evaluate(1.0), 1.0, tol: 1e-12), "Expected \(curve)(1) == 1")
            #expect(approx(curve.function(0.5), curve.evaluate(0.5), tol: 1e-15))
        }

        // Exact analytic identities validating pure-Swift sin/cos/exp2/sqrt
        let invSqrt2 = 1.0 / 2.0.squareRoot()
        #expect(approx(EasingName.linear.evaluate(0.37), 0.37))
        #expect(approx(EasingName.inQuad.evaluate(0.5), 0.25))
        #expect(approx(EasingName.outQuad.evaluate(0.5), 0.75))
        #expect(approx(EasingName.inOutQuad.evaluate(0.5), 0.5))
        #expect(approx(EasingName.inCubic.evaluate(0.5), 0.125))
        #expect(approx(EasingName.outCubic.evaluate(0.5), 0.875))
        #expect(approx(EasingName.inOutCubic.evaluate(0.5), 0.5))
        #expect(approx(EasingName.inQuart.evaluate(0.5), 0.0625))
        #expect(approx(EasingName.outQuart.evaluate(0.5), 0.9375))
        #expect(approx(EasingName.inOutQuart.evaluate(0.5), 0.5))
        #expect(approx(EasingName.inQuint.evaluate(0.5), 0.03125))
        #expect(approx(EasingName.outQuint.evaluate(0.5), 0.96875))
        #expect(approx(EasingName.inOutQuint.evaluate(0.5), 0.5))
        #expect(approx(EasingName.inSine.evaluate(0.5), 1.0 - invSqrt2, tol: 1e-14))
        #expect(approx(EasingName.outSine.evaluate(0.5), invSqrt2, tol: 1e-14))
        #expect(approx(EasingName.inOutSine.evaluate(0.5), 0.5, tol: 1e-14))
        #expect(approx(EasingName.inExpo.evaluate(0.5), 0.03125, tol: 1e-14))
        #expect(approx(EasingName.outExpo.evaluate(0.5), 0.96875, tol: 1e-14))
        #expect(approx(EasingName.inOutExpo.evaluate(0.5), 0.5, tol: 1e-14))
        #expect(approx(EasingName.inCirc.evaluate(0.5), 1.0 - 0.75.squareRoot(), tol: 1e-14))
        #expect(approx(EasingName.outCirc.evaluate(0.5), 0.75.squareRoot(), tol: 1e-14))
        #expect(approx(EasingName.inOutCirc.evaluate(0.5), 0.5, tol: 1e-14))

        // Back curves overshoot / undershoot
        #expect(EasingName.inBack.evaluate(0.3) < 0.0)
        #expect(EasingName.outBack.evaluate(0.7) > 1.0)
        #expect(approx(EasingName.inOutBack.evaluate(0.5), 0.5, tol: 1e-12))

        // Elastic curves oscillate beyond [0, 1] (first peak at t=0.15, trough at t=0.30)
        #expect(EasingName.inElastic.evaluate(0.85) < 0.0)
        #expect(approx(EasingName.inElastic.evaluate(0.7), 0.125, tol: 1e-12))
        #expect(EasingName.outElastic.evaluate(0.15) > 1.0)
        #expect(approx(EasingName.outElastic.evaluate(0.3), 0.875, tol: 1e-12))
        #expect(approx(EasingName.inOutElastic.evaluate(0.5), 0.5, tol: 1e-12))

        // Bounce curves
        #expect(approx(EasingName.inOutBounce.evaluate(0.5), 0.5, tol: 1e-12))
        #expect(EasingName.outBounce.evaluate(0.5) > 0.7)
        #expect(EasingName.inBounce.evaluate(0.5) < 0.3)
    }

    @Test("Numeric and RGBA interpolation, delay, and lifecycle callbacks")
    func numericAndColorAnimation() {
        let state = AnimationState(
            ["x": 10.0, "y": 100.0],
            colors: ["bg": RGBA.fromInts(255, 0, 0, 255)]
        )

        var started = 0
        var updates = 0
        var completed = 0
        var paused = 0
        var lastProgress = -1.0

        let timeline = Timeline(options: TimelineOptions(duration: 500, autoplay: false))
        timeline.add(
            state,
            options: AnimationOptions(
                duration: 200,
                delay: 50,
                ease: .linear,
                properties: ["x": 110.0, "y": 200.0],
                colorProperties: ["bg": RGBA.fromInts(0, 0, 255, 55)],
                onUpdate: { anim in
                    updates += 1
                    lastProgress = anim.progress
                },
                onComplete: { completed += 1 },
                onStart: { started += 1 },
                onPause: { paused += 1 }
            ),
            startTime: 50
        )

        timeline.play()

        // Before startTime + delay = 100ms
        timeline.update(deltaTime: 80)
        #expect(started == 0)
        #expect(approx(state["x"] ?? 0, 10.0))

        // Midpoint at t = 200ms (100ms into 200ms animation)
        timeline.update(deltaTime: 120)
        #expect(started == 1)
        #expect(updates == 1)
        #expect(approx(lastProgress, 0.5))
        #expect(approx(state["x"] ?? 0, 60.0))
        #expect(approx(state["y"] ?? 0, 150.0))

        let midColor = state[color: "bg"]
        #expect(midColor != nil)
        if let mid = midColor {
            let (r, g, b, a) = mid.toInts()
            #expect(abs(Int(r) - 128) <= 1)
            #expect(g == 0)
            #expect(abs(Int(b) - 128) <= 1)
            #expect(abs(Int(a) - 155) <= 1)
        }

        // Pause triggers item onPause
        timeline.pause()
        #expect(paused == 1)
        timeline.update(deltaTime: 50)
        #expect(approx(state["x"] ?? 0, 60.0))

        // Resume and finish animation at t = 300ms
        timeline.play()
        timeline.update(deltaTime: 100)
        #expect(completed == 1)
        #expect(approx(state["x"] ?? 0, 110.0))
        #expect(approx(state["y"] ?? 0, 200.0))
        #expect(state[color: "bg"] == RGBA.fromInts(0, 0, 255, 55))
    }

    @Test("Looping, alternate reversal, loopDelay, once removal, and callbacks")
    func loopingAlternateAndOnce() {
        let state = AnimationState(["v": 0.0])
        var loopCount = 0
        var animCompleted = 0
        var callbackHits = 0

        let timeline = Timeline(options: TimelineOptions(duration: 1000, autoplay: false))
        timeline.add(
            state,
            options: AnimationOptions(
                duration: 100,
                ease: .linear,
                properties: ["v": 100.0],
                onComplete: { animCompleted += 1 },
                onLoop: { loopCount += 1 },
                loop: 3,
                loopDelay: 50,
                alternate: true
            ),
            startTime: 0
        )
        timeline.call({ callbackHits += 1 }, startTime: 200)
        timeline.play()

        // Cycle 0 forward at 50ms -> v = 50
        timeline.update(deltaTime: 50)
        #expect(approx(state["v"] ?? -1, 50.0))

        // Cycle 0 loopDelay hold at 120ms -> v = 100
        timeline.update(deltaTime: 70)
        #expect(approx(state["v"] ?? -1, 100.0))

        // Cycle 1 reversed at 200ms (50ms into second cycle) -> v = 50, onLoop fired once
        timeline.update(deltaTime: 80)
        #expect(loopCount == 1)
        #expect(callbackHits == 1)
        #expect(approx(state["v"] ?? -1, 50.0))

        // Once animation added at currentTime (200ms), duration 50ms
        let temp = AnimationState(["n": 0.0])
        timeline.once(temp, options: AnimationOptions(duration: 50, properties: ["n": 10.0]))
        #expect(timeline.itemCount == 3)

        // Advance past once animation completion (t = 260ms)
        timeline.update(deltaTime: 60)
        #expect(approx(temp["n"] ?? -1, 10.0))
        #expect(timeline.itemCount == 2) // once item removed

        // Advance to end of cycle 2 (cycle 2 starts at 300ms, finishes at 400ms)
        timeline.update(deltaTime: 140)
        #expect(loopCount == 2)
        #expect(animCompleted == 1)
        #expect(approx(state["v"] ?? -1, 100.0))

        // Restart resets callback and animation
        timeline.restart()
        #expect(timeline.currentTime == 0.0)
        timeline.update(deltaTime: 200)
        #expect(callbackHits == 2)
    }

    @Test("Synced sub-timelines, timeline looping, and engine lifecycle")
    func syncedSubTimelinesAndEngine() throws {
        let childState = AnimationState(["x": 0.0])
        let child = Timeline(options: TimelineOptions(duration: 100, autoplay: false))
        child.add(childState, options: AnimationOptions(duration: 100, properties: ["x": 50.0]))

        let parent = Timeline(options: TimelineOptions(duration: 300, autoplay: false))
        try parent.sync(child, startTime: 50)
        #expect(child.synced)

        // Syncing twice must throw
        #expect(throws: TimelineError.alreadySynced) {
            try parent.sync(child, startTime: 0)
        }

        parent.play()
        parent.update(deltaTime: 100) // 50ms overshoot into child
        #expect(approx(childState["x"] ?? -1, 25.0))
        parent.update(deltaTime: 50)
        #expect(approx(childState["x"] ?? -1, 50.0))
        #expect(child.isComplete)

        // Invalid frameRate throws
        #expect(throws: TimelineError.invalidFrameRate(0)) {
            try parent.setFrameRate(0)
        }

        // TimelineEngine attach/register/pause/resume/clear/destroy
        let renderer = MockTimelineRenderer()
        let ownedEngine = try getTimelineEngine(renderer)
        let tl = createTimeline(options: TimelineOptions(duration: 200, loop: true), renderer: renderer)
        let box = AnimationState(["pos": 0.0])
        tl.add(box, options: AnimationOptions(duration: 200, properties: ["pos": 100.0]))

        #expect(ownedEngine.count == 1)
        #expect(renderer.liveRequests == 1)

        renderer.stepFrame(100)
        #expect(approx(box["pos"] ?? -1, 50.0))

        ownedEngine.pause()
        #expect(ownedEngine.isPaused)
        renderer.stepFrame(50)
        #expect(approx(box["pos"] ?? -1, 50.0))

        ownedEngine.resume()
        #expect(!ownedEngine.isPaused)
        renderer.stepFrame(150) // loops past 200ms with 50ms overshoot -> 25
        #expect(approx(box["pos"] ?? -1, 25.0))

        destroyTimelineEngine(renderer)
        #expect(ownedEngine.count == 0)
        #expect(renderer.frameCallbacks.isEmpty)
    }
}

// MARK: - ASCIIFont Tests

@Suite("ASCIIFont")
struct ASCIIFontTests {
    @Test("All 7 embedded fonts match upstream metadata and character counts")
    func allSevenFontsLoaded() {
        let expectedHeights: [ASCIIFontName: Int] = [
            .tiny: 2,
            .block: 6,
            .shade: 8,
            .slick: 6,
            .huge: 11,
            .grid: 6,
            .pallet: 6,
        ]

        #expect(asciiFonts.count == 7)
        for (name, height) in expectedHeights {
            let def = ASCIIFont.definition(for: name)
            #expect(def.name == name.rawValue)
            #expect(def.lines == height)
            #expect(def.chars.count == 57)
            #expect(def.chars["A"]?.count == height)
            #expect(def.chars[" "] != nil)
        }
    }

    @Test("Color tag parsing splits <c1>/<c2> and plain runs accurately")
    func colorTagParsing() {
        let segments = parseASCIIFontColorTags(" <c1>█████</c1><c2>╗</c2> tail")
        #expect(segments.count == 4)
        #expect(segments[0] == ASCIIFontSegment(text: " ", colorIndex: 0))
        #expect(segments[1] == ASCIIFontSegment(text: "█████", colorIndex: 0))
        #expect(segments[2] == ASCIIFontSegment(text: "╗", colorIndex: 1))
        #expect(segments[3] == ASCIIFontSegment(text: " tail", colorIndex: 0))
    }

    @Test("Measurement, character positions, and coordinate hit-testing")
    func measurementAndHitTesting() {
        // In tiny: H=3, I=1, letterspace=1 -> "HI" width = 3 + 1 + 1 = 5, height = 2
        let hiMeasure = measureAsciiText("hi", font: .tiny)
        #expect(hiMeasure == ASCIIFontMeasurement(width: 5, height: 2))
        #expect(ASCIIFont.measureText("HI", font: .tiny) == hiMeasure)

        let positions = getCharacterPositions("HI", font: .tiny)
        #expect(positions == [0, 4, 5])

        // Hit-testing around character midpoints
        #expect(coordinateToCharacterIndex(-3, text: "HI", font: .tiny) == 0)
        #expect(coordinateToCharacterIndex(0, text: "HI", font: .tiny) == 0)
        #expect(coordinateToCharacterIndex(1, text: "HI", font: .tiny) == 0)
        #expect(coordinateToCharacterIndex(2, text: "HI", font: .tiny) == 1)
        #expect(coordinateToCharacterIndex(4, text: "HI", font: .tiny) == 1)
        #expect(coordinateToCharacterIndex(5, text: "HI", font: .tiny) == 2)
        #expect(coordinateToCharacterIndex(20, text: "HI", font: .tiny) == 2)

        // Multi-color block font "A" width = 8, height = 6
        let blockA = measureAsciiText("A", font: .block)
        #expect(blockA == ASCIIFontMeasurement(width: 8, height: 6))

        // Huge font height = 11
        #expect(measureAsciiText("OPENTUI", font: .huge).height == 11)
    }

    @Test("renderFontToFrameBuffer renders glyphs, multi-color <c1>/<c2>, and alignment")
    func renderIntoOptimizedBuffer() {
        let buffer = OptimizedBuffer(width: 30, height: 10)
        buffer.clear(bg: RGBA.fromInts(0, 0, 0, 255))

        let c1 = RGBA.fromInts(255, 0, 0, 255)
        let c2 = RGBA.fromInts(0, 255, 0, 255)
        let bg = RGBA.fromInts(10, 10, 10, 255)

        let measured = renderFontToFrameBuffer(
            buffer,
            text: "A",
            x: 2,
            y: 1,
            colors: [c1, c2],
            backgroundColor: bg,
            font: .block
        )
        #expect(measured == ASCIIFontMeasurement(width: 8, height: 6))

        // Row 0 of block "A" is: " <c1>█████</c1><c2>╗</c2> "
        // x=2 is space (not drawn), x=3..7 is █ in c1, x=8 is ╗ in c2
        let blockCell = buffer.cell(atX: 3, y: 1)
        #expect(blockCell?.scalar == Unicode.Scalar("█").value)
        #expect(blockCell?.foreground == c1)
        #expect(blockCell?.background == bg)

        let shadowCell = buffer.cell(atX: 8, y: 1)
        #expect(shadowCell?.scalar == Unicode.Scalar("╗").value)
        #expect(shadowCell?.foreground == c2)

        // Center alignment check with tiny font ("I" has width 1, height 2)
        let alignBuf = OptimizedBuffer(width: 11, height: 4)
        alignBuf.clear(bg: RGBA.fromInts(0, 0, 0, 255))
        renderFontToFrameBuffer(
            alignBuf,
            text: "I",
            x: 0,
            y: 1,
            colors: [c1],
            backgroundColor: bg,
            font: .tiny,
            alignment: .center
        )
        // (11 - 1) / 2 = 5
        #expect(alignBuf.cell(atX: 5, y: 1)?.scalar == Unicode.Scalar("█").value)
        #expect(alignBuf.cell(atX: 5, y: 2)?.scalar == Unicode.Scalar("█").value)
        #expect(alignBuf.cell(atX: 0, y: 1)?.scalar == defaultSpaceChar)

        // Right alignment check
        alignBuf.clear(bg: RGBA.fromInts(0, 0, 0, 255))
        renderFontToFrameBuffer(
            alignBuf,
            text: "I",
            x: 0,
            y: 0,
            colors: [c2],
            backgroundColor: bg,
            font: .tiny,
            alignment: .right
        )
        #expect(alignBuf.cell(atX: 10, y: 0)?.scalar == Unicode.Scalar("█").value)
    }
}

// MARK: - Console Tests

@Suite("Console")
struct ConsoleTests {
    @Test("Positions, size clamping, visibility lifecycle, and cache draining")
    func positionsLifecycleAndCaching() {
        let console = TerminalConsole(
            width: 80,
            height: 20,
            options: ConsoleOptions(
                position: .bottom,
                sizePercent: 50,
                timestampProvider: { "12:34:56" }
            )
        )

        #expect(!console.visible)
        #expect(!console.isFocused)
        #expect(console.bounds == ConsoleBounds(x: 0, y: 10, width: 80, height: 10))

        console.activate()
        #expect(console.isActive)

        // Log while hidden -> cached
        console.log("first message")
        console.warn("second warning")
        #expect(console.logCount == 2)
        #expect(console.getCachedLogsAsString().contains("[12:34:56] [LOG] first message"))
        #expect(console.getCachedLogsAsString().contains("[12:34:56] [WARN] second warning"))

        // Show drains cache and focuses console
        console.show()
        #expect(console.visible)
        #expect(console.isFocused)
        #expect(console.entries.count == 2)
        #expect(console.displayLines.count == 2)

        // Toggle while focused hides; toggle while hidden shows
        console.toggle()
        #expect(!console.visible)
        console.toggle()
        #expect(console.visible)
        #expect(console.isFocused)

        // Blur then toggle re-focuses without hiding
        console.blur()
        #expect(!console.isFocused)
        console.toggle()
        #expect(console.visible)
        #expect(console.isFocused)

        // Position changes
        console.setPosition(.top)
        #expect(console.bounds == ConsoleBounds(x: 0, y: 0, width: 80, height: 10))
        console.setPosition(.left)
        #expect(console.bounds == ConsoleBounds(x: 0, y: 0, width: 40, height: 20))
        console.setPosition(.right)
        #expect(console.bounds == ConsoleBounds(x: 40, y: 0, width: 40, height: 20))

        // Size clamping
        console.setSizePercent(5)
        #expect(console.sizePercent == 10)
        console.setSizePercent(150)
        #expect(console.sizePercent == 100)

        console.deactivate()
        #expect(!console.isActive)
        console.destroy()
        #expect(!console.visible)
    }

    @Test("Ring-buffer eviction, scrolling, keybindings, selection, and copy")
    func ringBufferScrollingKeysAndSelection() {
        var copiedText = ""
        var savedText = ""

        let console = TerminalConsole(
            width: 60,
            height: 20,
            options: ConsoleOptions(
                position: .bottom,
                sizePercent: 30, // height = 6, bordered logAreaHeight = 4
                maxStoredLogs: 10,
                onCopySelection: { copiedText = $0 },
                timestampProvider: { "00:00:01" }
            ),
            onSaveLogs: { savedText = $0 }
        )

        console.show()
        for i in 1...15 {
            console.info("line \(i)")
        }

        // Ring buffer retains latest 10 entries
        #expect(console.entries.count == 10)
        #expect(console.entries.first?.message == "line 6")
        #expect(console.entries.last?.message == "line 15")

        // Scrolled to bottom initially
        let bottomOffset = console.scrollOffset
        #expect(bottomOffset > 0)

        // Scroll to top via Home key
        let homeKey = ParsedKey(name: "home", sequence: "", raw: "")
        #expect(console.handleKeyPress(homeKey))
        #expect(console.scrollOffset == 0)

        // Page down & scroll delta
        let pgDown = ParsedKey(name: "pagedown", sequence: "", raw: "")
        #expect(console.handleKeyPress(pgDown))
        #expect(console.scrollOffset > 0)

        console.scroll(delta: -2)
        let afterUp = console.scrollOffset
        console.scroll(delta: 2)
        #expect(console.scrollOffset >= afterUp)

        // End key jumps back to bottom
        let endKey = ParsedKey(name: "end", sequence: "", raw: "")
        #expect(console.handleKeyPress(endKey))
        #expect(console.scrollOffset == bottomOffset)

        // Position cycling via ctrl+o / ctrl+p
        #expect(console.position == .bottom)
        #expect(console.handleKeyPress(ParsedKey(name: "o", ctrl: true, sequence: "", raw: "")))
        #expect(console.position == .left)
        #expect(console.handleKeyPress(ParsedKey(name: "p", ctrl: true, sequence: "", raw: "")))
        #expect(console.position == .bottom)

        // Save logs via ctrl+s
        #expect(console.handleKeyPress(ParsedKey(name: "s", ctrl: true, sequence: "", raw: "")))
        #expect(savedText.contains("line 15"))

        // Selection and copy via ctrl+shift+c
        console.select(startLine: 0, startCol: 0, endLine: 0, endCol: 17)
        #expect(console.hasSelection)
        #expect(console.handleKeyPress(ParsedKey(name: "c", ctrl: true, shift: true, sequence: "", raw: "")))
        #expect(copiedText == "[00:00:01] [INFO]")
        #expect(!console.hasSelection)

        // Clear via ctrl+l
        #expect(console.handleKeyPress(ParsedKey(name: "l", ctrl: true, sequence: "", raw: "")))
        #expect(console.entries.isEmpty)
        #expect(console.displayLines.isEmpty)

        // Escape blurs
        #expect(console.isFocused)
        #expect(console.handleKeyPress(ParsedKey(name: "escape", sequence: "\u{1B}", raw: "\u{1B}")))
        #expect(!console.isFocused)
    }

    @Test("Mouse selection, wheel scroll, and bordered rendering into OptimizedBuffer")
    func mouseAndBufferRendering() {
        var copied = ""
        let errorColor = parseColor("#FF0000")
        let infoColor = parseColor("#00FFFF")

        let console = TerminalConsole(
            width: 50,
            height: 12,
            options: ConsoleOptions(
                position: .bottom,
                sizePercent: 50, // y = 6, height = 6, width = 50
                colorInfo: infoColor,
                colorError: errorColor,
                backgroundColor: RGBA.fromInts(20, 20, 20, 255),
                showBorder: true,
                title: "Debug",
                onCopySelection: { copied = $0 },
                timestampProvider: { "01:02:03" }
            )
        )

        let screen = OptimizedBuffer(width: 50, height: 12)
        screen.clear(bg: RGBA.fromInts(0, 0, 0, 255))

        // Hidden console renders nothing
        console.render(into: screen)
        #expect(screen.cell(atX: 0, y: 6)?.scalar == defaultSpaceChar)

        console.show()
        console.info("hello world")
        console.error("boom\u{07}")

        console.render(into: screen)

        // Top border corner at (0, 6) and title bar text on row 6
        #expect(screen.cell(atX: 0, y: 6)?.scalar == BorderCharArrays.single[BorderCharIndex.topLeft.rawValue])
        #expect(screen.cell(atX: 49, y: 6)?.scalar == BorderCharArrays.single[BorderCharIndex.topRight.rawValue])
        #expect(screen.cell(atX: 0, y: 11)?.scalar == BorderCharArrays.single[BorderCharIndex.bottomLeft.rawValue])

        let headerRow = rowText(in: screen, y: 6)
        #expect(headerRow.contains("Debug (Focused)"))
        #expect(headerRow.contains("[Copy"))

        // First log line at row 7 (info, with cursor `>`) and second at row 8 (error)
        let line1 = rowText(in: screen, y: 7)
        let line2 = rowText(in: screen, y: 8)
        #expect(line1.contains("hello world"))
        #expect(line2.contains("boom\\x07"))
        #expect(screen.cell(atX: 1, y: 7)?.scalar == Unicode.Scalar(">").value)
        #expect(screen.cell(atX: 2, y: 7)?.foreground == infoColor)
        #expect(screen.cell(atX: 2, y: 8)?.foreground == errorColor)

        // Pressing down moves the cursor marker `>` to row 8
        #expect(console.handleKeyPress(ParsedKey(name: "down", sequence: "", raw: "")))
        console.render(into: screen)
        #expect(screen.cell(atX: 1, y: 7)?.scalar == defaultSpaceChar)
        #expect(screen.cell(atX: 1, y: 8)?.scalar == Unicode.Scalar(">").value)

        // Mouse drag selection on row 7 (console localY = 1, lineIndex = 0)
        #expect(!console.handleMouse(RawMouseEvent(type: .down, button: 0, x: 5, y: 1))) // outside bounds
        #expect(console.handleMouse(RawMouseEvent(type: .down, button: 0, x: 2, y: 7)))
        #expect(console.handleMouse(RawMouseEvent(type: .drag, button: 0, x: 12, y: 7)))
        #expect(console.handleMouse(RawMouseEvent(type: .up, button: 0, x: 12, y: 7)))
        #expect(console.hasSelection)
        #expect(console.copySelection() == "[01:02:03]")
        #expect(copied == "[01:02:03]")

        // ConsoleCapture ring-buffer sanity check
        let cap = ConsoleCapture(maxChunks: 2)
        cap.write(stream: .stdout, data: "a")
        cap.write(stream: .stderr, data: "b")
        cap.write(stream: .stdout, data: "c")
        #expect(cap.size == 2)
        #expect(cap.readString(stream: .stdout) == "c")
        #expect(cap.readString(stream: .stderr) == "b")
        cap.clear()
        #expect(cap.size == 0)
    }
}
