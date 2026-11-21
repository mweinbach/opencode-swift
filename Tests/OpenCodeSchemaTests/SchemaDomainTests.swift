import Testing
import OpenCodeSchema

@Suite("OpenCodeSchema Domain Port Tests")
struct SchemaDomainTests {

    // MARK: - Primitives, Money, TokenUsage, FileDiff, BlobStore, Reference, UsageLimits, Goal

    @Test("SchemaPrimitive bounds and branded path/timestamp invariants")
    func primitiveValidatorsAndRoundTrips() throws {
        #expect(SchemaPrimitive.PositiveInt(rawValue: 0) == nil)
        #expect(SchemaPrimitive.PositiveInt(rawValue: -1) == nil)
        let pos = try #require(SchemaPrimitive.PositiveInt(rawValue: 42))
        #expect(try SchemaDomainCodecHelper.roundTrip(pos) == pos)
        #expect(!SchemaDomainCodecHelper.canDecode(SchemaPrimitive.PositiveInt.self, json: "0"))
        #expect(!SchemaDomainCodecHelper.canDecode(SchemaPrimitive.PositiveInt.self, json: "-5"))

        #expect(SchemaPrimitive.NonNegativeInt(rawValue: -1) == nil)
        let zero = try #require(SchemaPrimitive.NonNegativeInt(rawValue: 0))
        #expect(try SchemaDomainCodecHelper.roundTrip(zero) == zero)
        #expect(!SchemaDomainCodecHelper.canDecode(SchemaPrimitive.NonNegativeInt.self, json: "-1"))

        let ts = try SchemaPrimitive.DateTimeUtcFromMillis(validating: 1_700_000_000_123)
        #expect(try SchemaDomainCodecHelper.roundTrip(ts) == ts)
        #expect(SchemaPrimitive.DateTimeUtcFromMillis(epochMillis: .infinity) == nil)
        #expect(SchemaPrimitive.DateTimeUtcFromMillis(epochMillis: .nan) == nil)

        #expect(MoneySchema.USD.zero.rawValue == 0)
        #expect(MoneySchema.USDPerMillionTokens.zero.rawValue == 0)
        #expect(MoneySchema.USD(rawValue: .infinity) == nil)

        let usage = TokenUsageSchema.Info(
            input: 1_000_000_000,
            output: 2_000_000_000,
            reasoning: 3,
            cache: .init(read: 4_000_000_000, write: 5)
        )
        #expect(TokenUsageSchema.total(usage) == 7_000_000_008)
        #expect(try SchemaDomainCodecHelper.roundTrip(usage) == usage)
    }

