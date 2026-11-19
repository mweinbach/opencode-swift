import Testing
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables

// MARK: - YogaCompat Tests

@Suite("YogaCompat")
struct YogaCompatTests {
    @Test("Config lifecycle, options, errata, experimental features, and active node guard")
    func configLifecycleAndOptions() throws {
        let host = YogaHost()
        let config = YogaConfig.create(host: host)
        #expect(!config.isFreed)
        #expect(config.getPointScaleFactor() == 1.0)
        #expect(!config.useWebDefaults())
        #expect(config.getErrata() == .none)
        #expect(!config.isExperimentalFeatureEnabled(.webFlexBasis))

        config.setUseWebDefaults(true)
        config.setPointScaleFactor(2.0)
        config.setErrata(.classic)
        config.setExperimentalFeatureEnabled(.webFlexBasis, true)

        #expect(config.useWebDefaults())
        #expect(config.getPointScaleFactor() == 2.0)
        #expect(config.getErrata() == .classic)
        #expect(config.isExperimentalFeatureEnabled(.webFlexBasis))

        let node = Yoga.Node.createWithConfig(config)
        #expect(node.getFlexDirection() == .row)
        #expect(node.getAlignContent() == .stretch)

        // Cannot free config while active nodes exist
        #expect(throws: YogaError.self) {
            try config.free()
        }

