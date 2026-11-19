#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - session/recent-text.ts

/// Formats projected session messages into verbatim recent-context text for summary checkpoints
/// (`packages/core/src/session/recent-text.ts`).
public enum CoreSessionRecentText {
    public static let toolOutputMaxChars: Int = 1_250

    // parity: core/src/session/recent-text.ts#kept [status=implemented hash=d0484055cb03]
    public static func kept(_ message: SessionMessageSchema.Compaction) -> String? {
        guard case .completed(let comp) = message else { return nil }
        guard case .string(let text) = comp.metadata?["recent"] else { return "" }
        return text
    }

    // parity: core/src/session/recent-text.ts#truncateToolOutput [status=implemented hash=a2461897e72a]
    public static func truncateToolOutput(_ value: String) -> String {
        if value.utf16.count <= toolOutputMaxChars { return value }
        var keptCount = 0
        var scalarEnd = value.unicodeScalars.startIndex
        while scalarEnd < value.unicodeScalars.endIndex && keptCount < toolOutputMaxChars {
            scalarEnd = value.unicodeScalars.index(after: scalarEnd)
            keptCount += 1
        }
        if scalarEnd == value.unicodeScalars.endIndex { return value }
        return "\(String(value.unicodeScalars[..<scalarEnd]))\n[truncated]"
    }

    // parity: core/src/session/recent-text.ts#serializeToolContent [status=implemented hash=9d38058db9b1]
    public static func serializeToolContent(_ content: [SessionMessageSchema.ToolContent]) -> String {
        content.map { item -> String in
            switch item {
            case .text(let text):
                return text
            case .file(_, let mime, let name):
                let nameSuffix = name.map { ": \($0)" } ?? ""
                return "[Attached \(mime)\(nameSuffix)]"
            }
        }.joined(separator: "\n")
    }

    // parity: core/src/session/recent-text.ts#messageToText [status=implemented hash=c0d5385c3ada]
    public static func messageToText(_ message: SessionMessageSchema.Info) -> String {
        switch message {
        case .compaction, .system, .agentSelected, .modelSelected, .idle:
            return ""

        case .user(let u):
            var lines: [String] = []
            for skill in u.skills ?? [] {
                if let text = skill.text {
                    lines.append("[Skill activated: \(skill.name)]\n\(text)")
                }
            }
            lines.append("[User]: \(u.text)")
            for file in u.files ?? [] {
                let sourceLabel: String = switch file.source {
                case .uri(let uri): uri
                case .inline: "inline attachment"
                }
                lines.append("[Attached \(file.mime): \(file.name ?? sourceLabel)]")
            }
            return lines.joined(separator: "\n")

        case .locationSwitched(let loc):
            return "[User]: The working directory has been changed to \(loc.location.directory)."

        case .assistant(let a):
            return a.content.flatMap { part -> [String] in
                switch part {
                case .text(let t):
                    return ["[Assistant]: \(t.text)"]
                case .reasoning:
                    return []
                case .tool(let tool):
                    let inputStr: String = switch tool.state {
                    case .streaming(let s): s.input
                    case .running(let r): (try? CoreBusJSON.encodeJSONValue(.object(r.input))) ?? "{}"
                    case .completed(let c): (try? CoreBusJSON.encodeJSONValue(.object(c.input))) ?? "{}"
                    case .error(let e): (try? CoreBusJSON.encodeJSONValue(.object(e.input))) ?? "{}"
                    }
                    let call = "[Assistant tool call]: \(tool.name)(\(inputStr))"
                    switch tool.state {
                    case .completed(let c):
                        return [call, "[Tool result]: \(truncateToolOutput(serializeToolContent(c.content)))"]
                    case .error(let e):
                        return [call, "[Tool error]: \(e.error.message)"]
                    case .streaming, .running:
                        return [call]
                    }
                }
            }.joined(separator: "\n")

        case .synthetic(let s):
            return "[Synthetic context]: \(s.text)"

        case .skill(let s):
            return "[Skill activated: \(s.name)]\n\(s.text)"

        case .shell(let sh):
            if case .bool(true) = sh.metadata?["background"] { return "" }
            return "[Shell]: \(sh.command)\n\(truncateToolOutput(sh.output?.output ?? ""))"
        }
    }
}

