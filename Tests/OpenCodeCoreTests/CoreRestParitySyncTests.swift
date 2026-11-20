import Testing
import Synchronization
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Core parity sync: session, jobs, config markdown, MCP, variants")
struct CoreRestParitySyncTests {
    // MARK: config/markdown.ts

    @Test("sanitize keeps valid flow collections and plain colon scalars, rewrites trailing tags")
    func markdownSanitizeFlow() {
        let flow = "---\ntags: [a, \"b: c\"]\n---\nBody\n"
        #expect(CoreConfigMarkdown.sanitize(flow) == flow)

        let multiline = "---\ntags: [\nnot: a key,\n]\ntitle: A: B\n---\nBody\n"
        #expect(CoreConfigMarkdown.sanitize(multiline) == "---\ntags: [\nnot: a key,\n]\ntitle: |-\n  A: B\n---\nBody\n")

        let url = "---\nurl: http://example.com/a:b\n---\nBody\n"
        #expect(CoreConfigMarkdown.sanitize(url) == url)

        let tagged = "---\ndescription: [Release] Cut build\n---\nBody\n"
        #expect(CoreConfigMarkdown.sanitize(tagged) == "---\ndescription: |-\n  [Release] Cut build\n---\nBody\n")
    }

    @Test("joinLegacyVariant joins a separate variant into a string model only")
    func joinLegacyVariant() {
        let joined = CoreConfigMarkdown.joinLegacyVariant(["model": .string("openai/gpt-5"), "variant": .string("high")])
        #expect(joined["model"] == .string("openai/gpt-5#high"))

        let embedded: [String: JSONValue] = ["model": .string("openai/gpt-5#low"), "variant": .string("high")]
        #expect(CoreConfigMarkdown.joinLegacyVariant(embedded) == embedded)

        let noModel: [String: JSONValue] = ["variant": .string("high")]
        #expect(CoreConfigMarkdown.joinLegacyVariant(noModel) == noModel)

        let badVariant: [String: JSONValue] = ["model": .string("openai/gpt-5"), "variant": .string("a#b")]
        #expect(CoreConfigMarkdown.joinLegacyVariant(badVariant) == badVariant)
    }

    // MARK: session/background-result.ts, subagent-completion.ts

    @Test("Background results render as <background-result> and subagent bodies list running videos")
    func backgroundResultAndFormatBody() throws {
        #expect(CoreSessionBackgroundResult.render("kind=\"video\" id=\"j1\" state=\"completed\"", "done")
            == "<background-result kind=\"video\" id=\"j1\" state=\"completed\">\ndone\n</background-result>")

