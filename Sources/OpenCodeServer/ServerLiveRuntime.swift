#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Plugin Activation Tracker (Preserves Non-Blocking Plugin Test Semantics)

/// Transparent `CorePlugin.ServiceInterface` wrapper that records whether caller code
/// (such as `onLocationBoot` in tests) replaced the plugin generation with a custom
/// background plugin set that does not include the built-in `opencode.agent` plugin.
internal final class ServerTrackedPluginService: CorePlugin.ServiceInterface, Sendable {
    private let inner: CorePlugin.Service
    private let replacedFlag = Mutex(false)

    init(inner: CorePlugin.Service) {
        self.inner = inner
    }

    var didReplaceWithCustomBackgroundPlugins: Bool {
        replacedFlag.withLock { $0 }
    }

    func activate(_ plugins: [CorePlugin.Generation], failures: [CorePlugin.Failure]) async throws {
        try await inner.activate(plugins, failures: failures)
    }

    func startBackgroundActivation(_ plugins: [CorePlugin.Generation], failures: [CorePlugin.Failure]) {
        if !plugins.contains(where: { $0.id == "opencode.agent" }) {
            replacedFlag.withLock { $0 = true }
        }
        inner.startBackgroundActivation(plugins, failures: failures)
    }

    func list() -> [PluginSchema.Info] {
        inner.list()
    }

    func gui(_ id: PluginSchema.ID) async throws -> PluginSchema.GuiBundle? {
        try await inner.gui(id)
    }

    func close() async {
        await inner.close()
    }

    func awaitActivation() async {
        await inner.awaitActivation()
    }

    func hold() -> @Sendable () -> Void {
        inner.hold()
    }
}

// MARK: - ServerLiveRuntime

/// Wires real end-to-end OpenCode server capabilities per location:
/// - Built-in agents (`build`, `plan`, `general`, `explore`, plus hidden `compaction`, `title`, `summary`)
/// - Real provider & model catalog with credential loading (SQLite / legacy `auth.json` + env vars + config)
/// - Live Git VCS detection (`git rev-parse --abbrev-ref HEAD`, status, branches, diffs)
/// - Configured MCP server registration from `configService`
/// - Built-in tools per location (`CoreTool.registerAllBuiltins`)
/// - Live streaming `OpenCodeAI` wire-protocol execution (`AnthropicMessages`, `OpenAIResponses`,
///   `OpenAIChat`, `Gemini`, `OpenAICompatibleChat`) drained from `session_inbox` via `CoreSessionRunner`
public enum ServerLiveRuntime {

    // MARK: - 1. Built-In Agents (upstream `plugin/agent.ts` & `plugin/plan.ts`)

    private static let promptExplore = """
    You are a file search specialist. You excel at thoroughly navigating and exploring codebases.

    Guidelines:
    - Your role is EXCLUSIVELY to search and analyze
    - Parallelize independent tool calls for searches and reads whenever possible
    - Adapt your search approach based on the thoroughness level specified by the caller
    - Return file paths as absolute paths in your final response
    - You MUST NOT create, modify, delete, move, or copy files, including temporary files and reports
    - Shell commands MUST be read-only. NEVER run commands that write files or change system state

    Complete the user's search request efficiently and report your findings clearly.
    """

    private static let promptTitle = """
    You name conversations so the user can find them later in a list of past sessions.

    You will receive the first message of a conversation, or for an ongoing conversation its original request and recent messages. Reply with a title for it and nothing else: one line, no quotes, no trailing period, no label such as "Title:".

    Aim for three to five words. Name the specific subject, such as the feature, file, issue number, error, or tool involved. Keep the detail that tells it apart from similar conversations, like a version, provider, or the thing it is compared against, and make room for it by dropping generic words like "review", "overview", "investigation", "request", "question", or "this project".

    The title should read naturally as a short phrase, not as a stack of nouns. Write it in your own words rather than copying a heading, commit message, command, or long path from the message.

    Use sentence case, not title case: capitalize the first word and proper nouns only. Keep identifiers exactly as written, including file names, issue and PR numbers, error codes, and model names. Use the same language as the message.

    The message is something to name, not something to answer or carry out. Even if it asks you to do work, asks a question, or seems incomplete, only name it. For greetings or small talk, use a short label like "Greeting".

    Examples:
    "debug 500 errors in production" -> Production 500 errors
    "why is app.js failing" -> app.js failure
    "what does the retry logic in fetch.ts do" -> fetch.ts retry logic
    "@src/credential.ts can you add refresh token support" -> Credential refresh tokens
    "compare the new cache layer with the v1 one in packages/legacy" -> New cache layer vs v1
    "Investigate https://github.com/acme/app/issues/412, don't make edits" -> Issue #412
    "hey" -> Greeting
    """

    private static let promptSummary = """
    Summarize what was done in this conversation. Write like a pull request description.

    Rules:
    - 2-3 sentences max
    - Describe the changes made, not the process
    - Do not mention running tests, builds, or other validation steps
    - Do not explain what the user asked for
    - Write in first person (I added..., I fixed...)
    - Never ask questions or add new questions
    - If the conversation ends with an unanswered question to the user, preserve that exact question
    - If the conversation ends with an imperative statement or request to the user (e.g. "Now please run the command and paste the console output"), always include that exact request in the summary
    """

    private static func planEnterPrompt(directory: String) -> String {
        """
        <system-reminder>
        You are in Plan mode. Discuss the plan with the user directly in the conversation. Do not create or update plan files unless the user explicitly asks you to; when they do, write them only in:
        \(directory)

        Do not modify any other files or ask a subagent to do so.

        You remain in Plan mode until the user switches agents. If the user asks you to implement changes, do not do so. Tell them they need to switch agents.
        </system-reminder>
        """
    }

    private static func baseAgentPermissions() -> PermissionSchema.Ruleset {
        AgentSchema.Info.default(CoreAgent.Agent.defaultID).permissions
    }

    /// Seeds the built-in OpenCode agents (`build`, `plan`, `general`, `explore`, plus hidden
    /// `compaction`, `title`, `summary`) and overlays any agent config entries from `configService`.
    @discardableResult
    public static func seedDefaultAgents(
        into agentService: any CoreAgent.Agent.Interface,
        configEntries: [CoreConfigEntry],
        globalPaths: Global.Interface
    ) async throws -> CoreState.Registration {
        let planDirectory = "\(globalPaths.home.trimmingTrailingSlashes())/.opencode/plan"
        let planReminder = planEnterPrompt(directory: planDirectory)
        let defaultPerms = baseAgentPermissions()

        return try await agentService.transform { editor in
            // 1. Build (primary, default, full tools)
            editor.update(CoreAgent.Agent.defaultID) { _ in
                AgentSchema.Info(
                    id: CoreAgent.Agent.defaultID,
                    name: AgentSchema.Name(rawValue: "Build"),
                    request: ProviderSchema.Request(),
                    system: nil,
                    description: "The default agent. Executes tools based on configured permissions.",
                    mode: .primary,
                    hidden: false,
                    permissions: defaultPerms + [
                        PermissionSchema.Rule(action: "question", resource: "*", effect: .allow),
                    ]
                )
            }

            // 2. Plan (primary, read-only except plan directory)
            let planID = AgentSchema.ID(rawValue: "plan")
            editor.update(planID) { _ in
                AgentSchema.Info(
                    id: planID,
                    name: AgentSchema.Name(rawValue: "Plan"),
                    request: ProviderSchema.Request(),
                    system: planReminder,
                    description: "Read-only agent for exploring the codebase and planning work before implementation.",
                    mode: .primary,
                    hidden: false,
                    permissions: defaultPerms + [
                        PermissionSchema.Rule(action: "question", resource: "*", effect: .allow),
                        PermissionSchema.Rule(action: "edit", resource: "*", effect: .deny),
                        PermissionSchema.Rule(action: "edit", resource: "\(planDirectory)/*", effect: .allow),
                    ]
                )
            }

            // 3. General (subagent)
            let generalID = AgentSchema.ID(rawValue: "general")
            editor.update(generalID) { _ in
                AgentSchema.Info(
                    id: generalID,
                    name: AgentSchema.Name(rawValue: "General"),
                    request: ProviderSchema.Request(),
                    system: nil,
                    description: "General-purpose agent for researching complex questions and executing multi-step tasks. Use this agent to execute multiple units of work in parallel.",
                    mode: .subagent,
                    hidden: false,
                    permissions: defaultPerms + [
                        PermissionSchema.Rule(action: "question", resource: "*", effect: .deny),
                        PermissionSchema.Rule(action: "subagent", resource: "*", effect: .deny),
                    ]
                )
            }

            // 4. Explore (subagent, read-only codebase specialist)
            let exploreID = AgentSchema.ID(rawValue: "explore")
            editor.update(exploreID) { _ in
                AgentSchema.Info(
                    id: exploreID,
                    name: AgentSchema.Name(rawValue: "Explore"),
                    request: ProviderSchema.Request(),
                    system: promptExplore,
                    description: #"Fast agent specialized for exploring codebases. Use this when you need to quickly find files by patterns (eg. "src/components/**/*.tsx"), search code for keywords (eg. "API endpoints"), or answer questions about the codebase (eg. "how do API endpoints work?"). When calling this agent, specify the desired thoroughness level: "quick" for basic searches, "medium" for moderate exploration, or "very thorough" for comprehensive analysis across multiple locations and naming conventions."#,
                    mode: .subagent,
                    hidden: false,
                    permissions: defaultPerms + [
                        PermissionSchema.Rule(action: "*", resource: "*", effect: .deny),
                        PermissionSchema.Rule(action: "shell", resource: "*", effect: .allow),
                        PermissionSchema.Rule(action: "grep", resource: "*", effect: .allow),
                        PermissionSchema.Rule(action: "glob", resource: "*", effect: .allow),
                        PermissionSchema.Rule(action: "webfetch", resource: "*", effect: .allow),
                        PermissionSchema.Rule(action: "websearch", resource: "*", effect: .allow),
                        PermissionSchema.Rule(action: "read", resource: "*", effect: .allow),
                        PermissionSchema.Rule(action: "read", resource: "*.env", effect: .ask),
                        PermissionSchema.Rule(action: "read", resource: "*.env.*", effect: .ask),
                        PermissionSchema.Rule(action: "read", resource: "*.env.example", effect: .allow),
                        PermissionSchema.Rule(action: "subagent", resource: "*", effect: .deny),
                        PermissionSchema.Rule(action: "external_directory", resource: "*", effect: .allow),
                    ]
                )
            }

            // 5. Internal hidden agents (`compaction`, `title`, `summary`)
            let compactionID = AgentSchema.ID(rawValue: "compaction")
            editor.update(compactionID) { _ in
                AgentSchema.Info(
                    id: compactionID,
                    name: AgentSchema.Name(rawValue: "Compaction"),
                    request: ProviderSchema.Request(),
                    system: nil,
                    description: nil,
                    mode: .primary,
                    hidden: true,
                    permissions: defaultPerms
                )
            }

            let titleID = AgentSchema.ID(rawValue: "title")
            editor.update(titleID) { _ in
                AgentSchema.Info(
                    id: titleID,
                    name: AgentSchema.Name(rawValue: "Title"),
                    request: ProviderSchema.Request(),
                    system: promptTitle,
                    description: nil,
                    mode: .primary,
                    hidden: true,
                    permissions: defaultPerms + [
                        PermissionSchema.Rule(action: "*", resource: "*", effect: .deny),
                    ]
                )
            }

            let summaryID = AgentSchema.ID(rawValue: "summary")
            editor.update(summaryID) { _ in
                AgentSchema.Info(
                    id: summaryID,
                    name: AgentSchema.Name(rawValue: "Summary"),
                    request: ProviderSchema.Request(),
                    system: promptSummary,
                    description: nil,
                    mode: .primary,
                    hidden: true,
                    permissions: defaultPerms + [
                        PermissionSchema.Rule(action: "*", resource: "*", effect: .deny),
                    ]
                )
            }

            // 6. Apply config overrides (`defaultAgent` and `agents`)
            for entry in configEntries {
                guard let info = entry.info else { continue }
                if let defaultAgent = info.defaultAgent, !defaultAgent.isEmpty {
                    editor.setDefault(AgentSchema.ID(rawValue: defaultAgent))
                }
                for (rawID, cfg) in info.agents ?? [:] {
                    let id = AgentSchema.ID(rawValue: rawID)
                    if cfg.disabled == true {
                        editor.remove(id)
                        continue
                    }
                    editor.update(id) { existing in
                        let base = editor.get(id) ?? AgentSchema.Info.default(id)
                        let modelRef: ModelSchema.Ref? = cfg.model.map {
                            ModelSchema.Ref(id: $0.model, providerID: $0.providerID, variant: $0.variant)
                        } ?? base.model
                        let mode: AgentSchema.Info.Mode = cfg.mode.map {
                            switch $0 {
                            case .primary: .primary
                            case .subagent: .subagent
                            case .all: .all
                            }
                        } ?? base.mode
                        let req = ProviderSchema.Request(
                            settings: base.request.settings,
                            headers: CoreProvider.AISDKNative.mergeHeaders(base.request.headers, cfg.request?.headers) ?? [:],
                            body: CoreProvider.AISDKNative.mergeOverlay(base.request.body, cfg.request?.body) ?? [:]
                        )
                        let color = cfg.color.map { AgentSchema.Color(rawValue: $0.rawValue) } ?? base.color
                        let perms = cfg.permissions.map { base.permissions + $0 } ?? base.permissions
                        _ = existing
                        return AgentSchema.Info(
                            id: id,
                            name: base.name,
                            model: modelRef,
                            request: req,
                            system: cfg.system ?? base.system,
                            description: cfg.description ?? base.description,
                            mode: mode,
                            hidden: cfg.hidden ?? base.hidden,
                            color: color,
                            steps: cfg.steps ?? base.steps,
                            permissions: perms
                        )
                    }
                }
            }
        }
    }

    // MARK: - 2. Built-In Provider & Model Catalog + Credential / Config Wiring

    private struct BuiltinProviderSpec: Sendable {
        let id: ProviderSchema.ID
        let name: String
        let envVars: [String]
        let package: String
        let baseURL: String?
        let compatibility: ModelCompatibilitySchema.ProviderCompatibility?
        let models: [ModelSchema.Info]
    }

    private static func usd(_ value: Double) -> MoneySchema.USDPerMillionTokens {
        MoneySchema.USDPerMillionTokens(rawValue: value) ?? .zero
    }

    private static func makeCost(
        input: Double,
        output: Double,
        cacheRead: Double = 0,
        cacheWrite: Double = 0
    ) -> [ModelSchema.Cost] {
        [ModelSchema.Cost(
            tier: nil,
            input: usd(input),
            output: usd(output),
            cache: ModelSchema.Cost.Cache(read: usd(cacheRead), write: usd(cacheWrite))
        )]
    }

