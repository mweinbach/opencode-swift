import Testing
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeSDK
import OpenCodeServer
import OpenCodeUtil

@Suite("OpenCodeSDK Real OpenCodeServer.ServerRouter Integration Tests")
struct RealSDKRouterTests {
    @Test("OpenCode.create serves full non-stub protocol endpoints (/api/agent, /api/config, /api/mcp, /api/vcs, /openapi.json) via real ServerRouter")
    func embeddedHostServesAllRealServerRouterEndpoints() async throws {
        let dir = try SDKTestHelper.makeTempDirectory(prefix: "opencode-sdk-real-router")
        defer { SDKTestHelper.removeDirectory(dir) }

        let opencode = try await OpenCode.create(
            OpenCode.CreateOptions(
                app: .init(version: "sdk-router-test"),
                config: .init(directory: dir, project: false, content: "{\"default_agent\":\"build\"}")
            )
        )

        try await opencode.withClose { sdk in
            // 1. GET /api/agent (previously 404 on the 10-route stub!)
            let agents = try await sdk.agent.list()
            #expect(agents.location.directory.rawValue == dir)

            // 2. GET /api/config (previously 404 on the 10-route stub!)
            let configEntries = try await sdk.config.get()
            #expect(!configEntries.isEmpty)

            // 3. GET /api/mcp (previously 404 on the 10-route stub!)
            let mcpList = try await sdk.mcp.list()
            #expect(mcpList.location.directory.rawValue == dir)

            // 4. GET /api/vcs (previously 404 on the 10-route stub!)
            let vcsInfo = try await sdk.vcs.get()
            #expect(vcsInfo.location.directory.rawValue == dir)

            // 5. Additional non-stub endpoints served by real ServerRouter
            let commands = try await sdk.command.list()
            #expect(commands.location.directory.rawValue == dir)

            let skills = try await sdk.skill.list()
            #expect(skills.location.directory.rawValue == dir)

            let projects = try await sdk.project.list()
            #expect(projects.count >= 0)

            // 6. OpenAPI spec endpoint exposed directly by real OpenCodeServer.ServerRouter
            let specResp = try await sdk.host.fetch.send(
                HTTPRequest(method: "GET", url: "http://opencode.local/openapi.json")
            )
            #expect(specResp.head.statusCode == 200)
            let specText = String(decoding: specResp.body, as: UTF8.self)
            #expect(specText.contains("\"openapi\":\"3.1.0\""))
            #expect(specText.contains("/api/agent"))
            #expect(specText.contains("/api/config"))
            #expect(specText.contains("/api/mcp"))
            #expect(specText.contains("/api/vcs"))
        }
    }

    @Test("OpenCodeWorkerd serves real ServerRouter endpoints (/api/agent, /api/config, /api/mcp, /api/vcs) on DurableObjectStorage")
    func workerdHostServesRealServerRouterEndpoints() async throws {
        let storage = try SDKTestHelper.InMemoryDurableObjectStorage()
        defer { storage.close() }

        let opencode = try await OpenCodeWorkerd.create(
            OpenCodeWorkerd.CreateOptions(
                storage: storage,
                app: .init(version: "workerd-router-test"),
                config: WorkerdProfile.Configuration(defaultAgent: "build")
            )
        )

        try await opencode.withClose { sdk in
            let info = try await sdk.server.info()
            #expect(info.version == "workerd-router-test")
            #expect(info.pid == 0)
            #expect(info.hostname == nil)

            let agents = try await sdk.agent.list()
            #expect(agents.location.directory.rawValue == "/")

            let configEntries = try await sdk.config.get()
            #expect(!configEntries.isEmpty)

            let mcp = try await sdk.mcp.list()
            #expect(mcp.location.directory.rawValue == "/")

            let vcs = try await sdk.vcs.get()
            #expect(vcs.location.directory.rawValue == "/")
        }
    }
}