        let child = try SessionID(validating: "ses_child")
        let other = try SessionID(validating: "ses_other")
        let body = CoreSessionSubagentCompletion.formatBody(
            "Finished.",
            childSessionID: child,
            background: [.video(sessionID: child, path: "out.mp4"), .video(sessionID: other, path: "b.mp4")]
        )
        #expect(body == "Finished.\n\nBackground work still running:\n- video (out.mp4)\n- video (b.mp4, in ses_other)")
    }

    // MARK: session/runner/live-tool-metadata.ts

    @Test("Live tool metadata overlays running tool parts until cleared")
    func liveToolMetadataOverlay() throws {
        let messageID = SessionMessageSchema.ID.create()
        let running = SessionMessageSchema.AssistantContent.tool(SessionMessageSchema.AssistantTool(
            id: "call_live",
            name: "shell",
            state: .running(SessionMessageSchema.ToolStateRunning(input: [:], metadata: ["kept": .bool(true)])),
            time: .init(created: 1)
        ))
        let message = SessionMessageSchema.Info.assistant(SessionMessageSchema.Assistant(
            id: messageID,
            agent: "build",
            model: SessionSchema.ModelRef(id: "m", providerID: "p"),
            content: [running],
            time: .init(created: 1)
        ))

        #expect(CoreSessionLiveToolMetadata.overlay(message) == message)
        CoreSessionLiveToolMetadata.set(messageID.rawValue, "call_live", ["output": .string("partial")])
        guard case .assistant(let overlaid) = CoreSessionLiveToolMetadata.overlay(message),
              case .tool(let tool) = overlaid.content.first,
              case .running(let state) = tool.state else {
            Issue.record("Expected a running tool part")
            return
        }
        #expect(state.metadata == ["kept": .bool(true), "output": .string("partial")])

        CoreSessionLiveToolMetadata.clear(messageID.rawValue, "call_live")
        #expect(CoreSessionLiveToolMetadata.overlay(message) == message)
    }

    // MARK: session/to-session-error.ts

    private struct NotSent: CoreSessionErrorMapping.MachineFailure {
        var machineMessage: String { "gpu is unreachable" }
    }

    private struct EnvFailed: CoreSessionErrorMapping.CauseWrapping {
        let wrappedCause: (any Error)?
    }

    private struct WrappedToolFailure: CoreSessionErrorMapping.ToolFailureCause {
        let toolMessage: String
        let toolCause: (any Error)?
    }

    @Test("ChatGPT workspace limits and machine failures map to their session errors")
    func toSessionError() {
        let workspace = AISchema.AIError(reason: .rateLimit(AISchema.RateLimitError(
            message: "limit",
            body: #"{"error":{"code":"subscription_sharing_workplace_individual_usage_limit_exceeded"}}"#
        )))
        let mapped = CoreSessionErrorMapping.toSessionError(workspace)
        #expect(mapped.type == "provider.chatgpt-workspace-limit")

        let machine = CoreSessionErrorMapping.toSessionError(WrappedToolFailure(
            toolMessage: "Command failed",
            toolCause: EnvFailed(wrappedCause: NotSent())
        ))
        #expect(machine == SessionErrorSchema.Error(type: "tool.execution", message: "gpu is unreachable"))

        let bare = CoreSessionErrorMapping.toSessionError(WrappedToolFailure(toolMessage: "Command failed", toolCause: nil))
        #expect(bare == SessionErrorSchema.Error(type: "tool.execution", message: "Command failed"))
    }

    // MARK: session/runner/model.ts

    @Test("defaultSelect prefers the session's model, then the agent's, then the fallback")
    func runnerModelSelect() async throws {
        let available = [
            ModelSchema.Info.default(providerID: ProviderSchema.ID(rawValue: "p"), id: ModelSchema.ID(rawValue: "a")),
            ModelSchema.Info.default(providerID: ProviderSchema.ID(rawValue: "p"), id: ModelSchema.ID(rawValue: "b")),
        ]
        let sessionID = try SessionID(validating: "ses_select")
        let withModel = sessionInfo(id: sessionID, model: SessionSchema.ModelRef(id: "b", providerID: "p", variant: "high"))
        let picked = try await CoreSessionRunnerModel.defaultSelect(session: withModel, available: { available })
        #expect(picked.info.id.rawValue == "b")
        #expect(picked.variant == "high")

        let bare = sessionInfo(id: sessionID, model: nil)
        let agentPick = try await CoreSessionRunnerModel.defaultSelect(
            session: bare,
            available: { available },
            agentModel: SessionSchema.ModelRef(id: "a", providerID: "p")
        )
        #expect(agentPick.info.id.rawValue == "a")

        await #expect(throws: CoreSessionRunnerModel.ModelNotSelectedError.self) {
            _ = try await CoreSessionRunnerModel.defaultSelect(session: bare, available: { available })
        }
        let missing = sessionInfo(id: sessionID, model: SessionSchema.ModelRef(id: "zzz", providerID: "p"))
        await #expect(throws: CoreSessionRunnerModel.ModelUnavailableError.self) {
            _ = try await CoreSessionRunnerModel.defaultSelect(session: missing, available: { available })
        }
    }

    private func sessionInfo(id: SessionID, model: SessionSchema.ModelRef?) -> SessionSchema.Info {
        SessionSchema.Info(
            id: id,
            projectID: ProjectID.global,
            model: model,
            cost: 0,
            tokens: .zero,
            time: SessionSchema.Info.Time(created: 1, updated: 1),
            location: OpenCodeLocation(directory: "/workspace")
        )
    }

    // MARK: variant.ts

    @Test("Toggle-only Google Interactions models switch between minimal and high thinking")
    func googleInteractionsToggleVariants() {
        let gemma = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gemma-4"),
            modelID: ModelSchema.ID(rawValue: "gemma-4"),
            providerID: ProviderSchema.ID(rawValue: "google"),
            name: "Gemma 4",
            package: "@opencode/ai/providers/google/interactions",
            capabilities: ModelSchema.Capabilities.default(),
            variants: [],
            time: ModelSchema.Info.Time(released: 1),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 128_000, output: 8_000)
        )
        let variants = CoreModel.Variant.resolve(gemma, supports: [.toggle])
        #expect(variants.map(\.id.rawValue) == ["none", "thinking"])
        #expect(variants.first?.settings?.extra["thinkingLevel"] == .string("minimal"))
        #expect(variants.last?.settings?.extra["thinkingLevel"] == .string("high"))

        // A model that also takes effort levels keeps its effort variants and no toggle.
        let effort = CoreModel.Variant.resolve(gemma, supports: [.toggle, .effort(values: ["low", "high"])])
        #expect(effort.map(\.id.rawValue) == ["low", "high"])
    }

    // MARK: job.ts, job/list.ts

    @Test("Jobs publish experimental.job.updated when started in the background and when they end")
    func jobUpdatedEvents() async throws {
        let db = try SQLiteDatabaseFactory.open(path: ":memory:")
        let bus = CoreBus.Service(db: db)
        let seen = Mutex<[JSONValue]>([])
        let unsubscribe = bus.listen { event in
            guard event.type == "experimental.job.updated", case .ephemeral(let envelope) = event else { return }
            seen.withLock { $0.append(envelope.data) }
        }
        defer { unsubscribe() }

        let jobs = try CoreJob.make(database: db, bus: bus)
        let sessionID = try SessionID(validating: "ses_jobs")
        _ = try await jobs.start(CoreJob.StartInput(
            id: "job_video",
            type: "video",
            recovery: .video(sessionID: sessionID, path: "clip.mp4", videoID: "vid_1"),
            background: true,
            run: { "Saved clip.mp4" }
        ))
        _ = await jobs.wait(CoreJob.WaitInput(id: "job_video", timeoutMs: 2_000))
        for _ in 0..<50 where seen.withLock({ $0.count }) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let infos = seen.withLock { $0 }.compactMap { data -> JSONValue? in
            guard case .object(let obj) = data else { return nil }
            return obj["info"]
        }
        #expect(infos.count == 2)
        for info in infos {
            guard case .object(let obj) = info else { continue }
            #expect(obj["kind"] == .string("video"))
            #expect(obj["path"] == .string("clip.mp4"))
        }
        if case .object(let last) = infos.last {
            #expect(last["status"] == .string("completed"))
        }

        let listed = try await jobs.backgroundJobs()
        #expect(listed.contains { if case .video(let video) = $0 { return video.path == "clip.mp4" }; return false })
    }
}
