import Testing
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeSimulation
import OpenCodeUtil
import OpenTUICore
import OpenTUIRenderables

@Suite("OpenCodeSimulation Module, Manifest & Recording")
struct OpenCodeSimulationTests {
    @Test("module metadata and protocol re-exports")
    func metadataAndProtocolReexports() {
        #expect(OpenCodeSimulationModule.upstreamPackage == "simulation")
        #expect(SimulationProtocol.Frontend.Capabilities.contains("ui.snapshot"))
        #expect(SimulationProtocol.Backend.Capabilities.contains("llm.attach"))
        #expect(SimulationProtocol.UiRpcs.method(tag: "ui.capture") != nil)
        #expect(SimulationProtocol.BackendRpcs.method(tag: "tool.attach") != nil)
    }

    // MARK: - DriveManifest

    @Test("DriveManifest resolves default manifest when OPENCODE_DRIVE=1")
    func manifestDefaultsForDrive1() async throws {
        let env = DictionaryEnvironment(variables: ["OPENCODE_DRIVE": "1"])
        let manifest = try await DriveManifest.resolve(environment: env, fileSystem: InMemoryFileSystem())
        #expect(manifest == DriveManifest.defaults)
        #expect(manifest.endpoints.ui == "ws://127.0.0.1:40900")
        #expect(manifest.endpoints.backend == "ws://127.0.0.1:40950")
    }