    @Test("BlobStore.ID, FileDiff.Info, Reference.Source, and UsageLimits round-trip & validate")
    func primitivesDomainSchemas() throws {
        let blobID = BlobStoreSchema.ID.create()
        #expect(blobID.rawValue.hasPrefix("blob_"))
        #expect(blobID.rawValue.count == 31)
        #expect(BlobStoreSchema.ID(rawValue: blobID.rawValue) == blobID)
        #expect(BlobStoreSchema.ID(rawValue: "blob_BAD") == nil)
        #expect(!SchemaDomainCodecHelper.canDecode(BlobStoreSchema.ID.self, json: "\"blob_invalid\""))

        let blobInfo = BlobStoreSchema.Info(id: blobID, mime: "video/mp4", bytes: 4096)
        #expect(try SchemaDomainCodecHelper.roundTrip(blobInfo) == blobInfo)

        // FileDiff.Info enforces literal true for `more` and omits nil
        let diff = FileDiffSchema.Info(
            file: "Sources/App.swift",
            patch: "@@ -1 +1 @@",
            additions: SchemaPrimitive.NonNegativeInt(rawValue: 1)!,
            deletions: SchemaPrimitive.NonNegativeInt(rawValue: 1)!,
            status: .modified,
            more: true
        )
        #expect(try SchemaDomainCodecHelper.roundTrip(diff) == diff)
        #expect(!SchemaDomainCodecHelper.canDecode(
            FileDiffSchema.Info.self,
            json: #"{"file":"a","patch":"","additions":0,"deletions":0,"status":"added","more":false}"#
        ))

        // Reference.Source tagged union
        let gitRef = ReferenceSchema.Info(
            name: "docs",
            path: .init(rawValue: "/tmp/docs"),
            source: .git(.init(repository: "https://github.com/org/repo", branch: "main"))
        )
        #expect(try SchemaDomainCodecHelper.roundTrip(gitRef) == gitRef)
        let localRef = ReferenceSchema.Source.local(.init(path: .init(rawValue: "/workspace/ref")))
        #expect(try SchemaDomainCodecHelper.roundTrip(localRef) == localRef)

        // UsageLimits Meter bounds 0...100
        #expect(!SchemaDomainCodecHelper.canDecode(
            UsageLimitsSchema.Meter.self,
            json: #"{"percent":101,"limited":false,"resetsAt":1000}"#
        ))
        let limits = UsageLimitsSchema.Info(
            workspace: .init(id: "ws_1", name: "Acme", usageURL: "https://console.opencode.ai/usage"),
            go: .init(
                rolling: .init(percent: 45.5, limited: false, resetsAt: 1_700_000_000),
                weekly: .init(percent: 12, limited: false, resetsAt: 1_700_100_000),
                monthly: .init(percent: 80, limited: false, resetsAt: 1_700_200_000)
            ),
            budgets: [
                .init(
                    id: "b_1",
                    limit: MoneySchema.USD(rawValue: 100)!,
                    spent: MoneySchema.USD(rawValue: 25.5)!,
                    scope: .each,
                    per: .model,
                    coverage: .models,
                    models: [.init(providerID: .anthropic, modelID: .init(rawValue: "claude-sonnet"), name: "Sonnet")],
                    vendors: [],
                    inputPriceAtLeast: MoneySchema.USDPerMillionTokens(rawValue: 3)!,
                    picked: true,
                    shared: false,
                    resetsAt: 1_700_500_000
                ),
            ]
        )
        #expect(try SchemaDomainCodecHelper.roundTrip(limits) == limits)

        // Goal definition uses opencode.goal RPC ID and validates via RpcSchema.define
        let validatedGoal = try RpcSchema.define(GoalSchema.definition)
        #expect(validatedGoal.id == "opencode.goal")
        #expect(validatedGoal.methods["get"] != nil)
        #expect(validatedGoal.events["changed"] != nil)
    }

    // MARK: - Config & Feature Flags

    @Test("ConfigFlagSchema registry, optInOnly, and wildcard match upstream")
    func configFeatureFlags() {
        #expect(ConfigFlagSchema.wildcard == "all")
        #expect(ConfigFlagSchema.Key.allCases.count == 12)
        #expect(ConfigFlagSchema.registry.count == 12)
        #expect(ConfigFlagSchema.optInOnly == [.todo])
        #expect(ConfigFlagSchema.Key(rawValue: "recommended_api") == .recommendedApi)
        #expect(ConfigFlagSchema.Key(rawValue: "machines") == .machines)
        #expect(ConfigFlagSchema.Key(rawValue: "home_memory") == .homeMemory)
        #expect(ConfigFlagSchema.Key(rawValue: "project_overlay") == .projectOverlay)
        #expect(ConfigFlagSchema.Key(rawValue: "automations") == nil)
        #expect(ConfigFlagSchema.registry[.fullCodemode] == "Enable the full Code Mode work in progress.")
        for key in ConfigFlagSchema.Key.allCases {
            #expect(ConfigFlagSchema.registry[key] != nil)
            #expect(key.rawValue != "all_flags")
            #expect(key.rawValue != ConfigFlagSchema.wildcard)
        }
    }

    @Test("Job.Info decodes video jobs; experimental.video_generate takes an object; Tool.Options codemode object")
    func videoJobsAndCodeModeOptions() throws {
        let video = try SchemaDomainCodecHelper.decodeFromJSONString(JobSchema.Info.self, json: """
        {"kind":"video","id":"job_1","sessionID":"ses_1","status":"running","time":{"started":1},"path":"clip.mp4"}
        """)
        guard case .video(let job) = video else {
            Issue.record("Expected a video job, got \(video)")
            return
        }
        #expect(job.path == "clip.mp4")
        #expect(try SchemaDomainCodecHelper.roundTrip(video) == video)
        #expect(JobSchema.Kind(rawValue: "video") == .video)
        #expect(JobSchema.Event.updated.type == "experimental.job.updated")

        let experimental = try SchemaDomainCodecHelper.decodeFromJSONString(ConfigExperimentalSchema.Info.self, json: """
        {"video_generate":{"model":"google/veo-3"},"sqlite_fts":true,"part_rows":false}
        """)
        #expect(experimental.flagValue(for: .videoGenerate) == true)
        #expect(experimental.videoGenerate?.options?.model?.model.rawValue == "veo-3")
        #expect(experimental.flagValue(for: .sqliteFts) == true)
        #expect(experimental.partRows == false)

        let options = try SchemaDomainCodecHelper.decodeFromJSONString(ToolSchema.Options.self, json: """
        {"namespace":"browser","codemode":{"pinned":true,"description":"Browse"}}
        """)
        #expect(options.codemode == true)
        #expect(options.pinned == true)
        #expect(options.codemodeOptions?.description == "Browse")
        let legacy = try SchemaDomainCodecHelper.decodeFromJSONString(ToolSchema.Options.self, json: """
        {"codemode":true,"pinned":true}
        """)
        #expect(legacy.pinned == true)
        #expect(ToolSchema.Options(codemode: false, pinned: true).pinned == nil)
    }

    @Test("ConfigPolicy normalizes legacy prefixed integration.use statements")
    func configPolicyLegacyNormalization() throws {
        let json = """
        [
          {"action":"integration.use","resource":"mcp:*","effect":"deny"},
          {"action":"integration.use","resource":"mcp:github","effect":"allow"},
          {"action":"integration.use","resource":"skill:team:review","effect":"deny"},
          {"action":"integration.use","resource":"plugin:@acme/plugin","effect":"deny"},
          {"action":"integration.use","resource":"*","effect":"deny"},
          {"action":"integration.use","resource":"opencode#org_01","effect":"allow"},
          {"action":"integration.use","resource":"https://ai.acme.com","effect":"allow"},
          {"action":"integration.use","resource":"constructor:x","effect":"allow"},
          {"action":"integration.connect","resource":"mcp:x","effect":"allow"}
        ]
        """
        let decoded = try SchemaDomainCodecHelper.decodeFromJSONString([ConfigPolicySchema.Info].self, json: json)
        #expect(decoded == [
            .init(action: .mcpUse, resource: "*", effect: .deny),
            .init(action: .mcpUse, resource: "github", effect: .allow),
            .init(action: .skillUse, resource: "team:review", effect: .deny),
            .init(action: .pluginUse, resource: "@acme/plugin", effect: .deny),
            .init(action: .integrationUse, resource: "*", effect: .deny),
            .init(action: .integrationUse, resource: "opencode#org_01", effect: .allow),
            .init(action: .integrationUse, resource: "https://ai.acme.com", effect: .allow),
            .init(action: .integrationUse, resource: "constructor:x", effect: .allow),
            .init(action: .integrationConnect, resource: "mcp:x", effect: .allow),
        ])
    }

    @Test("ConfigSchema parses full document, short model selections, forgiving agent colors, and omits absent fields")
    func configDocumentParsingAndEncoding() throws {
        let raw = """
        {
          "$schema": "https://opencode.ai/config.json",
          "model": "openrouter/openai/gpt-5#high",
          "default_agent": "build",
          "update": "notify",
          "share": "manual",
          "worktree": { "directory": "  ../worktrees  " },
          "websearch": { "provider": "random" },
          "compaction": { "auto": true, "buffer": "20%" },
          "agents": {
            "reviewer": { "color": "#1a2B3c", "mode": "subagent" },
            "legacy": { "color": "theme-primary-not-hex", "mode": "primary" }
          },
          "providers": {
            "console-anthropic": {
              "canonical": "anthropic",
              "settings": { "timeout": 900000, "chunkTimeout": false, "customFlag": true }
            }
          },
          "automations": false,
          "experimental": {
            "all_flags": true,
            "project_overlay": true,
            "location_idle_timeout": false,
            "image_generate": { "model": "google/imagen-4" }
          }
        }
        """
        let decoded = try SchemaDomainCodecHelper.decodeFromJSONString(ConfigSchema.Info.self, json: raw)
        #expect(decoded.schema == "https://opencode.ai/config.json")
        #expect(decoded.model == .init(
            providerID: .openrouter,
            model: .init(rawValue: "openai/gpt-5"),
            variant: .init(rawValue: "high")
        ))
        #expect(decoded.worktree?.directory == "../worktrees")
        #expect(decoded.websearch == .enabled(.init(provider: .random)))
        #expect(decoded.compaction?.buffer == .percent(ConfigCompactionSchema.Percent(rawValue: "20%")!))
        #expect(decoded.agents?["reviewer"]?.color?.rawValue == "#1a2B3c")
        #expect(decoded.agents?["legacy"]?.color == nil)
        #expect(decoded.providers?["console-anthropic"]?.canonical == .anthropic)
        #expect(decoded.providers?["console-anthropic"]?.settings?.timeout == .milliseconds(900_000))
        #expect(decoded.providers?["console-anthropic"]?.settings?.chunkTimeout == .disabled)
        #expect(decoded.providers?["console-anthropic"]?.settings?.extra["customFlag"] == .bool(true))
        #expect(decoded.automations == false)
        #expect(decoded.experimental?.flagValue(for: .projectOverlay) == true)
        #expect(decoded.experimental?.locationIdleTimeout == .disabled)

        // Config.Patch encodes explicit null for shell
        let patchJSON = try SchemaDomainCodecHelper.encodeToJSONString(ConfigSchema.Patch(shell: nil))
        #expect(patchJSON == #"{"shell":null}"#)

        // Config.Entry union round-trip
        let entries: [ConfigSchema.Entry] = [
            .document(.init(path: .init(rawValue: "/repo/opencode.json"), info: decoded)),
            .directory(.init(path: .init(rawValue: "/repo/.opencode"))),
        ]
        #expect(try SchemaDomainCodecHelper.roundTrip(entries) == entries)

        // Worktree rejects blank directory; websearch rejects true; compaction percent rejects 0% and 100%
        #expect(!SchemaDomainCodecHelper.canDecode(ConfigWorktreeSchema.Info.self, json: #"{"directory":"   "}"#))
        #expect(!SchemaDomainCodecHelper.canDecode(ConfigWebSearchSchema.Selection.self, json: "true"))
        #expect(ConfigCompactionSchema.Percent(rawValue: "0%") == nil)
        #expect(ConfigCompactionSchema.Percent(rawValue: "100%") == nil)
        #expect(ConfigCompactionSchema.Percent(rawValue: "12.5%") != nil)
    }

    // MARK: - Model, Provider, Agent, Credential, Connection, Generate

    @Test("Model.Ref parsing, Provider/Model StructWithRest settings, and defaults")
    func modelAndProviderSchemas() throws {
        let withVariant = try ModelSchema.Ref.parse("openrouter/openai/gpt-5#high")
        #expect(withVariant.providerID == .openrouter)
        #expect(withVariant.id.rawValue == "openai/gpt-5")
        #expect(withVariant.variant?.rawValue == "high")

        let noVariant = try ModelSchema.Ref.parse("anthropic/claude-sonnet")
        #expect(noVariant.providerID == .anthropic)
        #expect(noVariant.id.rawValue == "claude-sonnet")
        #expect(noVariant.variant == nil)

        #expect(throws: SchemaPrimitive.ValidationError.self) { _ = try ModelSchema.Ref.parse("gpt-5") }
        #expect(throws: SchemaPrimitive.ValidationError.self) { _ = try ModelSchema.Ref.parse("openai/gpt-5#") }
        #expect(throws: SchemaPrimitive.ValidationError.self) { _ = try ModelSchema.Ref.parse("openai/gpt-5#a#b") }

        let defaultModel = ModelSchema.Info.default(providerID: .openai, id: .init(rawValue: "gpt-5.4-mini"))
        #expect(defaultModel.limit.context == 200_000)
        #expect(defaultModel.limit.output == 32_000)
        #expect(defaultModel.status == .active)
        #expect(defaultModel.enabled == true)
        #expect(try SchemaDomainCodecHelper.roundTrip(defaultModel) == defaultModel)

        // Model.Settings preserves arbitrary provider keys on the same flat JSON object
        let modelSettings = try SchemaDomainCodecHelper.decodeFromJSONString(
            ModelSchema.Settings.self,
            json: #"{"compaction":{"type":"native"},"encoding":"zstd","providerOption":true}"#
        )
        #expect(modelSettings.compaction == .native)
        #expect(modelSettings.encoding == .zstd)
        #expect(modelSettings.extra["providerOption"] == .bool(true))
        #expect(try SchemaDomainCodecHelper.roundTrip(modelSettings) == modelSettings)

        // Provider.CacheTTL validation
        #expect(ProviderSchema.CacheTTL(rawValue: "5m") != nil)
        #expect(ProviderSchema.CacheTTL(rawValue: "24h") != nil)
        #expect(ProviderSchema.CacheTTL(rawValue: "500ms") != nil)
        #expect(ProviderSchema.CacheTTL(rawValue: "5min") == nil)

        // ModelCompatibility resolution merges model overrides onto provider defaults
        let resolved = ModelCompatibilitySchema.resolve(
            model: .init(reasoningField: .init(rawValue: "vendor_reasoning"), supportsEffortUpdates: true),
            provider: .init(reasoningField: .reasoningContent, maxTokensField: .maxCompletionTokens)
        )
        #expect(resolved.reasoningField?.rawValue == "vendor_reasoning")
        #expect(resolved.maxTokensField == .maxCompletionTokens)
        #expect(resolved.supportsEffortUpdates == true)

        // Agent default permissions
        let agent = AgentSchema.Info.default(.init(rawValue: "build"))
        #expect(agent.permissions.count == 4)
        #expect(agent.mode == .primary)
        #expect(try SchemaDomainCodecHelper.roundTrip(agent) == agent)
    }

    @Test("CredentialLegacy migrates configuration into metadata with answer precedence")
    func credentialLegacyMigration() throws {
        let legacyJSON = """
        {
          "type": "key",
          "key": "secret",
          "metadata": { "imported": true, "resourceName": "older" },
          "configuration": { "resourceName": "answered", "accountId": "account" }
        }
        """
        let migrated = try SchemaDomainCodecHelper.decodeFromJSONString(CredentialLegacySchema.Value.self, json: legacyJSON)
        guard case .key(let keyCred) = migrated.credential else {
            Issue.record("Expected key credential")
            return
        }
        #expect(keyCred.key == "secret")
        #expect(keyCred.metadata?["imported"] == .bool(true))
        #expect(keyCred.metadata?["resourceName"] == .string("answered"))
        #expect(keyCred.metadata?["accountId"] == .string("account"))

        // Public Credential.Value does not absorb `configuration`
        let publicDecoded = try SchemaDomainCodecHelper.decodeFromJSONString(CredentialSchema.Value.self, json: legacyJSON)
        guard case .key(let pubKey) = publicDecoded else {
            Issue.record("Expected key credential")
            return
        }
        #expect(pubKey.metadata?["resourceName"] == .string("older"))
        #expect(pubKey.metadata?["accountId"] == nil)

        // Invalid legacy configuration fails
        #expect(!SchemaDomainCodecHelper.canDecode(
            CredentialLegacySchema.Value.self,
            json: #"{"type":"key","key":"secret","configuration":"answered"}"#
        ))
    }

    @Test("GenerateSchema image, video, and decision discriminated unions round-trip & distinguish ChoiceValue types")
    func generateSchemas() throws {
        let vid = GenerateSchema.VideoID.create()
        #expect(vid.rawValue.hasPrefix("video_"))
        #expect(vid.rawValue.count == 32)
        #expect(GenerateSchema.VideoID(rawValue: "video_short") == nil)

        // ChoiceValue preserves Bool true vs String "true"
        let boolChoice = try SchemaDomainCodecHelper.decodeFromJSONString(GenerateSchema.ChoiceValue.self, json: "true")
        let strChoice = try SchemaDomainCodecHelper.decodeFromJSONString(GenerateSchema.ChoiceValue.self, json: "\"true\"")
        #expect(boolChoice == .bool(true))
        #expect(strChoice == .string("true"))
        #expect(boolChoice != strChoice)

        let decisionReq = GenerateSchema.DecisionRequest(
            model: .init(id: .init(rawValue: "decision-1"), providerID: .opencode),
            input: [
                .text(.init(text: "Build output")),
                .json(.init(value: .object(["exitCode": .int(0)]))),
                .file(.init(data: "aGVsbG8=", mime: "text/plain", name: "log.txt")),
            ],
            questions: [
                .predicate(.init(name: "ok", instructions: "Did it pass?", criteria: .init(whenTrue: "exit 0"))),
                .choice(.init(name: "env", instructions: "Target?", choices: [.init(value: .string("prod")), .init(value: .bool(false))])),
                .score(.init(name: "quality", instructions: "Rate", levels: [.init(label: "low"), .init(label: "high")])),
            ]
        )
        #expect(try SchemaDomainCodecHelper.roundTrip(decisionReq) == decisionReq)

        let videoJob: GenerateSchema.VideoJob = .error(.init(id: vid, error: "timed out", reason: .expired))
        #expect(try SchemaDomainCodecHelper.roundTrip(videoJob) == videoJob)
        #expect(GenerateSchema.ImageAspect(rawValue: "16:9") != nil)
        #expect(GenerateSchema.ImageAspect(rawValue: "-16:9") == nil)
    }

    // MARK: - Tools, MCP, Plugin, Skill, Instruction, Permission, Artifact, Form, RPC

    @Test("MCP, Plugin, Skill, Instruction, Permission, Artifact, Form, and RPC schemas round-trip & validate")
    func toolsMcpPluginFormRpcSchemas() throws {
        // MCP server config & resource catalog
        let mcpRemote: McpSchema.ServerConfig = .remote(.init(
            url: "https://example.com/mcp",
            oauth: .disabled,
            wireProtocol: .rev20260728,
            pool: true
        ))
        #expect(try SchemaDomainCodecHelper.roundTrip(mcpRemote) == mcpRemote)
        let mcpSub: McpSchema.SubscriptionStatus = .rejected(error: .init(code: 403, message: "forbidden"))
        #expect(try SchemaDomainCodecHelper.roundTrip(mcpSub) == mcpSub)

        // Skill source equals & key helpers
        let dirSource: SkillSchema.Source = .directory(.init(path: .init(rawValue: "/skills/a")))
        let urlSource: SkillSchema.Source = .url(.init(url: "https://example.com/skill.md"))
        #expect(SkillSchema.Source.equals(dirSource, dirSource))
        #expect(!SkillSchema.Source.equals(dirSource, urlSource))
        #expect(SkillSchema.Source.key(dirSource) == "directory:/skills/a")
        #expect(SkillSchema.Source.key(urlSource) == "url:https://example.com/skill.md")

        // Instruction key & hash validation
        #expect(InstructionSchema.Key(rawValue: "api/my-key_1.0") != nil)
        #expect(InstructionSchema.Key(rawValue: "noslash") == nil)
        #expect(InstructionEntrySchema.Key(rawValue: "my-key_1.0") != nil)
        #expect(InstructionEntrySchema.Key(rawValue: "with/slash") == nil)
        #expect(InstructionEntrySchema.maxValueBytes == 262_144)
        let validHash = String(repeating: "a", count: 64)
        #expect(InstructionSchema.Hash(rawValue: validHash) != nil)
        #expect(InstructionSchema.Hash(rawValue: "short") == nil)

        // Branded IDs: Permission, Artifact, Form
        let permID = PermissionSchema.ID.create()
        #expect(permID.rawValue.hasPrefix("per_"))
        #expect(PermissionSchema.ID(rawValue: "bad_123") == nil)

        let artID = ArtifactSchema.ID.create()
        #expect(artID.rawValue.hasPrefix("art_"))
        #expect(ArtifactSchema.ID(rawValue: "art123") == nil)

        let formID = FormSchema.ID.create()
        #expect(formID.rawValue.hasPrefix("frm_"))
        #expect(FormSchema.ID(rawValue: "frm123") == nil)

        // Form.Fields rejects empty array
        #expect(!SchemaDomainCodecHelper.canDecode(FormSchema.Fields.self, json: "[]"))
        let formDetail = FormSchema.Detail(
            id: formID,
            sessionID: "global",
            title: "Configure",
            fields: FormSchema.Fields(first: .string(.init(key: "host", required: true, format: .uri)), rest: [
                .multiselect(.init(key: "scopes", options: [.init(value: "read", label: "Read")])),
                .external(.init(key: "oauth", url: "https://auth.example.com")),
            ]),
            state: .answered(answer: ["host": .string("https://api.example.com"), "scopes": .strings(["read"])])
        )
        #expect(try SchemaDomainCodecHelper.roundTrip(formDetail) == formDetail)

        // RPC define rejects reserved "rpc.*" error names
        let badDef = RpcSchema.Definition(
            id: "acme.demo",
            methods: [
                "run": .init(
                    input: .named("In"),
                    output: .named("Out"),
                    errors: ["rpc.internal": .named("Err")]
                ),
            ]
        )
        #expect(throws: RpcSchema.DefinitionError.reservedErrorName("rpc.internal")) {
            _ = try RpcSchema.define(badDef)
        }
    }

    // MARK: - Worktree, Location, VCS, PTY, PersistentPty, Shell, Job, Automation, Integration

    @Test("Worktree.adopt path normalization (POSIX & Windows) and PersistentPty tri-state title")
    func worktreeAdoptAndPersistentPty() throws {
        let adopted = WorktreeSchema.adopt(
            .init(projectID: ProjectID.global.rawValue, directory: "/Users/dev/repo/./packages/core/.."),
            .init(projectID: "prj_new", directory: "/Users/dev/repo", previous: "prj_old")
        )
        #expect(adopted == .init(projectID: "prj_new", subpath: "packages"))

        let exactRoot = WorktreeSchema.adopt(
            .init(projectID: "prj_old", directory: "C:\\Work\\Repo\\"),
            .init(projectID: "prj_new", directory: "c:/work/repo", previous: "prj_old")
        )
        #expect(exactRoot == .init(projectID: "prj_new", subpath: nil))

        // Session with workspaceID is never adopted
        let skipped = WorktreeSchema.adopt(
            .init(projectID: "prj_old", directory: "/Users/dev/repo", workspaceID: "wrk_123"),
            .init(projectID: "prj_new", directory: "/Users/dev/repo", previous: "prj_old")
        )
        #expect(skipped == nil)

        // PersistentPty.UpdateInput distinguishes omitted title vs null vs string
        let clearTitle = PersistentPtySchema.UpdateInput(title: .null)
        #expect(try SchemaDomainCodecHelper.encodeToJSONString(clearTitle) == #"{"title":null}"#)
        let omitTitle = PersistentPtySchema.UpdateInput(title: nil)
        #expect(try SchemaDomainCodecHelper.encodeToJSONString(omitTitle) == "{}")
        let setTitle = PersistentPtySchema.UpdateInput(title: .value("shell"))
        #expect(try SchemaDomainCodecHelper.roundTrip(setTitle) == setTitle)

        #expect(PersistentPtySchema.ReadLines(rawValue: 0) == nil)
        #expect(PersistentPtySchema.ReadLines(rawValue: 65_535) != nil)
        #expect(PersistentPtySchema.ReadLines(rawValue: 65_536) == nil)
    }

    @Test("Automation durationMillis, runSessionID, mutually exclusive Target, and strict decodeCodeResult")
    func automationSchemas() throws {
        #expect(AutomationSchema.durationMillis("90 seconds") == 90_000)
        #expect(AutomationSchema.durationMillis("1.5 seconds") == 1_500)
        #expect(AutomationSchema.durationMillis("5 minutes") == 300_000)
        #expect(AutomationSchema.durationMillis("2 hours") == 7_200_000)
        #expect(AutomationSchema.durationMillis("1 day") == 86_400_000)
        #expect(AutomationSchema.durationMillis("1 week") == 604_800_000)
        #expect(AutomationSchema.durationMillis("5m") == nil)
        #expect(AutomationSchema.durationMillis("-5 seconds") == nil)
        #expect(AutomationSchema.durationMillis("") == nil)

        let autID = AutomationSchema.ID.create()
        let runSID = AutomationSchema.runSessionID(autID, run: 3)
        #expect(AutomationSchema.isRunSession(runSID))
        #expect(!AutomationSchema.isRunSession(SessionID.create()))

        // Target rejects specifying both session and subagent
        let sid = SessionID.create()
        #expect(!SchemaDomainCodecHelper.canDecode(
            AutomationSchema.Target.self,
            json: #"{"session":"\#(sid.rawValue)","subagent":"reviewer"}"#
        ))
        let subTarget: AutomationSchema.Target = .subagent(.init(rawValue: "reviewer"))
        #expect(try SchemaDomainCodecHelper.roundTrip(subTarget) == subTarget)

        // decodeCodeResult accepts null and valid objects, preserves explicit state: null, rejects excess keys
        #expect(try AutomationSchema.decodeCodeResult(.null).get() == nil)
        let stateNull = try AutomationSchema.decodeCodeResult(.object(["state": .null])).get()
        #expect(stateNull == AutomationSchema.CodeResult(state: .null))
        let full = try AutomationSchema.decodeCodeResult(.object([
            "state": .object(["nested": .array([.int(1), .string("two")])]),
            "done": .bool(false),
            "send": .object(["prompt": .string("triage"), "to": .object(["subagent": .string("reviewer")])]),
        ])).get()
        #expect(full?.done == false)
        #expect(full?.send?.to?.subagent.rawValue == "reviewer")

        // Rejects unknown keys and malformed sends
        let invalidSends: [JSONValue] = [
            .null,
            .object([:]),
            .object(["prompt": .string("   \n ")]),
            .object(["prompt": .string("x"), "session": .string("ses_other")]),
            .object(["prompt": .string("x"), "to": .object([:])]),
            .object(["prompt": .string("x"), "to": .object(["subagent": .string("helper"), "session": .string("ses_other")])]),
            .object(["prompt": .string("x"), "to": .object(["subagent": .string("")])]),
        ]
        for send in invalidSends {
            let res = AutomationSchema.decodeCodeResult(.object(["send": send]))
            if case .success = res {
                Issue.record("Expected decodeCodeResult failure for \(send)")
            }
        }
    }

    // MARK: - V1 Compatibility Schemas

    @Test("V1Schema.Session messages, parts, named errors, default retryCount, and events round-trip")
    func v1CompatSchemas() throws {
        let msgID = try V1Schema.Session.MessageID.ascending()
        let prtID = try V1Schema.Session.PartID.ascending()
        let sid = SessionID.create()
        #expect(msgID.rawValue.hasPrefix("msg_"))
        #expect(prtID.rawValue.hasPrefix("prt_"))
        #expect(V1Schema.Session.MessageID(rawValue: "bad_1") == nil)
        #expect(V1Schema.Session.PartID(rawValue: "bad_1") == nil)

        // OutputFormatJsonSchema defaults retryCount to 2 when omitted
        let decodedFmt = try SchemaDomainCodecHelper.decodeFromJSONString(
            V1Schema.Session.Format.self,
            json: #"{"type":"json_schema","schema":{"type":"object"}}"#
        )
        guard case .jsonSchema(let jsFmt) = decodedFmt else {
            Issue.record("Expected jsonSchema format")
            return
        }
        #expect(jsFmt.retryCount.rawValue == 2)

        // Assistant message with APIError and ToolPart round-trip
        let assistantMsg: V1Schema.Session.Info = .assistant(.init(
            id: msgID,
            sessionID: sid,
            time: .init(created: SchemaPrimitive.NonNegativeInt(rawValue: 100)!),
            error: .api(.init(data: .init(message: "rate limited", statusCode: SchemaPrimitive.NonNegativeInt(rawValue: 429)!, isRetryable: true))),
            parentID: msgID,
            modelID: .init(rawValue: "claude-sonnet"),
            providerID: .anthropic,
            mode: "build",
            agent: "build",
            path: .init(cwd: "/repo", root: "/repo"),
            cost: 0.012,
            tokens: .init(total: 150, input: 100, output: 50, reasoning: 0, cache: .init(read: 0, write: 0)),
            finish: "stop"
        ))
        #expect(try SchemaDomainCodecHelper.roundTrip(assistantMsg) == assistantMsg)

        let toolPart: V1Schema.Session.Part = .tool(.init(
            id: prtID,
            sessionID: sid,
            messageID: msgID,
            callID: "call_1",
            tool: "bash",
            state: .completed(.init(
                input: ["command": .string("ls")],
                output: "README.md\n",
                title: "List files",
                metadata: [:],
                time: .init(
                    start: SchemaPrimitive.NonNegativeInt(rawValue: 10)!,
                    end: SchemaPrimitive.NonNegativeInt(rawValue: 20)!
                )
            ))
        ))
        #expect(try SchemaDomainCodecHelper.roundTrip(toolPart) == toolPart)

        // V1 event definitions inventory
        #expect(V1Schema.Session.Event.definitions.count == 10)
        #expect(V1Schema.FileSystem.Event.edited.type == "file.edited")
        #expect(V1Schema.LegacyEvent.commandExecuted.type == "command.executed")
        #expect(V1Schema.Permission.Event.definitions.count == 2)
    }
}