// MARK: - session/compaction.ts

/// Context compaction engine supporting native provider compaction and structured summary checkpoints,
/// token budgeting, and background precomputation (`packages/core/src/session/compaction.ts`).
public enum CoreSessionCompaction {
    public static let reserveMin: Int = 16_000
    public static let reserveShare: Double = 0.15
    public static let unknownWindow: Int = 200_000
    public static let shrinkSteps: [Double] = [0.85, 0.7, 0.5, 0.35]
    public static let imageTokenEstimate: Int = 1_500
    public static let pdfTokenEstimate: Int = 2_000

    public static let summaryTemplate = """
    You MUST use this format for your response (you may omit sections that aren't applicable). Do not include the <template> tags in your response.
    <template>
    ## Objective
    - [one or two brief sentences describing what the user is trying to accomplish]

    ## Requirements
    - [constraints, preferences, requirements, and scope boundaries stated by the user, or "(none)"]

    ## Decisions
    - [decisions already made and why, or "(none)"]

    ## Work State
    Break the objective into smaller goals and report which are completed, which are being worked on, and which are blocked.
    ### Completed
    - [goals that have been completed; otherwise "(none)"]

    ### Active
    - [goals currently being worked on; otherwise "(none)"]

    ### Blocked
    - [anything blocking progress, and why; otherwise "(none)"]

    ## Next Move
    1. [ordered list of next actions, or "(none)"]

    ## Relevant Files
    List the files and directories, other than the current working directory, that another agent would need to open to continue this work. Include at most 15, most important first. Do not list every file that was read or changed. Include paths outside the current working directory when relevant. If none, write "(none)".
    - `[file or directory path]`: [brief reason it matters]

    ## Important Context
    - [facts the next agent cannot continue without and cannot easily find on its own; or "(none)"]
    </template>
    """

    public static let summaryRules = """
    Rules:
    - Keep each section concise. Use terse, single-line bullets, not prose paragraphs or nested lists.
    - Prefer short references over detailed restatement. It is fine to leave out information the next agent can recover from the code or the files listed above.
    - Preserve exact file paths, symbols, commands, error strings, URLs, and identifiers.
    - Carry forward only user questions or requests that remain unanswered or require further action. Do not repeat ones that newer history has answered or resolved. Preserve exact wording when carrying one forward.
    - Preserve consequential workflow state, including whether changes are uncommitted, committed, pushed, under review, or merged.
    - Do not mention the summary process or that context was compacted.
    """

    public typealias Context = CoreSessionContext.Loaded

    public enum BufferSpec: Equatable, Hashable, Sendable {
        case tokens(Int)
        case percent(String)
    }

    // parity: core/src/session/compaction.ts#Settings [status=implemented hash=0fd4641b7cf2]
    public struct Settings: Equatable, Hashable, Sendable {
        public var auto: Bool
        public var buffer: BufferSpec?
        public var keep: Int
        public var background: Bool

        public init(
            auto: Bool = true,
            buffer: BufferSpec? = nil,
            keep: Int = 15_000,
            background: Bool = true
        ) {
            self.auto = auto
            self.buffer = buffer
            self.keep = keep
            self.background = background
        }
    }

    // parity: core/src/session/compaction.ts#Editor [status=implemented hash=1aa20741d14c]
    public struct Editor: Sendable {
        private let updateFn: @Sendable (Settings) -> Void

        public init(configure: @escaping @Sendable (Settings) -> Void) {
            self.updateFn = configure
        }

        public func configure(_ settings: Settings) {
            updateFn(settings)
        }
    }

    // parity: core/src/session/compaction.ts#Estimate [status=implemented hash=6e4eaa8b059c]
    public struct Estimate: Equatable, Hashable, Sendable {
        public let measured: Int
        public let estimated: Int

        public init(measured: Int, estimated: Int) {
            self.measured = measured
            self.estimated = estimated
        }

        public var total: Int { measured + estimated }
    }

    public enum TriggerReason: String, Equatable, Hashable, Sendable, Codable {
        case auto
        case manual
        case overflow

        public var eventReason: SessionMessageSchema.CompactionReason {
            switch self {
            case .manual: .manual
            case .auto, .overflow: .auto
            }
        }
    }

