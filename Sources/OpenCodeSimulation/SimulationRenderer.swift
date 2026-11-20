import Synchronization
import OpenCodeUtil
import OpenTUICore
import OpenTUIRenderables

/// Headless OpenTUI `TestRenderer` acquisition and recording lifecycle
/// (`packages/simulation/src/frontend/renderer.ts`).
public enum SimulationRenderer {
    /// Viewport dimensions (`cols` x `rows`) for a simulated terminal renderer.
    // parity: simulation/src/frontend/renderer.ts#Viewport [status=implemented hash=efbc78adb29b]
    public struct Viewport: Equatable, Hashable, Sendable, Codable {
        public let cols: Int
        public let rows: Int

        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }
    }

    /// Error raised when a renderer recording operation cannot be satisfied.
    public struct RendererError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    private struct WeakSetupEntry: @unchecked Sendable {
        weak var renderer: CliRenderer?
        let setup: TestRenderer
    }

    private struct WeakRecordingEntry: @unchecked Sendable {
        weak var renderer: CliRenderer?
        let timeline: SimulationRecording.Timeline
    }

    private static let setups = Mutex<[ObjectIdentifier: WeakSetupEntry]>([:])
    private static let recordings = Mutex<[ObjectIdentifier: WeakRecordingEntry]>([:])

    /// Creates a headless `CliRenderer` backed by an in-memory `TestRenderer` with optional JSONL recording.
    ///
    /// Keeps the `TestRenderer` setup and optional `Timeline` in module-side weak tables so app code
    /// only carries `CliRenderer` while the simulation harness can access testing APIs and recording hooks.
    // parity: simulation/src/frontend/renderer.ts#create [status=implemented hash=e8715ffa5e0d]
    public static func create(
        options: CliRendererConfig = CliRendererConfig(),
        path: String? = nil,
        viewport: Viewport? = nil,
        scope: LayerNode.ResourceScope? = nil
    ) async throws -> CliRenderer {
        let cols = viewport?.cols ?? 100
        let rows = viewport?.rows ?? 40

        let recording: SimulationRecording.Timeline?
        if let path {
            let timeline = try await SimulationRecording.Timeline.create(path: path, cols: cols, rows: rows)
            recording = timeline
            if let scope {
                scope.addFinalizer {
                    _ = try? await timeline.finish()
                }
            }
        } else {
            recording = nil
        }

        let testOptions = TestRendererOptions(
            width: cols,
            height: rows,
            kittyKeyboard: options.useKittyKeyboard != nil,
            otherModifiersMode: false,
            screenMode: options.screenMode,
            footerHeight: options.footerHeight,
            backgroundColor: options.backgroundColor,
            useMouse: options.useMouse,
            autoFocus: options.autoFocus,
            exitOnCtrlC: options.exitOnCtrlC,
            widthMethod: options.widthMethod,
            rendererCapabilities: options.rendererCapabilities,
            clock: options.clock as? ManualClock,
            debounceDelay: options.debounceDelay
        )
        let setup = createTestRenderer(options: testOptions)
        let renderer = setup.renderer

        if let recording {
            let previousWriter = renderer.outputWriter
            // Finishing a recording must not close the live renderer's output sink.
            renderer.outputWriter = { chunk in
                previousWriter?(chunk)
                recording.write(chunk)
            }
            let screenMode = options.screenMode
            _ = renderer.on(.destroy) {
                if screenMode == .alternateScreen {
                    recording.write(ANSI.switchToMainScreen)
                }
                recording.write("\u{1B}[?25h")
            }
        }

        if let scope {
            scope.addFinalizer {
                if !renderer.isDestroyed {
                    renderer.destroy()
                }
            }
        }

        await renderer.setupTerminal()

        let key = ObjectIdentifier(renderer)
        setups.withLock { map in
            if map.count > 128 {
                map = map.filter { $0.value.renderer != nil }
            }
            map[key] = WeakSetupEntry(renderer: renderer, setup: setup)
        }
        if let recording {
            recordings.withLock { map in
                if map.count > 128 {
                    map = map.filter { $0.value.renderer != nil }
                }
                map[key] = WeakRecordingEntry(renderer: renderer, timeline: recording)
            }
        }

        return renderer
    }

    /// Records a viewport resize event into the renderer's active timeline (if recording).
    // parity: simulation/src/frontend/renderer.ts#recordResize [status=implemented hash=9fd8017f091e]
    public static func recordResize(_ renderer: CliRenderer, cols: Int, rows: Int) {
        recordingFor(renderer)?.resize(cols: cols, rows: rows)
    }

    /// Records a pointer action into the renderer's pointer sidecar (if recording).
    // parity: simulation/src/frontend/renderer.ts#recordPointer [status=implemented hash=1f979afc73b3]
    public static func recordPointer(
        _ renderer: CliRenderer,
        action: SimulationRecording.Pointer.Action,
        x: Int,
        y: Int
    ) {
        recordingFor(renderer)?.pointer(action: action, x: x, y: y)
    }

    /// Looks up the module-side `TestRenderer` setup associated with a headless simulation `CliRenderer`.
    // parity: simulation/src/frontend/renderer.ts#setupFor [status=implemented hash=456ab40e5bde]
    public static func setupFor(_ renderer: CliRenderer) -> TestRenderer? {
        let key = ObjectIdentifier(renderer)
        return setups.withLock { map in
            guard let entry = map[key], entry.renderer === renderer else {
                return nil
            }
            return entry.setup
        }
    }

    /// Finalizes the active recording timeline for `renderer` and returns its file path.
    // parity: simulation/src/frontend/renderer.ts#finish [status=implemented hash=3904dff5eb1f]
    public static func finish(_ renderer: CliRenderer) async throws -> String {
        guard let recording = recordingFor(renderer) else {
            throw RendererError("UI recording is not available")
        }
        return try await recording.finish()
    }

    private static func recordingFor(_ renderer: CliRenderer) -> SimulationRecording.Timeline? {
        let key = ObjectIdentifier(renderer)
        return recordings.withLock { map in
            guard let entry = map[key], entry.renderer === renderer else {
                return nil
            }
            return entry.timeline
        }
    }
}