    @Test("DriveManifest loads and validates manifest from DRIVE_REGISTRY_DIR")
    func manifestLoadsAndValidates() async throws {
        let json = """
        {
          "endpoints": {
            "ui": "ws://127.0.0.1:41000",
            "backend": "ws://127.0.0.1:41050"
          },
          "viewport": { "cols": 120, "rows": 50 },
          "recording": { "timeline": "/tmp/drive/timeline.jsonl" }
        }
        """
        let fs = InMemoryFileSystem(initialFiles: ["/tmp/drive/test-instance.json": Array(json.utf8)])
        let env = DictionaryEnvironment(variables: [
            "OPENCODE_DRIVE": "test-instance",
            "DRIVE_REGISTRY_DIR": "/tmp/drive",
        ])

        let manifest = try await DriveManifest.resolve(environment: env, fileSystem: fs)
        #expect(manifest == DriveManifest.Manifest(
            endpoints: .init(ui: "ws://127.0.0.1:41000", backend: "ws://127.0.0.1:41050"),
            viewport: .init(cols: 120, rows: 50),
            recording: .init(timeline: "/tmp/drive/timeline.jsonl")
        ))
    }

    @Test("DriveManifest falls back to XDG_STATE_HOME/opencode-drive/instances")
    func manifestXDGStateFallback() async throws {
        let json = """
        {"endpoints":{"ui":"ws://127.0.0.1:42000","backend":"ws://127.0.0.1:42050"}}
        """
        let fs = InMemoryFileSystem(initialFiles: [
            "/state/opencode-drive/instances/ci_run.json": Array(json.utf8),
        ])
        let env = DictionaryEnvironment(variables: [
            "OPENCODE_DRIVE": "ci_run",
            "XDG_STATE_HOME": "/state",
        ])

        let manifest = try await DriveManifest.resolve(environment: env, fileSystem: fs)
        #expect(manifest.endpoints.ui == "ws://127.0.0.1:42000")
        #expect(manifest.endpoints.backend == "ws://127.0.0.1:42050")
    }

    @Test("DriveManifest reports typed config, not-found, and decode failures")
    func manifestTypedErrors() async {
        // Missing / invalid OPENCODE_DRIVE -> .config
        do {
            _ = try await DriveManifest.resolve(
                environment: DictionaryEnvironment(variables: ["OPENCODE_DRIVE": "../escape"]),
                fileSystem: InMemoryFileSystem()
            )
            Issue.record("Expected config error for invalid instance name")
        } catch {
            #expect(error.reason == .config)
        }

        // Missing file -> .notFound
        do {
            _ = try await DriveManifest.resolve(
                environment: DictionaryEnvironment(variables: [
                    "OPENCODE_DRIVE": "missing-instance",
                    "DRIVE_REGISTRY_DIR": "/tmp/drive",
                ]),
                fileSystem: InMemoryFileSystem()
            )
            Issue.record("Expected not-found error")
        } catch {
            #expect(error.reason == .notFound)
            #expect(error.path == "/tmp/drive/missing-instance.json")
        }

        // Non-loopback / non-ws endpoint -> .decode
        let invalidEndpoint = """
        {"endpoints":{"ui":"https://example.com","backend":"ws://127.0.0.1:41050"}}
        """
        do {
            _ = try await DriveManifest.resolve(
                environment: DictionaryEnvironment(variables: [
                    "OPENCODE_DRIVE": "bad-endpoint",
                    "DRIVE_REGISTRY_DIR": "/tmp/drive",
                ]),
                fileSystem: InMemoryFileSystem(initialFiles: [
                    "/tmp/drive/bad-endpoint.json": Array(invalidEndpoint.utf8),
                ])
            )
            Issue.record("Expected decode error for non-loopback endpoint")
        } catch {
            #expect(error.reason == .decode)
        }

        // Relative timeline path -> .decode
        let relativeTimeline = """
        {"endpoints":{"ui":"ws://127.0.0.1:41000","backend":"ws://127.0.0.1:41050"},"recording":{"timeline":"relative/timeline.jsonl"}}
        """
        do {
            _ = try DriveManifest.decode(relativeTimeline)
            Issue.record("Expected decode error for relative recording path")
        } catch {
            #expect(error.reason == .decode)
        }
    }

    // MARK: - SimulationRecording

    @Test("Timeline streams ANSI chunks and resizes into versioned v1 JSONL")
    func timelineStreamsVersionedJSONL() async throws {
        let dir = try SimTestFS.makeTempDir(prefix: "sim-rec-")
        defer { SimTestFS.remove(dir) }
        let path = "\(dir)/nested/timeline.jsonl"
        let clock = SimTestClock(startMs: 5_000)

        let timeline = try await SimulationRecording.Timeline.create(
            path: path,
            cols: 80,
            rows: 24,
            nowMs: { clock.now() }
        )
        #expect(timeline.isTTY == true)
        #expect(timeline.getColorDepth() == 24)
        clock.advance(by: 15)
        timeline.write("\u{1B}[2Jhello")
        clock.advance(by: 25)
        timeline.resize(cols: 100, rows: 30)
        clock.advance(by: 10)
        let finishedPath = try await timeline.finish()
        #expect(finishedPath == path)
        // Idempotent finish & ignored post-finish writes
        #expect(try await timeline.finish() == path)
        timeline.write("ignored")
        timeline.resize(cols: 50, rows: 10)

        let raw = try SimTestFS.readText(path)
        let events = try SimulationRecording.parseTimeline(raw)
        #expect(events.count == 4)
        #expect(events[0] == .header(SimulationRecording.Header(cols: 80, rows: 24)))
        guard case .output(let firstOut) = events[1] else {
            Issue.record("Expected output event at index 1")
            return
        }
        #expect(firstOut.at_ms == 15)
        #expect(String(decoding: try base64ToBytes(firstOut.data), as: UTF8.self) == "\u{1B}[2Jhello")
        #expect(events[2] == .resize(SimulationRecording.Resize(at_ms: 40, cols: 100, rows: 30)))
        #expect(events[3] == .output(SimulationRecording.Output(at_ms: 50, data: "")))
    }

    @Test("Timeline finishes pointer sidecar on shared monotonic clock without altering v1 timeline")
    func timelinePointerSidecar() async throws {
        let dir = try SimTestFS.makeTempDir(prefix: "sim-ptr-")
        defer { SimTestFS.remove(dir) }
        let path = "\(dir)/timeline.jsonl"
        let clock = SimTestClock(startMs: 1_000)

        let timeline = try await SimulationRecording.Timeline.create(
            path: path,
            cols: 80,
            rows: 24,
            nowMs: { clock.now() }
        )
        clock.advance(by: 5)
        timeline.write("before")
        clock.advance(by: 10)
        timeline.pointer(action: .move, x: 12, y: 5)
        clock.advance(by: 7)
        timeline.pointer(action: .click, x: 15, y: 6)
        clock.advance(by: 8)
        timeline.write("after")
        clock.advance(by: 5)
        let result = try await timeline.finish()
        #expect(result == path)
        // Post-finish pointer events are ignored
        timeline.pointer(action: .move, x: 30, y: 10)

        let pointers = try SimulationRecording.parsePointers(try SimTestFS.readText("\(dir)/timeline.pointers.jsonl"))
        #expect(pointers == [
            SimulationRecording.Pointer(atMs: 15, action: .move, x: 12, y: 5),
            SimulationRecording.Pointer(atMs: 22, action: .click, x: 15, y: 6),
        ])

        let events = try SimulationRecording.parseTimeline(try SimTestFS.readText(path))
        #expect(events.count == 4)
        if case .output(let firstOut) = events[1], case .output(let lastOut) = events[3] {
            #expect(pointers[0].atMs >= firstOut.at_ms)
            #expect(pointers[1].atMs <= lastOut.at_ms)
        } else {
            Issue.record("Expected output events bracketing pointer timestamps")
        }
    }

    @Test("Timeline closes both streams and rejects finish after pointer sidecar failure")
    func timelinePointerFailureClosesStreams() async throws {
        let dir = try SimTestFS.makeTempDir(prefix: "sim-ptr-fail-")
        defer { SimTestFS.remove(dir) }
        let path = "\(dir)/timeline.jsonl"
        let timeline = try await SimulationRecording.Timeline.create(path: path, cols: 80, rows: 24)
        // Make sidecar path a directory so opening it fails with EISDIR
        try SimTestFS.makeDirectory("\(dir)/timeline.pointers.jsonl")
        timeline.pointer(action: .move, x: 10, y: 5)
        #expect(timeline.isClosed == true)

        var threw = false
        do {
            _ = try await timeline.finish()
        } catch {
            threw = true
        }
        #expect(threw)
        // Second finish also rejects with the same recorded failure
        var threwSecond = false
        do {
            _ = try await timeline.finish()
        } catch {
            threwSecond = true
        }
        #expect(threwSecond)
    }

    @Test("SimulationRenderer records terminal restoration before finishing on destroy and scope close")
    func rendererRecordingRestorationAndLiveMatches() async throws {
        let dir = try SimTestFS.makeTempDir(prefix: "sim-ren-rec-")
        defer { SimTestFS.remove(dir) }

        // 1. Destroy then explicit finish
        let destroyPath = "\(dir)/destroy.jsonl"
        do {
            let scope = LayerNode.ResourceScope()
            let renderer = try await SimulationRenderer.create(
                options: CliRendererConfig(screenMode: .alternateScreen),
                path: destroyPath,
                scope: scope
            )
            SimulationRenderer.setupFor(renderer)?.renderOnce()
            renderer.destroy()
            let finished = try await SimulationRenderer.finish(renderer)
            #expect(finished == destroyPath)
            await scope.close()
        }
        let destroyEvents = try SimulationRecording.parseTimeline(try SimTestFS.readText(destroyPath))
        let destroyOutputs = try destroyEvents.compactMap { event -> String? in
            guard case .output(let out) = event else { return nil }
            return String(decoding: try base64ToBytes(out.data), as: UTF8.self)
        }
        #expect(destroyOutputs.joined().contains("\u{1B}[?1049l"))
        #expect(destroyOutputs.count >= 2)
        #expect(destroyOutputs[destroyOutputs.count - 2].contains("\u{1B}[?25h"))
        #expect(destroyOutputs.last == "")

        // 2. Scope close automatically restores terminal before finishing recording
        let scopePath = "\(dir)/scope.jsonl"
        do {
            let scope = LayerNode.ResourceScope()
            let renderer = try await SimulationRenderer.create(
                options: CliRendererConfig(screenMode: .alternateScreen),
                path: scopePath,
                scope: scope
            )
            SimulationRenderer.setupFor(renderer)?.renderOnce()
            await scope.close()
        }
        let scopeEvents = try SimulationRecording.parseTimeline(try SimTestFS.readText(scopePath))
        let scopeOutputs = try scopeEvents.compactMap { event -> String? in
            guard case .output(let out) = event else { return nil }
            return String(decoding: try base64ToBytes(out.data), as: UTF8.self)
        }
        #expect(scopeOutputs.joined().contains("\u{1B}[?1049l"))
        #expect(scopeOutputs.last == "")

        // 3. Live screen text matching works while recording, and finishing recording keeps renderer alive
        let livePath = "\(dir)/live.jsonl"
        let scope = LayerNode.ResourceScope()
        let renderer = try await SimulationRenderer.create(path: livePath, scope: scope)
        renderer.root.add(TextRenderable(ctx: renderer, options: TextOptions(content: "recorded screen text")))
        SimulationRenderer.setupFor(renderer)?.renderOnce()
        #expect(SimulationActions.matches(SimulationActions.createHarness(renderer), text: "recorded screen text") == true)
        #expect(try await SimulationRenderer.finish(renderer) == livePath)
        SimulationRenderer.setupFor(renderer)?.renderOnce()
        #expect(renderer.isDestroyed == false)
        await scope.close()
    }
}