    public struct CompactInput: Sendable {
        public let reason: TriggerReason
        public let inputID: SessionMessageSchema.ID?
        public let context: Context
        public let estimate: Estimate?

        public init(
            reason: TriggerReason,
            inputID: SessionMessageSchema.ID? = nil,
            context: Context,
            estimate: Estimate? = nil
        ) {
            self.reason = reason
            self.inputID = inputID
            self.context = context
            self.estimate = estimate
        }
    }

    // parity: core/src/session/compaction.ts#Trigger [status=implemented hash=7dab85c52cfc]
    public typealias Trigger = CompactInput

    // parity: core/src/session/compaction.ts#Outcome [status=implemented hash=750e7b7aaaf4]
    public enum Outcome: Equatable, Sendable {
        case skipped
        case completed
        case failed(error: SessionErrorSchema.Error)

        public var didCompact: Bool {
            if case .completed = self { return true }
            return false
        }
    }

    // parity: core/src/session/compaction.ts#Interface [status=implemented hash=f930bfe1e0f6]
    public protocol Interface: Sendable {
        func settings() -> Settings
        func configure(_ update: (inout Settings) -> Void)
        func compact(_ trigger: Trigger) async throws -> Outcome
        func precompute(_ load: @escaping @Sendable () async throws -> Context, estimate: Estimate?) async
    }

    // parity: core/src/session/compaction.ts#buildPrompt [status=implemented hash=8f5ddad2b668]
    public static func buildPrompt(update: Bool, legacy: Bool = false) -> String {
        let shared = [
            "Summarize only what the user and the assistant said and did. Leave out instructions and setup the assistant was given rather than told by the user: repository conventions, instruction files such as AGENTS.md, and environment details like the session ID. The next agent receives current versions of all of these separately.",
            summaryTemplate,
            summaryRules,
            "Do not continue the task or call tools.",
            "Return only the structured summary in the requested format. Do not include a preamble, explanation, or other commentary.",
        ]
        if !update {
            return ([
                "You MUST summarize the conversation above into a structured summary that will be given to another agent to resume the work.",
            ] + shared).joined(separator: "\n\n")
        }
        var lines = [
            "Update the existing checkpoint in the conversation above into one consolidated summary.",
        ]
        if legacy {
            lines.append("The existing checkpoint was written with an earlier format that recorded far more detail than this one asks for. Rewrite it at the level of detail described below rather than carrying its detail forward. Keep its requirements, decisions, and open questions; they came from earlier conversation with the user.")
        }
        lines.append("Newer history always takes precedence over the existing checkpoint. Preserve previous information unless newer history clearly contradicts, supersedes, resolves, or makes it stale. If something is no longer relevant to continuing the work, you may remove it.")
        lines.append("Incorporate newer requirements, decisions, progress, and context. Reconcile Work State and Next Move: move completed work out of Active, remove resolved blockers and answered questions, and preserve unresolved or pending work.")
        lines.append("Return only the updated Markdown sections. Do not reproduce the `<conversation-checkpoint>`, `<summary>`, or `<recent-context>` wrapper tags from the previous checkpoint.")
        return (lines + shared).joined(separator: "\n\n")
    }

    private static func estimateTextTokens(_ text: String) -> Int {
        max(0, (text.utf8.count + 3) / 4)
    }

    private static func estimateMessageTokens(_ message: AISchema.Message) -> Int {
        var tokens = 4
        for part in message.contentParts {
            switch part {
            case .text(let t):
                tokens += estimateTextTokens(t.text)
            case .reasoning(let r):
                tokens += estimateTextTokens(r.text)
            case .media(let m):
                tokens += m.media.mediaType == "application/pdf" ? pdfTokenEstimate : imageTokenEstimate
            case .toolCall(let c):
                let inputStr = (try? CoreBusJSON.encodeJSONValue(c.input)) ?? ""
                tokens += estimateTextTokens(c.name) + estimateTextTokens(inputStr)
            case .toolResult(let r):
                switch r.result {
                case .content(let items):
                    for item in items {
                        switch item {
                        case .text(let t): tokens += estimateTextTokens(t.text)
                        case .file(let f): tokens += f.mime == "application/pdf" ? pdfTokenEstimate : imageTokenEstimate
                        }
                    }
                case .text(let v), .json(let v), .error(let v):
                    tokens += estimateTextTokens((try? CoreBusJSON.encodeJSONValue(v)) ?? "")
                }
            case .compaction(let c):
                if let text = c.text { tokens += estimateTextTokens(text) }
            case .effort:
                break
            }
        }
        return tokens
    }

