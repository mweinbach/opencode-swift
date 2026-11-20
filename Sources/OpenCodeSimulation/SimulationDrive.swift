import Synchronization
import OpenCodePlatform
import OpenCodeUtil
import OpenTUIRenderables

/// End-to-end Drive-mode renderer and UI control server acquisition (`packages/simulation/src/frontend/simulation.ts`).
public enum Drive {
    private struct WeakServerEntry: @unchecked Sendable {
        weak var renderer: CliRenderer?
        let server: SimulationControlServer.Server
    }

    private static let servers = Mutex<[ObjectIdentifier: WeakServerEntry]>([:])

    /// Resolves `DriveManifest`, acquires a headless or visible `CliRenderer`, starts `SimulationServer`
    /// on `manifest.endpoints.ui`, and returns the live `CliRenderer`.
    // parity: simulation/src/frontend/simulation.ts#create [status=implemented hash=5ff904d1275a]
    public static func create(
        options: CliRendererConfig = CliRendererConfig(),
        version: String,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        bindNetwork: Bool = true,
        scope: LayerNode.ResourceScope? = nil
    ) async throws -> CliRenderer {
        let headless = (environment.variable("OPENCODE_DRIVE_RENDERER") ?? "visible") == "headless"
        let manifest = try await DriveManifest.resolve(environment: environment, fileSystem: fileSystem)

        let viewport = manifest.viewport.map { SimulationRenderer.Viewport(cols: $0.cols, rows: $0.rows) }
        let renderer: CliRenderer
        if headless {
            renderer = try await SimulationRenderer.create(
                options: options,
                path: manifest.recording?.timeline,
                viewport: viewport,
                scope: scope
            )
        } else {
            renderer = await createCliRenderer(config: options)
            if let scope {
                scope.addFinalizer {
                    if !renderer.isDestroyed {
                        renderer.destroy()
                    }
                }
            }
            if let viewport {
                renderer.resize(width: viewport.cols, height: viewport.rows)
            }
        }

        let server = try await SimulationServer.start(
            harness: SimulationActions.createHarness(renderer),
            endpoint: manifest.endpoints.ui,
            version: version,
            bindNetwork: bindNetwork,
            scope: scope
        )

        let key = ObjectIdentifier(renderer)
        servers.withLock { map in
            if map.count > 64 {
                map = map.filter { $0.value.renderer != nil }
            }
            map[key] = WeakServerEntry(renderer: renderer, server: server)
        }

        return renderer
    }

    /// Returns the UI `SimulationControlServer.Server` started for a Drive-created `CliRenderer`, if still live.
    public static func serverFor(_ renderer: CliRenderer) -> SimulationControlServer.Server? {
        let key = ObjectIdentifier(renderer)
        return servers.withLock { map in
            guard let entry = map[key], entry.renderer === renderer else {
                return nil
            }
            return entry.server
        }
    }
}
