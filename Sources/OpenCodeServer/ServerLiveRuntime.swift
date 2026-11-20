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
            name: "OpenCode Console",
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
            envVars: ["COPILOT_GITHUB_TOKEN", "GITHUB_TOKEN"],
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
            id: ProviderSchema.ID(rawValue: "poe"),
            name: "Poe",
            envVars: ["POE_API_KEY"],
            package: "@opencode/ai/providers/openai-compatible",
            baseURL: "https://api.poe.com/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "claude-sonnet-4.6",
                    providerID: ProviderSchema.ID(rawValue: "poe"),
                    name: "Claude Sonnet 4.6 (Poe)",
                    family: "claude-sonnet",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 200_000,
                    output: 64_000,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2026, 2, 17)
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "digitalocean"),
            name: "DigitalOcean",
            envVars: ["DIGITALOCEAN_API_KEY"],
            package: "@opencode/ai/providers/openai-compatible",
            baseURL: "https://inference.do-ai.run/v1",
            compatibility: nil,
            models: [
                makeModel(
                    id: "llama3.3-instruct-70b",
                    providerID: ProviderSchema.ID(rawValue: "digitalocean"),
                    name: "Llama 3.3 Instruct 70B",
                    family: "llama",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 128_000,
                    output: 8_192,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2025, 1, 1),
                    inputModalities: ["text"]
                ),
            ]
        ),
        BuiltinProviderSpec(
            id: ProviderSchema.ID(rawValue: "gitlab"),
            name: "GitLab Duo",
            envVars: ["GITLAB_TOKEN"],
            package: "@opencode/ai/providers/openai-compatible",
            baseURL: "https://gitlab.com/api/v4/ai/llm/proxy",
            compatibility: nil,
            models: [
                makeModel(
                    id: "duo-chat",
                    providerID: ProviderSchema.ID(rawValue: "gitlab"),
                    name: "GitLab Duo Chat",
                    family: "duo",
                    package: "@opencode/ai/providers/openai-compatible",
                    context: 200_000,
                    output: 16_384,
                    inputCost: 0,
                    outputCost: 0,
                    released: (2025, 6, 1)
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

    /// Registrations returned by `seedProvidersAndModels` so custom background plugin tests can dispose them cleanly.
    public struct ProviderSeedRegistrations: Sendable {
        public let integrations: CoreState.Registration
        public let providers: CoreState.Registration
        public let models: CoreState.Registration

        public func dispose() async {
            await integrations.dispose()
            await providers.dispose()
            await models.dispose()
        }
    }

    private final class TimeoutRace<T: Sendable>: Sendable {
        private struct Inner: Sendable {
            var settled = false
            var continuation: CheckedContinuation<T?, Never>?
            var workTask: Task<Void, Never>?
            var timerTask: Task<Void, Never>?
        }
        private let box = Mutex(Inner())

        func finish(_ value: T?) {
            let (cont, work, timer) = box.withLock { inner -> (CheckedContinuation<T?, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
                guard !inner.settled else { return (nil, nil, nil) }
                inner.settled = true
                let c = inner.continuation
                let w = inner.workTask
                let t = inner.timerTask
                inner.continuation = nil
                inner.workTask = nil
                inner.timerTask = nil
                return (c, w, t)
            }
            work?.cancel()
            timer?.cancel()
            cont?.resume(returning: value)
        }

        func start(
            continuation: CheckedContinuation<T?, Never>,
            milliseconds: Int64,
            operation: @escaping @Sendable () async throws -> T
        ) {
            let alreadySettled = box.withLock { inner -> Bool in
                if inner.settled { return true }
                inner.continuation = continuation
                return false
            }
            if alreadySettled {
                continuation.resume(returning: nil)
                return
            }
            let work = Task {
                let result = try? await operation()
                self.finish(result)
            }
            let timer = Task {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                self.finish(nil)
            }
            let shouldCancel = box.withLock { inner -> Bool in
                if inner.settled { return true }
                inner.workTask = work
                inner.timerTask = timer
                return false
            }
            if shouldCancel {
                work.cancel()
                timer.cancel()
            }
        }
    }

    /// Runs `operation` with a hard millisecond deadline, returning `nil` immediately on expiry
    /// and cancelling the underlying operation task.
    internal static func withHTTPTimeout<T: Sendable>(
        milliseconds: Int64,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let race = TimeoutRace<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation: continuation, milliseconds: milliseconds, operation: operation)
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    // MARK: - 2a. Live & Cached ModelsDev Catalog

    public static let modelsDevCatalogKVKey = "models-dev:v2:catalog"
    public static let modelsDevMetaKVKey = "models-dev:v2:catalog:meta"
    private static let modelsDevStaleMs: Int64 = 3_600_000

    private static let decodedDiskCache = Mutex<[String: [CoreModel.ModelsDev.Snapshot]]>([:])
    private static let decodedTextCache = Mutex<[String: [CoreModel.ModelsDev.Snapshot]]>([:])
    private static let decodeLocks = CoreSubsystems.Effect.KeyedMutex<String>()

    private static func decodeAndFilterCached(text: String) -> [CoreModel.ModelsDev.Snapshot] {
        let key = "\(text.utf8.count):\(CoreModel.ModelsDev.bodyDigest(text))"
        if let hit = decodedTextCache.withLock({ $0[key] }) {
            return hit
        }
        guard let decoded = try? CoreModel.ModelsDev.decodeSnapshot(text), !decoded.isEmpty else {
            return []
        }
        let filtered = filterModelsDevSnapshots(decoded)
        decodedTextCache.withLock { cache in
            if cache.count > 16 { cache.removeAll() }
            cache[key] = filtered
        }
        return filtered
    }

    private static func decodeDiskCacheFile(
        at cachePath: String,
        fileSystem: any OpenCodeFileSystem
    ) async -> [CoreModel.ModelsDev.Snapshot] {
        guard await fileSystem.exists(at: cachePath) else { return [] }
        // Fast stat-keyed memoization for real disk files (avoids re-reading & re-decoding an 11MB+ models.json across locations)
        if !(fileSystem is InMemoryFileSystem),
           let st = try? await fileSystem.stat(at: cachePath),
           st.type == .file
        {
            let statKey = "\(cachePath)|\(st.size)|\(st.modifiedAtMs)"
            if let hit = decodedDiskCache.withLock({ $0[statKey] }) {
                return hit
            }
            return await decodeLocks.withLock(statKey) {
                if let hit = decodedDiskCache.withLock({ $0[statKey] }) {
                    return hit
                }
                guard let bytes = try? await fileSystem.readFile(at: cachePath) else { return [] }
                let text = String(decoding: bytes, as: UTF8.self)
                let filtered = decodeAndFilterCached(text: text)
                if !filtered.isEmpty {
                    decodedDiskCache.withLock { cache in
                        if cache.count > 16 { cache.removeAll() }
                        cache[statKey] = filtered
                    }
                }
                return filtered
            }
        }
        guard let bytes = try? await fileSystem.readFile(at: cachePath) else { return [] }
        return decodeAndFilterCached(text: String(decoding: bytes, as: UTF8.self))
    }

    private static func filterModelsDevSnapshots(
        _ decoded: [CoreModel.ModelsDev.Snapshot]
    ) -> [CoreModel.ModelsDev.Snapshot] {
        decoded.compactMap { snap -> CoreModel.ModelsDev.Snapshot? in
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

    private static func modelsDevCacheFilePath(
        globalPaths: Global.Interface?,
        options: CoreModel.ModelsDev.Options?
    ) -> String? {
        if let explicit = options?.file, !explicit.isEmpty {
            return explicit
        }
        guard let globalPaths else { return nil }
        return "\(globalPaths.cache.trimmingTrailingSlashes())/models.json"
    }

    private static func extractKVCatalogText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            return text.isEmpty ? nil : text
        case .object(let obj):
            if let body = obj["body"] {
                switch body {
                case .string(let text):
                    return text.isEmpty ? nil : text
                case .object:
                    return (try? JSONEncoder().encode(body)).map { String(decoding: $0, as: UTF8.self) }
                default:
                    return nil
                }
            }
            return (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
        default:
            return nil
        }
    }

    private static func extractEpochMs(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }

    /// Returns `true` when the ModelsDev catalog cache is absent or older than 1 hour.
    public static func isModelsDevCacheColdOrStale(
        kv: CoreKV.Service,
        globalPaths: Global.Interface?,
        fileSystem: any OpenCodeFileSystem,
        options: CoreModel.ModelsDev.Options?
    ) async -> Bool {
        let now = Flock.currentEpochMs()
        var updatedAt: Int64? = nil
        if let meta = try? await kv.get(modelsDevMetaKVKey),
           case .object(let obj) = meta
        {
            updatedAt = extractEpochMs(obj["updatedAt"])
        }
        let kvRaw = try? await kv.get(modelsDevCatalogKVKey)
        if updatedAt == nil, case .object(let obj) = kvRaw {
            updatedAt = extractEpochMs(obj["updatedAt"])
        }
        if let updatedAt {
            if now - updatedAt >= modelsDevStaleMs {
                return true
            }
            let hasKV = kvRaw.flatMap(extractKVCatalogText) != nil
            let cacheFile = modelsDevCacheFilePath(globalPaths: globalPaths, options: options)
            let hasDisk = if let cacheFile { await fileSystem.exists(at: cacheFile) } else { false }
            return !(hasKV || hasDisk)
        }
        // When KV meta has not been written yet (e.g., fresh :memory: DB with warm disk cache),
        // honor the on-disk `<cache>/models.json` modification time so fresh caches avoid redundant fetches.
        if !(fileSystem is InMemoryFileSystem),
           let cacheFile = modelsDevCacheFilePath(globalPaths: globalPaths, options: options),
           let st = try? await fileSystem.stat(at: cacheFile),
           st.type == .file, st.size > 2,
           st.modifiedAtMs > 0,
           now - st.modifiedAtMs < modelsDevStaleMs
        {
            return false
        }
        return true
    }

    /// Fetches the live ModelsDev v2 catalog (falling back to models.dev v1 on failure), persists it
    /// to KV (`models-dev:v2:catalog` + `:meta` in upstream envelope format) and disk (`<cache>/models.json`),
    /// refreshes `modelsDev`, and returns `true` if catalog content changed.
    @discardableResult
    public static func refreshModelsDevCatalog(
        modelsDev: CoreModel.ModelsDev.Service?,
        kv: CoreKV.Service?,
        fileSystem: (any OpenCodeFileSystem)?,
        httpTransport: (any HTTPTransport)?,
        globalPaths: Global.Interface?,
        options: CoreModel.ModelsDev.Options?
    ) async -> Bool {
        guard let httpTransport else { return false }
        let source = (options?.url ?? "https://models.opencode.ai").trimmingTrailingSlashes()
        let primaryURL = "\(source)\(CoreModel.ModelsDev.catalogPath)"
        let fallbackURL = source == "https://models.opencode.ai"
            ? "https://models.dev/api.json"
            : "\(source)/api.json"

        var fetchedText: String? = nil
        for candidateURL in [primaryURL, fallbackURL] {
            let response = await withHTTPTimeout(milliseconds: 10_000) {
                try await httpTransport.send(HTTPRequest(
                    method: "GET",
                    url: candidateURL,
                    headers: [
                        "accept": "application/json",
                        "user-agent": "opencode/2.3.2",
                    ]
                ))
            }
            guard let response, (200..<300).contains(response.head.statusCode) else {
                continue
            }
            let text = String(decoding: response.body, as: UTF8.self)
            let parsed = decodeAndFilterCached(text: text)
            if !parsed.isEmpty {
                fetchedText = text
                break
            }
        }
        guard let text = fetchedText else {
            return false
        }
        let digest = CoreModel.ModelsDev.bodyDigest(text)
        let now = Flock.currentEpochMs()
        var previousDigest: String? = nil
        if let kv, let meta = try? await kv.get(modelsDevMetaKVKey),
           case .object(let obj) = meta, case .string(let d) = obj["digest"]
        {
            previousDigest = d
        } else if let kv, let existing = try? await kv.get(modelsDevCatalogKVKey),
                  case .object(let obj) = existing, case .string(let d) = obj["digest"]
        {
            previousDigest = d
        }
        if let kv {
            // Write upstream's exact `{ updatedAt, digest, body }` envelope so real ~/.local/share/opencode/opencode.db stays 100% compatible.
            try? await kv.set(modelsDevCatalogKVKey, value: .object([
                "updatedAt": .int(now),
                "digest": .string(digest),
                "body": .string(text),
            ]))
            try? await kv.set(modelsDevMetaKVKey, value: .object([
                "updatedAt": .int(now),
                "digest": .string(digest),
            ]))
        }
        if let fileSystem, let cachePath = modelsDevCacheFilePath(globalPaths: globalPaths, options: options) {
            try? await fileSystem.writeFile(Array(text.utf8), to: cachePath, createDirectories: true)
            if let modelsDev {
                _ = try? await modelsDev.get()
            }
        }
        return previousDigest != digest
    }

    private static func loadModelsDevSnapshots(
        modelsDev: CoreModel.ModelsDev.Service?,
        kv: CoreKV.Service?,
        globalPaths: Global.Interface?,
        fileSystem: (any OpenCodeFileSystem)?,
        httpTransport: (any HTTPTransport)?,
        options: CoreModel.ModelsDev.Options?,
        allowLiveNetwork: Bool,
        syncFetchOnColdCache: Bool,
        forceRefresh: Bool
    ) async -> [CoreModel.ModelsDev.Snapshot] {
        // 1. If forceRefresh requested and network is allowed, fetch live first so KV & disk cache update.
        if forceRefresh && allowLiveNetwork {
            _ = await refreshModelsDevCatalog(
                modelsDev: modelsDev,
                kv: kv,
                fileSystem: fileSystem,
                httpTransport: httpTransport,
                globalPaths: globalPaths,
                options: options
            )
        }

        // 2. Check KV cache (`models-dev:v2:catalog` — supports both upstream `{ updatedAt, digest, body }` envelope and legacy string)
        if let kv, let raw = try? await kv.get(modelsDevCatalogKVKey),
           let text = extractKVCatalogText(raw)
        {
            let decoded = decodeAndFilterCached(text: text)
            if !decoded.isEmpty { return decoded }
        }

        // 3. Check disk cache (`<globalPaths.cache>/models.json` or `options.file`)
        if let fileSystem, let cachePath = modelsDevCacheFilePath(globalPaths: globalPaths, options: options) {
            let decoded = await decodeDiskCacheFile(at: cachePath, fileSystem: fileSystem)
            if !decoded.isEmpty { return decoded }
        }

        // 4. Explicit synchronous fetch requested on cold cache (`options.models?.fetch == true`): fetch live now
        if allowLiveNetwork && syncFetchOnColdCache {
            _ = await refreshModelsDevCatalog(
                modelsDev: modelsDev,
                kv: kv,
                fileSystem: fileSystem,
                httpTransport: httpTransport,
                globalPaths: globalPaths,
                options: options
            )
            if let kv, let raw = try? await kv.get(modelsDevCatalogKVKey),
               let text = extractKVCatalogText(raw)
            {
                let decoded = decodeAndFilterCached(text: text)
                if !decoded.isEmpty { return decoded }
            }
        }

        return []
    }

    // MARK: - 2b. OpenCode Console Live Sync (`opencode.ts`)

    private struct ConsoleSyncResult: Sendable {
        let document: CoreConfigIntegration.Document
        let instructions: [(id: String, content: String)]
        let skills: [(skill: SkillSchema.Info, files: [String: String])]
    }

    private struct ConsoleInstructionsResponse: Decodable {
        struct Item: Decodable { let id: String; let content: String }
        let instructions: [Item]
    }

    private struct ConsoleSkillsResponse: Decodable {
        struct Item: Decodable { let slug: String; let version: String }
        let skills: [Item]
    }

    private struct ConsoleSkillBundleResponse: Decodable {
        struct FileItem: Decodable { let path: String; let content: String }
        let slug: String
        let files: [FileItem]
    }

    private struct ConsoleErrorTag: Decodable {
        let _tag: String?
        let orgId: String?
        let connectionId: String?
    }

    private static func fetchConsoleSync(
        connection: CoreIntegration.Connection.Info,
        credentialValue: CredentialSchema.Value,
        credentialID: CredentialSchema.ID?,
        integrationService: any CoreIntegration.Integration.Interface,
        httpTransport: any HTTPTransport,
        oauthManager: ServerLiveOAuthManager?,
        userAgent: String
    ) async -> ConsoleSyncResult? {
        var effectiveValue = credentialValue
        if case .oauth(let oauth) = effectiveValue, let credentialID, let oauthManager {
            let nowMs = Flock.currentEpochMs()
            if oauth.expires.rawValue > 0 && Int64(oauth.expires.rawValue) <= nowMs + 60_000 {
                if let refreshed = try? await oauthManager.refreshToken(
                    credentialID: credentialID,
                    integrationID: IntegrationID(rawValue: "opencode")
                ) {
                    effectiveValue = .oauth(refreshed)
                }
            }
        }

        let opencodeID = IntegrationID(rawValue: "opencode")
        let server = CoreProvider.ConsoleAccess.server(effectiveValue).trimmingTrailingSlashes()
        var mutableHeaders = CoreProvider.ConsoleAccess.headers(effectiveValue)
        mutableHeaders["accept"] = "application/json"
        mutableHeaders["user-agent"] = userAgent
        let headers = mutableHeaders

        let response = await withHTTPTimeout(milliseconds: 5_000) {
            try await httpTransport.send(HTTPRequest(
                method: "GET",
                url: "\(server)/api/v2/config",
                headers: headers
            ))
        }
        guard let response else { return nil }

        if response.head.statusCode == 404 {
            await integrationService.setConnectionStatus(integrationID: opencodeID, connection: connection, status: nil)
            return nil
        }
        if response.head.statusCode == 401 {
            if let tagged = try? ServerCodec.decode(ConsoleErrorTag.self, from: response.body),
               tagged._tag == "Unauthorized"
            {
                await integrationService.setConnectionStatus(
                    integrationID: opencodeID,
                    connection: connection,
                    status: CoreIntegration.Connection.Status(
                        status: .needsAuth,
                        message: "Reconnect OpenCode Console to continue"
                    )
                )
            }
            return nil
        }
        if response.head.statusCode == 403 {
            if let tagged = try? ServerCodec.decode(ConsoleErrorTag.self, from: response.body),
               tagged._tag == "SsoRequired", let connID = tagged.connectionId
            {
                let orgName: String? = {
                    switch effectiveValue {
                    case .oauth(let o): if case .string(let s) = o.metadata?["orgName"] { return s }
                    case .key(let k): if case .string(let s) = k.metadata?["orgName"] { return s }
                    case .external: break
                    }
                    return nil
                }()
                let ssoURL = "\(server)/auth/sso/\(ServerParsedURL.encodeURIComponent(connID))/start?redirectTo=%2F"
                await integrationService.setConnectionStatus(
                    integrationID: opencodeID,
                    connection: connection,
                    status: CoreIntegration.Connection.Status(
                        status: .needsAuth,
                        message: "Sign in with SSO again to use \(orgName ?? "your OpenCode Console organization")",
                        url: ssoURL
                    )
                )
            }
            return nil
        }
        guard (200..<300).contains(response.head.statusCode),
              let remote = try? ServerCodec.decode(CoreConfigIntegration.Remote.self, from: response.body)
        else {
            return nil
        }

        await integrationService.setConnectionStatus(integrationID: opencodeID, connection: connection, status: nil)

        let orgName: String? = {
            switch effectiveValue {
            case .oauth(let o): if case .string(let s) = o.metadata?["orgName"] { return s }
            case .key(let k): if case .string(let s) = k.metadata?["orgName"] { return s }
            case .external: break
            }
            return nil
        }()

        let document = CoreConfigIntegration.make(CoreConfigIntegration.MakeInput(
            integrationID: opencodeID,
            connection: connection,
            organization: orgName,
            info: remote
        ))

        var instructions: [(id: String, content: String)] = []
        var skills: [(skill: SkillSchema.Info, files: [String: String])] = []

        if ServerHeaders.value(in: response.head.headers, for: "x-opencode-instructions-skills") != nil {
            if let instrResp = await withHTTPTimeout(milliseconds: 5_000, operation: {
                try await httpTransport.send(HTTPRequest(method: "GET", url: "\(server)/api/v2/instructions", headers: headers))
            }), (200..<300).contains(instrResp.head.statusCode),
               let parsed = try? ServerCodec.decode(ConsoleInstructionsResponse.self, from: instrResp.body)
            {
                instructions = parsed.instructions.map { ($0.id, $0.content) }
            }

            if let skillsResp = await withHTTPTimeout(milliseconds: 5_000, operation: {
                try await httpTransport.send(HTTPRequest(method: "GET", url: "\(server)/api/v2/skills", headers: headers))
            }), (200..<300).contains(skillsResp.head.statusCode),
               let listed = try? ServerCodec.decode(ConsoleSkillsResponse.self, from: skillsResp.body)
            {
                for item in listed.skills {
                    let slug = item.slug
                    guard !slug.isEmpty, !slug.contains(".."), !slug.contains("/") else { continue }
                    let encodedSlug = ServerParsedURL.encodeURIComponent(slug)
                    guard let bundleResp = await withHTTPTimeout(milliseconds: 5_000, operation: {
                        try await httpTransport.send(HTTPRequest(
                            method: "GET",
                            url: "\(server)/api/v2/skills/\(encodedSlug)",
                            headers: headers
                        ))
                    }), (200..<300).contains(bundleResp.head.statusCode),
                          let bundle = try? ServerCodec.decode(ConsoleSkillBundleResponse.self, from: bundleResp.body),
                          let main = bundle.files.first(where: { $0.path == "SKILL.md" }),
                          case .parsed(let parsedSkill) = CoreConfigPlugin.SkillFile.parse(
                              directory: "/\(slug)",
                              filepath: "/\(slug)/SKILL.md",
                              content: main.content
                          )
                    else { continue }
                    var siblings: [String: String] = [:]
                    for file in bundle.files where file.path != "SKILL.md" {
                        siblings[file.path] = file.content
                    }
                    skills.append((skill: parsedSkill, files: siblings))
                }
            }
        }

        return ConsoleSyncResult(document: document, instructions: instructions, skills: skills)
    }

    // MARK: - 2c. Live ChatGPT / Codex Model Discovery (`chatgpt.ts`)

    private struct CodexModelsResponse: Decodable {
        struct ReasoningLevel: Decodable {
            let effort: String
        }
        struct RemoteModel: Decodable {
            let slug: String
            let display_name: String?
            let visibility: String?
            let supported_in_api: Bool?
            let context_window: Int?
            let max_output_tokens: Int?
            let input_modalities: [String]?
            let supported_reasoning_levels: [ReasoningLevel]?
        }
        struct DataItem: Decodable {
            let id: String
            let name: String?
        }
        let models: [RemoteModel]?
        let data: [DataItem]?
    }

    private struct ChatGPTDiscoveryResult: Sendable {
        let models: [ModelSchema.Info]
        let connection: CoreIntegration.Connection.Info
        let accountID: String?
    }

    private static func fetchChatGPTCodexModels(
        connection: CoreIntegration.Connection.Info,
        oauth: CredentialSchema.OAuth,
        credentialID: CredentialSchema.ID?,
        existingModels: [ModelSchema.Info],
        httpTransport: any HTTPTransport,
        oauthManager: ServerLiveOAuthManager?,
        userAgent: String
    ) async -> ChatGPTDiscoveryResult? {
        var effectiveOAuth = oauth
        if let credentialID, let oauthManager {
            let nowMs = Flock.currentEpochMs()
            if effectiveOAuth.expires.rawValue > 0 && Int64(effectiveOAuth.expires.rawValue) <= nowMs + 60_000 {
                if let refreshed = try? await oauthManager.refreshToken(
                    credentialID: credentialID,
                    integrationID: IntegrationID(rawValue: "openai")
                ) {
                    effectiveOAuth = refreshed
                }
            }
        }
        let accountID: String? = if case .string(let acct) = effectiveOAuth.metadata?["accountID"], !acct.isEmpty {
            acct
        } else {
            nil
        }
        var mutableHeaders: [String: String] = [
            "accept": "application/json",
            "authorization": "Bearer \(effectiveOAuth.access)",
            "user-agent": userAgent,
            "originator": "opencode",
        ]
        if let accountID {
            mutableHeaders["chatgpt-account-id"] = accountID
        }
        let headers = mutableHeaders
        let response = await withHTTPTimeout(milliseconds: 5_000) {
            try await httpTransport.send(HTTPRequest(
                method: "GET",
                url: ServerLiveOAuth.chatGPTCodexModelsURL,
                headers: headers
            ))
        }
        guard let response, (200..<300).contains(response.head.statusCode),
              let decoded = try? ServerCodec.decode(CodexModelsResponse.self, from: response.body)
        else {
            return nil
        }

        let existingByID: [String: ModelSchema.Info] = Dictionary(
            existingModels.map { ($0.modelID.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var derived: [ModelSchema.Info] = []
        if let remoteModels = decoded.models {
            for item in remoteModels {
                if let vis = item.visibility, vis != "list" { continue }
                if item.supported_in_api == false { continue }
                let previous = existingByID[item.slug]
                let mid = ModelSchema.ID(rawValue: item.slug)
                let inputMods: [String] = {
                    if let mods = item.input_modalities {
                        let filtered = mods.filter { $0 == "text" || $0 == "image" }
                        if !filtered.isEmpty { return filtered }
                    }
                    return previous?.capabilities.input ?? ["text", "image"]
                }()
                let variants: [ModelSchema.Variant] = {
                    if let levels = item.supported_reasoning_levels, !levels.isEmpty {
                        return levels.map { lvl in
                            ModelSchema.Variant(
                                id: ModelSchema.VariantID(rawValue: lvl.effort),
                                settings: ModelSchema.VariantSettings(extra: ["reasoningEffort": .string(lvl.effort)])
                            )
                        }
                    }
                    return previous?.variants ?? []
                }()
                let context = item.context_window ?? previous?.limit.context ?? 400_000
                let output = item.max_output_tokens ?? previous?.limit.output ?? 128_000
                derived.append(ModelSchema.Info(
                    id: mid,
                    modelID: mid,
                    providerID: .openai,
                    canonical: previous?.canonical,
                    type: .chat,
                    family: previous?.family ?? ModelSchema.Family(rawValue: "gpt"),
                    name: item.display_name ?? previous?.name ?? item.slug,
                    compatibility: previous?.compatibility,
                    package: previous?.package ?? "@opencode/ai/providers/openai",
                    settings: previous?.settings,
                    headers: previous?.headers,
                    body: previous?.body,
                    capabilities: ModelSchema.Capabilities(
                        tools: previous?.capabilities.tools ?? true,
                        input: inputMods,
                        output: ["text"],
                        temperature: previous?.capabilities.temperature ?? true
                    ),
                    variants: variants,
                    time: previous?.time ?? ModelSchema.Info.Time(released: 0),
                    cost: [],
                    status: .active,
                    enabled: true,
                    limit: ModelSchema.Info.Limit(context: context, output: output)
                ))
            }
        } else if let dataItems = decoded.data {
            for item in dataItems where !item.id.isEmpty {
                let previous = existingByID[item.id]
                let mid = ModelSchema.ID(rawValue: item.id)
                derived.append(ModelSchema.Info(
                    id: mid,
                    modelID: mid,
                    providerID: .openai,
                    type: .chat,
                    family: previous?.family ?? ModelSchema.Family(rawValue: "gpt"),
                    name: item.name ?? previous?.name ?? item.id,
                    package: previous?.package ?? "@opencode/ai/providers/openai",
                    capabilities: previous?.capabilities ?? ModelSchema.Capabilities(tools: true, input: ["text", "image"], output: ["text"]),
                    variants: previous?.variants ?? [],
                    time: previous?.time ?? ModelSchema.Info.Time(released: 0),
                    cost: [],
                    status: .active,
                    enabled: true,
                    limit: previous?.limit ?? ModelSchema.Info.Limit(context: 400_000, output: 128_000)
                ))
            }
        }
        guard !derived.isEmpty else { return nil }
        return ChatGPTDiscoveryResult(models: derived, connection: connection, accountID: accountID)
    }

    // MARK: - 2d. Live GitHub Copilot Model Discovery (`github-copilot.ts`)

    private struct CopilotDiscoveryResult: Sendable {
        let baseURL: String
        let snapshot: CoreModel.CopilotModels.Snapshot
        let connection: CoreIntegration.Connection.Info
    }

    private static func fetchCopilotLiveModels(
        connection: CoreIntegration.Connection.Info,
        oauth: CredentialSchema.OAuth,
        httpTransport: any HTTPTransport,
        userAgent: String
    ) async -> CopilotDiscoveryResult? {
        let baseURL = ServerLiveOAuth.copilotBaseURL(oauth.metadata)
        let token = oauth.access.isEmpty ? oauth.refresh : oauth.access
        guard !token.isEmpty else { return nil }
        let headers: [String: String] = [
            "accept": "application/json",
            "authorization": "Bearer \(token)",
            "user-agent": userAgent,
            "x-github-api-version": ServerLiveOAuth.copilotApiVersion,
            "copilot-integration-id": "vscode-chat",
            "openai-intent": "conversation-edits",
            "editor-version": "vscode/1.99.0",
        ]
        guard let snap = await withHTTPTimeout(milliseconds: 5_000, operation: {
            try await CoreModel.CopilotModels.load(http: httpTransport, baseURL: baseURL, headers: headers)
        }), !snap.isEmpty else {
            return nil
        }
        return CopilotDiscoveryResult(baseURL: baseURL, snapshot: snap, connection: connection)
    }

    // MARK: - 2e. Live Local Model Discovery (Ollama / LM Studio / vLLM, 400ms fast probe)

    private struct DiscoveredLocalProvider: Sendable {
        let id: ProviderSchema.ID
        let name: String
        let baseURL: String
        let models: [ModelSchema.Info]
    }

    private struct OllamaTagsResponse: Decodable {
        struct Details: Decodable { let family: String? }
        struct Entry: Decodable {
            let name: String?
            let model: String?
            let details: Details?
        }
        let models: [Entry]
    }

    private struct OpenAIModelsListResponse: Decodable {
        struct Entry: Decodable {
            let id: String
            let owned_by: String?
            let max_model_len: Int?
        }
        let data: [Entry]?
    }

    private struct LMStudioNativeModelsResponse: Decodable {
        struct Entry: Decodable {
            let key: String
            let display_name: String?
            let architecture: String?
            let max_context_length: Int?
            let type: String?
        }
        let models: [Entry]?
    }

    private static func probeLocalModels(
        httpTransport: any HTTPTransport,
        configuredProviders: [String: [ConfigProviderSchema.Info]]
    ) async -> [DiscoveredLocalProvider] {
        func configuredOrigin(for providerID: String, defaultOrigin: String) -> (origin: String, baseURL: String) {
            if let cfgs = configuredProviders[providerID] {
                for cfg in cfgs.reversed() {
                    if case .string(let raw) = cfg.settings?.extra["baseURL"], !raw.isEmpty {
                        let trimmed = raw.trimmingTrailingSlashes()
                        var origin = trimmed
                        if origin.hasSuffix("/v1") { origin = String(origin.dropLast(3)) }
                        else if origin.hasSuffix("/api") { origin = String(origin.dropLast(4)) }
                        return (origin.trimmingTrailingSlashes(), trimmed)
                    }
                }
            }
            return (defaultOrigin, "\(defaultOrigin)/v1")
        }

        let ollamaTarget = configuredOrigin(for: "ollama", defaultOrigin: "http://127.0.0.1:11434")
        let lmstudioTarget = configuredOrigin(for: "lmstudio", defaultOrigin: "http://127.0.0.1:1234")
        let vllmTarget = configuredOrigin(for: "vllm", defaultOrigin: "http://127.0.0.1:8000")

        return await withTaskGroup(of: DiscoveredLocalProvider?.self) { group in
            // 1. Ollama: GET 127.0.0.1:11434/api/tags
            group.addTask {
                guard let resp = await withHTTPTimeout(milliseconds: 400, operation: {
                    try await httpTransport.send(HTTPRequest(
                        method: "GET",
                        url: "\(ollamaTarget.origin)/api/tags",
                        headers: ["accept": "application/json"]
                    ))
                }), (200..<300).contains(resp.head.statusCode),
                      let parsed = try? ServerCodec.decode(OllamaTagsResponse.self, from: resp.body)
                else { return nil }
                let pid = ProviderSchema.ID(rawValue: "ollama")
                let models: [ModelSchema.Info] = parsed.models.compactMap { entry in
                    let id = (entry.model?.isEmpty == false ? entry.model : entry.name) ?? ""
                    guard !id.isEmpty else { return nil }
                    return makeModel(
                        id: id,
                        providerID: pid,
                        name: (entry.name?.isEmpty == false ? entry.name! : id),
                        family: entry.details?.family ?? "ollama",
                        package: "@opencode/ai/providers/openai-compatible",
                        context: 131_072,
                        output: 16_384,
                        inputCost: 0,
                        outputCost: 0,
                        released: (2025, 1, 1),
                        inputModalities: ["text"]
                    )
                }
                guard !models.isEmpty else { return nil }
                return DiscoveredLocalProvider(id: pid, name: "Ollama", baseURL: ollamaTarget.baseURL, models: models)
            }

            // 2. LM Studio: GET 127.0.0.1:1234/v1/models
            group.addTask {
                guard let resp = await withHTTPTimeout(milliseconds: 400, operation: {
                    try await httpTransport.send(HTTPRequest(
                        method: "GET",
                        url: "\(lmstudioTarget.origin)/v1/models",
                        headers: ["accept": "application/json"]
                    ))
                }), (200..<300).contains(resp.head.statusCode)
                else { return nil }
                let pid = ProviderSchema.ID(rawValue: "lmstudio")
                var models: [ModelSchema.Info] = []
                if let openai = try? ServerCodec.decode(OpenAIModelsListResponse.self, from: resp.body),
                   let data = openai.data, !data.isEmpty
                {
                    models = data.compactMap { entry in
                        guard !entry.id.isEmpty else { return nil }
                        return makeModel(
                            id: entry.id,
                            providerID: pid,
                            name: entry.id,
                            family: "lmstudio",
                            package: "@opencode/ai/providers/openai-compatible",
                            context: entry.max_model_len ?? 131_072,
                            output: 16_384,
                            inputCost: 0,
                            outputCost: 0,
                            released: (2025, 1, 1),
                            inputModalities: ["text"]
                        )
                    }
                } else if let native = try? ServerCodec.decode(LMStudioNativeModelsResponse.self, from: resp.body),
                          let items = native.models, !items.isEmpty
                {
                    models = items.compactMap { entry in
                        guard !entry.key.isEmpty else { return nil }
                        return makeModel(
                            id: entry.key,
                            providerID: pid,
                            name: entry.display_name ?? entry.key,
                            family: entry.architecture ?? "lmstudio",
                            package: "@opencode/ai/providers/openai-compatible",
                            context: entry.max_context_length ?? 131_072,
                            output: 16_384,
                            inputCost: 0,
                            outputCost: 0,
                            released: (2025, 1, 1),
                            inputModalities: ["text"]
                        )
                    }
                }
                guard !models.isEmpty else { return nil }
                return DiscoveredLocalProvider(id: pid, name: "LM Studio", baseURL: lmstudioTarget.baseURL, models: models)
            }

            // 3. vLLM: GET 127.0.0.1:8000/v1/models
            group.addTask {
                guard let resp = await withHTTPTimeout(milliseconds: 400, operation: {
                    try await httpTransport.send(HTTPRequest(
                        method: "GET",
                        url: "\(vllmTarget.origin)/v1/models",
                        headers: ["accept": "application/json"]
                    ))
                }), (200..<300).contains(resp.head.statusCode),
                      let openai = try? ServerCodec.decode(OpenAIModelsListResponse.self, from: resp.body),
                      let data = openai.data, !data.isEmpty
                else { return nil }
                let pid = ProviderSchema.ID(rawValue: "vllm")
                let models: [ModelSchema.Info] = data.compactMap { entry in
                    guard !entry.id.isEmpty else { return nil }
                    return makeModel(
                        id: entry.id,
                        providerID: pid,
                        name: entry.id,
                        family: "vllm",
                        package: "@opencode/ai/providers/openai-compatible",
                        context: entry.max_model_len ?? 131_072,
                        output: 16_384,
                        inputCost: 0,
                        outputCost: 0,
                        released: (2025, 1, 1),
                        inputModalities: ["text"]
                    )
                }
                guard !models.isEmpty else { return nil }
                return DiscoveredLocalProvider(id: pid, name: "vLLM", baseURL: vllmTarget.baseURL, models: models)
            }

            var out: [DiscoveredLocalProvider] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out.sorted { $0.id.rawValue < $1.id.rawValue }
        }
    }

    /// Helper applying a single `ConfigProviderSchema.ModelConfig` onto an existing or default `ModelSchema.Info`.
    private static func overlayModelConfig(
        rawProviderID: String,
        providerInfo: ProviderSchema.Info,
        modelKey: String,
        modelCfg: ConfigProviderSchema.ModelConfig,
        existing: ModelSchema.Info?
    ) -> ModelSchema.Info {
        let pid = providerInfo.id
        let mid = ModelSchema.ID(rawValue: modelKey)
        let base = existing ?? ModelSchema.Info.default(providerID: pid, id: mid)
        let modelPkg = CoreProvider.AISDKNative.rewrite(
            specifier: modelCfg.package ?? base.package ?? providerInfo.package,
            providerID: rawProviderID,
            canonical: providerInfo.canonical?.rawValue,
            modelID: (modelCfg.modelID ?? base.modelID).rawValue
        ).package ?? providerInfo.package

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
            canonical: providerInfo.canonical ?? base.canonical,
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
        return updatedModel
    }

    /// Seeds ALL 7 real OAuth methods, live/cached ModelsDev catalog (300+ providers, 1,000+ models),
    /// built-in providers, live OpenCode Console workspace config & free public Zen fallback,
    /// live ChatGPT Codex models, live GitHub Copilot models, live local models (Ollama/LM Studio/vLLM),
    /// and user/project config overlays.
    @discardableResult
    public static func seedProvidersAndModels(
        integrations integrationService: any CoreIntegration.Integration.Interface,
        providers providerService: any CoreProvider.Provider.Interface,
        models modelService: any CoreModel.Model.Interface,
        configEntries: [CoreConfigEntry],
        globalPaths: Global.Interface? = nil,
        fileSystem: (any OpenCodeFileSystem)? = nil,
        configService: (any CoreConfig.Interface)? = nil,
        skillService: (any CoreSkill.Interface)? = nil,
        credentialService: CoreProvider.Credential.Service? = nil,
        modelsDev: CoreModel.ModelsDev.Service? = nil,
        kv: CoreKV.Service? = nil,
        httpTransport: (any HTTPTransport)? = nil,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        oauthManager: ServerLiveOAuthManager? = nil,
        modelsDevOptions: CoreModel.ModelsDev.Options? = nil,
        allowLiveNetwork: Bool = false,
        syncFetchOnColdCache: Bool = false,
        forceRefresh: Bool = false,
        userAgent: String = "opencode/2.0.0"
    ) async throws -> ProviderSeedRegistrations {
        // Collect provider configs & default model from ordered non-integration config entries (later wins).
        var configuredProviders: [String: [ConfigProviderSchema.Info]] = [:]
        var configuredDefaultModel: ConfigModelSchema.Selection? = nil
        for entry in configEntries {
            if case .integration = entry { continue }
            guard let info = entry.info else { continue }
            if let modelSel = info.model {
                configuredDefaultModel = modelSel
            }
            for (rawID, provCfg) in info.providers ?? [:] {
                configuredProviders[rawID, default: []].append(provCfg)
            }
        }

        // Load ModelsDev snapshots from KV (`models-dev:v2:catalog`) + disk `<cache>/models.json` + live fetch when allowed.
        let catalogSnapshots = await loadModelsDevSnapshots(
            modelsDev: modelsDev,
            kv: kv,
            globalPaths: globalPaths,
            fileSystem: fileSystem,
            httpTransport: httpTransport,
            options: modelsDevOptions,
            allowLiveNetwork: allowLiveNetwork,
            syncFetchOnColdCache: syncFetchOnColdCache,
            forceRefresh: forceRefresh
        )
        let catalogByID: [String: CoreModel.ModelsDev.Snapshot] = Dictionary(
            catalogSnapshots.map { ($0.info.id.rawValue, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        let builtinByID: [String: BuiltinProviderSpec] = Dictionary(
            uniqueKeysWithValues: builtinProviders.map { ($0.id.rawValue, $0) }
        )

        // 1. Register ModelsDev + built-in + 7 real OAuth methods + custom integrations.
        let configProvidersSnapshot = configuredProviders
        let integrationReg = try await integrationService.transform { editor in
            // 1a. All ModelsDev providers (300+ providers, lowest priority)
            for snap in catalogSnapshots where builtinByID[snap.info.id.rawValue] == nil {
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

            // 1b. Built-in providers (preserve display names, merge env vars without hiding ModelsDev env vars)
            for spec in builtinProviders {
                let intID = IntegrationID(rawValue: spec.id.rawValue)
                var envVars = spec.envVars
                if let cachedEnv = catalogByID[spec.id.rawValue]?.environment {
                    for name in cachedEnv where !envVars.contains(name) {
                        envVars.append(name)
                    }
                }
                if let cfgs = configProvidersSnapshot[spec.id.rawValue] {
                    for cfg in cfgs {
                        for name in cfg.env ?? [] where !envVars.contains(name) {
                            envVars.append(name)
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

            // 1c. Register ALL 7 real upstream OAuth methods
            ServerLiveOAuth.registerAllOAuthMethods(into: editor, environment: environment)

            // 1d. Custom config-declared providers (highest priority)
            for (rawID, cfgs) in configProvidersSnapshot where builtinByID[rawID] == nil {
                let intID = IntegrationID(rawValue: rawID)
                let cached = catalogByID[rawID]
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

        // 2. Inspect active connections for OpenCode Console, OpenAI ChatGPT OAuth, and GitHub Copilot OAuth.
        let opencodeID = IntegrationID(rawValue: "opencode")
        let openaiID = IntegrationID(rawValue: "openai")
        let copilotID = IntegrationID(rawValue: "github-copilot")

        let activeOpencodeConn = try? await integrationService.activeConnection(opencodeID)
        let activeOpenAIConn = try? await integrationService.activeConnection(openaiID)
        let activeCopilotConn = try? await integrationService.activeConnection(copilotID)

        // Helper extracting stored credential ID + value for an active connection
        func resolveActiveCred(
            _ conn: CoreIntegration.Connection.Info?
        ) async -> (id: CredentialSchema.ID?, value: CredentialSchema.Value)? {
            guard let conn else { return nil }
            let credID: CredentialSchema.ID? = if case .credential(let c) = conn { c.id } else { nil }
            if let credID, let credService = credentialService,
               let stored = try? await credService.get(credID)
            {
                return (credID, stored.value)
            }
            if let resolved = try? await integrationService.resolveConnection(conn) {
                return (credID, resolved)
            }
            return nil
        }

        let opencodeCred = await resolveActiveCred(activeOpencodeConn)
        let openAICred = await resolveActiveCred(activeOpenAIConn)
        let copilotCred = await resolveActiveCred(activeCopilotConn)

        // 3. Perform live provider discovery concurrently when live network is allowed.
        var consoleSync: ConsoleSyncResult? = nil
        var chatGPTDiscovery: ChatGPTDiscoveryResult? = nil
        var copilotDiscovery: CopilotDiscoveryResult? = nil
        var localDiscovered: [DiscoveredLocalProvider] = []

        if allowLiveNetwork, let httpTransport {
            let existingOpenAIModels: [ModelSchema.Info] = {
                var merged = builtinByID["openai"]?.models ?? []
                let ids = Set(merged.map(\.id))
                for m in catalogByID["openai"]?.models ?? [] where !ids.contains(m.id) {
                    merged.append(m)
                }
                return merged
            }()

            async let consoleTask: ConsoleSyncResult? = {
                guard let conn = activeOpencodeConn, let cred = opencodeCred else { return nil }
                if case .external = cred.value { return nil }
                return await fetchConsoleSync(
                    connection: conn,
                    credentialValue: cred.value,
                    credentialID: cred.id,
                    integrationService: integrationService,
                    httpTransport: httpTransport,
                    oauthManager: oauthManager,
                    userAgent: userAgent
                )
            }()

            async let chatGPTTask: ChatGPTDiscoveryResult? = {
                guard let conn = activeOpenAIConn,
                      let cred = openAICred,
                      case .oauth(let oauth) = cred.value,
                      oauth.methodID == ServerLiveOAuth.chatGPTMethodID
                        || oauth.methodID.rawValue == "chatgpt-browser"
                        || oauth.methodID.rawValue == "chatgpt-headless"
                else { return nil }
                return await fetchChatGPTCodexModels(
                    connection: conn,
                    oauth: oauth,
                    credentialID: cred.id,
                    existingModels: existingOpenAIModels,
                    httpTransport: httpTransport,
                    oauthManager: oauthManager,
                    userAgent: userAgent
                )
            }()

            async let copilotTask: CopilotDiscoveryResult? = {
                guard let conn = activeCopilotConn,
                      let cred = copilotCred,
                      case .oauth(let oauth) = cred.value
                else { return nil }
                return await fetchCopilotLiveModels(
                    connection: conn,
                    oauth: oauth,
                    httpTransport: httpTransport,
                    userAgent: userAgent
                )
            }()

            async let localTask: [DiscoveredLocalProvider] = probeLocalModels(
                httpTransport: httpTransport,
                configuredProviders: configProvidersSnapshot
            )

            consoleSync = await consoleTask
            chatGPTDiscovery = await chatGPTTask
            copilotDiscovery = await copilotTask
            localDiscovered = await localTask
        }

        // Layer Console remote config into configService (policies, MCP, providers) and register Console skills
        if let consoleSync {
            await configService?.integration(opencodeID, document: consoleSync.document)
            if let skillService, !consoleSync.skills.isEmpty {
                let consoleSkills = consoleSync.skills
                _ = try? await skillService.transform { editor in
                    for item in consoleSkills {
                        editor.add(item.skill, files: item.files.isEmpty ? nil : item.files)
                    }
                }
            }
        } else if activeOpencodeConn == nil {
            await configService?.integration(opencodeID, document: nil)
        }

        // Compute OpenCode Console free public Zen fallback condition (matching upstream `opencode.ts:482-507`)
        let disableFreeModels = ["1", "true"].contains(
            (environment.variable("OPENCODE_DISABLE_FREE_MODELS") ?? "").lowercased()
        )
        let hasOpencodeEnvKey = !(environment.variable("OPENCODE_API_KEY") ?? "").isEmpty
        let hasOpencodeConfigKey: Bool = {
            for cfg in configProvidersSnapshot["opencode"] ?? [] {
                if case .string(let k) = cfg.settings?.extra["apiKey"], !k.isEmpty, k != "public" {
                    return true
                }
            }
            return false
        }()
        let hasOpencodeKey = hasOpencodeEnvKey || activeOpencodeConn != nil || hasOpencodeConfigKey

        let activeChatGPTOAuth: CredentialSchema.OAuth? = {
            guard let cred = openAICred, case .oauth(let o) = cred.value else { return nil }
            if o.methodID == ServerLiveOAuth.chatGPTMethodID
                || o.methodID.rawValue == "chatgpt-browser"
                || o.methodID.rawValue == "chatgpt-headless"
            {
                return o
            }
            return nil
        }()
        let activeCopilotOAuth: CredentialSchema.OAuth? = {
            guard let cred = copilotCred, case .oauth(let o) = cred.value else { return nil }
            return o
        }()

        let finalConsoleSync = consoleSync
        let finalChatGPTDiscovery = chatGPTDiscovery
        let finalCopilotDiscovery = copilotDiscovery
        let finalLocalDiscovered = localDiscovered

        // 4. Register ModelsDev + built-in + Console + ChatGPT + Copilot + Local + Config providers & models.
        let providerReg = try await providerService.transform { editor in
            // 4a. All ModelsDev providers not in built-ins (lowest priority)
            for snap in catalogSnapshots where builtinByID[snap.info.id.rawValue] == nil {
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

            // 4b. Built-in providers merged cleanly with ALL live/cached ModelsDev models for that provider
            for spec in builtinProviders {
                let catalogSnap = catalogByID[spec.id.rawValue]
                var extra = catalogSnap?.info.settings?.extra ?? [:]
                if let baseURL = spec.baseURL {
                    extra["baseURL"] = .string(baseURL)
                }
                let settings = extra.isEmpty ? catalogSnap?.info.settings : ProviderSchema.Settings(
                    timeout: catalogSnap?.info.settings?.timeout,
                    headerTimeout: catalogSnap?.info.settings?.headerTimeout,
                    chunkTimeout: catalogSnap?.info.settings?.chunkTimeout,
                    compaction: catalogSnap?.info.settings?.compaction,
                    cache: catalogSnap?.info.settings?.cache,
                    transport: catalogSnap?.info.settings?.transport,
                    encoding: catalogSnap?.info.settings?.encoding,
                    tls: catalogSnap?.info.settings?.tls,
                    extra: extra
                )
                let info = ProviderSchema.Info(
                    id: spec.id,
                    canonical: catalogSnap?.info.canonical,
                    integrationID: IntegrationID(rawValue: spec.id.rawValue),
                    name: spec.name,
                    activation: .auto,
                    package: spec.package,
                    compatibility: spec.compatibility ?? catalogSnap?.info.compatibility,
                    settings: settings,
                    headers: catalogSnap?.info.headers,
                    body: catalogSnap?.info.body
                )
                var mergedModels = spec.models
                if let cachedModels = catalogSnap?.models {
                    let builtinModelIDs = Set(spec.models.map(\.id))
                    for cachedModel in cachedModels where !builtinModelIDs.contains(cachedModel.id) {
                        mergedModels.append(cachedModel)
                    }
                }
                editor.add(info: info, models: mergedModels)
            }

            // 4c. OpenCode Console live workspace providers & custom models (matching `ConfigProviderPlugin.integrate`)
            if let sync = finalConsoleSync {
                for (rawID, provCfg) in (sync.document.info.providers ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let pid = ProviderSchema.ID(rawValue: rawID)
                    let existing = editor.get(pid)
                    let source: CoreProvider.Provider.Definition? = {
                        let sourceID = provCfg.canonical ?? existing?.provider.canonical ?? pid
                        return editor.get(sourceID)
                    }()
                    let baseInfo = existing?.provider ?? source?.provider ?? ProviderSchema.Info(
                        id: pid,
                        integrationID: opencodeID,
                        name: provCfg.name ?? rawID,
                        activation: .enabled,
                        package: provCfg.package ?? "@opencode/ai/providers/openai-compatible"
                    )
                    let rewritten = CoreProvider.AISDKNative.rewrite(
                        specifier: provCfg.package ?? baseInfo.package,
                        providerID: rawID,
                        canonical: (provCfg.canonical ?? baseInfo.canonical)?.rawValue,
                        settings: provCfg.settings?.extra,
                        headers: provCfg.headers,
                        body: provCfg.body
                    )
                    let mergedExtra = CoreProvider.AISDKNative.mergeOverlay(
                        baseInfo.settings?.extra,
                        rewritten.settings ?? provCfg.settings?.extra
                    ) ?? [:]
                    let mergedSettings = ProviderSchema.Settings(
                        timeout: provCfg.settings?.timeout ?? baseInfo.settings?.timeout,
                        headerTimeout: provCfg.settings?.headerTimeout ?? baseInfo.settings?.headerTimeout,
                        chunkTimeout: provCfg.settings?.chunkTimeout ?? baseInfo.settings?.chunkTimeout,
                        compaction: provCfg.settings?.compaction ?? baseInfo.settings?.compaction,
                        cache: provCfg.settings?.cache ?? baseInfo.settings?.cache,
                        transport: provCfg.settings?.transport ?? baseInfo.settings?.transport,
                        encoding: provCfg.settings?.encoding ?? baseInfo.settings?.encoding,
                        tls: provCfg.settings?.tls ?? baseInfo.settings?.tls,
                        extra: mergedExtra
                    )
                    let mergedInfo = ProviderSchema.Info(
                        id: pid,
                        canonical: provCfg.canonical ?? baseInfo.canonical,
                        integrationID: opencodeID,
                        name: provCfg.name ?? baseInfo.name,
                        activation: .enabled,
                        package: rewritten.package ?? baseInfo.package,
                        compatibility: provCfg.compatibility ?? baseInfo.compatibility,
                        settings: mergedSettings,
                        headers: CoreProvider.AISDKNative.mergeHeaders(baseInfo.headers, rewritten.headers ?? provCfg.headers),
                        body: CoreProvider.AISDKNative.mergeOverlay(baseInfo.body, rewritten.body ?? provCfg.body)
                    )
                    var mergedModels = existing?.models ?? [:]
                    for (modelKey, modelCfg) in provCfg.models ?? [:] {
                        let baseModel = mergedModels[ModelSchema.ID(rawValue: modelKey)]
                            ?? source?.models[modelCfg.modelID ?? ModelSchema.ID(rawValue: modelKey)]
                            ?? source?.models[ModelSchema.ID(rawValue: modelKey)]
                        let updated = overlayModelConfig(
                            rawProviderID: rawID,
                            providerInfo: mergedInfo,
                            modelKey: modelKey,
                            modelCfg: modelCfg,
                            existing: baseModel
                        )
                        mergedModels[updated.id] = updated
                    }
                    editor.add(
                        info: mergedInfo,
                        models: Array(mergedModels.values),
                        sourceConnection: sync.document.connection
                    )
                }
            }

            // 4d. OpenCode Console signed-out free public Zen fallback (`opencode.ts:482-491`)
            if !hasOpencodeKey && !disableFreeModels, let existing = editor.get(.opencode) {
                var extra = existing.provider.settings?.extra ?? [:]
                if extra["apiKey"] == nil {
                    extra["apiKey"] = .string("public")
                }
                let updatedSettings = ProviderSchema.Settings(
                    timeout: existing.provider.settings?.timeout,
                    headerTimeout: existing.provider.settings?.headerTimeout,
                    chunkTimeout: existing.provider.settings?.chunkTimeout,
                    compaction: existing.provider.settings?.compaction,
                    cache: existing.provider.settings?.cache,
                    transport: existing.provider.settings?.transport,
                    encoding: existing.provider.settings?.encoding,
                    tls: existing.provider.settings?.tls,
                    extra: extra
                )
                let updatedProvider = ProviderSchema.Info(
                    id: existing.provider.id,
                    canonical: existing.provider.canonical,
                    integrationID: existing.provider.integrationID,
                    name: existing.provider.name,
                    activation: .enabled,
                    package: existing.provider.package,
                    compatibility: existing.provider.compatibility,
                    settings: updatedSettings,
                    headers: existing.provider.headers,
                    body: existing.provider.body
                )
                editor.add(info: updatedProvider, models: Array(existing.models.values))
            }

            // 4e. Live ChatGPT / Codex models merged onto `openai` provider
            if let chatGPT = finalChatGPTDiscovery, let existing = editor.get(.openai) {
                var headers = existing.provider.headers ?? [:]
                headers["originator"] = "opencode"
                if let acct = chatGPT.accountID {
                    headers["chatgpt-account-id"] = acct
                }
                let updatedProvider = ProviderSchema.Info(
                    id: existing.provider.id,
                    canonical: existing.provider.canonical,
                    integrationID: existing.provider.integrationID,
                    name: existing.provider.name,
                    activation: existing.provider.activation,
                    package: existing.provider.package,
                    compatibility: existing.provider.compatibility,
                    settings: existing.provider.settings,
                    headers: headers,
                    body: existing.provider.body
                )
                var mergedMap = existing.models
                for discovered in chatGPT.models {
                    mergedMap[discovered.id] = discovered
                }
                editor.add(
                    info: updatedProvider,
                    models: Array(mergedMap.values),
                    sourceConnection: chatGPT.connection
                )
            } else if let oauth = activeChatGPTOAuth, let existing = editor.get(.openai) {
                var headers = existing.provider.headers ?? [:]
                headers["originator"] = "opencode"
                if case .string(let acct) = oauth.metadata?["accountID"], !acct.isEmpty {
                    headers["chatgpt-account-id"] = acct
                }
                editor.update(.openai) { prov in
                    ProviderSchema.Info(
                        id: prov.id, canonical: prov.canonical, integrationID: prov.integrationID,
                        name: prov.name, activation: prov.activation, package: prov.package,
                        compatibility: prov.compatibility, settings: prov.settings,
                        headers: headers, body: prov.body
                    )
                }
            }

            // 4f. Live GitHub Copilot models & `CoreModel.CopilotModels.routeFor` routing
            if let existing = editor.get(.githubCopilot) {
                let copilotRoot = finalCopilotDiscovery?.baseURL
                    ?? activeCopilotOAuth.map { ServerLiveOAuth.copilotBaseURL($0.metadata) }
                    ?? "https://api.githubcopilot.com"
                var extra = existing.provider.settings?.extra ?? [:]
                extra["baseURL"] = .string(copilotRoot)
                let updatedProvider = ProviderSchema.Info(
                    id: existing.provider.id,
                    canonical: existing.provider.canonical,
                    integrationID: existing.provider.integrationID,
                    name: existing.provider.name,
                    activation: existing.provider.activation,
                    package: existing.provider.package,
                    compatibility: existing.provider.compatibility,
                    settings: ProviderSchema.Settings(extra: extra),
                    headers: existing.provider.headers,
                    body: existing.provider.body
                )
                if let live = finalCopilotDiscovery {
                    let derivedMap = CoreModel.CopilotModels.derive(
                        baseURL: live.baseURL,
                        remote: live.snapshot,
                        existing: Array(existing.models.values)
                    )
                    var list = Array(derivedMap.values)
                    if let auto = CoreModel.CopilotModels.autoModel(baseURL: live.baseURL, remote: live.snapshot) {
                        list.append(auto)
                    }
                    editor.add(info: updatedProvider, models: list, sourceConnection: live.connection)
                } else {
                    let routedModels: [ModelSchema.Info] = existing.models.values.map { model in
                        let advertised: CoreModel.CopilotModels.Endpoint? = {
                            if model.package == "@opencode/ai/providers/anthropic" { return .messages }
                            if model.package == "@opencode/ai/providers/openai" { return .responses }
                            return nil
                        }()
                        let route = CoreModel.CopilotModels.routeFor(
                            modelID: model.modelID.rawValue,
                            advertised: advertised,
                            root: copilotRoot
                        )
                        var mExtra = model.settings?.extra ?? [:]
                        mExtra["baseURL"] = .string(route.baseURL)
                        return ModelSchema.Info(
                            id: model.id, modelID: model.modelID, providerID: model.providerID,
                            canonical: model.canonical, type: model.type, family: model.family,
                            name: model.name, compatibility: model.compatibility, package: route.package,
                            settings: ModelSchema.Settings(
                                compaction: model.settings?.compaction,
                                cache: model.settings?.cache,
                                encoding: model.settings?.encoding,
                                extra: mExtra
                            ),
                            headers: model.headers, body: model.body,
                            capabilities: model.capabilities, variants: model.variants,
                            time: model.time, cost: model.cost, status: model.status,
                            enabled: model.enabled, limit: model.limit
                        )
                    }
                    editor.add(info: updatedProvider, models: routedModels)
                }
            }

            // 4g. Live Local Models (Ollama, LM Studio, vLLM) registered with `activation: .enabled`
            for local in finalLocalDiscovered {
                let info = ProviderSchema.Info(
                    id: local.id,
                    integrationID: nil,
                    name: local.name,
                    activation: .enabled,
                    package: "@opencode/ai/providers/openai-compatible",
                    settings: ProviderSchema.Settings(extra: [
                        "baseURL": .string(local.baseURL),
                        "provider": .string(local.id.rawValue),
                        "apiKey": .string(""),
                    ])
                )
                editor.add(info: info, models: local.models)
            }

            // 4h. User & project `opencode.json[c]` provider/model overlays (highest priority)
            for (rawID, cfgs) in configProvidersSnapshot.sorted(by: { $0.key < $1.key }) {
                let pid = ProviderSchema.ID(rawValue: rawID)
                let isBuiltin = builtinByID[rawID] != nil
                let hasCachedEnv = !(catalogByID[rawID]?.environment.isEmpty ?? true)
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
                        let updated = overlayModelConfig(
                            rawProviderID: rawID,
                            providerInfo: currentInfo,
                            modelKey: modelKey,
                            modelCfg: modelCfg,
                            existing: currentModels[mid]
                        )
                        currentModels[mid] = updated
                    }
                }

                editor.add(info: currentInfo, models: Array(currentModels.values))
            }
        }

        // 5. Model transforms: signed-out OpenCode paid model gating (`opencode.ts:492-507`),
        //    Copilot chat-alias hiding, and default model selection.
        let finalConfiguredDefault = configuredDefaultModel
        let modelReg = try await modelService.transform { editor in
            // 5a. When signed out of OpenCode Console, disable paid models (cost.input > 0) while keeping free models enabled
            if !hasOpencodeKey && !disableFreeModels {
                for model in editor.list(providerID: .opencode) {
                    if model.cost.contains(where: { $0.input.rawValue > 0 }) {
                        editor.update(providerID: .opencode, modelID: model.id) { draft in
                            ModelSchema.Info(
                                id: draft.id, modelID: draft.modelID, providerID: draft.providerID,
                                canonical: draft.canonical, type: draft.type, family: draft.family,
                                name: draft.name, compatibility: draft.compatibility, package: draft.package,
                                settings: draft.settings, headers: draft.headers, body: draft.body,
                                capabilities: draft.capabilities, variants: draft.variants, time: draft.time,
                                cost: draft.cost, status: draft.status, enabled: false, limit: draft.limit
                            )
                        }
                    }
                }
            }

            // 5b. Hide Copilot's conflicting chat-only alias (`github-copilot.ts:301-307`)
            let chatAliasID = ModelSchema.ID(rawValue: "gpt-5-chat-latest")
            if editor.get(providerID: .githubCopilot, modelID: chatAliasID) != nil {
                editor.update(providerID: .githubCopilot, modelID: chatAliasID) { draft in
                    ModelSchema.Info(
                        id: draft.id, modelID: draft.modelID, providerID: draft.providerID,
                        canonical: draft.canonical, type: draft.type, family: draft.family,
                        name: draft.name, compatibility: draft.compatibility, package: draft.package,
                        settings: draft.settings, headers: draft.headers, body: draft.body,
                        capabilities: draft.capabilities, variants: draft.variants, time: draft.time,
                        cost: draft.cost, status: draft.status, enabled: false, limit: draft.limit
                    )
                }
            }

            // 5c. Default model selection (user config first, then deterministic preferred flagship, then first enabled text model)
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

        return ProviderSeedRegistrations(
            integrations: integrationReg,
            providers: providerReg,
            models: modelReg
        )
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
        let extraHeaders: [String: String]
        let baseURLOverride: String?

        init(mode: AuthMode, extraHeaders: [String: String] = [:], baseURLOverride: String? = nil) {
            self.mode = mode
            self.extraHeaders = extraHeaders
            self.baseURLOverride = baseURLOverride
        }
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
    /// and provider config settings (`apiKey`), automatically refreshing expired OAuth tokens via
    /// `ServerLiveOAuthManager.refreshToken(...)` (locked per credential ID) and attaching provider-specific headers.
    private static func resolveCredential(
        for provider: ProviderSchema.Info,
        integrations: any CoreIntegration.Integration.Interface,
        environment: any EnvironmentProviding,
        oauthManager: ServerLiveOAuthManager? = nil
    ) async -> ResolvedCredential? {
        let intID = provider.integrationID ?? IntegrationID(rawValue: provider.id.rawValue)
        if let activeConn = try? await integrations.activeConnection(intID),
           let value = try? await integrations.resolveConnection(activeConn)
        {
            switch value {
            case .key(let k) where !k.key.isEmpty:
                var extraHeaders: [String: String] = [:]
                if intID.rawValue == "opencode",
                   case .string(let orgID) = k.metadata?["orgID"], !orgID.isEmpty
                {
                    extraHeaders["x-org-id"] = orgID
                }
                return ResolvedCredential(mode: .apiKey(k.key), extraHeaders: extraHeaders)
            case .oauth(var o) where !o.access.isEmpty:
                if case .credential(let credInfo) = activeConn,
                   let oauthManager
                {
                    let nowMs = Flock.currentEpochMs()
                    if o.expires.rawValue > 0 && Int64(o.expires.rawValue) <= nowMs + 60_000 {
                        if let refreshed = try? await oauthManager.refreshToken(
                            credentialID: credInfo.id,
                            integrationID: intID
                        ) {
                            o = refreshed
                        }
                    }
                }
                var extraHeaders: [String: String] = [:]
                var baseURLOverride: String? = nil
                switch intID.rawValue {
                case "opencode":
                    if case .string(let orgID) = o.metadata?["orgID"], !orgID.isEmpty {
                        extraHeaders["x-org-id"] = orgID
                    }
                case "openai":
                    if o.methodID == ServerLiveOAuth.chatGPTMethodID
                        || o.methodID.rawValue == "chatgpt-browser"
                        || o.methodID.rawValue == "chatgpt-headless"
                    {
                        extraHeaders["originator"] = "opencode"
                        if case .string(let accountID) = o.metadata?["accountID"], !accountID.isEmpty {
                            extraHeaders["chatgpt-account-id"] = accountID
                        }
                    }
                case "github-copilot":
                    extraHeaders["copilot-integration-id"] = "vscode-chat"
                    extraHeaders["openai-intent"] = "conversation-edits"
                    extraHeaders["editor-version"] = "vscode/1.99.0"
                    extraHeaders["x-github-api-version"] = ServerLiveOAuth.copilotApiVersion
                    baseURLOverride = ServerLiveOAuth.copilotBaseURL(o.metadata)
                default:
                    break
                }
                return ResolvedCredential(
                    mode: .bearerOAuth(o.access),
                    extraHeaders: extraHeaders,
                    baseURLOverride: baseURLOverride
                )
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

    /// Builds a location-scoped `CoreSessionRunnerModel.Service` with live credential resolution,
    /// automatic OAuth token refresh (locked per credential ID via `ServerLiveOAuthManager`),
    /// and provider-specific wire headers (`x-org-id`, `ChatGPT-Account-ID`, Copilot headers).
    public static func makeModelResolver(
        agentService: any CoreAgent.Agent.Interface,
        integrationService: any CoreIntegration.Integration.Interface,
        providerService: any CoreProvider.Provider.Interface,
        modelService: any CoreModel.Model.Interface,
        environment: any EnvironmentProviding,
        oauthManager: ServerLiveOAuthManager? = nil
    ) -> CoreSessionRunnerModel.Service {
        CoreSessionRunnerModel.Service { session, availableFn, kind, agentID in
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
               let cred = await resolveCredential(
                   for: providerInfo,
                   integrations: integrationService,
                   environment: environment,
                   oauthManager: oauthManager
               )
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
                let baseURL = configuredBaseURL
                    ?? cred.baseURLOverride
                    ?? defaultBaseURL(for: providerInfo.id.rawValue, protocolKind: protoKind)

                // Strip non-wire settings (`baseURL`, `base_url`, `apiKey`, `provider`) before sending providerOptions.
                let wireSettings = settings.filter { key, _ in
                    key != "baseURL" && key != "base_url" && key != "apiKey" && key != "provider"
                }

                var mergedHeaders = CoreProvider.AISDKNative.mergeHeaders(providerInfo.headers, modelInfo.headers) ?? [:]
                if !cred.extraHeaders.isEmpty {
                    mergedHeaders = CoreProvider.AISDKNative.mergeHeaders(mergedHeaders, cred.extraHeaders) ?? mergedHeaders
                }
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
        oauthManager: ServerLiveOAuthManager? = nil,
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

        let runnerModel = makeModelResolver(
            agentService: agentService,
            integrationService: integrationService,
            providerService: providerService,
            modelService: modelService,
            environment: environment,
            oauthManager: oauthManager
        )

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
