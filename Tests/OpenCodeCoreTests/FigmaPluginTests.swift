import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("FigmaPlugin Tests")
struct FigmaPluginTests {
    /// Core 11 Figma skills explicitly required, plus the full 14-skill upstream bundle.
    private static let requiredElevenSkillIDs: [String] = [
        "figma-code-connect",
        "figma-create-new-file",
        "figma-design-to-code",
        "figma-generate-design",
        "figma-generate-diagram",
        "figma-generate-library",
        "figma-generative-plugins",
        "figma-implement-motion",
        "figma-shaders",
        "figma-use-motion",
        "figma-use-slides",
    ]

    private static let allOfficialUpstreamSkillIDs: [String] = [
        "figma-code-connect",
        "figma-create-new-file",
        "figma-design-to-code",
        "figma-generate-design",
        "figma-generate-diagram",
        "figma-generate-library",
        "figma-generative-plugins",
        "figma-implement-motion",
        "figma-shaders",
        "figma-swiftui",
        "figma-use",
        "figma-use-figjam",
        "figma-use-motion",
        "figma-use-slides",
    ]

    // MARK: - 1. Bundle Discovery & Attribution

    @Test("Bundled FigmaSkills resource root, NOTICE.md, and skills-source.json resolve from Bundle.module")
    func bundledRootNoticeAndSourceManifest() throws {
        let rootPath = try #require(FigmaPluginHelper.bundledSkillsRootPath())
        #expect(rootPath.hasSuffix("/FigmaSkills"))

        let notice = try #require(FigmaPlugin.bundledNotice())
        #expect(notice.contains("Figma Developer Terms"))
        #expect(notice.contains("mcp-server-guide"))

        let manifest = try #require(FigmaPlugin.bundledSourceManifest())
        #expect(manifest.repository == "https://github.com/figma/mcp-server-guide.git")
        #expect(manifest.revision == "f0493295acf5f7cbdebcbcc483c06de814420cb1")
        #expect(manifest.skills == Self.allOfficialUpstreamSkillIDs)
    }

    @Test("bundledSkillDirectories() discovers all 11 required and all 14 official Figma skills from Bundle.module")
    func bundledSkillDirectoriesDiscovery() {
        let names = FigmaPluginHelper.bundledSkillDirectoryNames()
        #expect(names == Self.allOfficialUpstreamSkillIDs)
        for requiredID in Self.requiredElevenSkillIDs {
            #expect(names.contains(requiredID))
        }

        let paths = FigmaPluginHelper.bundledSkillDirectoryPaths()
        #expect(paths.count == Self.allOfficialUpstreamSkillIDs.count)
        for (name, path) in zip(names, paths) {
            #expect(path.hasSuffix("/\(name)"))
        }
    }

    // MARK: - 2. Bundled Skills Loading, YAML Frontmatter & Reference Enumeration