    private static func releaseTimestamp(_ year: Int, _ month: Int, _ day: Int) -> Double {
        // Howard Hinnant civil-to-days pure arithmetic (epoch ms)
        let adjY = month <= 2 ? year - 1 : year
        let era = (adjY >= 0 ? adjY : adjY - 399) / 400
        let yoe = adjY - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days) * 86_400_000.0
    }

    private static func parseReleaseDate(_ raw: String?) -> Double {
        guard let raw else { return 0 }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return 0 }
        return releaseTimestamp(parts[0], parts[1], parts.count >= 3 ? parts[2] : 1)
    }

    private static func makeModel(
        id: String,
        modelID: String? = nil,
        providerID: ProviderSchema.ID,
        name: String,
        family: String,
        package: String,
        context: Int,
        output: Int,
        inputCost: Double,
        outputCost: Double,
        cacheRead: Double = 0,
        cacheWrite: Double = 0,
        released: (Int, Int, Int),
        inputModalities: [String] = ["text", "image", "pdf"],
        reasoning: [CoreModel.Variant.Support] = []
    ) -> ModelSchema.Info {
        let base = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: id),
            modelID: ModelSchema.ID(rawValue: modelID ?? id),
            providerID: providerID,
            type: .chat,
            family: ModelSchema.Family(rawValue: family),
            name: name,
            package: package,
            capabilities: ModelSchema.Capabilities(
                tools: true,
                input: inputModalities,
                output: ["text"],
                temperature: true
            ),
            variants: [],
            time: ModelSchema.Info.Time(released: releaseTimestamp(released.0, released.1, released.2)),
            cost: makeCost(input: inputCost, output: outputCost, cacheRead: cacheRead, cacheWrite: cacheWrite),
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: context, output: output)
        )
        let variants = reasoning.isEmpty ? [] : CoreModel.Variant.resolve(base, supports: reasoning)
        return ModelSchema.Info(
            id: base.id,
            modelID: base.modelID,
            providerID: base.providerID,
            canonical: base.canonical,
            type: base.type,
            family: base.family,
            name: base.name,
            compatibility: base.compatibility,
            package: base.package,
            settings: base.settings,
            headers: base.headers,
            body: base.body,
            capabilities: base.capabilities,
            variants: variants,
            time: base.time,
            cost: base.cost,
            status: base.status,
            enabled: base.enabled,
            limit: base.limit
        )
    }

    private static let preferredDefaultModels: [(ProviderSchema.ID, ModelSchema.ID)] = [
        (.anthropic, ModelSchema.ID(rawValue: "claude-sonnet-4-6")),
        (.openai, ModelSchema.ID(rawValue: "gpt-5.4")),
        (.google, ModelSchema.ID(rawValue: "gemini-2.5-pro")),
        (.openrouter, ModelSchema.ID(rawValue: "anthropic/claude-sonnet-4.6")),
        (ProviderSchema.ID(rawValue: "xai"), ModelSchema.ID(rawValue: "grok-4")),
        (ProviderSchema.ID(rawValue: "groq"), ModelSchema.ID(rawValue: "llama-3.3-70b-versatile")),
        (.opencode, ModelSchema.ID(rawValue: "claude-sonnet-4-6")),
    ]

    private static let builtinProviders: [BuiltinProviderSpec] = [
        BuiltinProviderSpec(
            id: .anthropic,
            name: "Anthropic",
            envVars: ["ANTHROPIC_API_KEY"],
            package: "@opencode/ai/providers/anthropic",
            baseURL: AIProtocols.AnthropicMessages.DEFAULT_BASE_URL,
            compatibility: nil,
            models: [
                makeModel(
                    id: "claude-sonnet-4-6",
                    providerID: .anthropic,
                    name: "Claude Sonnet 4.6",
                    family: "claude-sonnet",
                    package: "@opencode/ai/providers/anthropic",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 3.0,
                    outputCost: 15.0,
                    cacheRead: 0.3,
                    cacheWrite: 3.75,
                    released: (2026, 2, 17),
                    reasoning: [.toggle, .effort(values: ["low", "medium", "high", "max"])]
                ),
                makeModel(
                    id: "claude-opus-4-6",
                    providerID: .anthropic,
                    name: "Claude Opus 4.6",
                    family: "claude-opus",
                    package: "@opencode/ai/providers/anthropic",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 5.0,
                    outputCost: 25.0,
                    cacheRead: 0.5,
                    cacheWrite: 6.25,
                    released: (2026, 2, 5),
                    reasoning: [.toggle, .effort(values: ["low", "medium", "high", "max"])]
                ),
                makeModel(
                    id: "claude-sonnet-4-5",
                    providerID: .anthropic,
                    name: "Claude Sonnet 4.5",
                    family: "claude-sonnet",
                    package: "@opencode/ai/providers/anthropic",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 3.0,
                    outputCost: 15.0,
                    cacheRead: 0.3,
                    cacheWrite: 3.75,
                    released: (2025, 9, 29),
                    reasoning: [.toggle, .budgetTokens(min: 1_024, max: 32_000)]
                ),
                makeModel(
                    id: "claude-haiku-4-5",
                    providerID: .anthropic,
                    name: "Claude Haiku 4.5",
                    family: "claude-haiku",
                    package: "@opencode/ai/providers/anthropic",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 1.0,
                    outputCost: 5.0,
                    cacheRead: 0.1,
                    cacheWrite: 1.25,
                    released: (2025, 10, 15),
                    reasoning: [.toggle, .budgetTokens(min: 1_024, max: 32_000)]
                ),
                makeModel(
                    id: "claude-sonnet-4-20250514",
                    providerID: .anthropic,
                    name: "Claude Sonnet 4",
                    family: "claude-sonnet",
                    package: "@opencode/ai/providers/anthropic",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 3.0,
                    outputCost: 15.0,
                    cacheRead: 0.3,
                    cacheWrite: 3.75,
                    released: (2025, 5, 22),
                    reasoning: [.toggle, .budgetTokens(min: 1_024, max: 32_000)]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: .openai,
            name: "OpenAI",
            envVars: ["OPENAI_API_KEY"],
            package: "@opencode/ai/providers/openai",
            baseURL: AIProtocols.OpenAIResponses.DEFAULT_BASE_URL,
            compatibility: nil,
            models: [
                makeModel(
                    id: "gpt-5.4",
                    providerID: .openai,
                    name: "GPT-5.4",
                    family: "gpt",
                    package: "@opencode/ai/providers/openai",
                    context: 400_000,
                    output: 128_000,
                    inputCost: 2.5,
                    outputCost: 15.0,
                    cacheRead: 0.25,
                    released: (2026, 3, 5),
                    reasoning: [.effort(values: ["low", "medium", "high", "xhigh"])]
                ),
                makeModel(
                    id: "gpt-5.2-codex",
                    providerID: .openai,
                    name: "GPT-5.2 Codex",
                    family: "gpt",
                    package: "@opencode/ai/providers/openai",
                    context: 400_000,
                    output: 128_000,
                    inputCost: 1.75,
                    outputCost: 14.0,
                    cacheRead: 0.175,
                    released: (2025, 12, 11),
                    reasoning: [.effort(values: ["low", "medium", "high", "xhigh"])]
                ),
                makeModel(
                    id: "gpt-4.1",
                    providerID: .openai,
                    name: "GPT-4.1",
                    family: "gpt",
                    package: "@opencode/ai/providers/openai",
                    context: 1_047_576,
                    output: 32_768,
                    inputCost: 2.0,
                    outputCost: 8.0,
                    cacheRead: 0.5,
                    released: (2025, 4, 14)
                ),
                makeModel(
                    id: "gpt-4.1-mini",
                    providerID: .openai,
                    name: "GPT-4.1 Mini",
                    family: "gpt-mini",
                    package: "@opencode/ai/providers/openai",
                    context: 1_047_576,
                    output: 32_768,
                    inputCost: 0.4,
                    outputCost: 1.6,
                    cacheRead: 0.1,
                    released: (2025, 4, 14)
                ),
                makeModel(
                    id: "o4-mini",
                    providerID: .openai,
                    name: "o4-mini",
                    family: "o-series",
                    package: "@opencode/ai/providers/openai",
                    context: 200_000,
                    output: 100_000,
                    inputCost: 1.1,
                    outputCost: 4.4,
                    cacheRead: 0.275,
                    released: (2025, 4, 16),
                    reasoning: [.effort(values: ["low", "medium", "high"])]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: .google,
            name: "Google",
            envVars: ["GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"],
            package: "@opencode/ai/providers/google",
            baseURL: AIProtocols.Gemini.DEFAULT_BASE_URL,
            compatibility: nil,
            models: [
                makeModel(
                    id: "gemini-2.5-pro",
                    providerID: .google,
                    name: "Gemini 2.5 Pro",
                    family: "gemini-pro",
                    package: "@opencode/ai/providers/google",
                    context: 1_048_576,
                    output: 65_536,
                    inputCost: 1.25,
                    outputCost: 10.0,
                    cacheRead: 0.31,
                    released: (2025, 6, 17),
                    inputModalities: ["text", "image", "audio", "video", "pdf"],
                    reasoning: [.toggle, .effort(values: ["low", "medium", "high"])]
                ),
                makeModel(
                    id: "gemini-2.5-flash",
                    providerID: .google,
                    name: "Gemini 2.5 Flash",
                    family: "gemini-flash",
                    package: "@opencode/ai/providers/google",
                    context: 1_048_576,
                    output: 65_536,
                    inputCost: 0.3,
                    outputCost: 2.5,
                    cacheRead: 0.075,
                    released: (2025, 6, 17),
                    inputModalities: ["text", "image", "audio", "video", "pdf"],
                    reasoning: [.toggle, .effort(values: ["low", "medium", "high"])]
                ),
                makeModel(
                    id: "gemini-2.5-flash-lite",
                    providerID: .google,
                    name: "Gemini 2.5 Flash Lite",
                    family: "gemini-flash-lite",
                    package: "@opencode/ai/providers/google",
                    context: 1_048_576,
                    output: 65_536,
                    inputCost: 0.1,
                    outputCost: 0.4,
                    cacheRead: 0.025,
                    released: (2025, 7, 22),
                    inputModalities: ["text", "image", "audio", "video", "pdf"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: .openrouter,
            name: "OpenRouter",
            envVars: ["OPENROUTER_API_KEY"],
            package: "@opencode/ai/providers/openrouter",
            baseURL: "https://openrouter.ai/api/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "anthropic/claude-sonnet-4.6",
                    providerID: .openrouter,
                    name: "Claude Sonnet 4.6 (OpenRouter)",
                    family: "claude-sonnet",
                    package: "@opencode/ai/providers/openrouter",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 3.0,
                    outputCost: 15.0,
                    cacheRead: 0.3,
                    cacheWrite: 3.75,
                    released: (2026, 2, 17),
                    reasoning: [.toggle, .effort(values: ["low", "medium", "high"])]
                ),
                makeModel(
                    id: "openai/gpt-5.4",
                    providerID: .openrouter,
                    name: "GPT-5.4 (OpenRouter)",
                    family: "gpt",
                    package: "@opencode/ai/providers/openrouter",
                    context: 400_000,
                    output: 128_000,
                    inputCost: 2.5,
                    outputCost: 15.0,
                    cacheRead: 0.25,
                    released: (2026, 3, 5)
                ),
                makeModel(
                    id: "google/gemini-2.5-pro",
                    providerID: .openrouter,
                    name: "Gemini 2.5 Pro (OpenRouter)",
                    family: "gemini-pro",
                    package: "@opencode/ai/providers/openrouter",
                    context: 1_048_576,
                    output: 65_536,
                    inputCost: 1.25,
                    outputCost: 10.0,
                    cacheRead: 0.31,
                    released: (2025, 6, 17)
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "xai"),
            name: "xAI",
            envVars: ["XAI_API_KEY"],
            package: "@opencode/ai/providers/xai",
            baseURL: "https://api.x.ai/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "grok-4",
                    providerID: ProviderSchema.ID(rawValue: "xai"),
                    name: "Grok 4",
                    family: "grok",
                    package: "@opencode/ai/providers/xai",
                    context: 256_000,
                    output: 64_000,
                    inputCost: 3.0,
                    outputCost: 15.0,
                    cacheRead: 0.75,
                    released: (2025, 7, 9),
                    inputModalities: ["text", "image"],
                    reasoning: [.effort(values: ["low", "high"])]
                ),
                makeModel(
                    id: "grok-code-fast-1",
                    providerID: ProviderSchema.ID(rawValue: "xai"),
                    name: "Grok Code Fast 1",
                    family: "grok",
                    package: "@opencode/ai/providers/xai",
                    context: 256_000,
                    output: 32_768,
                    inputCost: 0.2,
                    outputCost: 1.5,
                    cacheRead: 0.02,
                    released: (2025, 8, 26),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "groq"),
            name: "Groq",
            envVars: ["GROQ_API_KEY"],
            package: "@opencode/ai/providers/groq",
            baseURL: "https://api.groq.com/openai/v1",
            compatibility: ModelCompatibilitySchema.ProviderCompatibility(
                reasoningField: .reasoning,
                requireReasoning: false,
                maxTokensField: .maxCompletionTokens
            ),
            models: [
                makeModel(
                    id: "llama-3.3-70b-versatile",
                    providerID: ProviderSchema.ID(rawValue: "groq"),
                    name: "Llama 3.3 70B Versatile",
                    family: "llama",
                    package: "@opencode/ai/providers/groq",
                    context: 131_072,
                    output: 32_768,
                    inputCost: 0.59,
                    outputCost: 0.79,
                    released: (2024, 12, 6),
                    inputModalities: ["text"]
                ),
                makeModel(
                    id: "openai/gpt-oss-120b",
                    providerID: ProviderSchema.ID(rawValue: "groq"),
                    name: "GPT-OSS 120B",
                    family: "gpt-oss",
                    package: "@opencode/ai/providers/groq",
                    context: 131_072,
                    output: 32_768,
                    inputCost: 0.15,
                    outputCost: 0.75,
                    released: (2025, 8, 5),
                    inputModalities: ["text"],
                    reasoning: [.effort(values: ["low", "medium", "high"])]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: .opencode,
            name: "OpenCode",
            envVars: ["OPENCODE_API_KEY"],
            package: "@opencode/ai/providers/openai-compatible",
            baseURL: "https://opencode.ai/zen/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "claude-sonnet-4-6",
                    providerID: .opencode,
                    name: "Claude Sonnet 4.6",
                    family: "claude-sonnet",
                    package: "@opencode/ai/providers/anthropic",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 3.0,
                    outputCost: 15.0,
                    cacheRead: 0.3,
                    cacheWrite: 3.75,
                    released: (2026, 2, 17),
                    reasoning: [.toggle, .effort(values: ["low", "medium", "high", "max"])]
                ),
                makeModel(
                    id: "gpt-5.4",
                    providerID: .opencode,
                    name: "GPT-5.4",
                    family: "gpt",
                    package: "@opencode/ai/providers/openai",
                    context: 400_000,
                    output: 128_000,
                    inputCost: 2.5,
                    outputCost: 15.0,
                    cacheRead: 0.25,
                    released: (2026, 3, 5),
                    reasoning: [.effort(values: ["low", "medium", "high", "xhigh"])]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "opencode-go"),
            name: "OpenCode Go",
            envVars: ["OPENCODE_API_KEY"],
            package: "@opencode/ai/providers/openai-compatible",
            baseURL: "https://opencode.ai/zen/go/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "glm-5",
                    providerID: ProviderSchema.ID(rawValue: "opencode-go"),
                    name: "GLM-5",
                    family: "glm",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2026, 2, 10),
                    inputModalities: ["text"]
                ),
                makeModel(
                    id: "kimi-k2.5",
                    providerID: ProviderSchema.ID(rawValue: "opencode-go"),
                    name: "Kimi K2.5",
                    family: "kimi",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 256_000,
                    output: 64_000,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2026, 1, 25),
                    inputModalities: ["text", "image"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "github-copilot"),
            name: "GitHub Copilot",
            envVars: ["GITHUB_TOKEN"],
            package: "@opencode/ai/providers/github-copilot",
            baseURL: "https://api.githubcopilot.com",
            compatibility: nil,
            models: [
                makeModel(
                    id: "claude-sonnet-4.6",
                    providerID: ProviderSchema.ID(rawValue: "github-copilot"),
                    name: "Claude Sonnet 4.6",
                    family: "claude-sonnet",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2026, 2, 17)
                ),
                makeModel(
                    id: "gpt-5.4",
                    providerID: ProviderSchema.ID(rawValue: "github-copilot"),
                    name: "GPT-5.4",
                    family: "gpt",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 400_000,
                    output: 128_000,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2026, 3, 5)
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "deepseek"),
            name: "DeepSeek",
            envVars: ["DEEPSEEK_API_KEY"],
            package: "@opencode/ai/providers/deepseek",
            baseURL: "https://api.deepseek.com/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "deepseek-reasoner",
                    providerID: ProviderSchema.ID(rawValue: "deepseek"),
                    name: "DeepSeek Reasoner (R1)",
                    family: "deepseek",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 128_000,
                    output: 64_000,
                    inputCost: 0.55,
                    outputCost: 2.19,
                    cacheRead: 0.14,
                    released: (2025, 5, 28),
                    inputModalities: ["text"],
                    reasoning: [.effort(values: ["low", "medium", "high"])]
                ),
                makeModel(
                    id: "deepseek-chat",
                    providerID: ProviderSchema.ID(rawValue: "deepseek"),
                    name: "DeepSeek Chat (V3)",
                    family: "deepseek",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 128_000,
                    output: 8_192,
                    inputCost: 0.27,
                    outputCost: 1.1,
                    cacheRead: 0.07,
                    released: (2025, 3, 24),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "mistral"),
            name: "Mistral",
            envVars: ["MISTRAL_API_KEY"],
            package: "@opencode/ai/providers/mistral",
            baseURL: "https://api.mistral.ai/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "mistral-large-latest",
                    providerID: ProviderSchema.ID(rawValue: "mistral"),
                    name: "Mistral Large",
                    family: "mistral",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 128_000,
                    output: 32_768,
                    inputCost: 2.0,
                    outputCost: 6.0,
                    released: (2025, 11, 18),
                    inputModalities: ["text"]
                ),
                makeModel(
                    id: "codestral-latest",
                    providerID: ProviderSchema.ID(rawValue: "mistral"),
                    name: "Codestral",
                    family: "codestral",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 256_000,
                    output: 32_768,
                    inputCost: 0.3,
                    outputCost: 0.9,
                    released: (2025, 1, 13),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "cerebras"),
            name: "Cerebras",
            envVars: ["CEREBRAS_API_KEY"],
            package: "@opencode/ai/providers/cerebras",
            baseURL: "https://api.cerebras.ai/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "qwen-3-coder-480b",
                    providerID: ProviderSchema.ID(rawValue: "cerebras"),
                    name: "Qwen 3 Coder 480B",
                    family: "qwen",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 131_072,
                    output: 40_000,
                    inputCost: 2.0,
                    outputCost: 2.0,
                    released: (2025, 7, 23),
                    inputModalities: ["text"]
                ),
                makeModel(
                    id: "llama-3.3-70b",
                    providerID: ProviderSchema.ID(rawValue: "cerebras"),
                    name: "Llama 3.3 70B",
                    family: "llama",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 128_000,
                    output: 8_192,
                    inputCost: 0.85,
                    outputCost: 1.2,
                    released: (2024, 12, 6),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "togetherai"),
            name: "Together AI",
            envVars: ["TOGETHER_API_KEY"],
            package: "@opencode/ai/providers/togetherai",
            baseURL: "https://api.together.xyz/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8",
                    providerID: ProviderSchema.ID(rawValue: "togetherai"),
                    name: "Qwen3 Coder 480B",
                    family: "qwen",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 262_144,
                    output: 32_768,
                    inputCost: 2.0,
                    outputCost: 2.0,
                    released: (2025, 7, 23),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "fireworks-ai"),
            name: "Fireworks AI",
            envVars: ["FIREWORKS_API_KEY"],
            package: "@opencode/ai/providers/fireworks-ai",
            baseURL: "https://api.fireworks.ai/inference/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "accounts/fireworks/models/deepseek-r1-0528",
                    providerID: ProviderSchema.ID(rawValue: "fireworks-ai"),
                    name: "DeepSeek R1",
                    family: "deepseek",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 163_840,
                    output: 16_384,
                    inputCost: 3.0,
                    outputCost: 8.0,
                    released: (2025, 5, 28),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "perplexity"),
            name: "Perplexity",
            envVars: ["PERPLEXITY_API_KEY"],
            package: "@opencode/ai/providers/perplexity",
            baseURL: "https://api.perplexity.ai",
            compatibility: nil,
            models: [
                makeModel(
                    id: "sonar-pro",
                    providerID: ProviderSchema.ID(rawValue: "perplexity"),
                    name: "Sonar Pro",
                    family: "sonar",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 200_000,
                    output: 8_192,
                    inputCost: 3.0,
                    outputCost: 15.0,
                    released: (2025, 1, 21),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "amazon-bedrock"),
            name: "Amazon Bedrock",
            envVars: ["AWS_BEARER_TOKEN_BEDROCK", "AWS_ACCESS_KEY_ID"],
            package: "@opencode/ai/providers/amazon-bedrock",
            baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
            compatibility: nil,
            models: [
                makeModel(
                    id: "anthropic.claude-sonnet-4-5-20250929-v1:0",
                    providerID: ProviderSchema.ID(rawValue: "amazon-bedrock"),
                    name: "Claude Sonnet 4.5 (Bedrock)",
                    family: "claude-sonnet",
                    package: "@opencode/ai/providers/amazon-bedrock",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 3.0,
                    outputCost: 15.0,
                    released: (2025, 9, 29)
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "azure"),
            name: "Azure OpenAI",
            envVars: ["AZURE_OPENAI_API_KEY", "AZURE_API_KEY"],
            package: "@opencode/ai/providers/azure",
            baseURL: "https://api.openai.com/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "gpt-4.1",
                    providerID: ProviderSchema.ID(rawValue: "azure"),
                    name: "GPT-4.1 (Azure)",
                    family: "gpt",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 1_047_576,
                    output: 32_768,
                    inputCost: 2.0,
                    outputCost: 8.0,
                    released: (2025, 4, 14)
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "google-vertex"),
            name: "Google Vertex AI",
            envVars: ["GOOGLE_VERTEX_API_KEY", "GEMINI_API_KEY"],
            package: "@opencode/ai/providers/google-vertex",
            baseURL: AIProtocols.Gemini.DEFAULT_BASE_URL,
            compatibility: nil,
            models: [
                makeModel(
                    id: "gemini-2.5-pro",
                    providerID: ProviderSchema.ID(rawValue: "google-vertex"),
                    name: "Gemini 2.5 Pro (Vertex)",
                    family: "gemini-pro",
                    package: "@opencode/ai/providers/google",
                    context: 1_048_576,
                    output: 65_536,
                    inputCost: 1.25,
                    outputCost: 10.0,
                    released: (2025, 6, 17)
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "ollama"),
            name: "Ollama (Local)",
            envVars: ["OLLAMA_API_KEY"],
            package: "@opencode/ai/providers/openai-compatible",
            baseURL: "http://127.0.0.1:11434/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "qwen2.5-coder:32b",
                    providerID: ProviderSchema.ID(rawValue: "ollama"),
                    name: "Qwen 2.5 Coder 32B",
                    family: "qwen",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 131_072,
                    output: 16_384,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2024, 11, 12),
                    inputModalities: ["text"]
                ),
                makeModel(
                    id: "llama3.3:latest",
                    providerID: ProviderSchema.ID(rawValue: "ollama"),
                    name: "Llama 3.3",
                    family: "llama",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 131_072,
                    output: 16_384,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2024, 12, 6),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "lmstudio"),
            name: "LM Studio (Local)",
            envVars: ["LMSTUDIO_API_KEY"],
            package: "@opencode/ai/providers/openai-compatible",
            baseURL: "http://127.0.0.1:1234/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "local-model",
                    providerID: ProviderSchema.ID(rawValue: "lmstudio"),
                    name: "Local Model",
                    family: "local",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 131_072,
                    output: 16_384,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2025, 1, 1),
                    inputModalities: ["text"]
                ),
            ]
        ),
    ]

    private static func loadCachedModelsDevSnapshots(
        globalPaths: Global.Interface?,
        fileSystem: (any OpenCodeFileSystem)?
    ) async -> [CoreModel.ModelsDev.Snapshot] {
        guard let globalPaths, let fileSystem else { return [] }
        let cachePath = "\(globalPaths.cache.trimmingTrailingSlashes())/models.json"
        guard await fileSystem.exists(at: cachePath),
              let bytes = try? await fileSystem.readFile(at: cachePath),
              let decoded = try? CoreModel.ModelsDev.decodeSnapshot(String(decoding: bytes, as: UTF8.self))
        else {
            return []
        }
        return decoded.compactMap { snap -> CoreModel.ModelsDev.Snapshot? in
            if snap.info.id.rawValue == "azure-cognitive-services"
                || snap.info.id.rawValue == "google-vertex-anthropic"
            {
                return nil
            }
            let filteredModels = snap.models.filter { model in
                model.status != .deprecated
                    && ((model.type ?? .chat) != .chat || CoreModel.Model.supportsText(model))
            }
            guard !filteredModels.isEmpty else { return nil }
            return CoreModel.ModelsDev.Snapshot(
                info: snap.info,
                models: filteredModels,
                environment: snap.environment
            )
        }
    }

    /// Seeds built-in integrations, providers, models, merges any cached `globalPaths.cache/models.json`
    /// ModelsDev catalog at lower priority, and overlays providers/models/default-model configured in
    /// `configEntries` (`opencode.json[c]`).
    public static func seedProvidersAndModels(
        integrations integrationService: any CoreIntegration.Integration.Interface,
        providers providerService: any CoreProvider.Provider.Interface,
        models modelService: any CoreModel.Model.Interface,
        configEntries: [CoreConfigEntry],
        globalPaths: Global.Interface? = nil,
        fileSystem: (any OpenCodeFileSystem)? = nil
    ) async throws {
        // Collect provider configs & default model from ordered config entries (later wins).
        var configuredProviders: [String: [ConfigProviderSchema.Info]] = [:]
        var configuredDefaultModel: ConfigModelSchema.Selection? = nil
        for entry in configEntries {
            guard let info = entry.info else { continue }
            if let modelSel = info.model {
                configuredDefaultModel = modelSel
            }
            for (rawID, provCfg) in info.providers ?? [:] {
                configuredProviders[rawID, default: []].append(provCfg)
            }
        }

        let cachedSnapshots = await loadCachedModelsDevSnapshots(
            globalPaths: globalPaths,
            fileSystem: fileSystem
        )
        let cachedByID: [String: CoreModel.ModelsDev.Snapshot] = Dictionary(
            cachedSnapshots.map { ($0.info.id.rawValue, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        let builtinByID: [String: BuiltinProviderSpec] = Dictionary(
            uniqueKeysWithValues: builtinProviders.map { ($0.id.rawValue, $0) }
        )

        // 1. Register cached ModelsDev + built-in + custom integrations (with `.key` + `.env` auth methods)
        let configProvidersSnapshot = configuredProviders
        _ = try await integrationService.transform { editor in
            // 1a. Cached ModelsDev providers not in built-ins (lowest priority)
            for snap in cachedSnapshots where builtinByID[snap.info.id.rawValue] == nil {
                let intID = IntegrationID(rawValue: snap.info.id.rawValue)
                editor.update(intID) { _ in
                    IntegrationSchema.Ref(id: intID, name: snap.info.name, metadata: nil)
                }
                editor.updateMethod(.key(CoreIntegration.Integration.KeyImplementation(
                    integrationID: intID,
                    method: IntegrationSchema.KeyMethod(label: "API key")
                )))
                if !snap.environment.isEmpty {
                    editor.updateMethod(.env(CoreIntegration.Integration.EnvImplementation(
                        integrationID: intID,
                        method: IntegrationSchema.EnvMethod(names: snap.environment)
                    )))
                }
            }

            // 1b. Built-in providers (higher priority than cached ModelsDev)
            for spec in builtinProviders {
                let intID = IntegrationID(rawValue: spec.id.rawValue)
                var envVars = spec.envVars
                if let cachedEnv = cachedByID[spec.id.rawValue]?.environment {
                    for name in cachedEnv where !envVars.contains(name) {
                        envVars.append(name)
                    }
                }
                if let cfgs = configProvidersSnapshot[spec.id.rawValue] {
                    for cfg in cfgs {
                        if let extraEnv = cfg.env {
                            for name in extraEnv where !envVars.contains(name) {
                                envVars.append(name)
                            }
                        }
                    }
                }
                editor.update(intID) { _ in
                    IntegrationSchema.Ref(id: intID, name: spec.name, metadata: nil)
                }
                editor.updateMethod(.key(CoreIntegration.Integration.KeyImplementation(
                    integrationID: intID,
                    method: IntegrationSchema.KeyMethod(label: "API key")
                )))
                if !envVars.isEmpty {
                    editor.updateMethod(.env(CoreIntegration.Integration.EnvImplementation(
                        integrationID: intID,
                        method: IntegrationSchema.EnvMethod(names: envVars)
                    )))
                }
            }

            // 1c. Custom config-declared providers (highest priority)
            for (rawID, cfgs) in configProvidersSnapshot where builtinByID[rawID] == nil {
                let intID = IntegrationID(rawValue: rawID)
                let cached = cachedByID[rawID]
                let displayName = cfgs.compactMap(\.name).last ?? cached?.info.name ?? rawID
                var envVars = cached?.environment ?? []
                for cfg in cfgs {
                    for name in cfg.env ?? [] where !envVars.contains(name) {
                        envVars.append(name)
                    }
                }
                editor.update(intID) { _ in
                    IntegrationSchema.Ref(id: intID, name: displayName, metadata: nil)
                }
                editor.updateMethod(.key(CoreIntegration.Integration.KeyImplementation(
                    integrationID: intID,
                    method: IntegrationSchema.KeyMethod(label: "API key")
                )))
                if !envVars.isEmpty {
                    editor.updateMethod(.env(CoreIntegration.Integration.EnvImplementation(
                        integrationID: intID,
                        method: IntegrationSchema.EnvMethod(names: envVars)
                    )))
                }
            }
        }

        // 2. Register cached ModelsDev + built-in providers (with `activation: .auto` so only
        //    credentialed/env-keyed providers become available) and apply config provider/model overlays.
        _ = try await providerService.transform { editor in
            // 2a. Cached ModelsDev providers not in built-ins (lowest priority)
            for snap in cachedSnapshots where builtinByID[snap.info.id.rawValue] == nil {
                let info = ProviderSchema.Info(
                    id: snap.info.id,
                    canonical: snap.info.canonical,
                    integrationID: IntegrationID(rawValue: snap.info.id.rawValue),
                    name: snap.info.name,
                    activation: .auto,
                    package: snap.info.package,
                    compatibility: snap.info.compatibility,
                    settings: snap.info.settings,
                    headers: snap.info.headers,
                    body: snap.info.body
                )
                editor.add(info: info, models: snap.models)
            }

            // 2b. Built-in providers + any additional non-conflicting cached models for that provider
            for spec in builtinProviders {
                var extra: [String: JSONValue] = [:]
                if let baseURL = spec.baseURL {
                    extra["baseURL"] = .string(baseURL)
                }
                let settings = extra.isEmpty ? nil : ProviderSchema.Settings(extra: extra)
                let info = ProviderSchema.Info(
                    id: spec.id,
                    integrationID: IntegrationID(rawValue: spec.id.rawValue),
                    name: spec.name,
                    activation: .auto,
                    package: spec.package,
                    compatibility: spec.compatibility,
                    settings: settings
                )
                var mergedModels = spec.models
                if let cachedModels = cachedByID[spec.id.rawValue]?.models {
                    let builtinModelIDs = Set(spec.models.map(\.id))
                    for cachedModel in cachedModels where !builtinModelIDs.contains(cachedModel.id) {
                        mergedModels.append(cachedModel)
                    }
                }
                editor.add(info: info, models: mergedModels)
            }

            for (rawID, cfgs) in configProvidersSnapshot.sorted(by: { $0.key < $1.key }) {
                let pid = ProviderSchema.ID(rawValue: rawID)
                let isBuiltin = builtinByID[rawID] != nil
                let hasCachedEnv = !(cachedByID[rawID]?.environment.isEmpty ?? true)
                var currentInfo = editor.get(pid)?.provider ?? ProviderSchema.Info(
                    id: pid,
                    integrationID: IntegrationID(rawValue: rawID),
                    name: rawID,
                    activation: .auto,
                    package: "@opencode/ai/providers/openai-compatible"
                )
                var currentModels = editor.get(pid)?.models ?? [:]

                for cfg in cfgs {
                    let rewritten = CoreProvider.AISDKNative.rewrite(
                        specifier: cfg.package ?? currentInfo.package,
                        providerID: rawID,
                        canonical: (cfg.canonical ?? currentInfo.canonical)?.rawValue,
                        settings: cfg.settings?.extra,
                        headers: cfg.headers,
                        body: cfg.body
                    )
                    let mergedExtra = CoreProvider.AISDKNative.mergeOverlay(
                        currentInfo.settings?.extra,
                        rewritten.settings ?? cfg.settings?.extra
                    ) ?? [:]
                    let mergedSettings = ProviderSchema.Settings(
                        timeout: cfg.settings?.timeout ?? currentInfo.settings?.timeout,
                        headerTimeout: cfg.settings?.headerTimeout ?? currentInfo.settings?.headerTimeout,
                        chunkTimeout: cfg.settings?.chunkTimeout ?? currentInfo.settings?.chunkTimeout,
                        compaction: cfg.settings?.compaction ?? currentInfo.settings?.compaction,
                        cache: cfg.settings?.cache ?? currentInfo.settings?.cache,
                        transport: cfg.settings?.transport ?? currentInfo.settings?.transport,
                        encoding: cfg.settings?.encoding ?? currentInfo.settings?.encoding,
                        tls: cfg.settings?.tls ?? currentInfo.settings?.tls,
                        extra: mergedExtra
                    )
                    let mergedHeaders = CoreProvider.AISDKNative.mergeHeaders(currentInfo.headers, rewritten.headers ?? cfg.headers)
                    let mergedBody = CoreProvider.AISDKNative.mergeOverlay(currentInfo.body, rewritten.body ?? cfg.body)

                    // Enable custom providers directly when apiKey is explicitly provided in settings
                    // or when a custom non-builtin provider declares a baseURL with no env requirement.
                    let hasExplicitApiKey: Bool = {
                        if case .string(let k) = mergedExtra["apiKey"], !k.isEmpty { return true }
                        if case .bool(false) = mergedExtra["apiKey"] { return true }
                        return false
                    }()
                    let hasCustomBaseURL: Bool = {
                        if case .string(let u) = mergedExtra["baseURL"], !u.isEmpty { return true }
                        if case .string(let u) = mergedExtra["base_url"], !u.isEmpty { return true }
                        return false
                    }()
                    let activation: ProviderSchema.Activation =
                        (hasExplicitApiKey || (!isBuiltin && !hasCachedEnv && hasCustomBaseURL && (cfg.env?.isEmpty ?? true)))
                        ? .enabled
                        : currentInfo.activation

                    currentInfo = ProviderSchema.Info(
                        id: pid,
                        canonical: cfg.canonical ?? currentInfo.canonical,
                        integrationID: currentInfo.integrationID ?? IntegrationID(rawValue: rawID),
                        name: cfg.name ?? currentInfo.name,
                        activation: activation,
                        package: rewritten.package ?? currentInfo.package,
                        compatibility: cfg.compatibility ?? currentInfo.compatibility,
                        settings: mergedSettings,
                        headers: mergedHeaders,
                        body: mergedBody
                    )

                    for (modelKey, modelCfg) in cfg.models ?? [:] {
                        let mid = ModelSchema.ID(rawValue: modelKey)
                        let base = currentModels[mid] ?? ModelSchema.Info.default(providerID: pid, id: mid)
                        let modelPkg = CoreProvider.AISDKNative.rewrite(
                            specifier: modelCfg.package ?? base.package ?? currentInfo.package,
                            providerID: rawID,
                            canonical: currentInfo.canonical?.rawValue,
                            modelID: (modelCfg.modelID ?? base.modelID).rawValue
                        ).package ?? currentInfo.package

                        let mergedCaps = CoreModel.Model.mergeCapabilities(
                            tools: modelCfg.capabilities?.tools,
                            freeform: modelCfg.capabilities?.freeform,
                            input: modelCfg.capabilities?.input,
                            output: modelCfg.capabilities?.output,
                            temperature: modelCfg.capabilities?.temperature,
                            base: base.capabilities
                        )
                        let resolvedLimit = ModelSchema.Info.Limit(
                            context: modelCfg.limit?.context ?? base.limit.context,
                            input: modelCfg.limit?.input ?? base.limit.input,
                            output: modelCfg.limit?.output ?? base.limit.output
                        )
                        let resolvedCost: [ModelSchema.Cost] = {
                            guard let costVal = modelCfg.cost else { return base.cost }
                            let items: [ConfigProviderSchema.Cost] = switch costVal {
                            case .single(let c): [c]
                            case .tiered(let arr): arr
                            }
                            return items.map { item in
                                ModelSchema.Cost(
                                    tier: item.tier.map { ModelSchema.Cost.Tier(size: $0.size) },
                                    input: item.input,
                                    output: item.output,
                                    cache: ModelSchema.Cost.Cache(
                                        read: item.cache?.read ?? .zero,
                                        write: item.cache?.write ?? .zero
                                    )
                                )
                            }
                        }()
                        let mergedModelExtra = CoreProvider.AISDKNative.mergeOverlay(
                            base.settings?.extra,
                            modelCfg.settings?.extra
                        ) ?? [:]
                        let mergedModelSettings = ModelSchema.Settings(
                            compaction: modelCfg.settings?.compaction ?? base.settings?.compaction,
                            cache: modelCfg.settings?.cache ?? base.settings?.cache,
                            encoding: modelCfg.settings?.encoding ?? base.settings?.encoding,
                            extra: mergedModelExtra
                        )
                        let released = modelCfg.releaseDate != nil ? parseReleaseDate(modelCfg.releaseDate) : base.time.released
                        var updatedModel = ModelSchema.Info(
                            id: mid,
                            modelID: modelCfg.modelID ?? base.modelID,
                            providerID: pid,
                            canonical: currentInfo.canonical ?? base.canonical,
                            type: modelCfg.type ?? base.type ?? .chat,
                            family: modelCfg.family ?? base.family,
                            name: modelCfg.name ?? base.name,
                            compatibility: modelCfg.compatibility ?? base.compatibility,
                            package: modelPkg,
                            settings: mergedModelSettings,
                            headers: CoreProvider.AISDKNative.mergeHeaders(base.headers, modelCfg.headers),
                            body: CoreProvider.AISDKNative.mergeOverlay(base.body, modelCfg.body),
                            capabilities: mergedCaps,
                            variants: base.variants,
                            time: ModelSchema.Info.Time(released: released),
                            cost: resolvedCost,
                            status: base.status,
                            enabled: modelCfg.disabled.map { !$0 } ?? base.enabled,
                            limit: resolvedLimit
                        )
                        if let explicitVariants = modelCfg.variants {
                            let converted = explicitVariants.map {
                                ModelSchema.Variant(id: $0.id, settings: $0.settings, headers: $0.headers, body: $0.body)
                            }
                            updatedModel = ModelSchema.Info(
                                id: updatedModel.id, modelID: updatedModel.modelID, providerID: updatedModel.providerID,
                                canonical: updatedModel.canonical, type: updatedModel.type, family: updatedModel.family,
                                name: updatedModel.name, compatibility: updatedModel.compatibility, package: updatedModel.package,
                                settings: updatedModel.settings, headers: updatedModel.headers, body: updatedModel.body,
                                capabilities: updatedModel.capabilities, variants: converted, time: updatedModel.time,
                                cost: updatedModel.cost, status: updatedModel.status, enabled: updatedModel.enabled,
                                limit: updatedModel.limit
                            )
                        } else if let reasoning = modelCfg.capabilities?.reasoning {
                            let supports = CoreModel.Variant.supports(reasoning)
                            let resolvedVariants = supports.isEmpty ? [] : CoreModel.Variant.resolve(updatedModel, supports: supports)
                            updatedModel = ModelSchema.Info(
                                id: updatedModel.id, modelID: updatedModel.modelID, providerID: updatedModel.providerID,
                                canonical: updatedModel.canonical, type: updatedModel.type, family: updatedModel.family,
                                name: updatedModel.name, compatibility: updatedModel.compatibility, package: updatedModel.package,
                                settings: updatedModel.settings, headers: updatedModel.headers, body: updatedModel.body,
                                capabilities: updatedModel.capabilities, variants: resolvedVariants, time: updatedModel.time,
                                cost: updatedModel.cost, status: updatedModel.status, enabled: updatedModel.enabled,
                                limit: updatedModel.limit
                            )
                        }
                        currentModels[mid] = updatedModel
                    }
                }

                editor.add(info: currentInfo, models: Array(currentModels.values))
            }
        }

        // 3. Configure default model selection (honors user config `model` first, then
        //    first configured provider with a valid credential in deterministic priority order).
        let finalConfiguredDefault = configuredDefaultModel
        _ = try await modelService.transform { editor in
            if let configured = finalConfiguredDefault {
                editor.setDefault(providerID: configured.providerID, modelID: configured.model)
                return
            }
            for (pid, mid) in preferredDefaultModels {
                if let model = editor.get(providerID: pid, modelID: mid), model.enabled {
                    editor.setDefault(providerID: pid, modelID: mid)
                    return
                }
            }
            if let fallback = editor.list().first(where: { $0.enabled && CoreModel.Model.supportsText($0) }) {
                editor.setDefault(providerID: fallback.providerID, modelID: fallback.id)
            }
        }
    }

    // MARK: - 2b. Built-In & Project/Global Custom Commands (`plugin/command.ts`, `config/plugin/command.ts`)

    private static let promptInitialize = """
    Create or update `AGENTS.md` for this repository.

    The goal is a compact instruction file that helps future OpenCode sessions avoid mistakes and ramp up quickly. Every line should answer: "Would an agent likely miss this without help?" If not, leave it out.

    User-provided focus or constraints (honor these):
    $ARGUMENTS

    ## How to investigate

    Read the highest-value sources first:
    - `README*`, root manifests, workspace config, lockfiles
    - build, test, lint, formatter, typecheck, and codegen config
    - CI workflows and pre-commit / task runner config
    - existing instruction files (`AGENTS.md`, `CLAUDE.md`, `.cursor/rules/`, `.cursorrules`, `.github/copilot-instructions.md`)
    - repo-local OpenCode config such as `opencode.json`

    If architecture is still unclear after reading config and docs, inspect a small number of representative code files to find the real entrypoints, package boundaries, and execution flow. Prefer reading the files that explain how the system is wired together over random leaf files.

    Prefer executable sources of truth over prose. If docs conflict with config or scripts, trust the executable source and only keep what you can verify.

    ## What to extract

    Look for the highest-signal facts for an agent working in this repo:
    - exact developer commands, especially non-obvious ones
    - how to run a single test, a single package, or a focused verification step
    - required command order when it matters, such as `lint -> typecheck -> test`
    - monorepo or multi-package boundaries, ownership of major directories, and the real app/library entrypoints
    - framework or toolchain quirks: generated code, migrations, codegen, build artifacts, special env loading, dev servers, infra deploy flow
    - testing quirks: fixtures, integration test prerequisites, snapshot workflows, required services, flaky or expensive suites
    - important constraints from existing instruction files worth preserving

    Good `AGENTS.md` content is usually hard-earned context that took reading multiple files to infer.

    ## Questions

    Only ask the user questions if the repo cannot answer something important. Use the `question` tool for one short batch at most.

    Good questions:
    - undocumented team conventions
    - branch / PR / release expectations
    - missing setup or test prerequisites that are known but not written down

    Do not ask about anything the repo already makes clear.

    ## Writing rules

    Include only high-signal, repo-specific guidance such as:
    - exact commands and shortcuts the agent would otherwise guess wrong
    - architecture notes that are not obvious from filenames
    - conventions that differ from language or framework defaults
    - setup requirements, environment quirks, and operational gotchas
    - references to existing instruction sources that matter

    Exclude:
    - generic software advice
    - long tutorials or exhaustive file trees
    - obvious language conventions
    - speculative claims or anything you could not verify
    - content better stored in another file referenced via `opencode.json` `instructions`

    When in doubt, omit.

    Prefer short sections and bullets. If the repo is simple, keep the file simple. If the repo is large, summarize the few structural facts that actually change how an agent should work.

    If `AGENTS.md` already exists at `${path}`, improve it in place rather than rewriting blindly. Preserve verified useful guidance, delete fluff or stale claims, and reconcile it with the current codebase.
    """

    private static let promptReview = """
    You are a code reviewer. Your job is to review code changes and provide actionable feedback.

    ---

    Input: $ARGUMENTS

    ---

    ## Determining What to Review

    Based on the input provided, determine which type of review to perform:

    1. **No arguments (default)**: Review all uncommitted changes
       - Run: `git diff` for unstaged changes
       - Run: `git diff --cached` for staged changes
       - Run: `git status --short` to identify untracked (net new) files

    2. **Commit hash** (40-char SHA or short hash): Review that specific commit
       - Run: `git show $ARGUMENTS`

    3. **Branch name**: Compare current branch to the specified branch
       - Run: `git diff $ARGUMENTS...HEAD`

    4. **PR URL or number** (contains "github.com" or "pull" or looks like a PR number): Review the pull request
       - Run: `gh pr view $ARGUMENTS` to get PR context
       - Run: `gh pr diff $ARGUMENTS` to get the diff

    Use best judgement when processing input.

    ---

    ## Gathering Context

    **Diffs alone are not enough.** After getting the diff, read the entire file(s) being modified to understand the full context. Code that looks wrong in isolation may be correct given surrounding logic—and vice versa.

    - Use the diff to identify which files changed
    - Use `git status --short` to identify untracked files, then read their full contents
    - Read the full file to understand existing patterns, control flow, and error handling
    - Check for existing style guide or conventions files (CONVENTIONS.md, AGENTS.md, .editorconfig, etc.)

    ---

    ## What to Look For

    **Bugs** - Your primary focus.
    - Logic errors, off-by-one mistakes, incorrect conditionals
    - If-else guards: missing guards, incorrect branching, unreachable code paths
    - Edge cases: null/empty/undefined inputs, error conditions, race conditions
    - Security issues: injection, auth bypass, data exposure
    - Broken error handling that swallows failures, throws unexpectedly or returns error types that are not caught.

    **Structure** - Does the code fit the codebase?
    - Does it follow existing patterns and conventions?
    - Are there established abstractions it should use but doesn't?
    - Excessive nesting that could be flattened with early returns or extraction

    **Performance** - Only flag if obviously problematic.
    - O(n²) on unbounded data, N+1 queries, blocking I/O on hot paths

    **Behavior Changes** - If a behavioral change is introduced, raise it (especially if it's possibly unintentional).

    ---

    ## Before You Flag Something

    **Be certain.** If you're going to call something a bug, you need to be confident it actually is one.

    - Only review the changes - do not review pre-existing code that wasn't modified
    - Don't flag something as a bug if you're unsure - investigate first
    - Don't invent hypothetical problems - if an edge case matters, explain the realistic scenario where it breaks
    - If you need more context to be sure, use the tools below to get it

    **Don't be a zealot about style.** When checking code against conventions:

    - Verify the code is *actually* in violation. Don't complain about else statements if early returns are already being used correctly.
    - Some "violations" are acceptable when they're the simplest option. A `let` statement is fine if the alternative is convoluted.
    - Excessive nesting is a legitimate concern regardless of other style choices.

    ---

    ## Tools

    Use these to inform your review:

    - **Explore agent** - Find how existing code handles similar problems. Check patterns, conventions, and prior art before claiming something doesn't fit.
    - **Available documentation and code-search tools** - Verify correct usage of libraries/APIs before flagging something as wrong.
    - **Web Search** - Research best practices if you're unsure about a pattern.

    If you're uncertain about something and can't verify it with these tools, say "I'm not sure about X" rather than flagging it as a definite issue.

    ---

    ## Output

    1. If there is a bug, be direct and clear about why it is a bug.
    2. Clearly communicate severity of issues. Do not overstate severity.
    3. Critiques should clearly and explicitly communicate the scenarios, environments, or inputs that are necessary for the bug to arise. The comment should immediately indicate that the issue's severity depends on these factors.
    4. Your tone should be matter-of-fact and not accusatory or overly positive. It should read as a helpful AI assistant suggestion without sounding too much like a human reviewer.
    5. Write so the reader can quickly understand the issue without reading too closely.
    6. AVOID flattery, do not give any comments that are not helpful to the reader.
    """

    /// Parses command invocation arguments matching upstream `config/plugin/command.ts#parseArguments`.
    internal static func parseCommandArguments(_ input: String) -> [String] {
        var result: [String] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            while i < chars.count && chars[i].isWhitespace {
                i += 1
            }
            guard i < chars.count else { break }

            // Match `[Image N]` token literally (case-insensitive)
            if chars[i] == "[" {
                var j = i + 1
                while j < chars.count && chars[j] != "]" {
                    j += 1
                }
                if j < chars.count {
                    let candidate = String(chars[i...j])
                    let inner = candidate.dropFirst().dropLast()
                    let parts = inner.split(whereSeparator: { $0.isWhitespace })
                    if parts.count == 2,
                       parts[0].lowercased() == "image",
                       parts[1].allSatisfy({ $0.isASCII && $0.isNumber })
                    {
                        result.append(candidate)
                        i = j + 1
                        continue
                    }
                }
            }

            if chars[i] == "\"" || chars[i] == "'" {
                let quote = chars[i]
                i += 1
                let start = i
                while i < chars.count && chars[i] != quote {
                    i += 1
                }
                result.append(String(chars[start..<i]))
                if i < chars.count && chars[i] == quote {
                    i += 1
                }
                continue
            }

            let start = i
            while i < chars.count && !chars[i].isWhitespace && chars[i] != "\"" && chars[i] != "'" {
                i += 1
            }
            if i > start {
                result.append(String(chars[start..<i]))
            }
        }
        return result
    }

    /// Evaluates a command template with `${path}`, `$ARGUMENTS`, positional `$1..$N`, and fallback append.
    public static func evaluateCommandTemplate(
        _ template: String,
        arguments: String,
        projectDirectory: String
    ) -> String {
        let withPath = template.replacing("${path}", with: projectDirectory)
        let args = parseCommandArguments(arguments)

        // Scan for `$1..$N` placeholders and `$ARGUMENTS`
        let chars = Array(withPath)
        var highestIndex = 0
        var hasPositional = false
        var hasArguments = false

        var scan = 0
        while scan < chars.count {
            if chars[scan] == "$" {
                let rest = String(chars[scan...])
                if rest.hasPrefix("$ARGUMENTS") {
                    hasArguments = true
                    scan += "$ARGUMENTS".count
                    continue
                }
                if scan + 1 < chars.count, chars[scan + 1] >= "1" && chars[scan + 1] <= "9" {
                    var end = scan + 1
                    while end < chars.count && chars[end].isASCII && chars[end].isNumber {
                        end += 1
                    }
                    if let num = Int(String(chars[(scan + 1)..<end])) {
                        hasPositional = true
                        if num > highestIndex { highestIndex = num }
                    }
                    scan = end
                    continue
                }
            }
            scan += 1
        }

        var substituted = ""
        substituted.reserveCapacity(withPath.count + arguments.count)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == "$" {
                let rest = String(chars[idx...])
                if rest.hasPrefix("$ARGUMENTS") {
                    substituted.append(arguments.trimmingCharacters(in: .whitespacesAndNewlines))
                    idx += "$ARGUMENTS".count
                    continue
                }
                if idx + 1 < chars.count, chars[idx + 1] >= "1" && chars[idx + 1] <= "9" {
                    var end = idx + 1
                    while end < chars.count && chars[end].isASCII && chars[end].isNumber {
                        end += 1
                    }
                    if let position = Int(String(chars[(idx + 1)..<end])) {
                        let argIdx = position - 1
                        if argIdx < args.count {
                            if position == highestIndex {
                                substituted.append(args[argIdx...].joined(separator: " "))
                            } else {
                                substituted.append(args[argIdx])
                            }
                        }
                        idx = end
                        continue
                    }
                }
            }
            substituted.append(chars[idx])
            idx += 1
        }

        let trimmedInput = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasPositional && !hasArguments && !trimmedInput.isEmpty {
            return "\(substituted)\n\n\(trimmedInput)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return substituted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseFrontmatterBool(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let b): return b
        case .int(let n): return n == 1 ? true : (n == 0 ? false : nil)
        case .double(let d): return d == 1 ? true : (d == 0 ? false : nil)
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func parseFrontmatterModel(_ value: JSONValue?) -> ConfigModelSchema.Selection? {
        guard let value else { return nil }
        switch value {
        case .string(let s):
            return try? ConfigModelSchema.Selection.parse(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case .object(let obj):
            guard case .string(let pid) = obj["providerID"],
                  case .string(let mid) = obj["model"],
                  !pid.isEmpty, !mid.isEmpty
            else { return nil }
            let variant: ModelSchema.VariantID? = {
                if case .string(let v) = obj["variant"], !v.isEmpty {
                    return ModelSchema.VariantID(rawValue: v)
                }
                return nil
            }()
            return ConfigModelSchema.Selection(
                providerID: ProviderSchema.ID(rawValue: pid),
                model: ModelSchema.ID(rawValue: mid),
                variant: variant
            )
        default:
            return nil
        }
    }

    internal static func parseCommandMarkdown(_ content: String) -> ConfigCommandSchema.Info? {
        guard let markdown = CoreConfigMarkdown.parseOption(content) else { return nil }
        let description: String? = {
            if case .string(let s) = markdown.data["description"] { return s }
            return nil
        }()
        let agent: String? = {
            if case .string(let s) = markdown.data["agent"], !s.isEmpty { return s }
            return nil
        }()
        let model = parseFrontmatterModel(markdown.data["model"])
        let subagent = parseFrontmatterBool(markdown.data["subagent"])
        let subtask = parseFrontmatterBool(markdown.data["subtask"])
        return ConfigCommandSchema.Info(
            template: markdown.content.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description,
            agent: agent,
            model: model,
            subagent: subagent,
            subtask: subtask
        )
    }

    private static func joinPath(_ a: String, _ b: String) -> String {
        if a == "/" { return "/\(b)" }
        if a.hasSuffix("/") { return a + b }
        return "\(a)/\(b)"
    }

    private static func dirname(_ path: String) -> String {
        var p = path.replacing("\\", with: "/")
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return "." }
        if slash == p.startIndex { return "/" }
        return String(p[..<slash])
    }

    private static func basename(_ path: String) -> String {
        var p = path.replacing("\\", with: "/")
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: slash)...])
    }

    private static func scanMarkdownCommands(
        in commandsRoot: String,
        fileSystem: any OpenCodeFileSystem
    ) async -> [(name: String, info: ConfigCommandSchema.Info)] {
        let normalizedRoot = serverResolvePath(base: "/", relative: commandsRoot)
        guard await fileSystem.exists(at: normalizedRoot) else { return [] }
        var filePaths: [String] = []
        var queue: [(dir: String, depth: Int)] = [(normalizedRoot, 0)]
        var idx = 0
        while idx < queue.count {
            let item = queue[idx]
            idx += 1
            guard let names = try? await fileSystem.readDirectory(at: item.dir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") && !FSPathUtil.ignoredDirectories.contains(name) {
                let child = joinPath(item.dir, name)
                guard let st = try? await fileSystem.stat(at: child) else { continue }
                if st.type == .file && name.hasSuffix(".md") {
                    filePaths.append(child)
                } else if st.type == .directory && item.depth < 6 {
                    queue.append((child, item.depth + 1))
                }
            }
        }
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : "\(normalizedRoot)/"
        var parsed: [(name: String, info: ConfigCommandSchema.Info)] = []
        for filepath in filePaths.sorted() {
            guard let bytes = try? await fileSystem.readFile(at: filepath) else { continue }
            let text = String(decoding: bytes, as: UTF8.self)
            guard let info = parseCommandMarkdown(text) else { continue }
            let rel = filepath.hasPrefix(prefix) ? String(filepath.dropFirst(prefix.count)) : basename(filepath)
            let cleanRel = rel.replacing("\\", with: "/")
            let cmdName = cleanRel.hasSuffix(".md") ? String(cleanRel.dropLast(3)) : cleanRel
            guard !cmdName.isEmpty else { continue }
            parsed.append((name: cmdName, info: info))
        }
        return parsed
    }

    /// Seeds built-in upstream commands (`init`, `review`), project/global custom command markdown files
    /// (`.opencode/commands/*.md`, `.claude/commands/*.md`, `.agents/commands/*.md`,
    /// `globalPaths.config/commands/*.md`, `~/.claude/commands/*.md`), and config-defined `commands`.
    @discardableResult
    public static func seedCommands(
        into commandService: any CoreSubsystems.Command.Interface,
        directory: String,
        projectDirectory: String? = nil,
        globalPaths: Global.Interface,
        configEntries: [CoreConfigEntry],
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        sessionProvider: (@Sendable () -> CoreSession.Service?)? = nil,
        agentService: (any CoreAgent.Agent.Interface)? = nil
    ) async throws -> CoreState.Registration {
        let effectiveProjectDir = projectDirectory ?? directory

        // Collect candidate command folders in ascending precedence order (deduplicated).
        var orderedBases: [String] = []
        var seenBases: Set<String> = []
        func appendBase(_ raw: String) {
            let norm = serverResolvePath(base: "/", relative: raw)
            if seenBases.insert(norm).inserted {
                orderedBases.append(norm)
            }
        }

        // 1. Global roots
        appendBase(globalPaths.config)
        appendBase(joinPath(globalPaths.home, ".claude"))
        appendBase(joinPath(globalPaths.home, ".agents"))

        // 2. Directory entries discovered in configEntries
        for entry in configEntries {
            if case .directory(let dir) = entry {
                appendBase(dir.path.rawValue)
            }
        }

        // 3. Project & location roots (higher precedence than global)
        for rootDir in [effectiveProjectDir, directory] {
            appendBase(joinPath(rootDir, ".claude"))
            appendBase(joinPath(rootDir, ".agents"))
            appendBase(joinPath(rootDir, ".opencode"))
        }

        // Scan markdown command files from each base's `command/` and `commands/` subdirectories.
        var customCommands: [(name: String, info: ConfigCommandSchema.Info)] = []
        for base in orderedBases {
            for folder in ["command", "commands"] {
                let sub = joinPath(base, folder)
                let scanned = await scanMarkdownCommands(in: sub, fileSystem: fileSystem)
                customCommands.append(contentsOf: scanned)
            }
        }

        // Append config document `commands` (highest precedence, in entry order).
        for entry in configEntries {
            guard let cmds = entry.info?.commands else { continue }
            for (name, cmdInfo) in cmds.sorted(by: { $0.key < $1.key }) {
                customCommands.append((name: name, info: cmdInfo))
            }
        }

        let resolvedCustom = customCommands
        return try await commandService.transform { editor in
            // Built-in `init` command (upstream `plugin/command.ts`)
            editor.add(CoreSubsystems.Command.Definition(
                name: "init",
                description: "guided AGENTS.md setup",
                execute: { invocation in
                    guard let session = sessionProvider?() else { return }
                    let rendered = evaluateCommandTemplate(
                        promptInitialize,
                        arguments: invocation.prompt.text,
                        projectDirectory: effectiveProjectDir
                    )
                    _ = try await session.prompt(CoreSession.PromptRequest(
                        sessionID: invocation.sessionID,
                        input: CoreSessionPrompt.Input(
                            text: rendered,
                            files: invocation.prompt.files,
                            agents: invocation.prompt.agents,
                            skills: invocation.prompt.skills,
                            delivery: invocation.delivery
                        )
                    ))
                }
            ))

            // Built-in `review` command (upstream `plugin/command.ts`)
            editor.add(CoreSubsystems.Command.Definition(
                name: "review",
                description: "review changes [commit|branch|pr], defaults to uncommitted",
                execute: { invocation in
                    guard let session = sessionProvider?() else { return }
                    let rendered = evaluateCommandTemplate(
                        promptReview,
                        arguments: invocation.prompt.text,
                        projectDirectory: effectiveProjectDir
                    )
                    _ = try await session.prompt(CoreSession.PromptRequest(
                        sessionID: invocation.sessionID,
                        input: CoreSessionPrompt.Input(
                            text: rendered,
                            files: invocation.prompt.files,
                            agents: invocation.prompt.agents,
                            skills: invocation.prompt.skills,
                            delivery: invocation.delivery
                        )
                    ))
                }
            ))

            // Custom markdown & config-defined commands
            for (name, cmd) in resolvedCustom {
                editor.add(CoreSubsystems.Command.Definition(
                    name: name,
                    description: cmd.description,
                    execute: { invocation in
                        guard let session = sessionProvider?() else { return }
                        let rendered = evaluateCommandTemplate(
                            cmd.template,
                            arguments: invocation.prompt.text,
                            projectDirectory: effectiveProjectDir
                        )
                        let agentID = cmd.agent.map(AgentSchema.ID.init(rawValue:))
                        let commandAgent: AgentSchema.Info? = if let agentID, let agentService {
                            await agentService.get(agentID)
                        } else {
                            nil
                        }
                        let resolvedModel: SessionSchema.ModelRef? = {
                            if let m = cmd.model {
                                return SessionSchema.ModelRef(
                                    id: m.model.rawValue,
                                    providerID: m.providerID.rawValue,
                                    variant: m.variant?.rawValue
                                )
                            }
                            if let m = commandAgent?.model {
                                return SessionSchema.ModelRef(
                                    id: m.id.rawValue,
                                    providerID: m.providerID.rawValue,
                                    variant: m.variant?.rawValue
                                )
                            }
                            return nil
                        }()
                        let shouldSpawnSubagent = (cmd.subagent ?? cmd.subtask) ?? (commandAgent?.mode == .subagent)
                        if shouldSpawnSubagent {
                            let parent = try session.get(invocation.sessionID)
                            let childAgent = agentID?.rawValue ?? parent.agent
                            let childModel = resolvedModel ?? parent.model
                            let child = try await session.create(CoreSession.CreateInput(
                                parentID: parent.id,
                                title: cmd.description ?? name,
                                agent: childAgent,
                                model: childModel
                            ))
                            _ = try await session.prompt(CoreSession.PromptRequest(
                                sessionID: child.id,
                                input: CoreSessionPrompt.Input(
                                    text: "You are a subagent spawned by another session.\n\(rendered)",
                                    files: invocation.prompt.files,
                                    agents: invocation.prompt.agents,
                                    skills: invocation.prompt.skills,
                                    delivery: invocation.delivery
                                )
                            ))
                            return
                        }
                        if let agentID {
                            try await session.selectAgent(sessionID: invocation.sessionID, agent: agentID.rawValue)
                        }
                        if let resolvedModel {
                            try await session.selectModel(sessionID: invocation.sessionID, model: resolvedModel)
                        }
                        _ = try await session.prompt(CoreSession.PromptRequest(
                            sessionID: invocation.sessionID,
                            input: CoreSessionPrompt.Input(
                                text: rendered,
                                files: invocation.prompt.files,
                                agents: invocation.prompt.agents,
                                skills: invocation.prompt.skills,
                                delivery: invocation.delivery
                            )
                        ))
                    }
                ))
            }
        }
    }

    // MARK: - 2c. Project & Global Skill Discovery (`config/plugin/skill.ts`)

    private static let maxSkillSiblingFiles = 50
    private static let maxSkillSiblingBytes = 512 * 1024

    private static func collectSiblingSkillFiles(
        in skillDirectory: String,
        fileSystem: any OpenCodeFileSystem
    ) async -> [String: String] {
        let normalizedRoot = serverResolvePath(base: "/", relative: skillDirectory)
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : "\(normalizedRoot)/"
        var siblingFiles: [String: String] = [:]
        var queue: [(dir: String, depth: Int)] = [(normalizedRoot, 0)]
        var idx = 0
        while idx < queue.count && siblingFiles.count < maxSkillSiblingFiles {
            let item = queue[idx]
            idx += 1
            guard let names = try? await fileSystem.readDirectory(at: item.dir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") && !FSPathUtil.ignoredDirectories.contains(name) {
                if siblingFiles.count >= maxSkillSiblingFiles { break }
                let child = joinPath(item.dir, name)
                guard let st = try? await fileSystem.stat(at: child) else { continue }
                if st.type == .file {
                    if item.depth == 0 && name == "SKILL.md" { continue }
                    if st.size > Int64(maxSkillSiblingBytes) { continue }
                    guard let bytes = try? await fileSystem.readFile(at: child) else { continue }
                    let rel = child.hasPrefix(prefix) ? String(child.dropFirst(prefix.count)) : name
                    siblingFiles[rel.replacing("\\", with: "/")] = String(decoding: bytes, as: UTF8.self)
                } else if st.type == .directory && item.depth < 4 {
                    queue.append((child, item.depth + 1))
                }
            }
        }
        return siblingFiles
    }

    /// Discovers project & global skills from `.opencode/skills`, `.claude/skills`, `.agents/skills`,
    /// `globalPaths.config/skills`, `~/.claude/skills`, `~/.agents/skills`, and config `skills` paths,
    /// parsing YAML frontmatter and registering each skill with its sibling files into `skillService`.
    @discardableResult
    public static func seedSkills(
        into skillService: any CoreSkill.Interface,
        directory: String,
        projectDirectory: String? = nil,
        globalPaths: Global.Interface,
        configEntries: [CoreConfigEntry],
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async throws -> CoreState.Registration {
        let effectiveProjectDir = projectDirectory ?? directory

        var skillRoots: [String] = []
        var seenRoots: Set<String> = []
        func appendSkillRoot(_ raw: String) {
            let norm = serverResolvePath(base: "/", relative: raw)
            if seenRoots.insert(norm).inserted {
                skillRoots.append(norm)
            }
        }
        func appendSkillSubdirs(of base: String) {
            appendSkillRoot(joinPath(base, "skill"))
            appendSkillRoot(joinPath(base, "skills"))
        }

        // 1. Global skill directories
        appendSkillSubdirs(of: globalPaths.config)
        appendSkillSubdirs(of: joinPath(globalPaths.home, ".claude"))
        appendSkillSubdirs(of: joinPath(globalPaths.home, ".agents"))

        // 2. Directory entries from configEntries
        for entry in configEntries {
            if case .directory(let dir) = entry {
                appendSkillSubdirs(of: dir.path.rawValue)
            }
        }

        // 3. Project & location skill directories (higher precedence than global)
        for rootDir in [effectiveProjectDir, directory] {
            appendSkillSubdirs(of: joinPath(rootDir, ".claude"))
            appendSkillSubdirs(of: joinPath(rootDir, ".agents"))
            appendSkillSubdirs(of: joinPath(rootDir, ".opencode"))
        }

        // 4. Explicit local `skills` directory paths declared in config documents
        for entry in configEntries {
            guard let items = entry.info?.skills else { continue }
            for item in items {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                    continue
                }
                let expanded: String
                if trimmed.hasPrefix("~/") {
                    expanded = joinPath(globalPaths.home, String(trimmed.dropFirst(2)))
                } else {
                    expanded = serverResolvePath(base: directory, relative: trimmed)
                }
                appendSkillRoot(expanded)
            }
        }

        var discovered: [(skill: SkillSchema.Info, files: [String: String])] = []
        for root in skillRoots {
            guard await fileSystem.exists(at: root) else { continue }
            let scanned = await CoreConfigPlugin.SkillScan.scan(root: root, fileSystem: fileSystem)
            for filepath in scanned {
                guard let bytes = try? await fileSystem.readFile(at: filepath) else { continue }
                let text = String(decoding: bytes, as: UTF8.self)
                guard case .parsed(let skillInfo) = CoreConfigPlugin.SkillFile.parse(
                    directory: root,
                    filepath: filepath,
                    content: text
                ) else {
                    continue
                }
                let siblings: [String: String]
                if basename(filepath) == "SKILL.md" {
                    let skillDir = dirname(filepath)
                    siblings = await collectSiblingSkillFiles(in: skillDir, fileSystem: fileSystem)
                } else {
                    siblings = [:]
                }
                discovered.append((skill: skillInfo, files: siblings))
            }
        }

        let resolvedSkills = discovered
        return try await skillService.transform { editor in
            for item in resolvedSkills {
                editor.add(item.skill, files: item.files.isEmpty ? nil : item.files)
            }
        }
    }

    // MARK: - 3. Live Git VCS Provider

    /// Registers a live Git VCS provider on `vcsService` (when `!workerdProfile`), backed by
    /// `ProcessSpawner` + `CoreVcs.Git.Service`, so `GET /api/vcs` detects the real git branch and status.
    public static func registerLiveGitVcs(
        into vcsService: any CoreVcs.Vcs.Interface,
        directory: SchemaPrimitive.AbsolutePath,
        projectDirectory: SchemaPrimitive.AbsolutePath,
        fileSystem: any OpenCodeFileSystem,
        spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared
    ) async {
        let gitExe = CoreSubsystems.Util.GitExecutable.gitExecutable()
        let gitService = CoreVcs.Git.Service(spawner: spawner, fileSystem: fileSystem, executable: gitExe)
        let workDir = directory.rawValue
        let projDir = projectDirectory.rawValue

        @Sendable
        func runGit(_ args: [String], cwd: String = workDir) async -> ProcessOutput? {
            try? await spawner.run(ProcessSpec(
                executable: gitExe,
                arguments: args,
                workingDirectory: cwd
            ))
        }

        @Sendable
        func detectCurrentBranch() async -> String? {
            if let out = await runGit(["rev-parse", "--abbrev-ref", "HEAD"]), out.exitCode == 0 {
                let raw = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty && raw != "HEAD" {
                    return raw
                }
            }
            // Fallback for unborn branches (fresh `git init` before first commit)
            if let out = await runGit(["symbolic-ref", "--short", "HEAD"]), out.exitCode == 0 {
                let raw = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    return raw
                }
            }
            return nil
        }

        @Sendable
        func detectDefaultBranch() async -> String? {
            if let repo = await gitService.discover(directory),
               let remoteDefault = await gitService.defaultRemoteBranch(repo, remote: "origin") {
                return remoteDefault
            }
            for candidate in ["main", "master"] {
                if let out = await runGit(["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"]),
                   out.exitCode == 0 {
                    return candidate
                }
            }
            return nil
        }

        let provider = CoreVcs.Vcs.ProviderDefinition(
            id: "git",
            info: {
                let current = await detectCurrentBranch()
                let defaultBranch = await detectDefaultBranch()
                return VcsSchema.Info(
                    provider: "git",
                    branch: VcsSchema.Branch(current: current, defaultBranch: defaultBranch)
                )
            },
            base: {
                guard let defaultName = await detectDefaultBranch() else { return nil }
                for ref in ["origin/\(defaultName)", defaultName] {
                    if let out = await runGit(["rev-parse", "--verify", "--quiet", ref]), out.exitCode == 0 {
                        let sha = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !sha.isEmpty {
                            return VcsSchema.Base(name: defaultName, ref: sha, source: .default)
                        }
                    }
                }
                return nil
            },
            branches: { options in
                guard let out = await runGit(["for-each-ref", "--format=%(refname:short)", "refs/heads"]),
                      out.exitCode == 0
                else {
                    return []
                }
                var list = String(decoding: out.stdout, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if let query = options?.search?.lowercased(), !query.isEmpty {
                    list = list.filter { $0.lowercased().contains(query) }
                }
                if let limit = options?.limit, limit >= 0, list.count > limit {
                    list = Array(list.prefix(limit))
                }
                return list
            },
            status: {
                guard let statusOut = await runGit(["status", "--porcelain=v1", "--untracked-files=all"]),
                      statusOut.exitCode == 0
                else {
                    return []
                }
                var numstat: [String: (additions: Int, deletions: Int)] = [:]
                if let nsOut = await runGit(["diff", "--numstat", "HEAD"]), nsOut.exitCode == 0 {
                    let nsText = String(decoding: nsOut.stdout, as: UTF8.self)
                    for line in nsText.split(separator: "\n", omittingEmptySubsequences: true) {
                        let cols = line.split(separator: "\t")
                        if cols.count >= 3 {
                            let add = Int(cols[0]) ?? 0
                            let del = Int(cols[1]) ?? 0
                            let file = String(cols[2])
                            numstat[file] = (add, del)
                        }
                    }
                }

                let text = String(decoding: statusOut.stdout, as: UTF8.self)
                var results: [VcsSchema.FileStatus] = []
                for lineSub in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(lineSub)
                    guard line.count >= 4 else { continue }
                    let idxStatus = line[line.startIndex]
                    let wtStatus = line[line.index(after: line.startIndex)]
                    var path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let arrow = path.range(of: " -> ") {
                        path = String(path[arrow.upperBound...])
                    }
                    if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
                        path = String(path.dropFirst().dropLast())
                    }
                    let status: VcsSchema.FileStatus.Status
                    if idxStatus == "?" || idxStatus == "A" || wtStatus == "A" {
                        status = .added
                    } else if idxStatus == "D" || wtStatus == "D" {
                        status = .deleted
                    } else {
                        status = .modified
                    }
                    let counts = numstat[path] ?? (0, 0)
                    results.append(VcsSchema.FileStatus(
                        file: path,
                        additions: SchemaPrimitive.NonNegativeInt(rawValue: counts.additions) ?? .zero,
                        deletions: SchemaPrimitive.NonNegativeInt(rawValue: counts.deletions) ?? .zero,
                        status: status
                    ))
                }
                return results
            },
            diff: { mode, options in
                var args = ["diff", "--no-color", "--no-ext-diff"]
                if let ctx = options?.context {
                    args.append("-U\(ctx)")
                }
                switch mode {
                case .working:
                    args.append("HEAD")
                case .branch:
                    let baseRef: String
                    if let explicit = options?.base {
                        baseRef = explicit
                    } else {
                        baseRef = await detectDefaultBranch() ?? "HEAD"
                    }
                    args.append("\(baseRef)...HEAD")
                case .committed:
                    if let baseRef = options?.base {
                        args.append("\(baseRef)..HEAD")
                    } else {
                        args.append("HEAD~1..HEAD")
                    }
                }
                guard let out = await runGit(args), out.exitCode == 0 else {
                    return []
                }
                let raw = String(decoding: out.stdout, as: UTF8.self)
                let byFile = CoreVcs.Patch.chunksByFile(CoreVcs.Patch.Info(text: raw, truncated: false))
                return byFile.keys.sorted().map { file in
                    let chunk = byFile[file] ?? ""
                    let counts = CoreVcs.Patch.countPatch(chunk)
                    let status: FileDiffSchema.Status = chunk.contains("new file mode")
                        ? .added
                        : chunk.contains("deleted file mode") ? .deleted : .modified
                    return FileDiffSchema.Info(
                        file: file,
                        patch: chunk,
                        additions: SchemaPrimitive.NonNegativeInt(rawValue: counts.additions) ?? .zero,
                        deletions: SchemaPrimitive.NonNegativeInt(rawValue: counts.deletions) ?? .zero,
                        status: status
                    )
                }
            },
            initialize: {
                let out = try await spawner.run(ProcessSpec(
                    executable: gitExe,
                    arguments: ["init"],
                    workingDirectory: projDir
                ))
                guard out.exitCode == 0 else {
                    throw CoreVcs.Vcs.InitializeError(kind: .failed)
                }
            }
        )

        _ = try? await vcsService.transform { editor in
            editor.add(provider)
        }
    }

    // MARK: - 4. MCP Config Seeding

    /// Seeds configured MCP servers from `configService` entries into `mcpService` so `GET /api/mcp`
    /// reports configured MCP servers and their statuses without blocking location boot on network I/O.
    public static func seedConfiguredMcpServers(
        into mcpService: any CoreMCP.Registry.Interface,
        configEntries: [CoreConfigEntry]
    ) async {
        let configured = CoreConfigPlugin.Mcp.register(entries: configEntries)
        guard !configured.isEmpty else { return }
        _ = try? await mcpService.transform { editor in
            for (name, cfg) in configured {
                editor.set(name, config: cfg)
            }
        }
        for (name, cfg) in configured.sorted(by: { $0.key < $1.key }) {
            await mcpService.add(server: name, config: cfg)
            let isDisabled: Bool = switch cfg {
            case .local(let l): l.disabled == true
            case .remote(let r): r.disabled == true
            }
            if isDisabled {
                try? await mcpService.disconnect(server: name)
            }
        }
    }

    // MARK: - 5. Live Streaming OpenCodeAI Wire Protocol Adapter

    public enum WireProtocolKind: String, Equatable, Hashable, Sendable {
        case anthropicMessages = "anthropic-messages"
        case openAIResponses = "openai-responses"
        case openAIChat = "openai-chat"
        case gemini = "gemini"
        case openAICompatibleChat = "openai-compatible-chat"
        case unconfigured = "unconfigured"
    }

    internal struct ResolvedCredential: Sendable {
        enum AuthMode: Sendable {
            case apiKey(String)
            case bearerOAuth(String)
            case none
        }
        let mode: AuthMode
    }

    internal struct LiveRouteConfig: Sendable {
        let protocolKind: WireProtocolKind
        let providerID: String
        let providerMetadataKey: String
        let wireModelID: String
        let baseURL: String
        let credential: ResolvedCredential
        let headers: [String: String]
        let body: [String: JSONValue]
        let settings: [String: JSONValue]
        let compatibility: ModelCompatibilitySchema.Compatibility?
        let missingCredentialMessage: String?
    }

    /// Creates an `AIRequestExecutor.RequestExecutorService` backed directly by `OpenCodePlatform.HTTPTransport`
    /// using true incremental streaming (`httpTransport.stream(...)`).
    public static func makeHTTPExecutor(
        transport: any HTTPTransport
    ) -> AIRequestExecutor.RequestExecutorService {
        AIRequestExecutor.RequestExecutorService { request, middleware in
            let send: @Sendable (HTTPRequest) async throws -> AIRequestExecutor.ExecutorResponse = { req in
                let streamed = try await transport.stream(req)
                return AIRequestExecutor.ExecutorResponse(
                    request: req,
                    head: streamed.head,
                    body: .streaming(streamed.chunks)
                )
            }
            if let middleware {
                return try await middleware(request, send)
            }
            return try await send(request)
        }
    }

    /// Creates the live `AIRoute.Interface` backed by `OpenCodeAI` wire protocols and `httpTransport`.
    public static func makeLLMClient(transport: any HTTPTransport) -> any AIRoute.Interface {
        AIRoute.layer(executor: makeHTTPExecutor(transport: transport))
    }

    internal static func detectProtocolKind(package: String?, providerID: String) -> WireProtocolKind {
        let pkg = (package ?? "").lowercased()
        if pkg.contains("/anthropic") || pkg.hasSuffix("/messages") {
            return .anthropicMessages
        }
        if pkg == "@opencode/ai/providers/google" || pkg.hasSuffix("/gemini") {
            return .gemini
        }
        if pkg == "@opencode/ai/providers/openai"
            || pkg == "@opencode/ai/providers/openai/responses"
            || pkg == "@opencode/ai/providers/openai-compatible/responses"
            || pkg == "@opencode/ai/providers/openai-compatible-responses"
            || pkg.hasSuffix("/responses")
        {
            return .openAIResponses
        }
        if pkg == "@opencode/ai/providers/openai/chat" {
            return .openAIChat
        }
        if pkg.contains("openai-compatible")
            || pkg.contains("openrouter")
            || pkg.contains("groq")
            || pkg.contains("xai")
            || !pkg.isEmpty
        {
            return .openAICompatibleChat
        }
        switch providerID.lowercased() {
        case "anthropic": return .anthropicMessages
        case "openai": return .openAIResponses
        case "google": return .gemini
        default: return .openAICompatibleChat
        }
    }

    internal static func defaultBaseURL(for providerID: String, protocolKind: WireProtocolKind) -> String {
        switch providerID.lowercased() {
        case "anthropic": return AIProtocols.AnthropicMessages.DEFAULT_BASE_URL
        case "openai": return AIProtocols.OpenAIResponses.DEFAULT_BASE_URL
        case "google": return AIProtocols.Gemini.DEFAULT_BASE_URL
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "xai": return "https://api.x.ai/v1"
        case "groq": return "https://api.groq.com/openai/v1"
        case "opencode": return "https://opencode.ai/zen/v1"
        default:
            switch protocolKind {
            case .anthropicMessages: return AIProtocols.AnthropicMessages.DEFAULT_BASE_URL
            case .gemini: return AIProtocols.Gemini.DEFAULT_BASE_URL
            case .openAIResponses, .openAIChat, .openAICompatibleChat, .unconfigured:
                return AIProtocols.OpenAIChat.DEFAULT_BASE_URL
            }
        }
    }

    internal static func makeLiveLanguageModel(config: LiveRouteConfig) -> AISchema.LanguageModel {
        let route = AIRoute.AnyRoute(
            id: config.protocolKind.rawValue,
            provider: AISchema.ProviderID.make(config.providerID),
            providerMetadataKey: config.providerMetadataKey,
            protocolID: config.protocolKind.rawValue,
            baseURL: config.baseURL,
            transportID: "http-json",
            headers: { _ in config.headers },
            options: AISchema.RequestOptions(
                headers: config.headers.isEmpty ? nil : config.headers,
                http: config.body.isEmpty ? nil : AISchema.HttpOptions(body: config.body),
                providerOptions: config.settings.isEmpty ? nil : [config.providerMetadataKey: .object(config.settings)]
            ),
            buildBody: { request in
                let protoReq = convertToProtocolRequest(request, config: config)
                let bodyObj = try buildWireBody(protoReq, config: config)
                return .object(bodyObj)
            },
            executeStream: { request, runtime, options in
                executeLiveWireStream(request: request, config: config, runtime: runtime, options: options)
            }
        )
        return AISchema.LanguageModel.make(AISchema.LanguageModel.Input(
            id: config.wireModelID,
            provider: config.providerID,
            route: route
        ))
    }

    private static func buildWireBody(
        _ protoReq: AIProtocolUtils.LLMRequest,
        config: LiveRouteConfig
    ) throws -> [String: JSONValue] {
        var body: [String: JSONValue]
        switch config.protocolKind {
        case .anthropicMessages:
            body = try AIProtocols.AnthropicMessages.fromRequest(protoReq)
        case .openAIResponses:
            body = try AIProtocols.OpenAIResponses.fromRequest(protoReq)
        case .openAIChat, .openAICompatibleChat:
            body = try AIProtocols.OpenAIChat.fromRequest(protoReq)
        case .gemini:
            body = try AIProtocols.Gemini.fromRequest(protoReq)
        case .unconfigured:
            body = [:]
        }
        if !config.body.isEmpty {
            body = AIProtocolUtils.JSONCodec.mergeObjects(body, config.body)
        }
        if let reqOverlay = protoReq.http?.body {
            body = AIProtocolUtils.JSONCodec.mergeObjects(body, reqOverlay)
        }
        return body
    }

    private static func buildWireHTTPRequest(
        _ protoReq: AIProtocolUtils.LLMRequest,
        config: LiveRouteConfig
    ) throws -> HTTPRequest {
        let body = try buildWireBody(protoReq, config: config)
        let base = config.baseURL.trimmingTrailingSlashes()

        let url: String
        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "text/event-stream",
        ]

        // Apply provider/model/request headers before auth so explicit config headers merge cleanly.
        for (k, v) in config.headers { headers[k.lowercased()] = v }
        if let reqHeaders = protoReq.http?.headers {
            for (k, v) in reqHeaders { headers[k.lowercased()] = v }
        }

        switch config.protocolKind {
        case .anthropicMessages:
            url = "\(base)\(AIProtocols.AnthropicMessages.PATH)"
            headers = AIProtocols.AnthropicMessages.transportHeaders(for: body, existing: headers)
            switch config.credential.mode {
            case .apiKey(let key):
                headers["x-api-key"] = key
            case .bearerOAuth(let token):
                headers["authorization"] = "Bearer \(token)"
            case .none:
                break
            }

        case .openAIResponses:
            url = "\(base)\(AIProtocols.OpenAIResponses.PATH)"
            switch config.credential.mode {
            case .apiKey(let key):
                headers["authorization"] = "Bearer \(key)"
            case .bearerOAuth(let token):
                headers["authorization"] = "Bearer \(token)"
            case .none:
                break
            }

        case .openAIChat, .openAICompatibleChat:
            url = "\(base)\(AIProtocols.OpenAIChat.PATH)"
            switch config.credential.mode {
            case .apiKey(let key):
                headers["authorization"] = "Bearer \(key)"
            case .bearerOAuth(let token):
                headers["authorization"] = "Bearer \(token)"
            case .none:
                break
            }

        case .gemini:
            let encodedModel = AIProtocolUtils.JSONCodec.percentEncodePathComponent(config.wireModelID)
            url = "\(base)/models/\(encodedModel):streamGenerateContent?alt=sse"
            switch config.credential.mode {
            case .apiKey(let key):
                headers["x-goog-api-key"] = key
            case .bearerOAuth(let token):
                headers["authorization"] = "Bearer \(token)"
            case .none:
                break
            }

        case .unconfigured:
            url = base
        }

        var finalURL = url
        if let query = protoReq.http?.query, !query.isEmpty {
            let sep = finalURL.contains("?") ? "&" : "?"
            let qs = query.keys.sorted().map { k in
                "\(AIProtocolUtils.JSONCodec.percentEncodePathComponent(k))=\(AIProtocolUtils.JSONCodec.percentEncodePathComponent(query[k]!))"
            }.joined(separator: "&")
            finalURL += sep + qs
        }

        let bodyText = AIProtocolUtils.JSONCodec.encodeObject(body)
        return HTTPRequest(
            method: "POST",
            url: finalURL,
            headers: headers,
            body: Array(bodyText.utf8)
        )
    }

    private static func executeLiveWireStream(
        request: AISchema.LLMRequest,
        config: LiveRouteConfig,
        runtime: AITransport.TransportRuntime,
        options: AIRoute.StreamOptions?
    ) -> AsyncThrowingStream<AISchema.LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let missingMsg = config.missingCredentialMessage {
                        throw AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(
                            message: missingMsg
                        )))
                    }

                    let protoReq = convertToProtocolRequest(request, config: config)
                    let httpReq: HTTPRequest
                    do {
                        httpReq = try buildWireHTTPRequest(protoReq, config: config)
                    } catch let protoErr as AIProtocolUtils.ProtocolError {
                        throw convertProtocolError(protoErr)
                    }

                    let response: AIRequestExecutor.ExecutorResponse
                    do {
                        response = try await runtime.http.execute(httpReq, middleware: options?.http)
                    } catch let aiErr as AISchema.AIError {
                        throw aiErr
                    } catch {
                        throw AIRequestExecutor.httpError(error: error, request: httpReq, operation: .request)
                    }

                    let httpCtx = AIRequestExecutor.responseHttp(response)
                    if !(200..<300).contains(response.status) {
                        let bodyText = (try? await response.text()) ?? ""
                        throw mapHTTPStatusError(status: response.status, body: bodyText, http: httpCtx, provider: config.providerID)
                    }

                    var sse = AIProtocolUtils.SSEParser()
                    var sawFinish = false

                    switch config.protocolKind {
                    case .anthropicMessages:
                        var state = AIProtocols.AnthropicMessages.ParserState(
                            provider: protoReq.model.provider,
                            providerMetadataKey: protoReq.model.providerMetadataKey ?? protoReq.model.provider
                        )
                        let processFrames: ([AIProtocolUtils.SSEFrame]) throws -> Void = { frames in
                            for frame in frames {
                                if let evName = frame.event, !AIProtocols.AnthropicMessages.sseEvents.contains(evName) {
                                    continue
                                }
                                let trimmed = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty { continue }
                                let decoded = try AIProtocolUtils.ProviderShared.parseJson(
                                    route: AIProtocols.AnthropicMessages.adapterID,
                                    input: trimmed,
                                    message: "Invalid Anthropic Messages SSE JSON"
                                )
                                guard let obj = AIProtocolUtils.JSONCodec.objectValue(decoded) else { continue }
                                let produced = try AIProtocols.AnthropicMessages.step(state: &state, event: obj)
                                for ev in produced {
                                    if ev.isFinish { sawFinish = true }
                                    continuation.yield(convertProtocolEvent(ev))
                                }
                            }
                        }
                        for try await chunk in AIRequestExecutor.responseStream(response) {
                            try Task.checkCancellation()
                            try processFrames(sse.feed(chunk))
                        }
                        try processFrames(sse.finish())

                    case .openAIResponses:
                        var state = AIProtocols.OpenResponses.initial(protoReq, adapter: AIProtocols.OpenAIResponses.adapter)
                        let hostedTools = AIProtocolUtils.ResponsesHostedTools.common
                        let processFrames: ([AIProtocolUtils.SSEFrame]) throws -> Void = { frames in
                            for frame in frames {
                                let trimmed = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty || trimmed == "[DONE]" { continue }
                                let rawObj = try AIProtocols.OpenResponses.decodeChannelEvent(trimmed)
                                let norm = AIProtocols.OpenResponses.normalize(state, input: rawObj)
                                if norm.type == "response.output_item.done", let item = norm.item {
                                    let hostedItem = AIProtocolUtils.ResponsesHostedTools.Item(id: item.id, type: item.type, raw: item.raw)
                                    if AIProtocolUtils.ResponsesHostedTools.isItem(hostedItem, in: hostedTools) {
                                        let (nextLifecycle, emitted) = try AIProtocolUtils.ResponsesHostedTools.onDone(
                                            lifecycle: state.lifecycle,
                                            item: hostedItem,
                                            tools: hostedTools,
                                            providerMetadataKey: state.providerMetadataKey
                                        )
                                        state.lifecycle = nextLifecycle
                                        for ev in emitted {
                                            if ev.isFinish { sawFinish = true }
                                            continuation.yield(convertProtocolEvent(ev))
                                        }
                                        continue
                                    }
                                }
                                let (nextState, produced) = try AIProtocols.OpenResponses.step(state, event: norm)
                                state = nextState
                                for ev in produced {
                                    if ev.isFinish { sawFinish = true }
                                    continuation.yield(convertProtocolEvent(ev))
                                }
                            }
                        }
                        for try await chunk in AIRequestExecutor.responseStream(response) {
                            try Task.checkCancellation()
                            try processFrames(sse.feed(chunk))
                        }
                        try processFrames(sse.finish())

                    case .openAIChat, .openAICompatibleChat:
                        var state = AIProtocols.OpenAIChat.ParserState(request: protoReq)
                        var hitDone = false
                        let processFrames: ([AIProtocolUtils.SSEFrame]) throws -> Void = { frames in
                            for frame in frames {
                                if hitDone { break }
                                let trimmed = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed == "[DONE]" {
                                    hitDone = true
                                    break
                                }
                                if trimmed.isEmpty { continue }
                                let decoded = try AIProtocolUtils.ProviderShared.parseJson(
                                    route: AIProtocols.OpenAIChat.adapterID,
                                    input: trimmed,
                                    message: "Invalid OpenAI Chat SSE JSON"
                                )
                                guard let obj = AIProtocolUtils.JSONCodec.objectValue(decoded) else { continue }
                                let produced = try AIProtocols.OpenAIChat.step(state: &state, event: obj)
                                for ev in produced {
                                    if ev.isFinish { sawFinish = true }
                                    continuation.yield(convertProtocolEvent(ev))
                                }
                            }
                        }
                        for try await chunk in AIRequestExecutor.responseStream(response) {
                            try Task.checkCancellation()
                            try processFrames(sse.feed(chunk))
                            if hitDone { break }
                        }
                        if !hitDone {
                            try processFrames(sse.finish())
                        }
                        if !sawFinish {
                            let finalEvents = try AIProtocols.OpenAIChat.finishEvents(state: state)
                            for ev in finalEvents {
                                if ev.isFinish { sawFinish = true }
                                continuation.yield(convertProtocolEvent(ev))
                            }
                        }

                    case .gemini:
                        var state = AIProtocols.Gemini.ParserState(request: protoReq)
                        let processFrames: ([AIProtocolUtils.SSEFrame]) throws -> Void = { frames in
                            for frame in frames {
                                let trimmed = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty { continue }
                                let decoded = try AIProtocolUtils.ProviderShared.parseJson(
                                    route: AIProtocols.Gemini.adapterID,
                                    input: trimmed,
                                    message: "Invalid Gemini SSE JSON"
                                )
                                guard let obj = AIProtocolUtils.JSONCodec.objectValue(decoded) else { continue }
                                let produced = try AIProtocols.Gemini.step(state: &state, event: obj)
                                for ev in produced {
                                    if ev.isFinish { sawFinish = true }
                                    continuation.yield(convertProtocolEvent(ev))
                                }
                            }
                        }
                        for try await chunk in AIRequestExecutor.responseStream(response) {
                            try Task.checkCancellation()
                            try processFrames(sse.feed(chunk))
                        }
                        try processFrames(sse.finish())
                        if !sawFinish {
                            let finalEvents = AIProtocols.Gemini.finish(state: state)
                            for ev in finalEvents {
                                if ev.isFinish { sawFinish = true }
                                continuation.yield(convertProtocolEvent(ev))
                            }
                        }

                    case .unconfigured:
                        throw AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(
                            message: noAPIKeyHelpMessage(providerID: nil)
                        )))
                    }

                    if !sawFinish {
                        throw AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                            message: "The provider response ended unexpectedly.",
                            http: httpCtx,
                            classification: .incompleteStream,
                            route: "\(config.providerID)/\(config.protocolKind.rawValue)"
                        )))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let aiErr as AISchema.AIError {
                    continuation.finish(throwing: aiErr)
                } catch let protoErr as AIProtocolUtils.ProtocolError {
                    continuation.finish(throwing: convertProtocolError(protoErr))
                } catch {
                    continuation.finish(throwing: AISchema.AIError(reason: .transport(AISchema.TransportError(
                        message: String(describing: error),
                        cause: String(describing: error),
                        transport: .http,
                        operation: .read,
                        url: config.baseURL
                    ))))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func mapHTTPStatusError(
        status: Int,
        body: String,
        http: AISchema.HttpContext,
        provider: String
    ) -> AISchema.AIError {
        let extractedMsg: String = {
            if let decoded = try? AIProtocolUtils.JSONCodec.decode(body),
               case .object(let obj) = decoded
            {
                if case .object(let errObj) = obj["error"],
                   case .string(let msg) = errObj["message"], !msg.isEmpty
                {
                    return msg
                }
                if case .string(let msg) = obj["message"], !msg.isEmpty {
                    return msg
                }
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(400))
            }
            return "Provider \(provider) returned HTTP \(status)"
        }()

        let retryAfterMs = AIRequestExecutor.parseRetryAfterMs(headers: http.headers)
        switch status {
        case 401, 403:
            return AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(
                message: extractedMsg,
                body: body,
                http: http
            )))
        case 429:
            return AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(
                message: extractedMsg,
                body: body,
                http: http,
                retryAfterMs: retryAfterMs,
                rateLimit: AIRequestExecutor.parseRateLimitDetails(headers: http.headers, retryAfter: retryAfterMs)
            )))
        case 400, 404, 422:
            return AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(
                message: extractedMsg,
                body: body,
                http: http
            )))
        default:
            return AISchema.AIError(reason: .providerInternal(AISchema.ProviderInternalError(
                message: extractedMsg,
                body: body,
                http: http,
                retryAfterMs: retryAfterMs
            )))
        }
    }

    private static func convertProtocolError(_ error: AIProtocolUtils.ProtocolError) -> AISchema.AIError {
        switch error.kind {
        case .authentication:
            return AISchema.AIError(reason: .authentication(AISchema.AuthenticationError(message: error.message, body: error.body)))
        case .rateLimit:
            return AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(message: error.message, body: error.body)))
        case .contentPolicy:
            return AISchema.AIError(reason: .contentPolicy(AISchema.ContentPolicyError(message: error.message, body: error.body)))
        case .invalidRequest:
            return AISchema.AIError(reason: .invalidRequest(AISchema.InvalidRequestError(message: error.message, body: error.body)))
        case .unsupportedOperation:
            return AISchema.AIError(reason: .unsupportedOperation(AISchema.UnsupportedOperationError(
                message: error.message,
                operation: error.operation ?? "stream",
                provider: error.provider.map(AISchema.ProviderID.make),
                route: error.route
            )))
        case .providerInternal:
            return AISchema.AIError(reason: .providerInternal(AISchema.ProviderInternalError(message: error.message, body: error.body)))
        case .transport:
            return AISchema.AIError(reason: .transport(AISchema.TransportError(
                message: error.message,
                body: error.body,
                transport: .http,
                operation: .read
            )))
        case .unknownProvider:
            return AISchema.AIError(reason: .unknownProvider(AISchema.UnknownProviderError(message: error.message, body: error.body)))
        case .invalidProviderOutput:
            let classification: AISchema.InvalidProviderOutputError.Classification? =
                (error.classification == "incomplete-stream") ? .incompleteStream : nil
            return AISchema.AIError(reason: .invalidProviderOutput(AISchema.InvalidProviderOutputError(
                message: error.message,
                body: error.body,
                classification: classification,
                route: error.route
            )))
        }
    }

    // MARK: - AISchema <-> AIProtocolUtils Conversion

    private static func convertCacheHint(_ hint: AISchema.CacheHint?) -> AIProtocolUtils.CacheHint? {
        guard let hint else { return nil }
        return AIProtocolUtils.CacheHint(type: hint.type.rawValue, ttl: hint.ttl?.rawValue)
    }

    private static func convertMediaAsset(_ asset: AIMedia.Asset) -> AIProtocolUtils.MediaAsset {
        let source: AIProtocolUtils.MediaSource = switch asset.source {
        case .bytes(let data, _): .bytes(data)
        case .base64(let data, _): .base64(data)
        case .url(let url, _, _): .url(url)
        case .ref(let provider, let id, _): .ref(provider: provider.rawValue, id: id)
        }
        return AIProtocolUtils.MediaAsset(
            source: source,
            mediaType: asset.mediaType,
            providerMetadata: asset.providerMetadata
        )
    }

    private static func convertToolResultValue(_ value: AISchema.ToolResultValue) -> AIProtocolUtils.ToolResultValue {
        switch value {
        case .json(let j):
            return .json(j)
        case .text(let t):
            if case .string(let s) = t {
                return .text(s)
            }
            return .text(AIProtocolUtils.JSONCodec.encode(t))
        case .error(let e):
            return .error(e)
        case .content(let items):
            let converted: [AIProtocolUtils.ToolContentItem] = items.map { item in
                switch item {
                case .text(let t): .text(t.text)
                case .file(let f): .file(AIProtocolUtils.ToolFileContent(uri: f.uri, mime: f.mime, name: f.name))
                }
            }
            return .content(converted)
        }
    }

    private static func convertToolResultPart(_ part: AISchema.ToolResultPart) -> AIProtocolUtils.ToolResultPart {
        AIProtocolUtils.ToolResultPart(
            id: part.id,
            name: part.name,
            namespace: part.namespace,
            result: convertToolResultValue(part.result),
            providerExecuted: part.providerExecuted,
            cache: convertCacheHint(part.cache),
            providerMetadata: part.providerMetadata
        )
    }

    private static func convertToolEntry(_ entry: AISchema.ToolEntry) -> AIProtocolUtils.ToolEntry {
        switch entry {
        case .tool(let def):
            let freeform: AIProtocolUtils.FreeformFormat? = def.freeform.map { ff in
                switch ff {
                case .text: .text
                case .regex(let pattern): .regex(pattern)
                case .lark(let definition): .lark(definition)
                }
            }
            return .tool(AIProtocolUtils.ToolDefinition(
                name: def.name,
                description: def.description,
                inputSchema: def.inputSchema,
                cache: convertCacheHint(def.cache),
                freeform: freeform,
                native: def.native
            ))
        case .namespace(let ns):
            return .namespace(
                name: ns.name,
                description: ns.description,
                tools: ns.tools.map(convertToolEntry)
            )
        }
    }

    private static func convertToProtocolRequest(
        _ request: AISchema.LLMRequest,
        config: LiveRouteConfig
    ) -> AIProtocolUtils.LLMRequest {
        let compat = config.compatibility.map { c in
            AIProtocolUtils.ModelCompatibility(
                reasoningField: c.reasoningField?.rawValue,
                requireReasoning: c.requireReasoning,
                maxTokensField: c.maxTokensField?.rawValue,
                requireFinishReason: c.requireFinishReason,
                requireAssistantAfterTool: c.requireAssistantAfterTool,
                cacheFormat: c.cacheFormat?.rawValue,
                supportsThinkingBlockBinding: c.supportsThinkingBlockBinding,
                mediaInput: c.mediaInput?.rawValue
            )
        }
        let descriptor = AIProtocolUtils.ModelDescriptor(
            id: config.wireModelID,
            provider: config.providerID,
            routeID: config.protocolKind.rawValue,
            providerMetadataKey: config.providerMetadataKey,
            baseURL: config.baseURL,
            sanitizer: config.protocolKind == .gemini ? "gemini" : nil,
            compatibility: compat
        )

        let systemParts = request.system.map {
            AIProtocolUtils.TextPart(text: $0.text, cache: convertCacheHint($0.cache))
        }

        let messages: [AIProtocolUtils.Message] = request.messages.map { msg in
            switch msg {
            case .system(let s):
                let parts: [AIProtocolUtils.ContentPart] = s.content.compactMap { part in
                    switch part {
                    case .text(let t):
                        return .text(AIProtocolUtils.TextPart(text: t.text, cache: convertCacheHint(t.cache), providerMetadata: t.providerMetadata))
                    case .effort:
                        return nil
                    }
                }
                return AIProtocolUtils.Message(
                    role: .system,
                    content: parts
                )
            case .user(let u):
                let parts: [AIProtocolUtils.ContentPart] = u.content.map { part in
                    switch part {
                    case .text(let t):
                        return .text(AIProtocolUtils.TextPart(text: t.text, cache: convertCacheHint(t.cache), providerMetadata: t.providerMetadata))
                    case .media(let m):
                        return .media(AIProtocolUtils.MediaPart(
                            media: convertMediaAsset(m.media),
                            filename: m.filename,
                            cache: convertCacheHint(m.cache),
                            providerMetadata: m.providerMetadata
                        ))
                    }
                }
                return AIProtocolUtils.Message(role: .user, content: parts, providerMetadata: u.providerMetadata)
            case .assistant(let a):
                let parts: [AIProtocolUtils.ContentPart] = a.content.map { part in
                    switch part {
                    case .text(let t):
                        return .text(AIProtocolUtils.TextPart(text: t.text, cache: convertCacheHint(t.cache), providerMetadata: t.providerMetadata))
                    case .reasoning(let r):
                        return .reasoning(AIProtocolUtils.ReasoningPart(text: r.text, encrypted: r.encrypted, providerMetadata: r.providerMetadata))
                    case .toolCall(let tc):
                        return .toolCall(AIProtocolUtils.ToolCallPart(
                            id: tc.id,
                            name: tc.name,
                            namespace: tc.namespace,
                            input: tc.input,
                            providerExecuted: tc.providerExecuted,
                            providerMetadata: tc.providerMetadata
                        ))
                    case .toolResult(let tr):
                        return .toolResult(convertToolResultPart(tr))
                    case .media(let m):
                        return .media(AIProtocolUtils.MediaPart(
                            media: convertMediaAsset(m.media),
                            filename: m.filename,
                            cache: convertCacheHint(m.cache),
                            providerMetadata: m.providerMetadata
                        ))
                    case .compaction(let c):
                        return .compaction(AIProtocolUtils.CompactionPart(
                            provider: c.provider.rawValue,
                            id: c.id,
                            text: c.text,
                            encrypted: c.encrypted
                        ))
                    }
                }
                return AIProtocolUtils.Message(role: .assistant, content: parts, providerMetadata: a.providerMetadata)
            case .tool(let t):
                return AIProtocolUtils.Message(
                    role: .tool,
                    content: t.content.map { .toolResult(convertToolResultPart($0)) }
                )
            }
        }

        let toolChoice: AIProtocolUtils.ToolChoice? = request.toolChoice.map { tc in
            let kind: AIProtocolUtils.ToolChoice.Kind = switch tc.type {
            case .auto: .auto
            case .none: .none
            case .required: .required
            case .tool: .tool
            }
            return AIProtocolUtils.ToolChoice(type: kind, name: tc.name, disableParallelToolUse: tc.disableParallelToolUse)
        }

        let cache: AIProtocolUtils.CacheSetting = switch request.cache {
        case .some(.auto), nil: .auto
        case .some(.none): .none
        case .some(.object(let obj)): .configured(ttl: obj.ttl?.rawValue)
        }

        var mergedProviderOpts = config.settings
        if let reqOpts = request.providerOptions {
            if case .object(let keyed) = reqOpts[config.providerMetadataKey] {
                mergedProviderOpts = AIProtocolUtils.JSONCodec.mergeObjects(mergedProviderOpts, keyed)
            } else {
                mergedProviderOpts = AIProtocolUtils.JSONCodec.mergeObjects(mergedProviderOpts, reqOpts)
            }
        }

        let httpOverlay = AIProtocolUtils.HTTPOverlay(
            headers: request.headers,
            body: request.http?.body,
            query: request.http?.query,
            encoding: request.http?.encoding?.rawValue
        )

        return AIProtocolUtils.LLMRequest(
            model: descriptor,
            system: systemParts,
            messages: messages,
            tools: request.tools.map(convertToolEntry),
            toolChoice: toolChoice,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            frequencyPenalty: request.frequencyPenalty,
            presencePenalty: request.presencePenalty,
            seed: request.seed,
            stop: request.stop,
            cache: cache,
            promptCacheKey: request.promptCacheKey,
            providerOptions: mergedProviderOpts.isEmpty ? nil : mergedProviderOpts,
            http: httpOverlay
        )
    }

    private static func convertFinishReason(_ reason: AIProtocolUtils.FinishReason) -> AISchema.FinishReason {
        switch reason {
        case .stop: .stop
        case .length: .length
        case .toolCalls: .toolCalls
        case .contentFilter: .contentFilter
        case .error: .error
        case .unknown: .unknown
        }
    }

    private static func convertFinishDetails(_ details: AIProtocolUtils.FinishReasonDetails) -> AISchema.FinishReasonDetails {
        AISchema.FinishReasonDetails(
            normalized: convertFinishReason(details.normalized),
            raw: details.raw,
            category: details.category,
            explanation: details.explanation
        )
    }

    private static func convertUsage(_ usage: AIProtocolUtils.Usage?) -> AISchema.Usage? {
        guard let usage else { return nil }
        return AISchema.Usage(
            contextTokens: usage.contextTokens,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            nonCachedInputTokens: usage.nonCachedInputTokens,
            cacheReadInputTokens: usage.cacheReadInputTokens,
            cacheWriteInputTokens: usage.cacheWriteInputTokens,
            reasoningTokens: usage.reasoningTokens,
            totalTokens: usage.totalTokens,
            cost: usage.cost,
            providerMetadata: usage.providerMetadata
        )
    }

    private static func convertProtocolEvent(_ event: AIProtocolUtils.LLMEvent) -> AISchema.LLMEvent {
        switch event {
        case .stepStart(let index):
            return .stepStart(AISchema.StepStart(index: index))
        case .textStart(let id, let meta):
            return .textStart(AISchema.TextStart(id: id, providerMetadata: meta))
        case .textDelta(let id, let text, let meta):
            return .textDelta(AISchema.TextDelta(id: id, text: text, providerMetadata: meta))
        case .textEnd(let id, let text, let meta):
            return .textEnd(AISchema.TextEnd(id: id, text: text, providerMetadata: meta))
        case .reasoningStart(let id, let meta):
            return .reasoningStart(AISchema.ReasoningStart(id: id, providerMetadata: meta))
        case .reasoningDelta(let id, let text, let meta):
            return .reasoningDelta(AISchema.ReasoningDelta(id: id, text: text, providerMetadata: meta))
        case .reasoningEnd(let id, let text, let meta):
            return .reasoningEnd(AISchema.ReasoningEnd(id: id, text: text, providerMetadata: meta))
        case .toolInputStart(let id, let name, let ns, let provExec, let meta):
            return .toolInputStart(AISchema.ToolInputStart(id: id, name: name, namespace: ns, providerExecuted: provExec, providerMetadata: meta))
        case .toolInputDelta(let id, let name, let ns, let text, let partial):
            return .toolInputDelta(AISchema.ToolInputDelta(id: id, name: name, namespace: ns, text: text, input: partial))
        case .toolInputEnd(let id, let name, let ns, let meta):
            return .toolInputEnd(AISchema.ToolInputEnd(id: id, name: name, namespace: ns, providerMetadata: meta))
        case .toolCall(let id, let name, let ns, let input, let provExec, let meta):
            return .toolCall(AISchema.ToolCall(id: id, name: name, namespace: ns, input: input, providerExecuted: provExec, providerMetadata: meta))
        case .toolInputError(let id, let name, let ns, let raw):
            return .toolInputError(AISchema.ToolInputError(id: id, name: name, namespace: ns, raw: raw))
        case .toolResult(let id, let name, let result, let provExec, let meta):
            let converted: AISchema.ToolResultValue = switch result {
            case .text(let s): .text(.string(s))
            case .json(let j): .json(j)
            case .error(let e): .error(e)
            case .content(let items):
                .content(items.map { item in
                    switch item {
                    case .text(let t): .text(ToolSchema.TextContent(text: t))
                    case .file(let f): .file(ToolSchema.FileContent(uri: f.uri, mime: f.mime, name: f.name))
                    }
                })
            }
            return .toolResult(AISchema.ToolResult(id: id, name: name, result: converted, providerExecuted: provExec, providerMetadata: meta))
        case .media(let media, let meta):
            let asset: AIMedia.Asset = switch media.source {
            case .bytes(let b): AIMedia.bytes(b, mediaType: media.mediaType)
            case .base64(let s): AIMedia.base64(s, mediaType: media.mediaType)
            case .url(let u): AIMedia.url(u, mediaType: media.mediaType)
            case .ref(let prov, let id): AIMedia.ref(provider: prov, id: id, mediaType: media.mediaType)
            }
            return .media(AISchema.MediaEvent(media: asset, providerMetadata: meta))
        case .compaction(let provider, let id, let text, let encrypted):
            let content: AISchema.CompactionPart.Content = encrypted.map { .encrypted($0) } ?? .text(text)
            return .compaction(AISchema.CompactionPart(provider: AISchema.ProviderID.make(provider), id: id, content: content))
        case .stepFinish(let index, let reason, let usage, let meta):
            return .stepFinish(AISchema.StepFinish(index: index, reason: convertFinishDetails(reason), usage: convertUsage(usage), providerMetadata: meta))
        case .finish(let reason, let usage, let meta):
            return .finish(AISchema.Finish(reason: convertFinishDetails(reason), usage: convertUsage(usage), providerMetadata: meta))
        }
    }

    // MARK: - 6. Location-Scoped Session Runner Composition

    internal static func noAPIKeyHelpMessage(providerID: String?) -> String {
        if let providerID, !providerID.isEmpty, providerID != "unconfigured" {
            return "No API key is configured for provider \"\(providerID)\". Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or GEMINI_API_KEY, or run `opencode auth` to configure credentials."
        }
        return "No AI provider API key is configured. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or GEMINI_API_KEY, or run `opencode auth` to connect a provider."
    }

    private static func mapNormalizedToolResult(
        _ result: CoreTool.NormalizedResult
    ) -> CoreSessionModelRequest.NormalizedToolResult {
        let mapped: [SessionMessageSchema.ToolContent] = result.content.map { item in
            switch item {
            case .text(let t): .text(t.text)
            case .file(let f): .file(uri: f.uri, mime: f.mime, name: f.name)
            }
        }
        return CoreSessionModelRequest.NormalizedToolResult(content: mapped, metadata: result.metadata)
    }

    internal static func effectivePermissionRuleset(
        agent: AgentSchema.Info?,
        configEntries: [CoreConfigEntry]
    ) -> PermissionSchema.Ruleset {
        var rules = agent?.permissions ?? baseAgentPermissions()
        for entry in configEntries {
            if let perms = entry.info?.permissions {
                rules.append(contentsOf: perms)
            }
        }
        return rules
    }

    /// Resolves credentials for a provider from `integrationService` (SQLite `credential` table + env vars)
    /// and provider config settings (`apiKey`).
    private static func resolveCredential(
        for provider: ProviderSchema.Info,
        integrations: any CoreIntegration.Integration.Interface,
        environment: any EnvironmentProviding
    ) async -> ResolvedCredential? {
        let intID = provider.integrationID ?? IntegrationID(rawValue: provider.id.rawValue)
        if let activeConn = try? await integrations.activeConnection(intID),
           let value = try? await integrations.resolveConnection(activeConn)
        {
            switch value {
            case .key(let k) where !k.key.isEmpty:
                return ResolvedCredential(mode: .apiKey(k.key))
            case .oauth(let o) where !o.access.isEmpty:
                return ResolvedCredential(mode: .bearerOAuth(o.access))
            case .key, .oauth, .external:
                break
            }
        }
        if let apiKeyVal = provider.settings?.extra["apiKey"] {
            switch apiKeyVal {
            case .string(let s) where !s.isEmpty:
                return ResolvedCredential(mode: .apiKey(s))
            case .bool(false):
                return ResolvedCredential(mode: .none)
            default:
                break
            }
        }
        // Fallback check on known env vars if integration was replaced/removed
        if let spec = builtinProviders.first(where: { $0.id == provider.id }) {
            for name in spec.envVars {
                if let val = environment.variable(name), !val.isEmpty {
                    return ResolvedCredential(mode: .apiKey(val))
                }
            }
        }
        if provider.activation == .enabled {
            return ResolvedCredential(mode: .none)
        }
        return nil
    }

    /// Location-scoped `CoreSessionContext.Interface` wrapper that delegates title selection
    /// to the location's real `title` agent definition (including its system prompt & model overrides).
    private final class LiveSessionContext: CoreSessionContext.Interface, Sendable {
        let inner: CoreSessionContext.Service
        let agentService: any CoreAgent.Agent.Interface

        init(inner: CoreSessionContext.Service, agentService: any CoreAgent.Agent.Interface) {
            self.inner = inner
            self.agentService = agentService
        }

        var request: any CoreSessionModelRequest.Interface { inner.request }

        func select(_ sessionID: SessionID) async throws -> CoreSessionContext.Selection {
            try await inner.select(sessionID)
        }

        func load(_ selection: CoreSessionContext.Selection) async throws -> CoreSessionContext.Loaded {
            try await inner.load(selection)
        }

        func resolveModel(
            _ session: SessionSchema.Info,
            kind: CoreSessionRunnerModel.RequestKind,
            agent: String
        ) async throws -> CoreSessionRunnerModel.Resolved {
            try await inner.resolveModel(session, kind: kind, agent: agent)
        }

        func selectTitle(_ session: SessionSchema.Info) async throws -> CoreSessionContext.TitleSelection? {
            let titleID = AgentSchema.ID(rawValue: "title")
            let info = await agentService.get(titleID)
            let systemPrompt = info?.system ?? ServerLiveRuntime.promptTitle
            let modelRef = info?.model.map {
                SessionSchema.ModelRef(
                    id: $0.id.rawValue,
                    providerID: $0.providerID.rawValue,
                    variant: $0.variant?.rawValue
                )
            }
            let titleAgent = CoreSessionModelRequest.AgentProfile(
                id: titleID.rawValue,
                system: systemPrompt,
                maxSteps: info?.steps?.rawValue,
                model: modelRef
            )
            guard let resolved = try? await resolveModel(session, kind: .title, agent: titleAgent.id) else {
                return nil
            }
            let primary = (try? await resolveModel(session, kind: .primary, agent: session.agent ?? "build")) ?? resolved
            return CoreSessionContext.TitleSelection(agent: titleAgent, primary: primary, selected: resolved)
        }
    }

    /// Captures per-step workspace tree snapshots via `CoreSessionSnapshotBridge` and stamps
    /// `{ start, end, files }` onto projected assistant step rows in SQLite so `GET /api/session/:id/diff`
    /// and `POST /api/session/:id/revert/stage|clear|commit` operate on real tracked snapshots.
    internal final class StepSnapshotTracker: Sendable {
        struct PendingStep: Sendable {
            let startSnapshot: String
            let seqBefore: Int64
        }

        private let db: any SQLiteDatabase
        let bridge: any CoreSessionSnapshotBridge
        private let pending = Mutex<[SessionID: PendingStep]>([:])

        init(db: any SQLiteDatabase, bridge: any CoreSessionSnapshotBridge) {
            self.db = db
            self.bridge = bridge
        }

        func beginStep(sessionID: SessionID) async {
            if let previous = pending.withLock({ $0.removeValue(forKey: sessionID) }) {
                await finalizeStep(sessionID: sessionID, step: previous)
            }
            guard let startSnap = try? await bridge.capture() else { return }
            let seqBefore = latestMessageSeq(sessionID: sessionID)
            pending.withLock { $0[sessionID] = PendingStep(startSnapshot: startSnap, seqBefore: seqBefore) }
        }

        func finishSession(sessionID: SessionID) async {
            guard let step = pending.withLock({ $0.removeValue(forKey: sessionID) }) else { return }
            await finalizeStep(sessionID: sessionID, step: step)
        }

        private func finalizeStep(sessionID: SessionID, step: PendingStep) async {
            let endSnap = (try? await bridge.capture()) ?? step.startSnapshot
            let changedFiles: [String]
            if step.startSnapshot == endSnap {
                changedFiles = []
            } else if let liveBridge = bridge as? CoreSessionLiveSnapshotBridge,
                      let relPaths = try? await liveBridge.service.files(CoreSnapshot.CompareInput(
                          from: CoreSnapshot.ID(rawValue: step.startSnapshot),
                          to: CoreSnapshot.ID(rawValue: endSnap)
                      ))
            {
                changedFiles = relPaths.map(\.rawValue)
            } else if let diffs = try? await bridge.diff(from: step.startSnapshot, to: endSnap, paths: nil) {
                changedFiles = diffs.map(\.file)
            } else {
                changedFiles = []
            }

            let rows = (try? db.query(
                """
                SELECT `id`, `data` FROM `session_message`
                WHERE `session_id` = ? AND `type` = 'assistant' AND `seq` > ?
                ORDER BY `seq` ASC
                """,
                parameters: [.text(sessionID.rawValue), .integer(step.seqBefore)]
            )) ?? []

            let snapJSON: JSONValue = .object([
                "start": .string(step.startSnapshot),
                "end": .string(endSnap),
                "files": .array(changedFiles.map { .string($0) }),
            ])

            for row in rows {
                guard let msgID = row.string("id"),
                      let rawData = row.string("data"),
                      let decoded = try? ServerCodec.decode(JSONValue.self, from: rawData),
                      case .object(var dict) = decoded
                else { continue }
                if dict["snapshot"] != nil && dict["snapshot"] != .null {
                    continue
                }
                dict["snapshot"] = snapJSON
                guard let encoded = try? ServerCodec.encodeString(JSONValue.object(dict)) else { continue }
                _ = try? db.execute(
                    "UPDATE `session_message` SET `data` = ? WHERE `id` = ? AND `session_id` = ?",
                    parameters: [.text(encoded), .text(msgID), .text(sessionID.rawValue)]
                )
            }
        }

        private func latestMessageSeq(sessionID: SessionID) -> Int64 {
            (try? db.queryScalar(
                "SELECT coalesce(max(`seq`), 0) FROM `session_message` WHERE `session_id` = ?",
                parameters: [.text(sessionID.rawValue)]
            )?.int64Value) ?? 0
        }
    }

    /// Location-scoped `CoreSessionRunner.Interface` implementation wrapping `CoreSessionRunner.Service`
    /// with live per-step snapshot tracking (`CoreSessionLiveSnapshotBridge`) and live `CoreSessionTitle.Service`.
    public final class LiveSessionRunner: CoreSessionRunner.Interface, Sendable {
        public let inner: CoreSessionRunner.Service
        public let snapshotBridge: (any CoreSessionSnapshotBridge)?
        public let sessionTitle: CoreSessionTitle.Service
        private let snapshotTracker: StepSnapshotTracker?

        public var modelTransport: any CoreSessionModelTransport.Interface {
            inner.modelTransport
        }

        internal init(
            inner: CoreSessionRunner.Service,
            snapshotBridge: (any CoreSessionSnapshotBridge)?,
            sessionTitle: CoreSessionTitle.Service,
            snapshotTracker: StepSnapshotTracker?
        ) {
            self.inner = inner
            self.snapshotBridge = snapshotBridge
            self.sessionTitle = sessionTitle
            self.snapshotTracker = snapshotTracker
        }

        public func drain(_ input: CoreSessionRunner.DrainInput) async throws -> CoreSessionRunner.DrainResult {
            do {
                let result = try await inner.drain(input)
                await snapshotTracker?.finishSession(sessionID: input.sessionID)
                return result
            } catch {
                await snapshotTracker?.finishSession(sessionID: input.sessionID)
                throw error
            }
        }
    }

    /// Builds a location-scoped `LiveSessionRunner` wired to real agents, models,
    /// credentials, built-in tools, live `CoreSessionLiveSnapshotBridge` (when `snapshotService != nil`),
    /// live `CoreSessionTitle.Service`, and streaming `OpenCodeAI` wire protocols.
    public static func makeSessionRunner(
        db: any SQLiteDatabase,
        bus: CoreBus.Service,
        sessionStore: CoreSessionStore.Service,
        sessionInstructions: CoreSessionInstructionEntry.Service,
        agentService: any CoreAgent.Agent.Interface,
        configService: any CoreConfig.Interface,
        integrationService: any CoreIntegration.Integration.Interface,
        providerService: any CoreProvider.Provider.Interface,
        modelService: any CoreModel.Model.Interface,
        toolService: any CoreTool.Interface,
        httpTransport: any HTTPTransport,
        environment: any EnvironmentProviding,
        snapshotService: (any CoreSnapshot.Interface)? = nil,
        isLocationClosed: @escaping @Sendable () -> Bool
    ) -> LiveSessionRunner {
        let llmClient = makeLLMClient(transport: httpTransport)
        let modelTransport = CoreSessionModelTransport.Service()
        let modelRequest = CoreSessionModelRequest.Service(modelTransport: modelTransport)
        let snapshotBridge: (any CoreSessionSnapshotBridge)? = snapshotService.map {
            CoreSessionLiveSnapshotBridge(service: $0)
        }
        let snapshotTracker: StepSnapshotTracker? = snapshotBridge.map {
            StepSnapshotTracker(db: db, bridge: $0)
        }

        let runnerModel = CoreSessionRunnerModel.Service { session, availableFn, kind, agentID in
            let available = try await availableFn()
            let agentInfo = await agentService.get(AgentSchema.ID(rawValue: agentID))

            // Determine requested provider/model/variant in precedence order:
            // 1. Title agent explicit model (for title generation)
            // 2. Session explicit selection
            // 3. Agent explicit model
            // 4. Model service default (config `model` or first credentialed flagship)
            // 5. First available text-capable model
            var targetProviderID: ProviderSchema.ID? = nil
            var targetModelID: ModelSchema.ID? = nil
            var targetVariant: String? = nil

            if kind == .title, let agentModel = agentInfo?.model {
                targetProviderID = agentModel.providerID
                targetModelID = agentModel.id
                targetVariant = agentModel.variant?.rawValue
            } else if let sessionModel = session.model {
                targetProviderID = ProviderSchema.ID(rawValue: sessionModel.providerID)
                targetModelID = ModelSchema.ID(rawValue: sessionModel.id)
                targetVariant = sessionModel.variant
            } else if let agentModel = agentInfo?.model {
                targetProviderID = agentModel.providerID
                targetModelID = agentModel.id
                targetVariant = agentModel.variant?.rawValue
            }

            let chosenModel: ModelSchema.Info?
            if let pid = targetProviderID, let mid = targetModelID {
                if let exact = available.first(where: { $0.providerID == pid && ($0.id == mid || $0.modelID == mid) }) {
                    chosenModel = exact
                } else if let fetched = try? await modelService.get(providerID: pid, modelID: mid) {
                    chosenModel = fetched
                } else {
                    chosenModel = nil
                }
            } else if let defaultInfo = try? await modelService.defaultModel() {
                chosenModel = defaultInfo
            } else {
                chosenModel = available.first(where: CoreModel.Model.supportsText)
            }

            if let modelInfo = chosenModel,
               let providerInfo = await providerService.get(modelInfo.providerID),
               let cred = await resolveCredential(for: providerInfo, integrations: integrationService, environment: environment)
            {
                let effectivePackage = modelInfo.package ?? providerInfo.package
                let protoKind = detectProtocolKind(package: effectivePackage, providerID: providerInfo.id.rawValue)

                let matchedVariant = targetVariant.flatMap { vid in
                    modelInfo.variants.first { $0.id.rawValue == vid }
                }

                var settings = CoreProvider.AISDKNative.mergeOverlay(
                    providerInfo.settings?.extra,
                    modelInfo.settings?.extra
                ) ?? [:]
                if let varExtra = matchedVariant?.settings?.extra {
                    settings = CoreProvider.AISDKNative.mergeOverlay(settings, varExtra) ?? settings
                }

                let configuredBaseURL: String? = {
                    if case .string(let u) = settings["baseURL"], !u.isEmpty { return u }
                    if case .string(let u) = settings["base_url"], !u.isEmpty { return u }
                    return nil
                }()
                let baseURL = configuredBaseURL ?? defaultBaseURL(for: providerInfo.id.rawValue, protocolKind: protoKind)

                // Strip non-wire settings (`baseURL`, `base_url`, `apiKey`, `provider`) before sending providerOptions.
                let wireSettings = settings.filter { key, _ in
                    key != "baseURL" && key != "base_url" && key != "apiKey" && key != "provider"
                }

                var mergedHeaders = CoreProvider.AISDKNative.mergeHeaders(providerInfo.headers, modelInfo.headers) ?? [:]
                if let varHeaders = matchedVariant?.headers {
                    mergedHeaders = CoreProvider.AISDKNative.mergeHeaders(mergedHeaders, varHeaders) ?? mergedHeaders
                }
                var mergedBody = CoreProvider.AISDKNative.mergeOverlay(providerInfo.body, modelInfo.body) ?? [:]
                if let varBody = matchedVariant?.body {
                    mergedBody = CoreProvider.AISDKNative.mergeOverlay(mergedBody, varBody) ?? mergedBody
                }

                let metaKey = providerInfo.canonical?.rawValue ?? providerInfo.id.rawValue
                let routeConfig = LiveRouteConfig(
                    protocolKind: protoKind,
                    providerID: providerInfo.id.rawValue,
                    providerMetadataKey: metaKey,
                    wireModelID: modelInfo.modelID.rawValue,
                    baseURL: baseURL,
                    credential: cred,
                    headers: mergedHeaders,
                    body: mergedBody,
                    settings: wireSettings,
                    compatibility: modelInfo.compatibility,
                    missingCredentialMessage: nil
                )
                let langModel = makeLiveLanguageModel(config: routeConfig)
                return CoreSessionRunnerModel.Resolved(
                    model: langModel,
                    ref: SessionSchema.ModelRef(
                        id: modelInfo.id.rawValue,
                        providerID: modelInfo.providerID.rawValue,
                        variant: targetVariant
                    ),
                    capabilities: modelInfo.capabilities,
                    cost: modelInfo.cost,
                    limit: modelInfo.limit,
                    compaction: modelInfo.settings?.compaction ?? providerInfo.settings?.compaction
                )
            }

            // No configured model or API key is available.
            // For background/secondary tasks (title, compaction, generate), fail fast via ModelNotSelectedError.
            guard kind == .primary else {
                throw CoreSessionRunnerModel.ModelNotSelectedError(sessionID: session.id)
            }

            // For primary user prompts, return an unconfigured sentinel model so CoreSessionStep
            // emits a durable assistant error step (`session.step.failed`) with clear setup instructions
            // (after the user's message has already been delivered to SQLite) without touching HTTP.
            let missingProvider = targetProviderID?.rawValue ?? "unconfigured"
            let missingModelID = targetModelID?.rawValue ?? "unconfigured"
            let helpMsg = noAPIKeyHelpMessage(providerID: targetProviderID?.rawValue)
            let sentinelConfig = LiveRouteConfig(
                protocolKind: .unconfigured,
                providerID: missingProvider,
                providerMetadataKey: missingProvider,
                wireModelID: missingModelID,
                baseURL: "https://unconfigured.opencode.local",
                credential: ResolvedCredential(mode: .none),
                headers: [:],
                body: [:],
                settings: [:],
                compatibility: nil,
                missingCredentialMessage: helpMsg
            )
            return CoreSessionRunnerModel.Resolved(
                model: makeLiveLanguageModel(config: sentinelConfig),
                ref: SessionSchema.ModelRef(id: missingModelID, providerID: missingProvider, variant: targetVariant),
                capabilities: ModelSchema.Capabilities.default()
            )
        }

        let sessionContext = CoreSessionContext.Service(
            db: db,
            store: sessionStore,
            models: runnerModel,
            request: modelRequest,
            entries: sessionInstructions,
            selectAgent: { session in
                let requestedID = session.agent.map(AgentSchema.ID.init(rawValue:))
                let selection = await agentService.select(requestedID)
                let info = selection.info
                let systemPrompt: String? = {
                    guard let info else { return nil }
                    if info.id.rawValue == "plan", let reminder = info.system, !reminder.isEmpty {
                        return reminder
                    }
                    return info.system
                }()
                let modelRef = info?.model.map {
                    SessionSchema.ModelRef(id: $0.id.rawValue, providerID: $0.providerID.rawValue, variant: $0.variant?.rawValue)
                }
                return CoreSessionModelRequest.AgentProfile(
                    id: selection.id.rawValue,
                    system: systemPrompt,
                    maxSteps: info?.steps?.rawValue,
                    model: modelRef
                )
            },
            selectTools: { session, agentProfile in
                await snapshotTracker?.beginStep(sessionID: session.id)
                let agentInfo = await agentService.get(AgentSchema.ID(rawValue: agentProfile.id))
                let ruleset = effectivePermissionRuleset(
                    agent: agentInfo,
                    configEntries: await configService.entries()
                )
                let snap = await toolService.snapshot(permissions: ruleset)
                let entries: [AISchema.ToolEntry] = snap.definitions.map { .tool($0) }
                return CoreSessionModelRequest.ToolSnapshot(
                    definitions: entries,
                    execute: { toolInput in
                        do {
                            let normalized = try await snap.execute(CoreTool.ExecuteCallInput(
                                sessionID: toolInput.sessionID,
                                agent: AgentSchema.ID(rawValue: toolInput.agent),
                                messageID: toolInput.messageID.rawValue,
                                callID: ToolSchema.CallID(rawValue: toolInput.call.id),
                                name: toolInput.call.name,
                                input: toolInput.call.input,
                                progress: { meta in await toolInput.progress(meta) },
                                cancel: toolInput.cancel
                            ))
                            return mapNormalizedToolResult(normalized)
                        } catch let failure as AISchema.ToolFailure {
                            throw ToolSchema.ToolError(message: failure.message)
                        }
                    }
                )
            },
            availableModels: {
                (try? await modelService.available(types: nil)) ?? []
            }
        )

        let liveContext = LiveSessionContext(inner: sessionContext, agentService: agentService)
        let sessionTitle = CoreSessionTitle.Service(
            db: db,
            bus: bus,
            store: sessionStore,
            context: liveContext,
            llm: llmClient
        )

        let innerRunner = CoreSessionRunner.Service(
            db: db,
            bus: bus,
            store: sessionStore,
            context: liveContext,
            modelTransport: modelTransport,
            llm: llmClient,
            compaction: nil,
            title: sessionTitle,
            isLocationClosed: isLocationClosed
        )
        return LiveSessionRunner(
            inner: innerRunner,
            snapshotBridge: snapshotBridge,
            sessionTitle: sessionTitle,
            snapshotTracker: snapshotTracker
        )
    }

    /// Process-global `CoreSessionExecution.Interface` adapter backed by `CoreSessionExecution.Service`.
    ///
    /// Preserves non-blocking background execution for all sessions when any model/provider is configured.
    /// When no provider credentials or models are configured for the session's location, awaits the fast
    /// local no-credential settlement (`session.inbox.delivered` + `session.step.failed`) so unconfigured
    /// sessions settle deterministically without racing idle checks.
    public final class LiveSessionExecution: CoreSessionExecution.Interface, Sendable {
        public let inner: CoreSessionExecution.Service
        private let store: CoreSessionStore.Service
        private let locationsProvider: @Sendable () -> CoreLocation.ServiceMap.Service?

        public init(
            inner: CoreSessionExecution.Service,
            store: CoreSessionStore.Service,
            locations: CoreLocation.ServiceMap.Service
        ) {
            self.inner = inner
            self.store = store
            self.locationsProvider = { locations }
        }

        internal init(
            inner: CoreSessionExecution.Service,
            store: CoreSessionStore.Service,
            locationsProvider: @escaping @Sendable () -> CoreLocation.ServiceMap.Service?
        ) {
            self.inner = inner
            self.store = store
            self.locationsProvider = locationsProvider
        }

        public func active() async -> Set<SessionID> {
            await inner.active()
        }

        public func isActive(_ sessionID: SessionID) async -> Bool {
            await inner.isActive(sessionID)
        }

        public func resume(_ sessionID: SessionID) async throws {
            try await inner.resume(sessionID)
        }

        public func wake(_ sessionID: SessionID) async {
            let hasAvailableModel: Bool = await {
                guard let locations = locationsProvider(),
                      let session = try? store.get(sessionID)
                else { return false }
                let locRef = LocationSchema.Ref(
                    directory: SchemaPrimitive.AbsolutePath(rawValue: session.location.directory),
                    workspaceID: session.location.workspaceID
                )
                let canonical = CoreLocation.ServiceMap.canonical(locRef)
                guard let out = try? await locations.get(canonical),
                      let bundle = ServerLocationBundle.from(out)
                else {
                    return false
                }
                let models = (try? await bundle.model.available(types: nil)) ?? []
                return !models.isEmpty
            }()

            await inner.wake(sessionID)
            if !hasAvailableModel {
                await inner.awaitIdle(sessionID)
            }
        }

        public func interrupt(_ sessionID: SessionID, resume: Bool = false) async -> Bool {
            await inner.interrupt(sessionID, resume: resume)
        }

        public func shutdownInterrupt(_ sessionID: SessionID) async -> Bool {
            await inner.shutdownInterrupt(sessionID)
        }

        public func awaitIdle(_ sessionID: SessionID) async {
            await inner.awaitIdle(sessionID)
        }
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var result = self
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
