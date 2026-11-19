import Synchronization
import Testing
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeSimulation
import OpenCodeUtil
import OpenTUICore
import OpenTUIRenderables

@Suite("OpenCodeSimulation Frontend Actions, Semantics, Server & Drive")
struct SimulationFrontendTests {
    // MARK: - Actions & Semantics

    @Test("SimulationActions.matches performs literal case-sensitive substring matching")
    func literalMatches() {
        let screen: () -> String = { "OpenCode [ready].*" }
        #expect(SimulationActions.matches(screen: screen, text: "OpenCode") == true)
        #expect(SimulationActions.matches(screen: screen, text: "[ready].*") == true)
        #expect(SimulationActions.matches(screen: screen, text: "OpenCode.*ready") == false)
        #expect(SimulationActions.matches(screen: screen, text: "opencode") == false)
    }

    @Test("SimulationActions normalizes named keys and mirrors configured Kitty keyboard protocol")
    func keyNormalizationAndKittyProtocol() async throws {
        #expect(SimulationActions.normalizeKeyInput("escape") == "ESCAPE")
        #expect(SimulationActions.normalizeKeyInput("return") == "RETURN")
        #expect(SimulationActions.normalizeKeyInput("x") == "x")

        let scope = LayerNode.ResourceScope()
        let renderer = try await SimulationRenderer.create(
            options: CliRendererConfig(useKittyKeyboard: KittyKeyboardOptions()),
            scope: scope
        )
        let harness = SimulationActions.createHarness(renderer)
        let capturedKey = Mutex<(name: String, source: ParsedKeySource)?>(nil)
        _ = renderer.keyInput.onKeypress { event in
            capturedKey.withLock { $0 = (event.name, event.source) }
        }

        _ = try await SimulationActions.execute(harness, action: .press(key: "escape"))
        let result = capturedKey.withLock { $0 }
        #expect(result?.name == "escape")
        #expect(result?.source == .kitty)
        await scope.close()
    }

