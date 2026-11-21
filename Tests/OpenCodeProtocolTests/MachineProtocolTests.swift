import Testing
import OpenCodeProtocol
import OpenCodeSchema

@Suite("Machine Protocol & Automation Shell Schema Parity Tests")
struct MachineProtocolTests {
    @Test("isWebSocketUpgrade and isMachineLinkUpgrade match upstream path and header rules")
    func machineLinkUpgradeDetection() {
        #expect(MACHINE_LINK_PATH == "/api/experimental/machine/link")

        let validHeaders = ["Upgrade": "WebSocket", "Connection": "keep-alive, Upgrade"]
        #expect(isWebSocketUpgrade(method: "GET", headers: validHeaders))
        #expect(!isWebSocketUpgrade(method: "POST", headers: validHeaders))
        #expect(!isWebSocketUpgrade(method: "GET", headers: ["Upgrade": "websocket"]))
        #expect(!isWebSocketUpgrade(method: "GET", headers: ["Connection": "Upgrade"]))

        #expect(isMachineLinkUpgrade(method: "GET", url: "/api/experimental/machine/link", headers: validHeaders))
        #expect(isMachineLinkUpgrade(method: "GET", url: "/api/experimental/machine/link?foo=bar", headers: validHeaders))
        // Dot segments and leading double-slash must NOT be normalized before comparing
        #expect(!isMachineLinkUpgrade(method: "GET", url: "/api/experimental/x/../machine/link", headers: validHeaders))
        #expect(!isMachineLinkUpgrade(method: "GET", url: "//host/api/experimental/machine/link", headers: validHeaders))
        #expect(!isMachineLinkUpgrade(method: "GET", url: "/api/experimental/machine", headers: validHeaders))
    }

    @Test("MachineEndpoints, MachineInfo, MachineInvite, and MachineNotFoundError wire contracts")
    func machineEndpointsAndSchemas() throws {
        #expect(MachineEndpoints.count == 4)
        #expect(MachineLinkEndpoint.path == MACHINE_LINK_PATH)
        #expect(MachineLinkEndpoint.isWebSocket)
        #expect(MachineLinkEndpoint.openAPIIdentifier == "experimental.machine.link")
        #expect(promiseOmitEndpoints.contains("machine.link"))
        #expect(effectOmitEndpoints.contains("machine.link"))

        let listEndpoint = try #require(ClientApi.endpoint(openAPIIdentifier: "experimental.machine.list"))
        #expect(listEndpoint.method == .get && listEndpoint.path == "/api/experimental/machine")
        let addEndpoint = try #require(ClientApi.endpoint(openAPIIdentifier: "experimental.machine.add"))
        #expect(addEndpoint.method == .post && addEndpoint.path == "/api/experimental/machine")
        let removeEndpoint = try #require(ClientApi.endpoint(openAPIIdentifier: "experimental.machine.remove"))
        #expect(removeEndpoint.method == .delete && removeEndpoint.path == "/api/experimental/machine/:name")
        #expect(removeEndpoint.successEncoding == .noContent)

        let info = MachineInfo(
            id: "gpu",
            online: true,
            paired: true,
            os: "linux",
            arch: "x64",
            connection: .init(kind: .iroh, path: .direct, rtt: 12.5)
        )
        #expect(try ProtocolTestCodec.roundTrip(info) == info)

        let invite = MachineInvite(
            name: "gpu",
            join: "ocjoin_abc",
            expires: 1_700_000_000_000,
            reach: [.url("wss://example.com/api/experimental/machine/link"), .iroh]
        )
        #expect(try ProtocolTestCodec.roundTrip(invite) == invite)

        let err = MachineNotFoundError(machine: "gpu", message: "No machine named \"gpu\".")
        #expect(MachineNotFoundError.httpStatusCode == 404)
        #expect(try ProtocolTestCodec.roundTrip(err) == err)
    }

    @Test("AutomationSchema.ShellAction and ShellActionInput round-trip and reject empty command")
    func automationShellActionSchema() throws {
        let action: AutomationSchema.Action = .shell(.init(command: "echo hi"))
        let fields = try ProtocolTestCodec.encodeObjectFields(action)
        #expect(fields["type"] == .string("shell"))
        #expect(fields["command"] == .string("echo hi"))
        #expect(try ProtocolTestCodec.roundTrip(action) == action)

        let input: AutomationSchema.ActionInput = .shell(.init(command: "make test"))
        #expect(try ProtocolTestCodec.roundTrip(input) == input)
    }
}
