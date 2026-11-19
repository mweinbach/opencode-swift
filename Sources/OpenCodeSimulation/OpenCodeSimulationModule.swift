import OpenCodeProtocol

/// Deterministic frontend/backend simulation harness (`packages/simulation`).
public enum OpenCodeSimulationModule {
    public static let upstreamPackage = "simulation"
}

/// Re-exports of `@opencode/protocol/simulation` matching `packages/simulation/src/protocol/index.ts`.
public enum SimulationProtocol {
    public typealias Backend = OpenCodeProtocol.Backend
    public typealias Frontend = OpenCodeProtocol.Frontend
    public typealias Handshake = OpenCodeProtocol.Handshake
    public typealias JsonRpc = OpenCodeProtocol.JsonRpc
    public typealias SimulationRequestError = OpenCodeProtocol.SimulationRequestError
    public static let UiRpcs = OpenCodeProtocol.UiRpcs
    public static let BackendRpcs = OpenCodeProtocol.BackendRpcs
}
