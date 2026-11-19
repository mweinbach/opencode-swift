import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Backend simulation layer replacements (`packages/simulation/src/backend/index.ts`).
///
/// Replaces `LayerNodePlatform.httpClient` when the server is built in simulation mode:
/// - Always answers the ModelsDev catalog fetch with `{}` so catalog startup stays offline.
/// - When `OPENCODE_DRIVE` is set, resolves `DriveManifest`, starts the Drive backend WebSocket
///   control server via `SimulatedProvider.layerDrive`, and registers `SimulationOpenAI.route`
///   as the first simulated network route.
public enum Simulation {
    /// Application version metadata passed into `simulationReplacements`.
    public struct AppDescriptor: Equatable, Hashable, Sendable {
        public let version: String

        public init(version: String) {
            self.version = version
        }
    }

    /// Canonical ModelsDev catalog URL answered offline with an empty JSON object in simulation mode.
    public static let modelsCatalogURL = "https://models.opencode.ai/experimental/v2.0/api.json"

    /// Builds `LayerNode.Replacements` overriding `LayerNodePlatform.httpClient` with the simulated network.
    // parity: simulation/src/backend/index.ts#simulationReplacements [status=implemented hash=bfbc8279b35b]
    public static func simulationReplacements(
        app: AppDescriptor,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        bindNetwork: Bool = true
    ) async throws -> LayerNode.Replacements {
        let models = SimulationNetwork.json(method: "GET", url: modelsCatalogURL, body: .object([:]))
        let drive = environment.variable("OPENCODE_DRIVE")
        guard let drive, !drive.isEmpty else {
            return [LayerNodePlatform.httpClient.replace(with: SimulationNetwork.layer(routes: [models]))]
        }

        let manifest = try await DriveManifest.resolve(environment: environment, fileSystem: fileSystem)
        let providerLayer = SimulatedProvider.layerDrive(
            SimulatedProvider.DriveOptions(
                endpoint: manifest.endpoints.backend,
                version: app.version,
                bindNetwork: bindNetwork
            )
        )
        let networkLayer = LayerNode.ExecutableLayer { deps, scope in
            let providerOut = try await providerLayer.build(deps, scope)
            guard let provider = providerOut.get(
                SimulatedProvider.Service.serviceKey,
                as: SimulatedProvider.Service.self
            ) else {
                throw LayerNode.GraphError("SimulatedProvider.layerDrive failed to produce SimulatedProvider.Service")
            }
            let network = SimulationNetwork.make(routes: [SimulationOpenAI.route(provider), models])
            var services: [String: any Sendable] = [
                LayerNodePlatform.httpClientKey: network.client,
                SimulatedProvider.Service.serviceKey: provider,
            ]
            if let server = providerOut.get(
                SimulatedProvider.driveServerKey,
                as: SimulationControlServer.Server.self
            ) {
                services[SimulatedProvider.driveServerKey] = server
            }
            return LayerNode.Output(services)
        }
        let networkNode = AppNode.makeGlobalNode(
            LayerNodePlatform.httpClientKey,
            networkLayer,
            [CorePlugin.SdkPlugins.node]
        )
        return [try LayerNodePlatform.httpClient.replace(with: networkNode)]
    }
}