    @Test("SimulationActions captures styled spans and visible ImageRenderable pixels in fill mode")
    func captureFrameAndImages() async throws {
        let scope = LayerNode.ResourceScope()
        let renderer = try await SimulationRenderer.create(
            viewport: SimulationRenderer.Viewport(cols: 20, rows: 10),
            scope: scope
        )
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let img = ImageRenderable(
            ctx: renderer,
            options: ImageRenderableOptions(
                width: .point(2),
                height: .point(1),
                position: .absolute,
                top: .point(1),
                left: .point(2),
                source: .rgba(width: 2, height: 1, pixels: pixels),
                fit: .fill
            )
        )
        renderer.root.add(img)

        let frame = await SimulationActions.capture(SimulationActions.createHarness(renderer))
        #expect(frame.cols == 20)
        #expect(frame.rows == 10)
        #expect(frame.cursor == OpenCodeProtocol.Frontend.CapturedFrame.Cursor(0, 0))
        #expect(frame.lines.count == 10)
        #expect(frame.images == [
            OpenCodeProtocol.Frontend.CapturedImage(
                x: 2,
                y: 1,
                width: 2,
                height: 1,
                pixelWidth: 2,
                pixelHeight: 1,
                rgba: "/wAA/wAA//8="
            ),
        ])
        await scope.close()
    }

    @Test("SimulationActions clicks targets through descendant text, handles native mouse events, and validates bounds")
    func clickAndMouseActions() async throws {
        let scope = LayerNode.ResourceScope()
        let renderer = try await SimulationRenderer.create(scope: scope)
        let harness = SimulationActions.createHarness(renderer)

        // Click through descendant text
        let clickCount = Mutex(0)
        let button = BoxRenderable(
            ctx: renderer,
            options: BoxOptions(
                id: "permission.action.once",
                width: .point(12),
                height: .point(1),
                onMouseUp: { _ in clickCount.withLock { $0 += 1 } }
            )
        )
        button.add(TextRenderable(ctx: renderer, options: TextOptions(content: "Allow once")))
        renderer.root.add(button)
        await harness.renderOnce()

        let currentState = SimulationActions.state(harness)
        #expect(currentState.focused.renderable == nil)
        #expect(currentState.focused.editor == false)
        #expect(currentState.elements.contains { $0.id == "permission.action.once" && $0.clickable })

        _ = try await SimulationActions.execute(harness, action: .click(target: Double(button.num), x: 1, y: 0))
        #expect(clickCount.withLock { $0 } == 1)

        // Out-of-bounds click error
        var boundsErr: String?
        do {
            _ = try await SimulationActions.execute(harness, action: .click(target: Double(button.num), x: 99, y: 0))
        } catch {
            boundsErr = String(describing: error)
        }
        #expect(boundsErr?.contains("within the target element") == true)

        // Removed target click error
        renderer.root.remove(button)
        var staleErr: String?
        do {
            _ = try await SimulationActions.execute(harness, action: .click(target: Double(button.num), x: 1, y: 0))
        } catch {
            staleErr = String(describing: error)
        }
        #expect(staleErr?.contains("click target is stale or unavailable") == true)

        // Native mouse hover, drag, right button, scroll, out, and viewport bounds
        let mouseEvents = Mutex<[(type: MouseEventType, x: Int, y: Int, button: Int)]>([])
        let target = BoxRenderable(
            ctx: renderer,
            options: BoxOptions(
                width: .point(15),
                height: .point(3),
                position: .absolute,
                top: .point(5),
                left: .point(10),
                onMouse: { event in
                    mouseEvents.withLock { $0.append((event.type, event.x, event.y, event.button)) }
                }
            )
        )
        renderer.root.add(target)
        await harness.renderOnce()

        _ = try await SimulationActions.execute(harness, action: .mouse(params: .move(x: 11, y: 6)))
        _ = try await SimulationActions.execute(harness, action: .mouse(params: .move(x: 12, y: 6)))
        _ = try await SimulationActions.execute(harness, action: .mouse(params: .down(x: 12, y: 6, button: .right)))
        _ = try await SimulationActions.execute(harness, action: .mouse(params: .move(x: 13, y: 6)))
        _ = try await SimulationActions.execute(harness, action: .mouse(params: .up(x: 13, y: 6, button: .right)))
        _ = try await SimulationActions.execute(harness, action: .mouse(params: .scroll(x: 12, y: 6, direction: .down)))
        _ = try await SimulationActions.execute(harness, action: .mouse(params: .move(x: 1, y: 1)))

        let recorded = mouseEvents.withLock { $0 }
        #expect(recorded.contains { $0.type == .over })
        #expect(recorded.contains { $0.type == .move && $0.x == 12 && $0.y == 6 })
        #expect(recorded.contains { $0.type == .down && $0.button == 2 })
        #expect(recorded.contains { $0.type == .drag && $0.x == 13 && $0.y == 6 })
        #expect(recorded.contains { $0.type == .up && $0.x == 13 && $0.y == 6 && $0.button == 2 })
        #expect(recorded.contains { $0.type == .scroll })
        #expect(recorded.contains { $0.type == .out })
        #expect(harness.mockMouse.getPressedButtons().isEmpty)

        var viewportErr: String?
        do {
            _ = try await SimulationActions.execute(harness, action: .mouse(params: .move(x: 100, y: 40)))
        } catch {
            viewportErr = String(describing: error)
        }
        #expect(viewportErr?.contains("within the terminal viewport") == true)

        // Resize validation
        _ = try await SimulationActions.execute(harness, action: .resize(cols: 120, rows: 35))
        #expect(renderer.width == 120)
        #expect(renderer.height == 35)

        var badResize = false
        do {
            _ = try await SimulationActions.execute(harness, action: .resize(cols: 0, rows: 10))
        } catch {
            badResize = true
        }
        #expect(badResize)

        await scope.close()
    }

    @Test("SimulationSemantics snapshots lazy hierarchy, reflects live state mutations, enforces uniqueness, and validates semantic clicks")
    func semanticSnapshotAndSemanticClicks() async throws {
        let scope = LayerNode.ResourceScope()
        let renderer = try await SimulationRenderer.create(scope: scope)
        let harness = SimulationActions.createHarness(renderer)

        let selected = Mutex("once")
        let clicks = Mutex(0)
        let dialog = BoxRenderable(ctx: renderer, options: BoxOptions(id: "session.permission", width: .point(30), height: .point(5)))
        let actions = BoxRenderable(ctx: renderer, options: BoxOptions(id: "session.permission.actions", width: .point(20), height: .point(3)))
        let once = BoxRenderable(
            ctx: renderer,
            options: BoxOptions(
                id: "session.permission.action.once",
                width: .point(12),
                height: .point(1),
                onMouseUp: { _ in clicks.withLock { $0 += 1 } }
            )
        )

        SimulationSemantics.bind {
            SimulationSemantics.Definition(
                instance: "permission-1",
                role: "dialog",
                label: "Permission required",
                expanded: false
            )
        }(dialog)
        SimulationSemantics.bind {
            SimulationSemantics.Definition(
                instance: "permission-1",
                role: "listbox",
                label: "Permission choices"
            )
        }(actions)
        SimulationSemantics.bind {
            let isOnce = selected.withLock { $0 == "once" }
            return SimulationSemantics.Definition(
                instance: "permission-1",
                role: "option",
                label: "Allow once",
                focused: isOnce,
                selected: isOnce,
                disabled: false
            )
        }(once)

        renderer.root.add(dialog)
        dialog.add(actions)
        actions.add(once)
        await harness.renderOnce()

        let snap1 = try SimulationActions.snapshot(harness)
        #expect(snap1.format == "opencode-ui-snapshot-v1")
        #expect(snap1.nodes == [
            OpenCodeProtocol.Frontend.SemanticNode(
                id: "session.permission",
                instance: "permission-1",
                parent: nil,
                role: "dialog",
                label: "Permission required",
                element: Int(dialog.num),
                expanded: false
            ),
            OpenCodeProtocol.Frontend.SemanticNode(
                id: "session.permission.actions",
                instance: "permission-1",
                parent: "session.permission",
                role: "listbox",
                label: "Permission choices",
                element: Int(actions.num)
            ),
            OpenCodeProtocol.Frontend.SemanticNode(
                id: "session.permission.action.once",
                instance: "permission-1",
                parent: "session.permission.actions",
                role: "option",
                label: "Allow once",
                element: Int(once.num),
                focused: true,
                selected: true,
                disabled: false
            ),
        ])

        // Lazy mutation reflected on next snapshot
        selected.withLock { $0 = "reject" }
        let snap2 = try SimulationActions.snapshot(harness)
        #expect(snap2.nodes.last?.focused == false)
        #expect(snap2.nodes.last?.selected == false)

        // Semantic click rejects mismatched instance
        var staleSemanticErr: String?
        do {
            _ = try await SimulationActions.execute(
                harness,
                action: .click(
                    target: Double(once.num),
                    x: 1,
                    y: 0,
                    semantic: OpenCodeProtocol.Frontend.SemanticClickTarget(
                        id: "session.permission.action.once",
                        instance: "permission-wrong",
                        element: Int(once.num)
                    )
                )
            )
        } catch {
            staleSemanticErr = String(describing: error)
        }
        #expect(staleSemanticErr?.contains("semantic click target is stale or unavailable") == true)
        #expect(clicks.withLock { $0 } == 0)

        // Semantic click succeeds when identity matches
        _ = try await SimulationActions.execute(
            harness,
            action: .click(
                target: Double(once.num),
                x: 1,
                y: 0,
                semantic: OpenCodeProtocol.Frontend.SemanticClickTarget(
                    id: "session.permission.action.once",
                    instance: "permission-1",
                    element: Int(once.num)
                )
            )
        )
        #expect(clicks.withLock { $0 } == 1)

        // Hiding dialog hides entire semantic subtree
        dialog.visible = false
        #expect(try SimulationActions.snapshot(harness).nodes.isEmpty)

        // Duplicate semantic id rejection
        let dup1 = BoxRenderable(ctx: renderer, options: BoxOptions(id: "duplicate"))
        let dup2 = BoxRenderable(ctx: renderer, options: BoxOptions(id: "duplicate"))
        SimulationSemantics.bind { SimulationSemantics.Definition(role: "option") }(dup1)
        SimulationSemantics.bind { SimulationSemantics.Definition(role: "option") }(dup2)
        renderer.root.add(dup1)
        renderer.root.add(dup2)
        var dupErr: String?
        do {
            _ = try SimulationActions.snapshot(harness)
        } catch {
            dupErr = String(describing: error)
        }
        #expect(dupErr?.contains("duplicate semantic UI id: duplicate") == true)

        // Empty role validation
        renderer.root.remove(dup1)
        renderer.root.remove(dup2)
        let badRole = BoxRenderable(ctx: renderer, options: BoxOptions(id: "invalid"))
        SimulationSemantics.bind { SimulationSemantics.Definition(role: "") }(badRole)
        renderer.root.add(badRole)
        var emptyRoleErr = false
        do {
            _ = try SimulationActions.snapshot(harness)
        } catch {
            emptyRoleErr = true
        }
        #expect(emptyRoleErr)

        await scope.close()
    }

    // MARK: - SimulationServer & Drive

    @Test("SimulationServer routes handshake, ui.state, ui.capture, ui.snapshot, actions, and reports malformed JSON over TCP WebSocket")
    func frontendServerOverTCPWebSocket() async throws {
        let port = try SimTestNet.availableLoopbackPort()
        let endpoint = "ws://127.0.0.1:\(port)"
        let scope = LayerNode.ResourceScope()

        let renderer = try await SimulationRenderer.create(scope: scope)
        let server = try await SimulationServer.start(
            harness: SimulationActions.createHarness(renderer),
            endpoint: endpoint,
            version: "2.0.0-ui",
            scope: scope
        )

        let ws = try await SimTestTCPWebSocket.connect(url: server.url)

        // 1. Handshake
        try ws.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(0),
            "method": .string("simulation.handshake"),
            "params": .object([
                "client": .object(["name": .string("test"), "version": .string("1.0")]),
                "expectedRole": .string("ui"),
                "offeredVersions": .array([.int(1)]),
                "requiredCapabilities": .array([.string("ui.state")]),
                "optionalCapabilities": .array([]),
            ]),
        ]))
        let hs = try await ws.readJSON()
        #expect(hs["id"] == .int(0))
        #expect(hs["result"]?["protocolVersion"] == .int(1))
        #expect(hs["result"]?["role"] == .string("ui"))

        // 2. ui.state
        try ws.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("ui.state")]))
        let stateResp = try await ws.readJSON()
        #expect(stateResp["id"] == .int(1))
        #expect(stateResp["result"]?["focused"]?["editor"] == .bool(false))
        #expect(stateResp["result"]?["elements"] == .array([]))

        // 3. ui.capture (default 100x40 viewport)
        try ws.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(2), "method": .string("ui.capture")]))
        let captureResp = try await ws.readJSON()
        #expect(captureResp["id"] == .int(2))
        #expect(captureResp["result"]?["cols"] == .int(100))
        #expect(captureResp["result"]?["rows"] == .int(40))
        #expect(captureResp["result"]?["cursor"] == .array([.int(0), .int(0)]))

        // 4. ui.snapshot
        try ws.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(3), "method": .string("ui.snapshot")]))
        let snapResp = try await ws.readJSON()
        #expect(snapResp["id"] == .int(3))
        #expect(snapResp["result"] == .object([
            "format": .string("opencode-ui-snapshot-v1"),
            "nodes": .array([]),
        ]))

        // 5. ui.enter + ui.matches on rendered text
        let text = TextRenderable(ctx: renderer, options: TextOptions(content: "Hello OpenCode"))
        renderer.root.add(text)
        try ws.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(4), "method": .string("ui.enter")]))
        _ = try await ws.readJSON()
        try ws.sendJSON(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(5),
            "method": .string("ui.matches"),
            "params": .object(["text": .string("Hello OpenCode")]),
        ]))
        let matchResp = try await ws.readJSON()
        #expect(matchResp["id"] == .int(5))
        #expect(matchResp["result"] == .bool(true))

        // 6. Malformed JSON -> id: null, code: -32000
        try ws.sendText("{")
        let errResp = try await ws.readJSON()
        #expect(errResp["id"] == .null)
        #expect(errResp["error"]?["code"] == .int(-32000))

        ws.close()
        await scope.close()
        // Port is cleanly released for immediate rebind
        #expect(SimTestNet.canBindLoopbackPort(port) == true)
    }

    @Test("Drive.create orchestrates manifest resolution, headless renderer, recording, and UI control server")
    func driveCreateOrchestrator() async throws {
        let dir = try SimTestFS.makeTempDir(prefix: "sim-drive-")
        defer { SimTestFS.remove(dir) }
        let timelinePath = "\(dir)/drive-timeline.jsonl"
        let manifestJSON = """
        {
          "endpoints": {
            "ui": "ws://127.0.0.1:43100",
            "backend": "ws://127.0.0.1:43150"
          },
          "viewport": { "cols": 90, "rows": 30 },
          "recording": { "timeline": "\(timelinePath)" }
        }
        """
        let fs = InMemoryFileSystem(initialFiles: ["/drive/e2e.json": Array(manifestJSON.utf8)])
        let env = DictionaryEnvironment(variables: [
            "OPENCODE_DRIVE": "e2e",
            "DRIVE_REGISTRY_DIR": "/drive",
            "OPENCODE_DRIVE_RENDERER": "headless",
        ])

        let scope = LayerNode.ResourceScope()
        let renderer = try await Drive.create(
            options: CliRendererConfig(),
            version: "2.0.0-drive",
            environment: env,
            fileSystem: fs,
            bindNetwork: false,
            scope: scope
        )
        #expect(renderer.width == 90)
        #expect(renderer.height == 30)
        guard let server = Drive.serverFor(renderer) else {
            Issue.record("Expected Drive control server registered for renderer")
            return
        }

        let sock = SimTestInMemorySocket()
        _ = server.attachConnection(sock.server)
        try await sock.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("ui.capture")]))
        let cap = try await sock.nextJSON()
        #expect(cap["result"]?["cols"] == .int(90))
        #expect(cap["result"]?["rows"] == .int(30))

        try await sock.sendJSON(.object(["jsonrpc": .string("2.0"), "id": .int(2), "method": .string("ui.recording.finish")]))
        let recFinish = try await sock.nextJSON()
        #expect(recFinish["result"] == .string(timelinePath))

        await sock.close()
        await scope.close()

        let events = try SimulationRecording.parseTimeline(try SimTestFS.readText(timelinePath))
        #expect(events.first == .header(SimulationRecording.Header(cols: 90, rows: 30)))
    }

    @Test("SimulationActions executes ui.focus, ui.type, ui.arrow on editor, captures cover-cropped images, and reports missing recording")
    func focusTypeArrowCoverAndMissingRecording() async throws {
        let scope = LayerNode.ResourceScope()
        let renderer = try await SimulationRenderer.create(
            viewport: SimulationRenderer.Viewport(cols: 40, rows: 12),
            scope: scope
        )
        let harness = SimulationActions.createHarness(renderer)

        // Missing recording finish throws descriptive error
        var missingRecErr: String?
        do {
            _ = try await SimulationRenderer.finish(renderer)
        } catch {
            missingRecErr = String(describing: error)
        }
        #expect(missingRecErr?.contains("UI recording is not available") == true)

        // Focusable TextareaRenderable (EditBufferRenderable) -> editor: true + ui.type + ui.arrow
        let editor = TextareaRenderable(
            ctx: renderer,
            options: TextareaOptions(
                id: "prompt.editor",
                width: .point(30),
                height: .point(3)
            )
        )
        renderer.root.add(editor)
        await harness.renderOnce()

        let focusedState = try await SimulationActions.execute(harness, action: .focus(target: Double(editor.num)))
        #expect(focusedState.focused.renderable == Double(editor.num))
        #expect(focusedState.focused.editor == true)
        #expect(focusedState.elements.contains { $0.id == "prompt.editor" && $0.focused && $0.editor })

        _ = try await SimulationActions.execute(harness, action: .type(text: "abc"))
        _ = try await SimulationActions.execute(harness, action: .arrow(direction: .left))
        _ = try await SimulationActions.execute(harness, action: .type(text: "Z"))
        #expect(editor.plainText == "abZc")

        // Cover-fit image cropping
        let widePixels: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255,   255, 255, 0, 255,
            255, 0, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255,   255, 255, 0, 255,
        ]
        let coverImg = ImageRenderable(
            ctx: renderer,
            options: ImageRenderableOptions(
                width: .point(2),
                height: .point(1),
                position: .absolute,
                top: .point(5),
                left: .point(0),
                source: .rgba(width: 4, height: 2, pixels: widePixels),
                fit: .cover
            )
        )
        renderer.root.add(coverImg)
        let frame = await SimulationActions.capture(harness)
        #expect(frame.images?.count == 1)
        #expect(frame.images?.first?.width == 2)
        #expect(frame.images?.first?.height == 1)
        #expect(frame.images?.first?.pixelWidth == 2)
        #expect(frame.images?.first?.pixelHeight == 2)

        await scope.close()

        // Drive.create in visible renderer mode resizes to manifest viewport
        let visibleManifest = """
        {"endpoints":{"ui":"ws://127.0.0.1:43200","backend":"ws://127.0.0.1:43250"},"viewport":{"cols":88,"rows":26}}
        """
        let visibleScope = LayerNode.ResourceScope()
        let visibleRenderer = try await Drive.create(
            options: CliRendererConfig(),
            version: "2.0.0-vis",
            environment: DictionaryEnvironment(variables: [
                "OPENCODE_DRIVE": "vis",
                "DRIVE_REGISTRY_DIR": "/drive",
                "OPENCODE_DRIVE_RENDERER": "visible",
            ]),
            fileSystem: InMemoryFileSystem(initialFiles: ["/drive/vis.json": Array(visibleManifest.utf8)]),
            bindNetwork: false,
            scope: visibleScope
        )
        #expect(visibleRenderer.width == 88)
        #expect(visibleRenderer.height == 26)
        await visibleScope.close()
    }
}