        node.free()
        #expect(node.isFreed())
        try Yoga.Config.destroy(config)
        #expect(config.isFreed)
        #expect(throws: YogaError.self) {
            try config.assertAlive()
        }
    }

    @Test("Flex row and column layout with percentages, auto sizing, margin, padding, border, and gap")
    func flexRowColumnPercentMarginPaddingBorder() {
        let root = Yoga.Node.create()
        root.setWidth(100)
        root.setHeight(40)
        root.setFlexDirection(Yoga.FLEX_DIRECTION_ROW)
        root.setPadding(Yoga.EDGE_ALL, 2)
        root.setBorder(Yoga.EDGE_ALL, 1)
        root.setGap(Yoga.GUTTER_COLUMN, 4)

        let left = Yoga.Node.create()
        left.setWidthPercent(50)
        left.setHeightAuto()
        left.setMargin(Yoga.EDGE_LEFT, 2)

        let right = Yoga.Node.create()
        right.setFlexGrow(1)
        right.setMinHeight(10)
        right.setMaxWidth(60)

        root.insertChild(left, 0)
        root.insertChild(right, 1)

        #expect(root.getChildCount() == 2)
        #expect(root.getChild(0) === left)
        #expect(left.getParent() === root)

        root.calculateLayout(100, 40, .ltr)

        #expect(root.getComputedWidth() == 100)
        #expect(root.getComputedHeight() == 40)
        #expect(root.getComputedPadding(.left) == 2)
        #expect(root.getComputedBorder(.top) == 1)

        // Inner width = 100 - 2*2(pad) - 2*1(border) = 94; 50% of 94 = 47
        #expect(left.getComputedWidth() == 47)
        #expect(left.getComputedLeft() == 5) // border(1) + pad(2) + marginLeft(2)
        #expect(left.getComputedMargin(.left) == 2)
        #expect(left.getComputedHeight() == 34) // 40 - 4(pad) - 2(border) stretched

        // Right gets remaining space: 94 - 2(marginLeft) - 47(left) - 4(gap) = 41
        #expect(right.getComputedWidth() == 41)
        #expect(right.getComputedLeft() == 56) // 5 + 47 + 4
        #expect(right.getComputedTop() == 3)

        #expect(root.hasNewLayout())
        root.markLayoutSeen()
        #expect(!root.hasNewLayout())

        root.freeRecursive()
        #expect(root.isFreed())
        #expect(left.isFreed())
        #expect(right.isFreed())
    }

    @Test("Custom measure function, dirtied callback, copyStyle, and reset")
    func measureFuncDirtiedAndReset() {
        let root = Yoga.Node.createForOpenTUI()
        root.setFlexDirection(.column)
        root.setAlignItems(.flexStart)

        let leaf = Yoga.Node.createForOpenTUI()
        leaf.setMeasureFunc { width, widthMode, _, _ in
            let w: Float = widthMode == .undefined ? 18 : min(18, width)
            return FlexSize(width: w, height: 3)
        }
        #expect(leaf.hasMeasureFunc())

        nonisolated(unsafe) var dirtiedCount = 0
        leaf.setDirtiedFunc { _ in
            dirtiedCount += 1
        }

        root.insertChild(leaf, 0)
        root.calculateLayout(80, 24)
        #expect(!leaf.isDirty())
        #expect(leaf.getComputedWidth() == 18)
        #expect(leaf.getComputedHeight() == 3)

        leaf.markDirty()
        #expect(leaf.isDirty())
        #expect(dirtiedCount == 1)

        // Style copy & value parsing
        let clone = Yoga.Node.create()
        leaf.setWidth("50%")
        leaf.setOverflow(.hidden)
        leaf.setDisplay(.flex)
        leaf.setAspectRatio(2.0)
        leaf.setPositionType(.absolute)
        leaf.setPosition(.top, 5)
        leaf.setPositionPercent(.left, 10)
        clone.copyStyle(leaf)

        #expect(clone.getWidth() == YogaValue(unit: .percent, value: 50))
        #expect(clone.getOverflow() == .hidden)
        #expect(clone.getAspectRatio() == 2.0)
        #expect(clone.getPositionType() == .absolute)
        #expect(clone.getPosition(.top) == YogaValue(unit: .point, value: 5))
        #expect(clone.getPosition(.left) == YogaValue(unit: .percent, value: 10))

        leaf.unsetMeasureFunc()
        leaf.unsetDirtiedFunc()
        #expect(!leaf.hasMeasureFunc())

        leaf.reset()
        #expect(leaf.getWidth() == YogaValue(unit: .auto, value: .nan))
        #expect(leaf.getChildCount() == 0)
        #expect(leaf.isDirty())

        clone.free()
        root.freeRecursive()
    }

    @Test("parseYogaValue and YogaHost callback/mutation guard")
    func parseYogaValueAndHostGuards() throws {
        #expect(try parseYogaValue(.undefined) == UNDEFINED_VALUE)
        #expect(try parseYogaValue("auto") == YogaValue(unit: .auto, value: .nan))
        #expect(try parseYogaValue("25%") == YogaValue(unit: .percent, value: 25))
        #expect(try parseYogaValue(42) == YogaValue(unit: .point, value: 42))
        #expect(throws: YogaError.self) {
            _ = try parseYogaValue("12px")
        }

        let host = YogaHost()
        #expect(!host.inCallback)
        nonisolated(unsafe) var mutationBlocked = false
        host.invokeCallback {
            #expect(host.inCallback)
            do {
                try host.assertMutable()
            } catch {
                mutationBlocked = true
            }
            return nil
        }
        #expect(mutationBlocked)
        #expect(!host.inCallback)
    }
}

// MARK: - NativeSpanFeed Tests

@Suite("NativeSpanFeed")
struct NativeSpanFeedTests {
    @Test("Multi-chunk reserve, commit, drain, and release accounting")
    func multiChunkReserveCommitDrain() throws {
        let feed = NativeSpanFeed.create(NativeSpanFeedOptions(
            chunkSize: 16,
            initialChunks: 1,
            maxBytes: 64,
            growthPolicy: .grow,
            autoCommitOnFull: false,
            spanQueueCapacity: 16
        ))

        let r1 = try feed.reserve(10)
        let s1 = try feed.commit(reservation: r1, bytes: Array("0123456789".utf8))
        #expect(s1.chunkIndex == 0)
        #expect(s1.offset == 0)
        #expect(s1.len == 10)

        // Next 10 bytes exceed remaining 6 bytes in chunk 0 -> grows to chunk 1
        let r2 = try feed.reserve(10)
        let s2 = try feed.commit(reservation: r2, bytes: Array("abcdefghij".utf8))
        #expect(s2.chunkIndex == 1)
        #expect(feed.chunks.count == 2)
        #expect(feed.isBackpressured())
        #expect(feed.stats.pendingSpans == 2)
        #expect(feed.stats.outstandingSpans == 2)
        #expect(feed.stats.bytesWritten == 20)
        #expect(feed.header.chunkCount == 2)

        let drained = feed.drain()
        #expect(drained.count == 2)
        #expect(String(decoding: feed.readSpan(drained[0]) ?? [], as: UTF8.self) == "0123456789")
        #expect(String(decoding: feed.readSpan(drained[1]) ?? [], as: UTF8.self) == "abcdefghij")

        for span in drained {
            feed.releaseSpan(slotIndex: span.slotIndex, releaseId: span.releaseId)
        }
        #expect(!feed.isBackpressured())
        #expect(feed.stats.outstandingSpans == 0)
        #expect(feed.stats.outstandingBytes == 0)
        feed.close()
        #expect(feed.isClosed)
        #expect(feed.isDestroyed)
    }