    @Test("loadBundledSkills() parses YAML frontmatter and enumerates sibling references for every bundled Figma skill")
    func loadAllBundledSkillsAndReferences() throws {
        let skills = try FigmaPlugin.loadBundledSkills()
        #expect(skills.count == Self.allOfficialUpstreamSkillIDs.count)

        let byID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id.rawValue, $0) })

        for skillID in Self.requiredElevenSkillIDs {
            let skill = try #require(byID[skillID], "Missing required Figma skill '\(skillID)'")
            #expect(skill.name.rawValue == skillID)
            let desc = try #require(skill.description, "Expected non-empty description for '\(skillID)'")
            #expect(!desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(skill.autoinvoke == true)
            #expect(skill.info.path.rawValue.hasSuffix("/\(skillID)/SKILL.md"))
            #expect(!skill.info.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!skill.info.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---"))
        }

        // Verify exact reference counts and sibling files for skills that ship references & scripts
        let expectedMarkdownReferenceCounts: [String: Int] = [
            "figma-code-connect": 2,
            "figma-create-new-file": 0,
            "figma-design-to-code": 0,
            "figma-generate-design": 2,
            "figma-generate-diagram": 7,
            "figma-generate-library": 7,
            "figma-generative-plugins": 1,
            "figma-implement-motion": 6,
            "figma-shaders": 1,
            "figma-swiftui": 2,
            "figma-use": 19,
            "figma-use-figjam": 13,
            "figma-use-motion": 2,
            "figma-use-slides": 6,
        ]

        for (skillID, expectedCount) in expectedMarkdownReferenceCounts {
            let skill = try #require(byID[skillID])
            #expect(skill.markdownReferences.count == expectedCount, "Unexpected markdown reference count for \(skillID)")
            for ref in skill.referenceFiles {
                #expect(ref.isReference)
                #expect(!ref.content.isEmpty, "Reference file \(ref.relativePath) in \(skillID) should be non-empty")
                #expect(skill.siblingFiles[ref.relativePath] == ref.content)
            }
        }

        // Spot-check specific upstream reference documents & nested assets
        let codeConnect = try #require(byID["figma-code-connect"])
        #expect(codeConnect.markdownReferences.map(\.relativePath) == [
            "references/advanced-patterns.md",
            "references/api.md",
        ])

        let generateLibrary = try #require(byID["figma-generate-library"])
        #expect(generateLibrary.scriptPaths.count == 8)
        #expect(generateLibrary.scriptPaths.contains("scripts/createSemanticTokens.js"))

        let figmaUse = try #require(byID["figma-use"])
        #expect(figmaUse.referenceFiles.count == 20) // 19 .md + plugin-api-standalone.d.ts
        #expect(figmaUse.siblingFiles["references/plugin-api-standalone.d.ts"]?.isEmpty == false)
        #expect(figmaUse.siblingFiles["references/working-with-design-systems/wwds.md"]?.isEmpty == false)
    }

    @Test("loadBundledSkill(id:) loads individual skills and rejects unknown or path-traversal IDs")
    func loadSingleBundledSkill() throws {
        let motion = try #require(try FigmaPlugin.loadBundledSkill(id: "figma-implement-motion"))
        #expect(motion.id.rawValue == "figma-implement-motion")
        #expect(motion.markdownReferences.count == 6)

        #expect(try FigmaPlugin.loadBundledSkill(id: "nonexistent-skill") == nil)
        #expect(try FigmaPlugin.loadBundledSkill(id: "../NOTICE.md") == nil)
        #expect(try FigmaPlugin.loadBundledSkill(id: "figma-use/references") == nil)
    }

    @Test("parseSkillMarkdown handles disable-model-invocation, fallback name, and malformed frontmatter")
    func parseSkillMarkdownEdgeCases() throws {
        let disabledMD = """
        ---
        name: custom-figma-skill
        description: "Manual-only Figma workflow: test colon handling"
        disable-model-invocation: true
        ---

        # Body Content
        """
        let parsedDisabled = try FigmaPlugin.parseSkillMarkdown(
            id: "figma-manual",
            skillFilePath: "/tmp/figma-manual/SKILL.md",
            directoryPath: "/tmp/figma-manual",
            rawMarkdown: disabledMD
        )
        #expect(parsedDisabled.id.rawValue == "figma-manual")
        #expect(parsedDisabled.name.rawValue == "custom-figma-skill")
        #expect(parsedDisabled.description == "Manual-only Figma workflow: test colon handling")
        #expect(parsedDisabled.autoinvoke == false)
        #expect(parsedDisabled.info.content.contains("# Body Content"))

        let badFrontmatter = """
        ---
        name: 12345
        description: "Invalid name type"
        ---
        Body
        """
        #expect(throws: FigmaPlugin.Error.self) {
            _ = try FigmaPlugin.parseSkillMarkdown(
                id: "bad-skill",
                skillFilePath: "/tmp/bad-skill/SKILL.md",
                directoryPath: "/tmp/bad-skill",
                rawMarkdown: badFrontmatter
            )
        }
    }

    // MARK: - 3. MCP Endpoint Config, Validation & OAuth/DCR Metadata

    @Test("MCP server configuration supports remote OAuth/DCR, Desktop local loopback, and custom endpoints")
    func mcpEndpointConfigAndValidation() throws {
        let remoteConfig = FigmaPlugin.remoteServerConfig()
        guard case .remote(let remote) = remoteConfig else {
            Issue.record("Expected .remote config for Figma remote MCP")
            return
        }
        #expect(remote.url == "https://mcp.figma.com/mcp")
        #expect(remote.oauth == nil) // Uses OpenCode OAuth discovery + DCR without explicit credentials
        #expect(remote.disabled == nil)

        let desktopConfig = FigmaPlugin.desktopServerConfig()
        guard case .remote(let desktop) = desktopConfig else {
            Issue.record("Expected .remote HTTP config for Figma Desktop MCP")
            return
        }
        #expect(desktop.url == "http://127.0.0.1:3845/mcp")
        #expect(desktop.oauth == .disabled)

        let customPortDesktop = FigmaPlugin.desktopServerConfig(port: 4100)
        if case .remote(let customDesktop) = customPortDesktop {
            #expect(customDesktop.url == "http://127.0.0.1:4100/mcp")
            #expect(customDesktop.oauth == .disabled)
        } else {
            Issue.record("Expected .remote config")
        }

        let customRemote = try FigmaPlugin.validatedMCPServerConfig(
            endpoint: .custom(url: "https://figma-proxy.internal.example/mcp"),
            headers: ["X-Org": "design"]
        )
        if case .remote(let cfg) = customRemote {
            #expect(cfg.url == "https://figma-proxy.internal.example/mcp")
            #expect(cfg.headers == ["X-Org": "design"])
            #expect(cfg.oauth == nil)
        } else {
            Issue.record("Expected .remote config")
        }

        let customLoopback = try FigmaPlugin.validatedMCPServerConfig(
            endpoint: .custom(url: "http://localhost:9000/mcp")
        )
        if case .remote(let cfg) = customLoopback {
            #expect(cfg.oauth == .disabled)
        }

        #expect(throws: FigmaPlugin.Error.invalidDesktopPort(0)) {
            _ = try FigmaPlugin.validatedMCPServerConfig(endpoint: .desktop(port: 0))
        }
        #expect(throws: FigmaPlugin.Error.invalidDesktopPort(70_000)) {
            _ = try FigmaPlugin.validatedMCPServerConfig(endpoint: .desktop(port: 70_000))
        }
        #expect(throws: FigmaPlugin.Error.invalidEndpointURL("ftp://invalid.example/mcp")) {
            _ = try FigmaPlugin.validatedMCPServerConfig(endpoint: .custom(url: "ftp://invalid.example/mcp"))
        }
    }

    @Test("Endpoint parsing from plugin options, AuthMetadata, OAuth authorization, and Descriptor round-trip")
    func optionsAuthMetadataAndDescriptor() throws {
        #expect(FigmaPlugin.endpoint(from: [:]) == .remote)
        #expect(FigmaPlugin.endpoint(from: ["desktop": .bool(true)]) == .desktop(port: 3845))
        #expect(FigmaPlugin.endpoint(from: ["endpoint": .string("desktop"), "port": .int(4242)]) == .desktop(port: 4242))
        #expect(FigmaPlugin.endpoint(from: ["endpoint": .string("remote")]) == .remote)
        #expect(
            FigmaPlugin.endpoint(from: ["url": .string("https://mcp.figma.com/custom")])
                == .custom(url: "https://mcp.figma.com/custom")
        )

        let remoteAuth = FigmaPlugin.authMetadata(for: .remote)
        #expect(remoteAuth.mode == .oauthDCR)
        #expect(remoteAuth.dynamicClientRegistration == true)
        #expect(remoteAuth.usesLoopbackCallback == true)
        #expect(remoteAuth.requiresClientSecret == false)
        #expect(remoteAuth.clientMetadataURL == CoreMCP.OAuth.CLIENT_METADATA_URL)
        #expect(remoteAuth.verificationTool == "whoami")
        #expect(remoteAuth.recommendedOAuthOption == nil)

        let desktopAuth = FigmaPlugin.authMetadata(for: .desktop())
        #expect(desktopAuth.mode == .localDesktop)
        #expect(desktopAuth.dynamicClientRegistration == false)
        #expect(desktopAuth.recommendedOAuthOption == .disabled)

        let oauthFlow = try #require(FigmaPlugin.oauthAuthorization(endpoint: .remote))
        #expect(oauthFlow.url.hasPrefix("https://mcp.figma.com/mcp?response_type=code"))
        #expect(FigmaPlugin.oauthAuthorization(endpoint: .desktop()) == nil)

        let descriptor = FigmaPlugin.descriptor
        #expect(descriptor.id == "opencode.figma")
        #expect(descriptor.packageName == "@opencode/plugin-figma")
        #expect(descriptor.version == "2.3.0")
        #expect(descriptor.serverName == "figma")
        #expect(descriptor.defaultEndpoint == .remote)
        #expect(descriptor.source?.skills.count == Self.allOfficialUpstreamSkillIDs.count)

        let roundTripped = try FigmaPluginHelper.encodeAndDecode(descriptor)
        #expect(roundTripped == descriptor)
    }

    // MARK: - 4. CoreSkill.Service & CoreMCP.Registry.Service Registration Helpers

    @Test("register(into:mcpService:) populates CoreSkill.Service with sibling references, wires MCP, preserves existing config, and disposes cleanly")
    func registerIntoCoreSkillAndMCPServices() async throws {
        let skillService = CoreSkill.Service()
        let mcpService = CoreMCP.Registry.Service()

        let handle = try await FigmaPlugin.register(
            into: skillService,
            mcpService: mcpService,
            endpoint: .remote
        )

        let registeredSkills = await skillService.list()
        #expect(registeredSkills.count == Self.allOfficialUpstreamSkillIDs.count)

        for requiredID in Self.requiredElevenSkillIDs {
            let found = await skillService.get(SkillSchema.ID(rawValue: requiredID))
            #expect(found != nil)
            #expect(found?.description?.isEmpty == false)
        }

        // Sibling references & scripts are attached in CoreSkill.Service
        let diagramFiles = try #require(await skillService.files(SkillSchema.ID(rawValue: "figma-generate-diagram")))
        #expect(diagramFiles.count == 7)
        #expect(diagramFiles["references/architecture.md"]?.isEmpty == false)

        let libraryFiles = try #require(await skillService.files(SkillSchema.ID(rawValue: "figma-generate-library")))
        #expect(libraryFiles["references/token-creation.md"]?.isEmpty == false)
        #expect(libraryFiles["scripts/createSemanticTokens.js"]?.isEmpty == false)

        // CoreSkill.SkillInstructions renders all bundled Figma skills cleanly
        let instructionService = CoreSkill.SkillInstructions.Service(skills: skillService)
        let sources = await instructionService.load(permissions: [])
        let readResult = await CoreInstruction.Instructions.read(sources)
        let admission = try CoreInstruction.Instructions.diff(observed: readResult)
        var valuesByKey: [String: JSONValue] = [:]
        for (key, deltaVal) in admission.delta {
            if case .hash(let h) = deltaVal, let blob = admission.blobs[h.rawValue] {
                valuesByKey[key] = blob
            }
        }
        let rendered = CoreInstruction.Instructions.join(
            CoreInstruction.Instructions.renderInitial(sources, values: valuesByKey)
        )
        #expect(rendered.contains("<id>figma-design-to-code</id>"))
        #expect(rendered.contains("<id>figma-code-connect</id>"))

        // MCP server registered with remote endpoint
        let servers = await mcpService.servers()
        #expect(servers.map(\.name) == ["figma"])
        let storedConfig = try await FigmaPluginHelper.inspectMCPConfig(named: "figma", in: mcpService)
        #expect(storedConfig == FigmaPlugin.remoteServerConfig())

        // Disposing handle cleanly removes both registrations
        await handle.dispose()
        #expect(await skillService.list().isEmpty)
        #expect(await mcpService.servers().isEmpty)
    }

    @Test("Registration preserves existing user MCP server (including disabled/custom) and user-overridden skills")
    func registrationPreservesExistingOverrides() async throws {
        let skillService = CoreSkill.Service()
        let mcpService = CoreMCP.Registry.Service()

        let customSkill = SkillSchema.Info(
            id: SkillSchema.ID(rawValue: "figma-shaders"),
            name: SkillSchema.Name(rawValue: "custom-user-shaders"),
            description: "User override",
            autoinvoke: true,
            path: SchemaPrimitive.AbsolutePath(rawValue: "/workspace/.opencode/skills/figma-shaders/SKILL.md"),
            content: "# Custom Shaders Override"
        )
        _ = try await skillService.transform { editor in
            editor.add(customSkill)
        }

        let disabledUserMCP = McpSchema.ServerConfig.remote(
            McpSchema.RemoteConfig(url: "https://enterprise.figma.example/mcp", disabled: true)
        )
        _ = try await mcpService.transform { editor in
            editor.set("figma", config: disabledUserMCP)
        }

        let handle = try await FigmaPlugin.register(
            into: skillService,
            mcpService: mcpService,
            endpoint: .desktop(),
            preserveExisting: true
        )

        // Existing user skill override is preserved; all other bundled Figma skills are added
        let shaderSkill = try #require(await skillService.get(SkillSchema.ID(rawValue: "figma-shaders")))
        #expect(shaderSkill.name.rawValue == "custom-user-shaders")
        #expect(shaderSkill.content == "# Custom Shaders Override")
        #expect(await skillService.get(SkillSchema.ID(rawValue: "figma-use-slides")) != nil)

        // Existing disabled custom MCP server entry is preserved
        let storedMCP = try await FigmaPluginHelper.inspectMCPConfig(named: "figma", in: mcpService)
        #expect(storedMCP == disabledUserMCP)

        await handle.dispose()
    }

    // MARK: - 5. CorePlugin Lifecycle, PluginEffect.Plugin, NativePlugin & Tool/Skill Hooks

    @Test("FigmaPlugin.definition activates cleanly in CorePlugin.Service, registers MCP & skills, executes hooks, and tears down on close")
    func pluginRegistrationLifecycleAndHooks() async throws {
        #expect(FigmaPlugin.definition.id == "opencode.figma")
        #expect(FigmaPlugin.Plugin.id == "opencode.figma")

        let env = CorePlugin.Host.Environment()
        let pluginService = CorePlugin.Service(environment: env)

        try await FigmaPlugin.activate(in: pluginService)

        // Plugin inventory reports active opencode.figma
        let inventory = pluginService.list()
        #expect(inventory.count == 1)
        #expect(inventory[0].id?.rawValue == "opencode.figma")
        #expect(inventory[0].state == .active)

        // MCP server registered on host environment
        let registeredMCP = await FigmaPluginHelper.inspectMCPServer(named: "figma", in: env)
        #expect(registeredMCP == FigmaPlugin.remoteServerConfig())

        // All official bundled skills registered on host environment
        let registeredSkills = env.registeredSkills()
        #expect(registeredSkills.count == Self.allOfficialUpstreamSkillIDs.count)
        for requiredID in Self.requiredElevenSkillIDs {
            #expect(registeredSkills.contains(where: { $0.id.rawValue == requiredID }))
        }

        // Hooks are installed
        #expect(env.hooks.has(domain: .tool, name: "execute.before") == true)
        #expect(env.hooks.has(domain: .tool, name: "execute.after") == true)

        let sessionID = SessionID.create()
        let agentID = AgentSchema.ID(rawValue: "build")
        let messageID = SessionMessageSchema.ID.create()

        // Calling a mandatory Figma tool that fails before loading its skill appends prerequisite guidance
        let failedAfter = try await env.hooks.triggerTool(
            .executeAfter(
                PluginEffect.ToolHooks.ExecuteAfter(
                    tool: "figma_use_figma",
                    sessionID: sessionID,
                    agent: agentID,
                    messageID: messageID,
                    id: ToolSchema.CallID(rawValue: "call_1"),
                    input: .object(["code": .string("return 1")]),
                    outcome: .error(ToolSchema.ToolError(message: "Script execution failed"))
                )
            )
        )
        if case .executeAfter(let afterEvent) = failedAfter,
           case .error(let err) = afterEvent.outcome
        {
            #expect(err.message.contains("figma-use"))
            #expect(err.message.contains("use_figma"))
        } else {
            Issue.record("Expected enriched error outcome from execute.after hook")
        }

        // Loading Figma skills via the `skill` tool records them for the session
        _ = try await env.hooks.triggerTool(
            .executeBefore(
                PluginEffect.ToolHooks.ExecuteBefore(
                    tool: "skill",
                    sessionID: sessionID,
                    agent: agentID,
                    messageID: messageID,
                    id: ToolSchema.CallID(rawValue: "call_2"),
                    input: .object(["id": .string("figma-use")])
                )
            )
        )
        _ = try await env.hooks.triggerTool(
            .executeBefore(
                PluginEffect.ToolHooks.ExecuteBefore(
                    tool: "skill",
                    sessionID: sessionID,
                    agent: agentID,
                    messageID: messageID,
                    id: ToolSchema.CallID(rawValue: "call_3"),
                    input: .object(["id": .string("figma-generate-design")])
                )
            )
        )

        // Subsequent use_figma call without skillNames automatically receives loaded skillNames
        let beforeUseFigma = try await env.hooks.triggerTool(
            .executeBefore(
                PluginEffect.ToolHooks.ExecuteBefore(
                    tool: "mcp__figma__use_figma",
                    sessionID: sessionID,
                    agent: agentID,
                    messageID: messageID,
                    id: ToolSchema.CallID(rawValue: "call_4"),
                    input: .object(["code": .string("return figma.root.id")])
                )
            )
        )
        if case .executeBefore(let beforeEvent) = beforeUseFigma,
           case .object(let args) = beforeEvent.input
        {
            #expect(args["skillNames"] == .string("figma-generate-design,figma-use"))
        } else {
            Issue.record("Expected skillNames injection on use_figma input")
        }

        // Caller-supplied skillNames is never overwritten
        let explicitSkillNames = try await env.hooks.triggerTool(
            .executeBefore(
                PluginEffect.ToolHooks.ExecuteBefore(
                    tool: "get_design_context",
                    sessionID: sessionID,
                    agent: agentID,
                    messageID: messageID,
                    id: ToolSchema.CallID(rawValue: "call_5"),
                    input: .object(["skillNames": .string("resource:figma-design-to-code")])
                )
            )
        )
        if case .executeBefore(let beforeEvent) = explicitSkillNames,
           case .object(let args) = beforeEvent.input
        {
            #expect(args["skillNames"] == .string("resource:figma-design-to-code"))
        }

        // Once figma-use is loaded, errors on use_figma no longer append missing-skill hint
        let afterLoaded = try await env.hooks.triggerTool(
            .executeAfter(
                PluginEffect.ToolHooks.ExecuteAfter(
                    tool: "use_figma",
                    sessionID: sessionID,
                    agent: agentID,
                    messageID: messageID,
                    id: ToolSchema.CallID(rawValue: "call_6"),
                    input: .object([:]),
                    outcome: .error(ToolSchema.ToolError(message: "Node not found"))
                )
            )
        )
        if case .executeAfter(let afterEvent) = afterLoaded,
           case .error(let err) = afterEvent.outcome
        {
            #expect(err.message == "Node not found")
        }

        // Closing CorePlugin.Service disposes hooks and clears inventory
        await pluginService.close()
        #expect(pluginService.list().isEmpty)
        #expect(env.hooks.has(domain: .tool, name: "execute.before") == false)
        #expect(env.hooks.has(domain: .tool, name: "execute.after") == false)
    }

    @Test("FigmaPlugin respects pre-existing host MCP/skill overrides, SdkPlugins registration, NativePlugin, and Desktop endpoint options")
    func hostPrecedenceSdkPluginsAndNativePlugin() async throws {
        // 1. Pre-existing MCP & skill in CorePlugin.Host.Environment take precedence over FigmaPlugin
        let env = CorePlugin.Host.Environment()
        let customMCP = McpSchema.ServerConfig.remote(McpSchema.RemoteConfig(url: "http://127.0.0.1:4555/mcp", oauth: .disabled))
        await FigmaPluginHelper.presetMCPServer(named: "figma", config: customMCP, in: env)
        await FigmaPluginHelper.presetSkill(
            SkillSchema.Info(
                id: SkillSchema.ID(rawValue: "figma-code-connect"),
                name: SkillSchema.Name(rawValue: "local-code-connect"),
                description: "Local override",
                autoinvoke: true,
                path: SchemaPrimitive.AbsolutePath(rawValue: "/repo/skills/figma-code-connect/SKILL.md"),
                content: "# Local Code Connect"
            ),
            in: env
        )

        try await env.activatePlugin(FigmaPlugin.definition)
        #expect(await FigmaPluginHelper.inspectMCPServer(named: "figma", in: env) == customMCP)
        let overridden = env.registeredSkills().first { $0.id.rawValue == "figma-code-connect" }
        #expect(overridden?.name.rawValue == "local-code-connect")

        // 2. SdkPlugins registration helper & NativePlugin conformance with Desktop endpoint
        let sdkPlugins = CorePlugin.SdkPlugins.Service()
        FigmaPlugin.register(into: sdkPlugins, endpoint: .desktop(port: 4999))
        let generations = sdkPlugins.all()
        #expect(generations.count == 1)
        #expect(generations[0].id == "opencode.figma")

        let desktopEnv = CorePlugin.Host.Environment()
        let desktopService = CorePlugin.Service(environment: desktopEnv)
        try await desktopService.activate(
            [CorePlugin.Generation(nativePlugin: FigmaPlugin.Native(endpoint: .desktop(port: 4999)))],
            failures: []
        )
        let desktopMCP = await FigmaPluginHelper.inspectMCPServer(named: "figma", in: desktopEnv)
        #expect(desktopMCP == FigmaPlugin.desktopServerConfig(port: 4999))
        #expect(desktopEnv.registeredSkills().count == Self.allOfficialUpstreamSkillIDs.count)
        await desktopService.close()
    }

    @Test("Tool name normalization & custom directory discovery work accurately")
    func toolNameNormalizationAndCustomDirectoryDiscovery() throws {
        #expect(FigmaPlugin.canonicalFigmaToolName("use_figma") == "use_figma")
        #expect(FigmaPlugin.canonicalFigmaToolName("figma_use_figma") == "use_figma")
        #expect(FigmaPlugin.canonicalFigmaToolName("mcp__figma__get_design_context") == "get_design_context")
        #expect(FigmaPlugin.canonicalFigmaToolName("figma.create_shader") == "create_shader")
        #expect(FigmaPlugin.canonicalFigmaToolName("unrelated_tool") == nil)
        #expect(FigmaPlugin.prerequisiteSkills(forTool: "figma_generate_diagram") == ["figma-generate-diagram"])
        #expect(FigmaPlugin.prerequisiteSkills(forTool: "read_file").isEmpty)

        let tempRoot = try FigmaPluginHelper.makeTemporarySkillFixture(
            skillID: "figma-temp-skill",
            skillMarkdown: """
            ---
            name: figma-temp-skill
            description: "Temporary skill fixture"
            disable-model-invocation: false
            ---

            # Temporary Skill
            """,
            references: [
                "references/guide.md": "# Guide",
                "references/nested/detail.md": "# Detail",
            ]
        )
        defer { FigmaPluginHelper.removeTemporaryDirectory(tempRoot) }

        let loaded = try FigmaPlugin.loadBundledSkills(under: tempRoot)
        #expect(loaded.count == 1)
        #expect(loaded[0].id.rawValue == "figma-temp-skill")
        #expect(loaded[0].description == "Temporary skill fixture")
        #expect(loaded[0].markdownReferences.map(\.relativePath) == [
            "references/guide.md",
            "references/nested/detail.md",
        ])
    }

    @Test("FigmaPlugin.definition honors ctx.options desktop configuration and CoreSkill.prepare renders bundled skill output")
    func contextOptionsAndSkillPreparation() async throws {
        // Verify ctx.options drives Desktop MCP endpoint selection when no explicit endpoint is pinned
        let env = CorePlugin.Host.Environment()
        let baseCtx = CorePlugin.Host.make(environment: env, pluginID: FigmaPlugin.pluginID)
        let desktopCtx = baseCtx.withOptions([
            "endpoint": .string("desktop"),
            "port": .int(4777),
        ])
        try await FigmaPlugin.definition.effect(desktopCtx)

        let configuredMCP = await FigmaPluginHelper.inspectMCPServer(named: "figma", in: env)
        #expect(configuredMCP == FigmaPlugin.desktopServerConfig(port: 4777))
        #expect(env.registeredSkills().count == Self.allOfficialUpstreamSkillIDs.count)

        // Verify preserveExisting: false overrides existing entries in CoreSkill.Service and CoreMCP.Registry.Service
        let skillService = CoreSkill.Service()
        let mcpService = CoreMCP.Registry.Service()
        _ = try await mcpService.transform { editor in
            editor.set("figma", config: FigmaPlugin.desktopServerConfig(port: 3999))
        }
        let overrideHandle = try await FigmaPlugin.register(
            into: skillService,
            mcpService: mcpService,
            endpoint: .remote,
            preserveExisting: false
        )
        let overriddenMCP = try await FigmaPluginHelper.inspectMCPConfig(named: "figma", in: mcpService)
        #expect(overriddenMCP == FigmaPlugin.remoteServerConfig())

        // Verify CoreSkill.prepare produces valid <skill_content> for a bundled Figma skill
        let codeConnect = try #require(await skillService.get(SkillSchema.ID(rawValue: "figma-code-connect")))
        let files = await skillService.files(SkillSchema.ID(rawValue: "figma-code-connect"))
        let prepared = await CoreSkill.prepare(skill: codeConnect, virtualFiles: files)
        #expect(prepared.directory.hasSuffix("/figma-code-connect"))
        #expect(prepared.output.contains("<skill_content name=\"figma-code-connect\">"))
        #expect(prepared.output.contains("Code Connect"))

        await overrideHandle.dispose()
    }
}