    private static func oldestToDrop(_ messages: [AISchema.Message], keepBudget: Int) -> Int {
        var remaining = 0
        var startIdx = messages.count
        for idx in stride(from: messages.count - 1, through: 0, by: -1) {
            let cost = estimateMessageTokens(messages[idx])
            if remaining + cost > keepBudget {
                break
            }
            remaining += cost
            startIdx = idx
        }
        return startIdx
    }

    // parity: core/src/session/compaction.ts#recentUserMessages [status=implemented hash=6290accd44de]
    public static func recentUserMessages(
        _ messages: [SessionMessageSchema.Info],
        model: CoreSessionRunnerModel.Resolved,
        keep: Int
    ) -> [AISchema.Message] {
        let users: [SessionMessageSchema.Info] = messages.compactMap { msg in
            guard case .user(let u) = msg else { return nil }
            return .user(SessionMessageSchema.User(
                id: u.id,
                metadata: u.metadata,
                time: u.time,
                text: u.text,
                files: u.files,
                agents: u.agents,
                skills: nil
            ))
        }
        let sendable = CoreSessionModelRequest.boundImages(
            CoreSessionModelRequest.unsupportedParts(
                CoreSessionToLLMMessage.toLLMMessages(users, model: model.ref),
                capabilities: model.capabilities
            )
        )
        let dropIdx = oldestToDrop(sendable, keepBudget: keep)
        return Array(sendable[dropIdx...])
    }

    private static func hasMeasuredPrompt(_ message: SessionMessageSchema.Info, model: SessionSchema.ModelRef) -> Bool {
        guard case .assistant(let a) = message else { return false }
        return a.model.providerID == model.providerID
            && a.error == nil
            && a.tokens != nil
            && a.time.completed != nil
    }

    // parity: core/src/session/compaction.ts#estimatePrompt [status=implemented hash=fa4c5b4989e9]
    public static func estimatePrompt(_ context: Context) -> Estimate {
        let anchorIndex = context.messages.lastIndex { hasMeasuredPrompt($0, model: context.model.ref) }
        let slice = anchorIndex.map { Array(context.messages[$0...]) } ?? context.messages
        let base = CoreSessionModelRequest.baseTranscript(
            agent: context.agent,
            model: context.model,
            tools: context.tools,
            initial: context.initial,
            messages: slice
        )
        let sent = CoreSessionModelRequest.boundImages(
            CoreSessionModelRequest.unsupportedParts(base.messages, capabilities: context.model.capabilities)
        )
        let anchor = anchorIndex.map { context.messages[$0] }
        let unmeasured = sent.filter { msg in
            if case .assistant(let a) = msg, let anchorID = anchor?.id.rawValue, a.id == anchorID {
                return false
            }
            return true
        }

        guard let anchor, case .assistant(let assistant) = anchor, let tokens = assistant.tokens else {
            let sysTokens = base.system.reduce(0) { $0 + estimateTextTokens($1.text) }
            let msgTokens = unmeasured.reduce(0) { $0 + estimateMessageTokens($1) }
            return Estimate(measured: 0, estimated: sysTokens + msgTokens)
        }

        let measured = Int(tokens.input + tokens.cache.read + tokens.cache.write + tokens.output + tokens.reasoning)
        let estimated = unmeasured.reduce(0) { $0 + estimateMessageTokens($1) }
        return Estimate(measured: measured, estimated: estimated)
    }

    // parity: core/src/session/compaction.ts#estimateContext [status=implemented hash=fc4297eaceb8]
    public static func estimateContext(_ context: Context) -> Int {
        estimatePrompt(context).total
    }

    private static func inputWindow(_ limit: ModelSchema.Info.Limit) -> Int {
        if let input = limit.input, input > 0, limit.context > 0 {
            return min(input, limit.context)
        }
        return limit.input ?? limit.context
    }