    @Test("onData deferred delivery, attach, error handler, and bounded block policy")
    func onDataDeliveryAndBoundedMemory() async throws {
        let feed = SpanFeed.create(NativeSpanFeedOptions(
            chunkSize: 8,
            initialChunks: 1,
            maxBytes: 8,
            growthPolicy: .block,
            autoCommitOnFull: false
        ))
        let attached = NativeSpanFeed.attach(feed)
        #expect(attached === feed)

        // Write before subscriber attaches -> stays queued as pendingDataAvailable
        _ = try feed.write("hello")
        #expect(feed.isBackpressured())

        // Exceeding remaining 3 bytes under .block policy throws .outOfSpace
        #expect(throws: NativeSpanFeedError.self) {
            _ = try feed.write("world!")
        }

        nonisolated(unsafe) var received: [String] = []
        let unsub = feed.onData { bytes in
            received.append(String(decoding: bytes, as: UTF8.self))
        }
        #expect(received == ["hello"])
        #expect(!feed.isBackpressured())

        // Error subscription
        nonisolated(unsafe) var errorCodes: [Int32] = []
        let unsubErr = feed.onError { code in
            errorCodes.append(code)
        }
        feed.emitError(-11)
        #expect(errorCodes == [-11])

        // Further writes deliver immediately and chunk 0 is recycled now that it's unpinned
        _ = try feed.write("world!")
        #expect(received == ["hello", "world!"])

        await feed.idle()
        unsub()
        unsubErr()
        feed.close()

        #expect(throws: NativeSpanFeedError.closed) {
            _ = try feed.write("after-close")
        }
    }

    @Test("Deferred close during onData callback cleans up after drain completes")
    func deferredCloseDuringCallback() throws {
        let feed = NativeSpanFeed.create(NativeSpanFeedOptions(chunkSize: 32, initialChunks: 1))
        nonisolated(unsafe) var deliveredCount = 0
        feed.onData { _ in
            deliveredCount += 1
            feed.close()
        }
        _ = try feed.write("trigger")
        #expect(deliveredCount == 1)
        #expect(feed.isClosed)
        #expect(feed.isDestroyed)
    }
}

// MARK: - NativeScene Tests

