import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Frontend UI simulation WebSocket JSON-RPC server (`packages/simulation/src/frontend/server.ts`).
public enum SimulationServer {
    /// Starts the UI Drive WebSocket control server dispatching all `ui.*` and `simulation.handshake` RPCs.
    // parity: simulation/src/frontend/server.ts#start [status=implemented hash=3f84d923e37d]
    public static func start(
        harness: SimulationActions.Harness,
        endpoint: String,
        version: String = "unknown",
        bindNetwork: Bool = true,
        scope: LayerNode.ResourceScope? = nil
    ) async throws -> SimulationControlServer.Server {
        try await SimulationControlServer.start(
            options: SimulationControlServer.StartOptions<OpenCodeProtocol.Frontend.Request>(
                endpoint: endpoint,
                label: "opencode drive ui websocket",
                data: { SimulationControlServer.SocketData(drive: true) },
                decode: { try OpenCodeProtocol.Frontend.decodeRequestEffect($0) },
                requestID: { requestID(of: $0) },
                handle: { _, request in
                    try await handle(harness: harness, request: request, version: version)
                },
                bindNetwork: bindNetwork
            ),
            scope: scope
        )
    }

    private static func requestID(of request: OpenCodeProtocol.Frontend.Request) -> OpenCodeProtocol.JsonRpc.ID? {
        switch request {
        case .handshake(let req): return req.id
        case .uiType(let id, _): return id
        case .uiPress(let id, _): return id
        case .uiArrow(let id, _): return id
        case .uiFocus(let id, _): return id
        case .uiClick(let id, _): return id
        case .uiMouse(let id, _): return id
        case .uiResize(let id, _): return id
        case .uiMatches(let id, _): return id
        case .uiEnter(let id): return id
        case .uiState(let id): return id
        case .uiSnapshot(let id): return id
        case .uiRecordingFinish(let id): return id
        case .uiCapture(let id): return id
        }
    }

    private static func handle(
        harness: SimulationActions.Harness,
        request: OpenCodeProtocol.Frontend.Request,
        version: String
    ) async throws -> JSONValue {
        switch request {
        case .handshake(let req):
            let response = try OpenCodeProtocol.Handshake.dispatch(
                action: OpenCodeProtocol.Handshake.DispatchAction(
                    role: .ui,
                    server: OpenCodeProtocol.Handshake.Identity(name: "opencode", version: version),
                    capabilities: OpenCodeProtocol.Frontend.Capabilities
                ),
                params: req.params
            )
            return try ServerCodec.toJSONValue(response)

        case .uiCapture:
            let frame = await SimulationActions.capture(harness)
            return try ServerCodec.toJSONValue(frame)

        case .uiState:
            let current = SimulationActions.state(harness)
            return try ServerCodec.toJSONValue(current)

        case .uiSnapshot:
            let snap = try SimulationActions.snapshot(harness)
            return try ServerCodec.toJSONValue(snap)

        case .uiMatches(_, let params):
            return .bool(SimulationActions.matches(harness, text: params.text))

        case .uiRecordingFinish:
            let path = try await SimulationRenderer.finish(harness.renderer)
            return .string(path)

        case .uiType(_, let params):
            let updated = try await SimulationActions.execute(harness, action: .type(text: params.text))
            return try ServerCodec.toJSONValue(updated)

        case .uiEnter:
            let updated = try await SimulationActions.execute(harness, action: .enter)
            return try ServerCodec.toJSONValue(updated)

        case .uiPress(_, let params):
            let updated = try await SimulationActions.execute(
                harness,
                action: .press(key: params.key, modifiers: params.modifiers)
            )
            return try ServerCodec.toJSONValue(updated)

        case .uiArrow(_, let params):
            let updated = try await SimulationActions.execute(harness, action: .arrow(direction: params.direction))
            return try ServerCodec.toJSONValue(updated)

        case .uiFocus(_, let params):
            let updated = try await SimulationActions.execute(harness, action: .focus(target: params.target))
            return try ServerCodec.toJSONValue(updated)

        case .uiClick(_, let params):
            let updated = try await SimulationActions.execute(
                harness,
                action: .click(target: params.target, x: params.x, y: params.y, semantic: params.semantic)
            )
            return try ServerCodec.toJSONValue(updated)

        case .uiMouse(_, let params):
            let updated = try await SimulationActions.execute(harness, action: .mouse(params: params))
            return try ServerCodec.toJSONValue(updated)

        case .uiResize(_, let params):
            let updated = try await SimulationActions.execute(
                harness,
                action: .resize(cols: params.cols, rows: params.rows)
            )
            return try ServerCodec.toJSONValue(updated)
        }
    }
}