    private static func calculateCeiling(_ limit: ModelSchema.Info.Limit, buffer: BufferSpec?) -> Int? {
        let window = inputWindow(limit)
        guard window > 0 else { return nil }
        if let buffer {
            let bufTokens: Int
            switch buffer {
            case .tokens(let n):
                bufTokens = n
            case .percent(let raw):
                let parsed = Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) ?? 0
                bufTokens = Int((Double(window) * parsed / 100.0).rounded())
            }
            if bufTokens < window {
                return window - bufTokens
            }
        }
        let share = Int(floor(Double(window) * reserveShare))
        let floorMin = window >= 2 * reserveMin ? reserveMin : 0
        return window - max(share, floorMin)
    }

    // parity: core/src/session/compaction.ts#Service [status=implemented hash=6909a3695915]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionCompaction"
        public let bus: CoreBus.Service
        public let llm: any AIRoute.Interface
        public let requests: any CoreSessionModelRequest.Interface
        private let state = Mutex<Settings>(Settings())

        public init(
            bus: CoreBus.Service,
            llm: any AIRoute.Interface,
            requests: any CoreSessionModelRequest.Interface = CoreSessionModelRequest.Service(),
            initial: Settings = Settings()
        ) {
            self.bus = bus
            self.llm = llm
            self.requests = requests
            self.state.withLock { $0 = initial }
        }

        public func settings() -> Settings {
            state.withLock { $0 }
        }

        public func configure(_ update: (inout Settings) -> Void) {
            state.withLock { update(&$0) }
        }

        public func precompute(
            _ load: @escaping @Sendable () async throws -> Context,
            estimate: Estimate? = nil
        ) async {
            let current = settings()
            guard current.auto && current.background else { return }
            _ = (load, estimate)
        }

        public func compact(_ trigger: Trigger) async throws -> Outcome {
            let current = settings()
            let ctx = trigger.context
            if trigger.reason != .manual && !current.auto {
                return .skipped
            }
            if trigger.reason == .auto {
                let est = trigger.estimate ?? CoreSessionCompaction.estimatePrompt(ctx)
                guard let ceiling = CoreSessionCompaction.calculateCeiling(ctx.model.limit, buffer: current.buffer),
                      est.total >= ceiling
                else {
                    return .skipped
                }
            }

            if ctx.messages.isEmpty {
                let err = SessionErrorSchema.Error(type: "compaction.unavailable", message: "Nothing to compact yet")
                if trigger.reason == .manual {
                    _ = try await bus.publish(
                        SessionEventSchema.Compaction.Failed,
                        data: SessionEventSchema.Compaction.FailedData(
                            sessionID: ctx.session.id,
                            reason: trigger.reason.eventReason,
                            error: err,
                            inputID: trigger.inputID
                        )
                    )
                }
                return .failed(error: err)
            }

            if trigger.reason != .manual {
                _ = try await bus.publish(
                    SessionEventSchema.Compaction.Started,
                    data: SessionEventSchema.Compaction.StartedData(
                        sessionID: ctx.session.id,
                        reason: .auto
                    )
                )
            }

            let isNative = ctx.model.compaction == .native
            let transcript = CoreSessionModelRequest.baseTranscript(
                agent: ctx.agent,
                model: ctx.model,
                tools: ctx.tools,
                initial: ctx.initial,
                messages: ctx.messages
            )

            do {
                if isNative && AIRoute.canCompact(ctx.model.model, mechanism: "endpoint") {
                    let prepared = try await requests.compaction(CoreSessionModelRequest.Input(
                        session: ctx.session,
                        agent: ctx.agent.id,
                        model: ctx.model,
                        system: transcript.system,
                        messages: transcript.messages
                    ))
                    let res = try await llm.compact(prepared.request, options: .endpoint(nil))
                    switch res {
                    case .endpoint(let comp):
                        let recorded = CoreSessionUsage.record(comp.usage, costs: ctx.model.cost)
                        let nativeMessages = try CoreBusJSON.encodeToJSONValue(comp.replacement)
                        _ = try await bus.publish(
                            SessionEventSchema.Compaction.Ended,
                            data: SessionEventSchema.Compaction.EndedData(
                                sessionID: ctx.session.id,
                                reason: trigger.reason.eventReason,
                                model: ctx.model.ref,
                                native: ["messages": nativeMessages],
                                text: "",
                                cost: recorded.cost,
                                tokens: recorded.tokens
                            )
                        )
                        return .completed
                    case .trigger:
                        break
                    }
                }

                let hasPriorCompaction = ctx.messages.contains {
                    if case .compaction(.completed) = $0 { return true }
                    return false
                }
                let prompt = CoreSessionCompaction.buildPrompt(update: hasPriorCompaction)
                let prepared = try await requests.compaction(CoreSessionModelRequest.Input(
                    session: ctx.session,
                    agent: ctx.agent.id,
                    model: ctx.model,
                    system: transcript.system,
                    messages: transcript.messages + [AISchema.Message.user(prompt)]
                ))

                var summaryText = ""
                var usageRecorded: CoreSessionUsage.Recorded? = nil
                let stream = llm.stream(prepared.request, options: prepared.options)
                for try await event in stream {
                    switch event {
                    case .textDelta(let d):
                        summaryText += d.text
                        await bus.emit(
                            SessionEventSchema.Compaction.Delta,
                            data: SessionEventSchema.Compaction.DeltaData(sessionID: ctx.session.id, text: d.text)
                        )
                    case .textEnd(let e):
                        if let t = e.text, summaryText.isEmpty { summaryText = t }
                    case .stepFinish(let f):
                        let step = CoreSessionUsage.record(f.usage, costs: ctx.model.cost)
                        usageRecorded = usageRecorded.map { CoreSessionUsage.add($0, step) } ?? step
                    case .finish(let f):
                        if usageRecorded == nil, let u = f.usage {
                            usageRecorded = CoreSessionUsage.record(u, costs: ctx.model.cost)
                        }
                    default:
                        break
                    }
                }

                let trimmed = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await bus.publish(
                    SessionEventSchema.Compaction.Ended,
                    data: SessionEventSchema.Compaction.EndedData(
                        sessionID: ctx.session.id,
                        reason: trigger.reason.eventReason,
                        model: ctx.model.ref,
                        text: trimmed,
                        cost: usageRecorded?.cost,
                        tokens: usageRecorded?.tokens
                    )
                )
                return .completed
            } catch {
                let err = CoreSessionErrorMapping.toSessionError(error)
                _ = try await bus.publish(
                    SessionEventSchema.Compaction.Failed,
                    data: SessionEventSchema.Compaction.FailedData(
                        sessionID: ctx.session.id,
                        reason: trigger.reason.eventReason,
                        error: err,
                        inputID: trigger.inputID
                    )
                )
                return .failed(error: err)
            }
        }
    }

    // parity: core/src/session/compaction.ts#layer [status=adapted hash=0a40983029d7]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        guard let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
              let llm = deps.get(AIRoute.LLMClientService.serviceID, as: (any AIRoute.Interface).self)
        else {
            throw SQLiteError.databaseClosed
        }
        let req = deps.get(CoreSessionModelRequest.Service.serviceKey, as: (any CoreSessionModelRequest.Interface).self)
            ?? CoreSessionModelRequest.Service()
        return LayerNode.Output([Service.serviceKey: Service(bus: bus, llm: llm, requests: req)])
    }

    // parity: core/src/session/compaction.ts#node [status=adapted hash=b2d01160048e]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        layer,
        [CoreBus.node, CoreSessionModelRequest.node]
    )
}