@Suite("NativeScene")
struct NativeSceneTests {
    @Test("Tree CRUD, staged style/paint mutations, FlexSolver layout, and scene style helpers")
    func treeCrudStagedMutationsAndLayout() throws {
        let sink = MemorySessionOutputSink()
        let session = try NativeSession(sink: sink, options: NativeSessionOptions(width: 40, height: 12))
        let scene = NativeScene(driver: session)

        let root = try scene.createStandaloneNode(num: 1)
        let header = try scene.createStandaloneNode(num: 2)
        let body = try scene.createStandaloneNode(num: 3)

        try scene.moveNode(header, parent: root, index: 0)
        try scene.moveNode(body, parent: root, index: 1)

        // Stage styles via yoga.internal.ts helpers
        try sceneSetEnum(scene: scene, node: root, kind: .flexDirection, value: FlexDirection.column.yogaRawValue)
        try sceneSetDimension(scene: scene, node: root, dimension: .width, input: 40)
        try sceneSetDimension(scene: scene, node: root, dimension: .height, input: 12)
        try sceneSetValue(scene: scene, node: header, kind: .height, edge: YOGA_EDGE_NONE, valueInput: 3)
        try sceneSetFloat(scene: scene, node: body, kind: .flexGrow, value: 1)

        #expect(scene.hasStagedMutations)
        #expect(try sceneGetEnum(scene: scene, node: root, kind: .flexDirection) == FlexDirection.column.yogaRawValue)
        #expect(!scene.hasStagedMutations)
        #expect(try sceneGetFloat(scene: scene, node: body, kind: .flexGrow) == 1)
        #expect(try sceneGetValue(scene: scene, node: header, kind: .height, edge: YOGA_EDGE_NONE) == YogaValue(unit: .point, value: 3))

        let revBefore = scene.observedLayoutRevision
        try scene.computeLayout(width: 40, height: 12)
        let revAfter = scene.observedLayoutRevision
        #expect(revBefore != revAfter)

        let headerLayout = try scene.getLayout(header)
        let bodyLayout = try scene.getLayout(body)
        #expect(headerLayout.width == 40)
        #expect(headerLayout.height == 3)
        #expect(bodyLayout.top == 3)
        #expect(bodyLayout.height == 9)

        let snapshotHeight = try scene.measureSnapshot(root, availableWidth: 40)
        #expect(snapshotHeight == 12)

        try scene.destroyNode(body)
        #expect(scene.nodeCount == 2)

        scene.destroy()
        #expect(throws: NativeSceneError.destroyed) {
            try scene.assertAlive()
        }
        try session.closeSync()
    }

    @Test("Rendering boxes, text, clipping, opacity, zIndex hit-testing, and scroll state")
    func renderHitTestTextAndScroll() throws {
        let sink = MemorySessionOutputSink()
        let session = try NativeSession(sink: sink, options: NativeSessionOptions(width: 30, height: 10))
        let scene = NativeScene(driver: session)

        let root = try scene.createStandaloneNode(num: 10)
        let box = try scene.createStandaloneNode(num: 20)
        let overlay = try scene.createStandaloneNode(num: 30)
        let scrollBox = try scene.createStandaloneNode(num: 40)
        let tallChild = try scene.createStandaloneNode(num: 41)

        try scene.moveNode(box, parent: root, index: 0)
        try scene.moveNode(overlay, parent: root, index: 1)
        try scene.moveNode(scrollBox, parent: root, index: 2)
        try scene.moveNode(tallChild, parent: scrollBox, index: 0)

        try sceneSetDimension(scene: scene, node: root, dimension: .width, input: 30)
        try sceneSetDimension(scene: scene, node: root, dimension: .height, input: 10)

        try sceneSetDimension(scene: scene, node: box, dimension: .width, input: 12)
        try sceneSetDimension(scene: scene, node: box, dimension: .height, input: 4)
        try scene.setBoxBorderStyle(box, style: .single, sides: .all)
        try scene.setPaint(box, NativeScenePaintUpdate(
            zIndex: 1,
            shouldFill: true,
            backgroundColor: RGBA.fromInts(10, 20, 30, 255),
            borderColor: RGBA.fromInts(200, 200, 200, 255)
        ))
        try scene.setBoxDetails(box, details: NativeSceneBoxDetails(title: "Box"))
        try scene.setText(box, "Hello\nWorld")

        // Overlay overlaps box with higher zIndex
        try sceneSetEnum(scene: scene, node: overlay, kind: .positionType, value: PositionType.absolute.rawValue)
        try scene.setPositions(overlay, mask: 0b0011, units: [.point, .point], values: [2, 1]) // left=2, top=1
        try sceneSetDimension(scene: scene, node: overlay, dimension: .width, input: 6)
        try sceneSetDimension(scene: scene, node: overlay, dimension: .height, input: 2)
        try scene.setPaint(overlay, NativeScenePaintUpdate(
            zIndex: 5,
            opacity: 0.8,
            shouldFill: true,
            backgroundColor: RGBA.fromInts(255, 0, 0, 255)
        ))

        // Scrollable container with overflowing child
        try sceneSetDimension(scene: scene, node: scrollBox, dimension: .width, input: 10)
        try sceneSetDimension(scene: scene, node: scrollBox, dimension: .height, input: 4)
        try sceneSetEnum(scene: scene, node: scrollBox, kind: .overflow, value: Overflow.scroll.rawValue)
        try sceneSetDimension(scene: scene, node: tallChild, dimension: .width, input: 10)
        try sceneSetDimension(scene: scene, node: tallChild, dimension: .height, input: 12)
        try scene.setScroll(scrollBox, options: NativeSceneScrollOptions(scrollX: false, scrollY: true))

        // Render into an explicit OptimizedBuffer
        let buffer = OptimizedBuffer(width: 30, height: 10)
        try scene.render(into: buffer)

        #expect(try scene.painted(box))
        #expect(try scene.painted(overlay))
        #expect(try scene.getText(box) == "Hello\nWorld")

        let metrics = try scene.getTextMetrics(box)
        #expect(metrics.lineCount == 2)
        #expect(metrics.widthColsMax == 5)
        #expect(try scene.textByteAt(box, x: 1, y: 0) == 1)

        // Selection API
        let selected = try scene.setTextSelection(
            box,
            operation: .set,
            bounds: LocalSelectionBounds(anchorX: 0, anchorY: 0, focusX: 4, focusY: 0, isActive: true)
        )
        #expect(selected)
        #expect(try scene.getSelectedText(box) == "Hello")

        // Hit test respects zIndex and excluded ID fallback
        #expect(try scene.hitTest(x: 3, y: 1) == 30) // overlay on top
        #expect(try scene.hitTest(x: 3, y: 1, excluded: 30) == 20) // falls through to box
        #expect(try scene.hitTest(x: 0, y: 0) == 20)

        // Scroll state queries & scrollTo
        let scrollBefore = try scene.getScroll(scrollBox)
        #expect(scrollBefore.maxY == 8)
        let scrollAfter = try scene.scrollTo(scrollBox, x: 0, y: 5)
        #expect(scrollAfter.offsetY == 5)
        #expect(scrollAfter.verticalBar.visible)

        // Paint + commit through NativeSession
        try scene.paint()
        #expect(scene.frame != nil)
        let status = try scene.commit(force: true)
        #expect(status == .presented)
        #expect(scene.frame == nil)
        #expect(!sink.allBytes.isEmpty)

        // Cancel frame clears pending ticket
        try scene.paint()
        #expect(scene.frame != nil)
        scene.cancelFrame()
        #expect(scene.frame == nil)

        scene.destroy()
        try session.closeSync()
    }
}

// MARK: - NativeSession Tests

@Suite("NativeSession")
struct NativeSessionTests {
    @Test("Full lifecycle: open, setupTerminal, resize, render, input, suspend, resume, close")
    func fullSessionLifecycle() async throws {
        let sink = MemorySessionOutputSink()
        let scheduler = ManualNativeSessionScheduler(initialNs: 1_000_000)
        let session = try NativeSession(
            sink: sink,
            options: NativeSessionOptions(
                scheduler: scheduler,
                width: 20,
                height: 6
            )
        )

        #expect(session.open)
        #expect(!session.disposed)
        #expect(!session.contextDisposed)
        #expect(session.usesOutput(sink))

        // Setup terminal
        try session.setupTerminal(NativeSessionTerminalOptions(
            useAlternateScreen: true,
            mouse: true,
            kittyKeyboardFlags: 1
        ))
        #expect(session.terminalPhase == .active)
        #expect(sink.outputText.contains(ANSI.switchToAlternateScreen))

        // Capabilities, palette, theme mode
        let caps = try session.getCapabilities()
        #expect(caps.kittyKeyboardFlags == 1)
        try session.control(.title("OpenTUI Swift"))
        #expect(sink.outputText.contains("\u{1B}]0;OpenTUI Swift\u{07}"))
        #expect(try session.writeClipboard(bytes: Array("copied".utf8)))
        #expect(try session.triggerNotification(message: "Build done", title: "OpenTUI"))
        #expect(try session.setProgramStatus(ProgramStatus(state: .working, app: "swift", progress: 0.5)))

        session.setThemeMode(.light)
        #expect(session.themeMode == .light)

        // Input attachment & decoding (including DSR theme mode dark sequence)
        nonisolated(unsafe) var decodedEvents: [StdinEvent] = []
        session.attachInput { event in
            decodedEvents.append(event)
        }
        let events = session.feedInput("a")
        #expect(events.count == 1)
        #expect(decodedEvents.count == 1)
        _ = session.feedInput("\u{1B}[?997;1n")
        #expect(session.themeMode == .dark)

        // Draw into diffRenderer & submit frame
        sink.clear()
        let renderer = try #require(session.diffRenderer)
        renderer.nextBuffer.drawText("Hi!", x: 0, y: 0, fg: RGBA.fromInts(255, 255, 255, 255))
        let r1 = try session.render()
        #expect(r1 == .presented)
        #expect(sink.outputText.contains("Hi!"))
        #expect(session.metrics.framesPresented == 1)

        // Unchanged second frame is skipped
        let r2 = try session.render()
        #expect(r2 == .skipped)
        #expect(session.metrics.framesSkipped == 1)

        // Resize updates renderer dimensions
        try session.resize(width: 40, height: 12)
        #expect(session.rendererState.width == 40)
        #expect(session.rendererState.height == 12)

        // Suspend and resume
        sink.clear()
        try session.suspend()
        #expect(session.terminalPhase == .suspended)
        #expect(sink.outputText.contains(ANSI.switchToMainScreen))

        sink.clear()
        try session.resume()
        #expect(session.terminalPhase == .active)
        #expect(sink.outputText.contains(ANSI.switchToAlternateScreen))

        // Kitty image transport methods
        try session.setKittyImageTransport(mode: 2)
        let kitty = try session.getKittyImageTransport()
        #expect(kitty.effective == 2)
        try session.startKittyFileProbe()
        #expect(try session.pollKittyImageTransport())
        #expect(try session.processKittyImageReply(Array("\u{1B}_Gi=31;OK\u{1B}\\".utf8)) == 1)
        try session.cancelKittyImageTransport(failed: false)

        // Detached child session shares ResourceContext
        nonisolated(unsafe) var childCleaned = false
        let detached = try session.createDetached(NativeSessionRendererOptions(width: 10, height: 4)) {
            childCleaned = true
        }
        #expect(detached.context == session.context)

        try await session.idle()
        try await session.close()
        #expect(childCleaned)
        #expect(detached.disposed)
        #expect(session.disposed)
        #expect(session.contextDisposed)
        #expect(!session.open)
    }