// MARK: - session/title.ts

/// Automatic session title generation from first user message or bounded conversation history
/// (`packages/core/src/session/title.ts`).
public enum CoreSessionTitle {
    public static let maxLength: Int = 100
    public static let maxContextLength: Int = 8_000
    public static let maxFirstMessageLength: Int = 2_000

    // parity: core/src/session/title.ts#Interface [status=implemented hash=0580cc21e8ef]
    public protocol Interface: Sendable {
        func generate(_ sessionID: SessionID) async throws
        func ensure(_ sessionID: SessionID) async throws
    }

    // parity: core/src/session/title.ts#isUntitled [status=implemented hash=aed16e0bae4e]
    public static func isUntitled(_ session: SessionSchema.Info) -> Bool {
        SessionTitleFallback.isExactRootFallback(title: session.title, created: session.time.created)
    }

    public static func isUntitled(_ title: String?) -> Bool {
        guard let title else { return true }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func truncate(_ value: String) -> String {
        if value.utf16.count <= maxLength { return value }
        return "\(TextBoundary.head(value, limit: maxLength - 3))..."
    }

    private static func messagePrompt(_ text: String) -> String {
        "Here is the first message of the conversation:\n\n<message>\n\(text)\n</message>\n\nReply with only the title."
    }

    private static func conversationPrompt(_ text: String) -> String {
        "Here is the conversation so far:\n\n<conversation>\n\(text)\n</conversation>\n\nReply with only the title."
    }

    // parity: core/src/session/title.ts#Service [status=implemented hash=8e03c2af16f6]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionTitle"
        public let db: any SQLiteDatabase
        public let bus: CoreBus.Service
        public let store: any CoreSessionStore.Interface
        public let context: any CoreSessionContext.Interface
        public let llm: any AIRoute.Interface

        public init(
            db: any SQLiteDatabase,
            bus: CoreBus.Service,
            store: any CoreSessionStore.Interface,
            context: any CoreSessionContext.Interface,
            llm: any AIRoute.Interface
        ) {
            self.db = db
            self.bus = bus
            self.store = store
            self.context = context
            self.llm = llm
        }

        public func ensure(_ sessionID: SessionID) async throws {
            guard let session = try store.get(sessionID),
                  CoreSessionTitle.isUntitled(session)
            else { return }
            try await generate(sessionID)
        }

        public func generate(_ sessionID: SessionID) async throws {
            guard let session = try store.get(sessionID),
                  let firstUser = try CoreSessionHistory.firstUserMessage(db, sessionID: sessionID),
                  let titleSel = try await context.selectTitle(session)
            else { return }

            let promptText: String
            if CoreSessionTitle.isUntitled(session) {
                promptText = CoreSessionTitle.messagePrompt(
                    TextBoundary.head(firstUser.text, limit: CoreSessionTitle.maxFirstMessageLength)
                )
            } else {
                let messages = try store.context(sessionID)
                let original = "Original request:\n\(TextBoundary.head(firstUser.text, limit: CoreSessionTitle.maxFirstMessageLength))"
                let recent = messages.compactMap { msg -> String? in
                    switch msg {
                    case .user(let u) where u.id != firstUser.id:
                        return "User: \(u.text.trimmingCharacters(in: .whitespacesAndNewlines))"
                    case .assistant(let a):
                        let txt = a.content.compactMap { part -> String? in
                            if case .text(let t) = part {
                                let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                return trimmed.isEmpty ? nil : trimmed
                            }
                            return nil
                        }.joined(separator: "\n")
                        return txt.isEmpty ? nil : "Assistant: \(txt)"
                    default:
                        return nil
                    }
                }.joined(separator: "\n\n")
                if recent.isEmpty {
                    promptText = CoreSessionTitle.conversationPrompt(original)
                } else {
                    let prefix = "\(original)\n\nRecent conversation:\n"
                    let budget = max(
                        256,
                        CoreSessionTitle.maxContextLength
                            - CoreSessionTitle.conversationPrompt("").utf16.count
                            - prefix.utf16.count
                    )
                    promptText = CoreSessionTitle.conversationPrompt("\(prefix)\(TextBoundary.tail(recent, limit: budget))")
                }
            }

            let prepared = try await context.request.title(CoreSessionModelRequest.Input(
                session: session,
                agent: titleSel.agent.id,
                model: titleSel.selected,
                system: titleSel.agent.system.map { [AISchema.SystemPart.make($0)] } ?? [],
                messages: [AISchema.Message.user(promptText)]
            ))

            var text = ""
            var usage: CoreSessionUsage.Recorded? = nil
            do {
                let stream = llm.stream(prepared.request, options: prepared.options)
                for try await event in stream {
                    switch event {
                    case .textDelta(let d):
                        text += d.text
                    case .stepFinish(let f):
                        let step = CoreSessionUsage.record(f.usage, costs: titleSel.selected.cost)
                        usage = usage.map { CoreSessionUsage.add($0, step) } ?? step
                    case .finish(let f):
                        if usage == nil, let u = f.usage {
                            usage = CoreSessionUsage.record(u, costs: titleSel.selected.cost)
                        }
                    default:
                        break
                    }
                }
            } catch {
                if let usage {
                    _ = try? await bus.publish(
                        SessionEventSchema.UsageRecorded,
                        data: SessionEventSchema.UsageRecordedData(
                            sessionID: sessionID,
                            source: .title,
                            cost: usage.cost,
                            tokens: usage.tokens
                        )
                    )
                }
                return
            }

            if let usage {
                _ = try await bus.publish(
                    SessionEventSchema.UsageRecorded,
                    data: SessionEventSchema.UsageRecordedData(
                        sessionID: sessionID,
                        source: .title,
                        cost: usage.cost,
                        tokens: usage.tokens
                    )
                )
            }

            let candidate = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            guard let candidate else { return }

            let finalTitle = CoreSessionTitle.truncate(candidate)
            _ = try await bus.publish(
                SessionEventSchema.Renamed,
                data: SessionEventSchema.RenamedData(sessionID: sessionID, title: finalTitle)
            )
        }
    }

    // parity: core/src/session/title.ts#layer [status=adapted hash=0ee6672882e9]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
              let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
              let store = deps.get(CoreSessionStore.Service.serviceKey, as: CoreSessionStore.Service.self),
              let context = deps.get(CoreSessionContext.Service.serviceKey, as: (any CoreSessionContext.Interface).self),
              let llm = deps.get(AIRoute.LLMClientService.serviceID, as: (any AIRoute.Interface).self)
        else {
            throw SQLiteError.databaseClosed
        }
        return LayerNode.Output([Service.serviceKey: Service(db: db, bus: bus, store: store, context: context, llm: llm)])
    }

    // parity: core/src/session/title.ts#node [status=adapted hash=af1144b1d0fc]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        layer,
        [CoreDatabaseStore.node, CoreBus.node, CoreSessionStore.node, CoreSessionContext.node]
    )
}

// MARK: - session/generate.ts

/// Non-mutating generation from current session context (`packages/core/src/session/generate.ts`).
public enum CoreSessionGenerate {
    // parity: core/src/session/generate.ts#Error [status=implemented hash=f10d72e8edf8]
    public typealias GenerateError = any Error

    // parity: core/src/session/generate.ts#Result [status=implemented hash=a7d97fcd5009]
    public struct Result: Equatable, Hashable, Sendable, Codable {
        public let text: String
        public let tokens: SessionSchema.TokenUsage
        public let cost: Double