    @Test("Output backpressure, write limit enforcement, and drain resumption")
    func backpressureAndWriteLimits() async throws {
        let sink = MemorySessionOutputSink(simulateBackpressure: true)
        let session = try NativeSession(
            sink: sink,
            options: NativeSessionOptions(
                output: NativeSessionOutputOptions(chunkSize: 64, spanCapacity: 4, maxBytes: 128, controlCapacity: 16),
                width: 10,
                height: 4
            )
        )

        // Single write exceeding maxAtomicWriteBytes (112) throws
        #expect(throws: NativeSessionError.self) {
            _ = try session.write(Array(repeating: 0x41, count: 120))
        }

        // First write passes through to sink, which triggers backpressure (needsDrain = true)
        #expect(try session.write(Array(repeating: 0x42, count: 60)))
        #expect(sink.needsDrain)

        // Next write queues while sink is blocked
        #expect(try session.write(Array(repeating: 0x43, count: 60)))
        #expect(session.metrics.bytesQueued == 60)

        // Exceeding remaining maxBytes while queued returns false (backpressure)
        #expect(try session.write(Array(repeating: 0x44, count: 80)) == false)
        #expect(session.metrics.backpressureEvents >= 2)

        // Draining the sink flushes queued output
        sink.simulateBackpressure = false
        sink.drain()
        #expect(session.metrics.bytesQueued == 0)

        // restoreOnExit works before dispose
        #expect(session.restoreOnExit())
        session.dispose()
        #expect(session.disposed)
    }
}