        public init(text: String, tokens: SessionSchema.TokenUsage, cost: Double) {
            self.text = text
            self.tokens = tokens
            self.cost = cost
        }
    }

    // parity: core/src/session/generate.ts#generate [status=implemented hash=76e9424f0d7d]
    public static func generate(
        session: SessionSchema.Info,
        prompt: String,
        db: any SQLiteDatabase,
        bus: CoreBus.Service,
        context: any CoreSessionContext.Interface,
        llm: any AIRoute.Interface
    ) async throws -> Result {
        let selection = try await context.select(session.id)
        let model = try await context.resolveModel(selection.session, kind: .generate, agent: selection.agent.id)
        let preview = try CoreSessionHistory.preview(
            db,
            sessionID: selection.session.id,
            instructions: selection.instructions,
            boundary: .model(model.ref)
        )
        let transcript = CoreSessionModelRequest.baseTranscript(
            agent: selection.agent,
            model: model,
            tools: selection.tools,
            initial: preview.initial,
            messages: preview.messages
        )
        var messages = transcript.messages
        if !preview.instructionUpdate.isEmpty {
            messages.append(AISchema.Message.system(preview.instructionUpdate))
        }
        messages.append(AISchema.Message.user(prompt))

        let prepared = try await context.request.generate(CoreSessionModelRequest.Input(
            session: selection.session,
            agent: selection.agent.id,
            model: model,
            tools: selection.tools,
            system: transcript.system,
            messages: messages
        ))
        let response = try await llm.generate(prepared.request, options: prepared.options)
        let recorded = CoreSessionUsage.record(response.usage, costs: model.cost)
        _ = try await bus.publish(
            SessionEventSchema.UsageRecorded,
            data: SessionEventSchema.UsageRecordedData(
                sessionID: selection.session.id,
                source: .generate,
                cost: recorded.cost,
                tokens: recorded.tokens
            )
        )
        return Result(text: response.text, tokens: recorded.tokens, cost: recorded.cost)
    }
}
