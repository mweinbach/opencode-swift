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

// MARK: - session/to-session-error.ts

/// Structured error normalization (`packages/core/src/session/to-session-error.ts`).
public enum CoreSessionErrorMapping {
    private static let tokenSharingMessages: [String: String] = [
        "subscription_sharing_user_not_eligible":
            "ChatGPT token sharing isn't available for this account. Connect with an API key or choose another provider.",
        "subscription_sharing_usage_limit_exceeded":
            "ChatGPT usage limit reached. Check ChatGPT Settings → Usage for details.",
        "subscription_sharing_workplace_individual_usage_limit_exceeded":
            "You've reached the usage limit your ChatGPT workspace admin set for you. Ask them to raise it in the OpenAI Admin Console.",
        "subscription_sharing_usage_unavailable":
            "ChatGPT usage can't be checked right now. Try again later.",
        "subscription_sharing_unsupported_capability":
            "This request uses a feature ChatGPT token sharing doesn't support. Remove the unsupported feature and try again.",
        "subscription_sharing_route_not_supported":
            "ChatGPT token sharing doesn't support this API route. Check the configured endpoint and HTTP method.",
        "subscription_sharing_invalid_user":
            "This ChatGPT connection is no longer valid. Reconnect to ChatGPT.",
        "subscription_sharing_user_unavailable":
            "Your ChatGPT account is temporarily unavailable. Try again later.",
        "chatpass_v2_scope_not_authorized":
            "This ChatGPT connection isn't authorized for this request. Reconnect to ChatGPT or choose another connection.",
        "chatpass_v2_invalid_authorization_context":
            "This ChatGPT connection isn't authorized for this request. Reconnect to ChatGPT or choose another connection.",
    ]

    private static let freeUsageLimitMessage =
        "Free usage limit reached. Connect a provider or subscribe to OpenCode Go to keep going, or switch models."
    private static let budgetLimitMessage =
        "Workspace usage limit reached. Model use is paused until the limit resets."
    private static let modelBudgetLimitMessage =
        "You've reached the spend limit for this model. Switch models to keep going."

    private static func providerError(
        _ type: String,
        reason: AISchema.AIErrorReason,
        overrideMessage: String? = nil
    ) -> SessionErrorSchema.Error {
        let retryAfterMs: Int64? = {
            switch reason {
            case .rateLimit(let e): (e.retryAfterMs ?? e.rateLimit?.retryAfterMs).map(Int64.init)
            case .quotaExceeded(let e): e.retryAfterMs.map(Int64.init)
            case .providerInternal(let e): e.retryAfterMs.map(Int64.init)
            default: nil
            }
        }()
        var msg = overrideMessage ?? reason.message
        if overrideMessage == nil, let body = reason.body {
            for (code, friendly) in tokenSharingMessages where body.contains(code) {
                msg = friendly
                break
            }
        }
        return SessionErrorSchema.Error(
            type: type,
            message: msg,
            status: reason.http?.status,
            response: reason.body.map { SessionErrorSchema.Error.Response(body: $0) },
            retryAfterMs: retryAfterMs.map { max(0, $0) }
        )
    }

    /// A machine failure whose message says why (upstream `Machine.NotSent`, `Machine.Unknown`,
    /// `Machine.ProcessLost`, `Machines.NotFound`, `MachinePath.NotAbsolute`).
    public protocol MachineFailure: Swift.Error {
        var machineMessage: String { get }
    }

    /// A wrapper that keeps the cause it wraps (upstream `Environment.Failed`, `AppProcessError`, `PlatformError`),
    /// so a machine failure underneath still says why.
    public protocol CauseWrapping: Swift.Error {
        var wrappedCause: (any Swift.Error)? { get }
    }

    /// A tool failure that carries its underlying cause (upstream `ToolFailure` / `Tool.Error` with `error`).
    public protocol ToolFailureCause: Swift.Error {
        var toolMessage: String { get }
        var toolCause: (any Swift.Error)? { get }
    }

    /// The message of a machine failure, through the wrappers a tool may have put around it. A local failure has no
    /// machine error anywhere in its cause, so its text is untouched.
    static func machineMessage(_ error: (any Swift.Error)?) -> String? {
        guard let error else { return nil }
        if let machine = error as? any MachineFailure { return machine.machineMessage }
        if let wrapper = error as? any CauseWrapping { return machineMessage(wrapper.wrappedCause) }
        return nil
    }

    // parity: core/src/session/to-session-error.ts#toSessionError [status=implemented hash=73235299307f]
    public static func toSessionError(_ cause: any Error) -> SessionErrorSchema.Error {
        if let aiError = cause as? AISchema.AIError {
            // ChatGPT's usage limit arrives in HTTP and stream errors alike, whatever their reason, so its code decides the type.
            if aiError.reason.body?.contains("subscription_sharing_usage_limit_exceeded") == true {
                return providerError("provider.chatgpt-limit", reason: aiError.reason)
            }
            if aiError.reason.body?.contains("subscription_sharing_workplace_individual_usage_limit_exceeded") == true {
                return providerError("provider.chatgpt-workspace-limit", reason: aiError.reason)
            }
            switch aiError.reason {
            case .rateLimit:
                return providerError("provider.rate-limit", reason: aiError.reason)
            case .authentication:
                return providerError("provider.auth", reason: aiError.reason)
            case .quotaExceeded:
                if aiError.reason.body?.contains("FreeUsageLimitError") == true {
                    return providerError("provider.free-limit", reason: aiError.reason, overrideMessage: freeUsageLimitMessage)
                }
                if aiError.reason.body?.contains("BudgetLimitError") == true {
                    let isModelBudget = aiError.reason.body?.contains("\"coverage\"") == true
                        && aiError.reason.body?.contains("\"models\"") == true
                    return providerError(
                        isModelBudget ? "provider.model-budget-limit" : "provider.budget-limit",
                        reason: aiError.reason,
                        overrideMessage: isModelBudget ? modelBudgetLimitMessage : budgetLimitMessage
                    )
                }
                if aiError.reason.body?.contains("GoUsageLimitError") == true {
                    return providerError("provider.go-limit", reason: aiError.reason)
                }
                return providerError("provider.quota", reason: aiError.reason)
            case .contentPolicy:
                return providerError("provider.content-filter", reason: aiError.reason)
            case .transport:
                return providerError("provider.transport", reason: aiError.reason)
            case .providerInternal:
                return providerError("provider.internal", reason: aiError.reason)
            case .invalidProviderOutput:
                return providerError("provider.invalid-output", reason: aiError.reason)
            case .invalidRequest:
                return providerError("provider.invalid-request", reason: aiError.reason)
            case .unsupportedOperation:
                return providerError("provider.unsupported-operation", reason: aiError.reason)
            case .unknownProvider:
                return providerError("provider.unknown", reason: aiError.reason)
            case .timeout:
                return providerError("provider.timeout", reason: aiError.reason)
            }
        }
        if let stepFailed = cause as? CoreSessionErrors.StepFailedError {
            return stepFailed.error
        }
        if let structured = cause as? SessionErrorSchema.Error {
            return structured
        }
        if let toolErr = cause as? ToolSchema.ToolError {
            return SessionErrorSchema.Error(type: "tool.execution", message: toolErr.message)
        }
        if let failure = cause as? any ToolFailureCause {
            guard let inner = failure.toolCause else {
                return SessionErrorSchema.Error(type: "tool.execution", message: failure.toolMessage)
            }
            // A machine failure says why, however the tool wrapped it; every other cause keeps the tool's curated message.
            if let machine = machineMessage(inner) {
                return SessionErrorSchema.Error(type: "tool.execution", message: machine)
            }
            // The canonical error is the sole model-visible representation, so a cause with no message must not
            // erase the tool's curated failure message.
            let unwrapped = toSessionError(inner)
            guard unwrapped.message.isEmpty else { return unwrapped }
            return SessionErrorSchema.Error(
                type: "tool.execution",
                message: failure.toolMessage,
                status: unwrapped.status,
                response: unwrapped.response,
                retryAfterMs: unwrapped.retryAfterMs
            )
        }
        if let agentNotFound = cause as? CoreSessionErrors.AgentNotFoundError {
            return SessionErrorSchema.Error(type: "unknown", message: agentNotFound.message)
        }
        if let modelErr = cause as? CoreSessionRunnerModel.ModelNotSelectedError {
            return SessionErrorSchema.Error(type: "provider.no-route", message: modelErr.message)
        }
        if let modelErr = cause as? CoreSessionRunnerModel.ModelUnavailableError {
            return SessionErrorSchema.Error(type: "provider.no-route", message: modelErr.message)
        }
        if cause is CancellationError {
            return SessionErrorSchema.Error(type: "aborted", message: "Execution aborted")
        }
        return SessionErrorSchema.Error(type: "unknown", message: String(describing: cause))
    }

    // parity: core/src/session/to-session-error.ts#contentFilterError [status=implemented hash=0ebd833225c6]
    public static func contentFilterError(
        _ summary: String,
        reason: AISchema.FinishReasonDetails
    ) -> SessionErrorSchema.Error {
        let head = reason.category.map { "\(summary) (\($0))" } ?? summary
        let message = [head, reason.explanation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        return SessionErrorSchema.Error(type: "provider.content-filter", message: message)
    }
}

// MARK: - session/usage.ts

/// Token usage normalization and tiered cost accounting (`packages/core/src/session/usage.ts`).
public enum CoreSessionUsage {
    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func safe(_ value: Double?) -> Double {
        max(0, finite(value ?? 0))
    }

    // parity: core/src/session/usage.ts#tokens [status=implemented hash=2cc73906bf02]
    public static func tokens(_ usage: AISchema.Usage?) -> SessionSchema.TokenUsage {
        SessionSchema.TokenUsage(
            input: safe(usage?.nonCachedInputTokens),
            output: safe(usage?.visibleOutputTokens),
            reasoning: safe(usage?.reasoningTokens),
            cache: SessionSchema.TokenUsage.Cache(
                read: safe(usage?.cacheReadInputTokens),
                write: safe(usage?.cacheWriteInputTokens)
            )
        )
    }

    // parity: core/src/session/usage.ts#calculateCost [status=implemented hash=cd9d6bb14c32]
    public static func calculateCost(_ costs: [ModelSchema.Cost], usage: SessionSchema.TokenUsage) -> Double {
        let context = usage.input + usage.cache.read + usage.cache.write
        let matchingTier = costs
            .filter { cost in
                guard let tier = cost.tier else { return false }
                return context > Double(tier.size)
            }
            .sorted { ($0.tier?.size ?? 0) > ($1.tier?.size ?? 0) }
            .first
        let selected = matchingTier ?? costs.first(where: { $0.tier == nil })
        guard let selected else { return 0 }
        let total = (
            usage.input * finite(selected.input.rawValue) +
            (usage.output + usage.reasoning) * finite(selected.output.rawValue) +
            usage.cache.read * finite(selected.cache.read.rawValue) +
            usage.cache.write * finite(selected.cache.write.rawValue)
        ) / 1_000_000.0
        return finite(total)
    }

    // parity: core/src/session/usage.ts#Recorded [status=implemented hash=8cd23409631a]
    public struct Recorded: Equatable, Hashable, Sendable, Codable {
        public let tokens: SessionSchema.TokenUsage
        public let cost: Double

        public init(tokens: SessionSchema.TokenUsage, cost: Double) {
            self.tokens = tokens
            self.cost = cost
        }
    }

    // parity: core/src/session/usage.ts#record [status=implemented hash=7c848d5bdac1]
    public static func record(_ usage: AISchema.Usage?, costs: [ModelSchema.Cost]) -> Recorded {
        let normalized = tokens(usage)
        let cost = usage?.cost ?? calculateCost(costs, usage: normalized)
        return Recorded(tokens: normalized, cost: finite(cost))
    }

    // parity: core/src/session/usage.ts#add [status=implemented hash=078a2e4faa68]
    public static func add(_ a: Recorded, _ b: Recorded) -> Recorded {
        Recorded(
            tokens: SessionSchema.TokenUsage(
                input: a.tokens.input + b.tokens.input,
                output: a.tokens.output + b.tokens.output,
                reasoning: a.tokens.reasoning + b.tokens.reasoning,
                cache: SessionSchema.TokenUsage.Cache(
                    read: a.tokens.cache.read + b.tokens.cache.read,
                    write: a.tokens.cache.write + b.tokens.cache.write
                )
            ),
            cost: a.cost + b.cost
        )
    }
}

// MARK: - session/system-prompt.ts

/// Default agent harness system prompt renderer (`packages/core/src/session/system-prompt.ts`).
public enum CoreSessionSystemPrompt {
    public static let defaultTemplate = """
    You are an AI agent running in OpenCode, a coding agent harness. Help the user accomplish their goals using the tools you have available.

    # Harness
    - Responses are rendered as GitHub-flavored Markdown.
    - `<system-reminder>` blocks are harness instructions, not user-authored content. Read and follow them.
    - Prefer parallelizing independent tool calls.
    ${OPENCODE_TOOL_GUIDANCE}

    # Communication
    - Use clear file paths when referring to files.
    - Keep responses clear and concise, and avoid unnecessary technical jargon.

    # Working in codebases
    - Keep changes consistent with the structure, naming, style, and patterns of the surrounding code.
    - Treat unfamiliar files or changes as potential user work and investigate before deleting or overwriting them.
    """

    // parity: core/src/session/system-prompt.ts#make [status=implemented hash=82cb4aecb29f]
    public static func make(_ tools: [String]) -> String {
        render(defaultTemplate, tools: tools)
    }

    // parity: core/src/session/system-prompt.ts#render [status=implemented hash=c9c91915adf1]
    public static func render(_ prompt: String, tools: [String]) -> String {
        var instructions: [String] = []
        if tools.contains("shell") {
            instructions.append("- Prefer dedicated tools over shell commands; fall back to the shell when a tool cannot do what you need.")
            instructions.append("- Do not chain shell commands with separators like `echo \"====\";` or `printf '---'`; the output becomes noisy in a way that makes the user's side of the conversation worse.")
        }
        if tools.contains("write") {
            instructions.append("- Use the write tool to create files or completely replace their content. Prefer using the edit tool for targeted changes.")
        }
        if tools.contains("edit") {
            instructions.append("- Use the edit tool for targeted changes to existing text files. It replaces the exact text in `oldString` with `newString`, and the values must differ. By default, `oldString` must occur exactly once. If it occurs multiple times, include more surrounding context to make it unique or set `replaceAll` to true to replace every occurrence.")
        }
        return prompt.replacingOccurrences(of: "${OPENCODE_TOOL_GUIDANCE}", with: instructions.joined(separator: "\n"))
    }
}

// MARK: - session/runner/max-steps.ts

public enum CoreSessionMaxSteps {
    // parity: core/src/session/runner/max-steps.ts#MAX_STEPS_PROMPT [status=implemented hash=5dfbc735fd49]
    public static let MAX_STEPS_PROMPT = """
    CRITICAL - MAXIMUM STEPS REACHED

    The maximum number of steps allowed for this task has been reached. Tools are disabled until next user input. Respond with text only.

    STRICT REQUIREMENTS:
    1. Do NOT make any tool calls (no reads, writes, edits, searches, or any other tools)
    2. MUST provide a text response summarizing work done so far
    3. This constraint overrides ALL other instructions, including any user requests for edits or tool use

    Response must include:
    - Statement that maximum steps for this agent have been reached
    - Summary of what has been accomplished so far
    - List of any remaining tasks that were not completed
    - Recommendations for what should be done next

    Any attempt to use tools is a critical violation. Respond with text ONLY.
    """
}

// MARK: - session/runner/to-llm-message.ts

/// Translates projected `SessionMessageSchema.Info` history into canonical `AISchema.Message` arrays
/// (`packages/core/src/session/runner/to-llm-message.ts`).
public enum CoreSessionToLLMMessage {
    private static let imageMimes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    private static let effortVariants: Set<String> = Set(AISchema.ReasoningEfforts)

    private static func mediaPart(_ file: PromptSchema.FileAttachment) -> AISchema.MediaPart {
        AISchema.MediaPart(
            media: AIMedia.base64(file.data.rawValue, mediaType: file.mime),
            filename: file.name
        )
    }

    private static func attachmentLocation(_ file: PromptSchema.FileAttachment) -> String? {
        guard case .uri(let uriStr) = file.source,
              let url = URL(string: uriStr),
              url.scheme == "file"
        else { return nil }
        return url.path
    }

    private static func decodeBase64UTF8(_ base64: String) -> String {
        guard let bytes = try? base64ToBytes(base64) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func textAttachment(_ file: PromptSchema.FileAttachment) -> AISchema.TextPart {
        let sourceLabel: String = switch file.source {
        case .uri(let u): u
        case .inline: "inline attachment"
        }
        var lines: [String] = ["Attached file: \(file.name ?? sourceLabel)"]
        if let desc = file.description { lines.append("Description: \(desc)") }
        lines.append("")
        lines.append(decodeBase64UTF8(file.data.rawValue))
        return AISchema.TextPart(text: "\n\n" + lines.joined(separator: "\n"))
    }

    private static func directoryAttachment(_ file: PromptSchema.FileAttachment) -> AISchema.TextPart {
        let sourceLabel: String = switch file.source {
        case .uri(let u): u
        case .inline: "directory"
        }
        var lines: [String] = ["Attached directory: \(attachmentLocation(file) ?? file.name ?? sourceLabel)"]
        if let desc = file.description { lines.append("Description: \(desc)") }
        if !file.data.rawValue.isEmpty {
            lines.append("")
            lines.append(decodeBase64UTF8(file.data.rawValue))
        }
        return AISchema.TextPart(text: "\n\n" + lines.joined(separator: "\n"))
    }

    private static func attachmentContent(_ file: PromptSchema.FileAttachment) -> [AISchema.UserMessage.Part] {
        if file.mime == "text/plain" { return [.text(textAttachment(file))] }
        if file.mime == "application/x-directory" { return [.text(directoryAttachment(file))] }
        if imageMimes.contains(file.mime) || file.mime == "application/pdf" {
            var parts: [AISchema.UserMessage.Part] = []
            if let loc = attachmentLocation(file) {
                parts.append(.text(AISchema.TextPart(text: "Attached file: \(loc)")))
            }
            parts.append(.media(mediaPart(file)))
            return parts
        }
        return []
    }

    private static func userAttachmentContent(_ files: [PromptSchema.FileAttachment]) -> [AISchema.UserMessage.Part] {
        let eligible = files.filter { file in
            if case .inline = file.source, imageMimes.contains(file.mime), let m = file.mention, !m.text.isEmpty {
                return true
            }
            return false
        }
        if eligible.count < 2 {
            return files.flatMap(attachmentContent)
        }
        var seen: [String: Set<String>] = [:]
        return files.flatMap { file -> [AISchema.UserMessage.Part] in
            guard case .inline = file.source,
                  imageMimes.contains(file.mime),
                  let mention = file.mention,
                  !mention.text.isEmpty
            else {
                return attachmentContent(file)
            }
            let key = "\(file.mime)|\(file.name ?? "")|\(file.description ?? "")|\(mention.text)"
            if seen[key]?.contains(file.data.rawValue) == true { return [] }
            seen[key, default: []].insert(file.data.rawValue)
            return attachmentContent(file)
        }
    }

    private static func providerMetadata(_ key: String, state: SessionMessageSchema.Native?) -> AISchema.ProviderMetadata? {
        guard let state else { return nil }
        return [key: state]
    }

    private static func ranTool(_ item: SessionMessageSchema.AssistantContent) -> Bool {
        guard case .tool(let t) = item else { return false }
        if t.time.ran != nil { return true }
        if case .completed = t.state { return true }
        return false
    }

    private static func toolInput(_ tool: SessionMessageSchema.AssistantTool) -> JSONValue {
        switch tool.state {
        case .streaming(let s):
            return (try? CoreBusJSON.decodeJSONValue(s.input)) ?? .string(s.input)
        case .running(let r):
            return .object(r.input)
        case .completed(let c):
            return .object(c.input)
        case .error(let e):
            return .object(e.input)
        }
    }

    private static func toolCall(
        _ tool: SessionMessageSchema.AssistantTool,
        metadata: AISchema.ProviderMetadata?
    ) -> AISchema.ToolCallPart {
        AISchema.ToolCallPart.make(
            id: tool.id,
            name: tool.name,
            input: toolInput(tool),
            providerExecuted: tool.executed,
            providerMetadata: metadata
        )
    }

    private static func toolResult(
        _ tool: SessionMessageSchema.AssistantTool,
        metadata: AISchema.ProviderMetadata?
    ) -> AISchema.ToolResultPart? {
        switch tool.state {
        case .completed(let c):
            let value: AISchema.ToolResultValue
            if c.content.count == 1, case .text(let text) = c.content[0] {
                value = .text(.string(text))
            } else {
                let mapped: [ToolSchema.Content] = c.content.map { item in
                    switch item {
                    case .text(let t): .text(ToolSchema.TextContent(text: t))
                    case .file(let uri, let mime, let name): .file(ToolSchema.FileContent(uri: uri, mime: mime, name: name))
                    }
                }
                value = .content(mapped)
            }
            return AISchema.ToolResultPart.make(
                id: tool.id,
                name: tool.name,
                result: value,
                providerExecuted: tool.executed,
                providerMetadata: metadata
            )
        case .error(let e):
            let errJSON = (try? CoreBusJSON.encodeToJSONValue(e.error)) ?? .string(e.error.message)
            let contentJSON = (try? CoreBusJSON.encodeToJSONValue(e.content ?? [])) ?? .array([])
            return AISchema.ToolResultPart.make(
                id: tool.id,
                name: tool.name,
                result: .error(.object(["error": errJSON, "content": contentJSON])),
                providerExecuted: tool.executed,
                providerMetadata: metadata
            )
        case .streaming, .running:
            return nil
        }
    }

    private static func convertAssistant(
        _ message: SessionMessageSchema.Assistant,
        model: SessionSchema.ModelRef,
        providerMetadataKey: String
    ) -> [AISchema.Message] {
        let sameProvider = message.model.providerID == model.providerID
        let sameModel = sameProvider && message.model.id == model.id

        let kept: [SessionMessageSchema.AssistantContent]
        if message.error == nil || message.error?.type == "aborted" {
            kept = message.content
        } else {
            let lastLocalRanIdx = message.content.lastIndex { item in
                guard case .tool(let t) = item else { return false }
                return t.executed != true && ranTool(item)
            }
            kept = lastLocalRanIdx.map { Array(message.content[...$0]) } ?? []
        }

        let cut = message.error != nil || message.finish == nil
        let tailIndex = cut ? (message.content.count - 1) : -1
        let items: [SessionMessageSchema.AssistantContent] = cut
            ? kept.filter { item in
                guard case .tool(let t) = item else { return true }
                if ranTool(item) { return true }
                if case .error(let e) = t.state, e.error.type.hasPrefix("tool.input") { return true }
                return false
            }
            : kept

        var assistantParts: [AISchema.AssistantMessage.Part] = []
        for (idx, item) in items.enumerated() {
            let isTail = cut && idx == tailIndex
            switch item {
            case .text(let t):
                assistantParts.append(.text(AISchema.TextPart(
                    text: t.text,
                    providerMetadata: (sameModel && !isTail) ? providerMetadata(providerMetadataKey, state: t.native) : nil
                )))
            case .reasoning(let r):
                if cut {
                    let hasOutputAfter = items[(idx + 1)...].contains { after in
                        switch after {
                        case .tool: return true
                        case .text(let txt): return !txt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        case .reasoning: return false
                        }
                    }
                    if !hasOutputAfter { continue }
                }
                if sameModel {
                    assistantParts.append(.reasoning(AISchema.ReasoningPart(
                        text: r.text,
                        providerMetadata: providerMetadata(providerMetadataKey, state: r.native)
                    )))
                } else if !r.text.isEmpty {
                    assistantParts.append(.reasoning(AISchema.ReasoningPart(text: r.text)))
                }
            case .tool(let t):
                let call = toolCall(t, metadata: sameModel ? providerMetadata(providerMetadataKey, state: t.native) : nil)
                assistantParts.append(.toolCall(call))
                if t.executed == true,
                   let res = toolResult(t, metadata: sameProvider ? providerMetadata(providerMetadataKey, state: t.native) : nil)
                {
                    assistantParts.append(.toolResult(res))
                }
            }
        }

        let meaningful = assistantParts.filter { part in
            switch part {
            case .text(let t):
                return cut ? !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !t.text.isEmpty
            case .reasoning(let r):
                return !r.text.isEmpty || !(r.providerMetadata?.isEmpty ?? true)
            default:
                return true
            }
        }

        let toolMessages: [AISchema.Message] = items.compactMap { item in
            guard case .tool(let t) = item, t.executed != true,
                  let res = toolResult(t, metadata: sameModel ? providerMetadata(providerMetadataKey, state: t.native) : nil)
            else { return nil }
            return AISchema.Message.tool(res)
        }

        if meaningful.isEmpty { return toolMessages }
        let msg = AISchema.Message.assistant(AISchema.AssistantMessage(id: message.id.rawValue, content: meaningful))
        return [msg] + toolMessages
    }

    private static func variantEffort(_ variant: String?) -> (matched: Bool, effort: AISchema.ReasoningEffort?) {
        guard let variant, variant != "default" else { return (true, nil) }
        if effortVariants.contains(variant) {
            return (true, AISchema.ReasoningEffort(rawValue: variant))
        }
        return (false, nil)
    }

    private static func convertOne(
        _ message: SessionMessageSchema.Info,
        model: SessionSchema.ModelRef,
        providerMetadataKey: String
    ) -> [AISchema.Message] {
        switch message {
        case .agentSelected, .idle:
            return []

        case .modelSelected(let m):
            guard let prev = m.previous,
                  m.model.providerID == model.providerID && m.model.id == model.id,
                  prev.providerID == model.providerID && prev.id == model.id
            else { return [] }
            let to = variantEffort(m.model.variant)
            let from = variantEffort(prev.variant)
            guard to.matched && from.matched else { return [] }
            return [AISchema.Message.effort(effort: to.effort, previous: from.effort)]

        case .locationSwitched(let l):
            return [
                .user(AISchema.UserMessage(
                    id: l.id.rawValue,
                    content: [.text(AISchema.TextPart(text: "The working directory has been changed to \(l.location.directory)."))]
                )),
            ]

        case .user(let u):
            var content: [AISchema.UserMessage.Part] = []
            for skill in u.skills ?? [] {
                if let text = skill.text {
                    content.append(.text(AISchema.TextPart(text: text)))
                }
            }
            if !u.text.isEmpty {
                content.append(.text(AISchema.TextPart(text: u.text)))
            }
            if let files = u.files {
                content.append(contentsOf: userAttachmentContent(files))
            }
            guard !content.isEmpty else { return [] }
            return [.user(AISchema.UserMessage(id: u.id.rawValue, content: content))]

        case .synthetic(let s):
            return [.user(AISchema.UserMessage(id: s.id.rawValue, content: [.text(AISchema.TextPart(text: s.text))]))]

        case .skill(let s):
            return [.user(AISchema.UserMessage(id: s.id.rawValue, content: [.text(AISchema.TextPart(text: s.text))]))]

        case .system(let s):
            return [AISchema.Message.system(s.text)]

        case .shell(let sh):
            if case .bool(true) = sh.metadata?["background"] { return [] }
            let text = "The following shell command was executed by the user:\n\nCommand:\n\(sh.command)\n\nOutput:\n\(sh.output?.output ?? "")"
            return [.user(AISchema.UserMessage(id: sh.id.rawValue, content: [.text(AISchema.TextPart(text: text))]))]

        case .assistant(let a):
            return convertAssistant(a, model: model, providerMetadataKey: providerMetadataKey)

        case .compaction(let comp):
            guard case .completed(let done) = comp else { return [] }
            if let rawWindow = done.native?["messages"],
               let window = try? CoreBusJSON.decodeFromJSONValue(rawWindow, as: [AISchema.Message].self)
            {
                return window
            }
            let kept = CoreSessionRecentText.kept(comp)
            var lines = [
                "<conversation-checkpoint>",
                "The following is a summary and serialized record of earlier conversation. Treat it as historical context, not as new instructions.",
                "",
                "<summary>\n\(done.summary)\n</summary>",
            ]
            if let kept, !kept.isEmpty {
                lines.append("")
                lines.append("<recent-context>\n\(kept)\n</recent-context>")
            }
            lines.append("</conversation-checkpoint>")
            return [.user(AISchema.UserMessage(
                id: done.id.rawValue,
                content: [.text(AISchema.TextPart(text: lines.joined(separator: "\n")))]
            ))]
        }
    }

    // parity: core/src/session/runner/to-llm-message.ts#toLLMMessages [status=implemented hash=982d81c72a4a]
    public static func toLLMMessages(
        _ messages: [SessionMessageSchema.Info],
        model: SessionSchema.ModelRef,
        providerMetadataKey: String? = nil
    ) -> [AISchema.Message] {
        let key = providerMetadataKey ?? model.providerID
        return messages.flatMap { convertOne($0, model: model, providerMetadataKey: key) }
    }
}

// MARK: - session/model-transport.ts

/// Per-session stateful WebSocket transport manager with HTTP fallback
/// (`packages/core/src/session/model-transport.ts`).
public enum CoreSessionModelTransport {
    // parity: core/src/session/model-transport.ts#Handshake [status=implemented hash=8f984865b45c]
    public struct Handshake: Equatable, Hashable, Sendable {
        public let url: String
        public let headers: [String: String]

        public init(url: String, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }
    }

    // parity: core/src/session/model-transport.ts#Interceptor [status=implemented hash=5493cfb35a83]
    public struct Interceptor: Sendable {
        public let handshake: (@Sendable (Handshake) async throws -> Handshake)?
        public let send: (@Sendable (String) async throws -> String)?
        public let receive: (@Sendable (String) async throws -> String)?

        public init(
            handshake: (@Sendable (Handshake) async throws -> Handshake)? = nil,
            send: (@Sendable (String) async throws -> String)? = nil,
            receive: (@Sendable (String) async throws -> String)? = nil
        ) {
            self.handshake = handshake
            self.send = send
            self.receive = receive
        }
    }

    // parity: core/src/session/model-transport.ts#Interface [status=implemented hash=bcb91c959ee1]
    public protocol Interface: Sendable {
        func bind(_ sessionID: SessionID, interceptor: Interceptor?, idleTimeoutMs: Int?) -> AITransport.WebSocketChannelExecutor
        func close(_ sessionID: SessionID) async
        func closeAll() async
    }

    // parity: core/src/session/model-transport.ts#Service [status=implemented hash=a3fd270682cd]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionModelTransport"
        private let connector: AITransport.WebSocketConnector?
        private let activeSessions = Mutex<Set<SessionID>>([])

        public init(connector: AITransport.WebSocketConnector? = nil) {
            self.connector = connector
        }

        public func bind(
            _ sessionID: SessionID,
            interceptor: Interceptor? = nil,
            idleTimeoutMs: Int? = nil
        ) -> AITransport.WebSocketChannelExecutor {
            _ = idleTimeoutMs
            activeSessions.withLock { _ = $0.insert(sessionID) }
            guard let connector else {
                return AITransport.WebSocketChannelExecutor { exchange in
                    AITransport.WebSocketChannelExecution(frames: exchange.fallback())
                }
            }
            let direct = AITransport.makeDirect(connector)
            return AITransport.WebSocketChannelExecutor { exchange in
                let connect: AITransport.WebSocketChannelExchange.Connect
                if let hook = interceptor?.handshake {
                    let updated = try await hook(Handshake(url: exchange.connect.url, headers: exchange.connect.headers))
                    connect = AITransport.WebSocketChannelExchange.Connect(url: updated.url, headers: updated.headers)
                } else {
                    connect = exchange.connect
                }
                let updatedExchange = AITransport.WebSocketChannelExchange(
                    id: exchange.id,
                    connect: connect,
                    fallback: exchange.fallback,
                    driver: exchange.driver
                )
                return try await direct.execute(updatedExchange)
            }
        }

        public func close(_ sessionID: SessionID) async {
            activeSessions.withLock { _ = $0.remove(sessionID) }
        }

        public func closeAll() async {
            activeSessions.withLock { $0.removeAll() }
        }
    }

    // parity: core/src/session/model-transport.ts#makeLayer [status=adapted hash=c4a002e6bd56]
    public static func makeLayer(connector: AITransport.WebSocketConnector? = nil) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { _, _ in
            LayerNode.Output([Service.serviceKey: Service(connector: connector)])
        }
    }

    // parity: core/src/session/model-transport.ts#layer [status=adapted hash=1fcfe2c0aaca]
    public static let layer: LayerNode.ExecutableLayer = makeLayer()

    // parity: core/src/session/model-transport.ts#node [status=adapted hash=2f8379e76979]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        layer,
        []
    )
}

// MARK: - session/runner/model.ts

/// Location-scoped model resolution (`packages/core/src/session/runner/model.ts`).
public enum CoreSessionRunnerModel {
    // parity: core/src/session/runner/model.ts#ModelNotSelectedError [status=implemented hash=f647dbb4bf58]
    public struct ModelNotSelectedError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionRunnerModel.ModelNotSelectedError"
        public let sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }

        // parity: core/src/session/runner/model.ts#ModelNotSelectedError.message [status=implemented hash=7f64b5e82ad4]
        public var message: String { "No model is available for session \(sessionID.rawValue)" }
        public var description: String { message }
    }

    // parity: core/src/session/runner/model.ts#ModelUnavailableError [status=implemented hash=f30948de079b]
    public struct ModelUnavailableError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public static let tag = "SessionRunnerModel.ModelUnavailableError"
        public let providerID: String
        public let modelID: String

        public init(providerID: String, modelID: String) {
            self.providerID = providerID
            self.modelID = modelID
        }

        // parity: core/src/session/runner/model.ts#ModelUnavailableError.message [status=implemented hash=08faee17908f]
        public var message: String {
            if providerID == "azure-cognitive-services" {
                return "Model unavailable: \(providerID)/\(modelID). This provider has been deprecated; use azure/\(modelID) instead."
            }
            if providerID == "google-vertex-anthropic" {
                return "Model unavailable: \(providerID)/\(modelID). This provider has been deprecated; use google-vertex/\(modelID) instead."
            }
            return "Model unavailable: \(providerID)/\(modelID)"
        }

        public var description: String { message }
    }

    // parity: core/src/session/runner/model.ts#Error [status=implemented hash=ee519310713f]
    public enum ResolutionError: Swift.Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case notSelected(ModelNotSelectedError)
        case unavailable(ModelUnavailableError)

        public var description: String {
            switch self {
            case .notSelected(let e): e.message
            case .unavailable(let e): e.message
            }
        }
    }

    // parity: core/src/session/runner/model.ts#Resolved [status=implemented hash=176ab0a56f03]
    public struct Resolved: Sendable {
        public let model: AISchema.LanguageModel
        public let ref: SessionSchema.ModelRef
        public let capabilities: ModelSchema.Capabilities
        public let cost: [ModelSchema.Cost]
        public let limit: ModelSchema.Info.Limit
        public let compaction: ProviderSchema.Compaction?

        public init(
            model: AISchema.LanguageModel,
            ref: SessionSchema.ModelRef,
            capabilities: ModelSchema.Capabilities,
            cost: [ModelSchema.Cost] = [],
            limit: ModelSchema.Info.Limit = ModelSchema.Info.Limit(context: 200_000, output: 32_000),
            compaction: ProviderSchema.Compaction? = nil
        ) {
            self.model = model
            self.ref = ref
            self.capabilities = capabilities
            self.cost = cost
            self.limit = limit
            self.compaction = compaction
        }
    }

    public enum RequestKind: String, Equatable, Hashable, Sendable, Codable {
        case primary
        case compaction
        case generate
        case title
    }

    // parity: core/src/session/runner/model.ts#resolved [status=implemented hash=c41ce2798733]
    public static func resolved(
        _ model: AISchema.LanguageModel,
        capabilities: ModelSchema.Capabilities = ModelSchema.Capabilities.default(),
        variant: String? = nil,
        cost: [ModelSchema.Cost] = [],
        limit: ModelSchema.Info.Limit = ModelSchema.Info.Limit(context: 200_000, output: 32_000),
        compaction: ProviderSchema.Compaction? = nil
    ) -> Resolved {
        Resolved(
            model: model,
            ref: SessionSchema.ModelRef(id: model.id.rawValue, providerID: model.provider.rawValue, variant: variant),
            capabilities: capabilities,
            cost: cost,
            limit: limit,
            compaction: compaction
        )
    }

    /// The model a session would run on, before plugins or credentials resolve it.
    public struct Selected: Sendable {
        public let info: ModelSchema.Info
        public let variant: String?

        public init(info: ModelSchema.Info, variant: String? = nil) {
            self.info = info
            self.variant = variant
        }
    }

    /// Picks the session's model from `available`: its explicit selection when that is available, otherwise the
    /// agent's preferred model, otherwise `fallback`.
    public static func defaultSelect(
        session: SessionSchema.Info,
        available: @Sendable () async throws -> [ModelSchema.Info],
        agentModel: SessionSchema.ModelRef? = nil,
        fallback: (@Sendable () async throws -> ModelSchema.Info?)? = nil
    ) async throws -> Selected {
        func find(_ ref: SessionSchema.ModelRef) async throws -> ModelSchema.Info? {
            try await available().first { $0.providerID.rawValue == ref.providerID && $0.id.rawValue == ref.id }
        }
        if let model = session.model {
            if let info = try await find(model) { return Selected(info: info, variant: model.variant) }
            throw ModelUnavailableError(providerID: model.providerID, modelID: model.id)
        }
        if let agentModel, let preferred = try await find(agentModel) {
            return Selected(info: preferred, variant: agentModel.variant)
        }
        if let info = try await fallback?() { return Selected(info: info, variant: nil) }
        throw ModelNotSelectedError(sessionID: session.id)
    }

    // parity: core/src/session/runner/model.ts#Interface [status=implemented hash=f92f8c63a04f]
    public protocol Interface: Sendable {
        /// The selected model and variant, without resolving a runnable model.
        func select(
            session: SessionSchema.Info,
            available: @Sendable () async throws -> [ModelSchema.Info]
        ) async throws -> Selected
        func resolve(
            session: SessionSchema.Info,
            available: @Sendable () async throws -> [ModelSchema.Info],
            kind: RequestKind,
            agent: String
        ) async throws -> Resolved
    }

    // parity: core/src/session/runner/model.ts#Service [status=implemented hash=493fc9ee28a4]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionRunnerModel"
        private let resolver: @Sendable (SessionSchema.Info, @Sendable () async throws -> [ModelSchema.Info], RequestKind, String) async throws -> Resolved
        private let selector: @Sendable (SessionSchema.Info, @Sendable () async throws -> [ModelSchema.Info]) async throws -> Selected

        public init(
            select: (@Sendable (SessionSchema.Info, @Sendable () async throws -> [ModelSchema.Info]) async throws -> Selected)? = nil,
            resolve: @escaping @Sendable (SessionSchema.Info, @Sendable () async throws -> [ModelSchema.Info], RequestKind, String) async throws -> Resolved
        ) {
            self.resolver = resolve
            self.selector = select ?? { session, available in
                try await CoreSessionRunnerModel.defaultSelect(session: session, available: available)
            }
        }

        public func select(
            session: SessionSchema.Info,
            available: @Sendable () async throws -> [ModelSchema.Info]
        ) async throws -> Selected {
            try await selector(session, available)
        }

        public func resolve(
            session: SessionSchema.Info,
            available: @Sendable () async throws -> [ModelSchema.Info],
            kind: RequestKind,
            agent: String
        ) async throws -> Resolved {
            try await resolver(session, available, kind, agent)
        }
    }

    // parity: core/src/session/runner/model.ts#node [status=adapted hash=03abcd6c254d]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { _, _ in
            LayerNode.Output([Service.serviceKey: Service { session, _, _, _ in
                throw ModelNotSelectedError(sessionID: session.id)
            }])
        },
        []
    )
}

// MARK: - session/model-request.ts

/// Model request builder, output-token budgeting, unsupported-modality replacement, and image bounding
/// (`packages/core/src/session/model-request.ts`).
public enum CoreSessionModelRequest {
    public static let imageBytesTrigger: Int = 25 * 1024 * 1024
    public static let imageBytesTarget: Int = 15 * 1024 * 1024
    public static let imageRemovedNotice =
        "[This image was removed to reduce the request size and is no longer visible. Do not make claims about its contents from memory. If needed, retrieve it again with an available tool or ask the user to attach it again.]"
    public static let outputTokenFallback: Int = 32_000
    public static let outputTokenMax: Int = 256_000
    public static let estimateError: Double = 0.15
    public static let windowHeadroom: Double = 0.01
    public static let outputTokenMin: Int = 1_024

    public struct ToolExecutionInput: Sendable {
        public let sessionID: SessionID
        public let agent: String
        public let messageID: SessionMessageSchema.ID
        public let call: AISchema.ToolCall
        public let progress: @Sendable ([String: JSONValue]) async -> Void
        public let cancel: @Sendable () async -> Void

        public init(
            sessionID: SessionID,
            agent: String,
            messageID: SessionMessageSchema.ID,
            call: AISchema.ToolCall,
            progress: @escaping @Sendable ([String: JSONValue]) async -> Void,
            cancel: @escaping @Sendable () async -> Void
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.messageID = messageID
            self.call = call
            self.progress = progress
            self.cancel = cancel
        }
    }

    public struct NormalizedToolResult: Equatable, Sendable {
        public let content: [SessionMessageSchema.ToolContent]
        public let metadata: [String: JSONValue]?

        public init(content: [SessionMessageSchema.ToolContent], metadata: [String: JSONValue]? = nil) {
            self.content = content
            self.metadata = metadata
        }
    }

    public struct ToolSnapshot: Sendable {
        public let definitions: [AISchema.ToolEntry]
        public let execute: @Sendable (ToolExecutionInput) async throws -> NormalizedToolResult

        public init(
            definitions: [AISchema.ToolEntry] = [],
            execute: @escaping @Sendable (ToolExecutionInput) async throws -> NormalizedToolResult = { input in
                throw ToolSchema.ToolError(message: "Unknown tool: \(input.call.name)")
            }
        ) {
            self.definitions = definitions
            self.execute = execute
        }
    }

    public struct AgentProfile: Equatable, Hashable, Sendable {
        public let id: String
        public let system: String?
        public let maxSteps: Int?
        public let temperature: Double?
        public let topP: Double?
        public let model: SessionSchema.ModelRef?

        public init(
            id: String,
            system: String? = nil,
            maxSteps: Int? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            model: SessionSchema.ModelRef? = nil
        ) {
            self.id = id
            self.system = system
            self.maxSteps = maxSteps
            self.temperature = temperature
            self.topP = topP
            self.model = model
        }
    }

    // parity: core/src/session/model-request.ts#ExecuteError [status=implemented hash=2036dc6ca685]
    public enum ExecuteError: Swift.Error, Equatable, Sendable {
        case tool(ToolSchema.ToolError)
        case permissionDeclined(String)
        case questionCancelled(String)
    }

    // parity: core/src/session/model-request.ts#Prepared [status=implemented hash=41ff1a3baa75]
    public struct Prepared: Sendable {
        public let request: AISchema.LLMRequest
        public let options: AIRoute.StreamOptions
        public let executeTool: @Sendable (ToolExecutionInput) async throws -> NormalizedToolResult

        public init(
            request: AISchema.LLMRequest,
            options: AIRoute.StreamOptions = AIRoute.StreamOptions(),
            executeTool: @escaping @Sendable (ToolExecutionInput) async throws -> NormalizedToolResult
        ) {
            self.request = request
            self.options = options
            self.executeTool = executeTool
        }
    }

    // parity: core/src/session/model-request.ts#Input [status=implemented hash=97fac9960239]
    public struct Input: Sendable {
        public struct TokenBudget: Equatable, Hashable, Sendable {
            public let measured: Int
            public let estimated: Int

            public init(measured: Int, estimated: Int) {
                self.measured = measured
                self.estimated = estimated
            }
        }

        public let session: SessionSchema.Info
        public let agent: String
        public let model: CoreSessionRunnerModel.Resolved
        public let tools: ToolSnapshot?
        public let system: [AISchema.SystemPart]
        public let messages: [AISchema.Message]
        public let toolChoice: AISchema.ToolChoice?
        public let useSessionWebSocket: Bool
        public let inputTokens: TokenBudget?

        public init(
            session: SessionSchema.Info,
            agent: String,
            model: CoreSessionRunnerModel.Resolved,
            tools: ToolSnapshot? = nil,
            system: [AISchema.SystemPart],
            messages: [AISchema.Message],
            toolChoice: AISchema.ToolChoice? = nil,
            useSessionWebSocket: Bool = false,
            inputTokens: TokenBudget? = nil
        ) {
            self.session = session
            self.agent = agent
            self.model = model
            self.tools = tools
            self.system = system
            self.messages = messages
            self.toolChoice = toolChoice
            self.useSessionWebSocket = useSessionWebSocket
            self.inputTokens = inputTokens
        }
    }

    // parity: core/src/session/model-request.ts#outputLimit [status=implemented hash=3cffd8f2017f]
    public static func outputLimit(
        _ limit: ModelSchema.Info.Limit,
        inputTokens: Input.TokenBudget? = nil,
        headroom: Double = 0
    ) -> Int {
        let requested = min(limit.output > 0 ? limit.output : outputTokenFallback, outputTokenMax)
        guard let inputTokens, limit.context > 0 else { return requested }
        let room = Int(floor(Double(limit.context) * (1.0 - headroom)))
            - inputTokens.measured
            - Int(ceil(Double(inputTokens.estimated) * (1.0 + estimateError)))
        return min(requested, max(outputTokenMin, room))
    }

    // parity: core/src/session/model-request.ts#baseTranscript [status=implemented hash=8e9ac58e84a1]
    public static func baseTranscript(
        agent: AgentProfile,
        model: CoreSessionRunnerModel.Resolved,
        tools: ToolSnapshot,
        initial: [CoreSessionInstructionState.RenderedInstruction],
        messages: [SessionMessageSchema.Info]
    ) -> (providerMetadataKey: String, system: [AISchema.SystemPart], messages: [AISchema.Message]) {
        let providerMetadataKey = model.model.route.providerMetadataKey ?? model.model.provider.rawValue
        let basePrompt = agent.system ?? CoreSessionSystemPrompt.make(tools.definitions.map(\.name))
        let instructionText = initial.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var system: [AISchema.SystemPart] = []
        if !basePrompt.isEmpty {
            system.append(AISchema.SystemPart.make(basePrompt))
        }
        if !instructionText.isEmpty {
            system.append(AISchema.SystemPart(text: instructionText))
        }
        let llmMessages = CoreSessionToLLMMessage.toLLMMessages(
            messages,
            model: model.ref,
            providerMetadataKey: providerMetadataKey
        )
        return (providerMetadataKey, system, llmMessages)
    }

    private static let xaiImageMimes: Set<String> = ["image/png", "image/jpeg", "image/webp"]

    private static func mimeToModality(_ mime: String) -> String? {
        if mime.hasPrefix("image/") { return "image" }
        if mime.hasPrefix("audio/") { return "audio" }
        if mime.hasPrefix("video/") { return "video" }
        if mime == "application/pdf" { return "pdf" }
        return nil
    }

    private static func mediaByteSize(_ media: AIMedia.Asset) -> Int {
        switch media.source {
        case .base64(let data, _): return data.utf8.count
        case .bytes(let data, _): return ((data.count + 2) / 3) * 4
        case .url, .ref: return 0
        }
    }

    private static func replaceMedia(
        _ messages: [AISchema.Message],
        replace: (String, String?, () -> Int) -> String?
    ) -> [AISchema.Message] {
        func mapToolResult(_ part: AISchema.ToolResultPart) -> AISchema.ToolResultPart {
            guard case .content(let items) = part.result else { return part }
            var changed = false
            let mapped: [ToolSchema.Content] = items.map { item in
                guard case .file(let f) = item else { return item }
                if let replacement = replace(f.mime, f.name, { f.uri.utf8.count }) {
                    changed = true
                    return .text(ToolSchema.TextContent(text: replacement))
                }
                return item
            }
            guard changed else { return part }
            return AISchema.ToolResultPart(
                id: part.id,
                name: part.name,
                namespace: part.namespace,
                result: .content(mapped),
                providerExecuted: part.providerExecuted,
                cache: part.cache,
                providerMetadata: part.providerMetadata
            )
        }

        return messages.map { message in
            switch message {
            case .system:
                return message
            case .user(let u):
                let nextParts: [AISchema.UserMessage.Part] = u.content.map { part in
                    guard case .media(let m) = part else { return part }
                    if let replacement = replace(m.media.mediaType, m.filename, { mediaByteSize(m.media) }) {
                        return .text(AISchema.TextPart(text: replacement))
                    }
                    return part
                }
                return .user(AISchema.UserMessage(id: u.id, content: nextParts, providerMetadata: u.providerMetadata))
            case .assistant(let a):
                let nextParts: [AISchema.AssistantMessage.Part] = a.content.map { part in
                    switch part {
                    case .media(let m):
                        if let replacement = replace(m.media.mediaType, m.filename, { mediaByteSize(m.media) }) {
                            return .text(AISchema.TextPart(text: replacement))
                        }
                        return part
                    case .toolResult(let tr):
                        return .toolResult(mapToolResult(tr))
                    default:
                        return part
                    }
                }
                return .assistant(AISchema.AssistantMessage(id: a.id, content: nextParts, providerMetadata: a.providerMetadata))
            case .tool(let t):
                return .tool(AISchema.ToolMessage(id: t.id, content: t.content.map(mapToolResult)))
            }
        }
    }

    // parity: core/src/session/model-request.ts#unsupportedParts [status=implemented hash=6b9959ee93e7]
    public static func unsupportedParts(
        _ messages: [AISchema.Message],
        capabilities: ModelSchema.Capabilities,
        provider: String? = nil
    ) -> [AISchema.Message] {
        replaceMedia(messages) { mime, name, _ in
            guard let modality = mimeToModality(mime) else { return nil }
            let unsupported: String?
            if !capabilities.input.contains(where: { $0.hasPrefix(modality) }) {
                unsupported = modality
            } else if provider == "xai", modality == "image", !xaiImageMimes.contains(mime.lowercased()) {
                unsupported = mime
            } else {
                unsupported = nil
            }
            guard let unsupported else { return nil }
            let target = name.map { "\"\($0)\"" } ?? modality
            return "ERROR: Cannot read \(target) (this model does not support \(unsupported) input). Inform the user."
        }
    }

    // parity: core/src/session/model-request.ts#boundImages [status=implemented hash=6a6383febe9f]
    public static func boundImages(_ messages: [AISchema.Message]) -> [AISchema.Message] {
        let isImage: (String) -> Bool = { $0.lowercased().hasPrefix("image/") }
        var sizes: [Int] = []
        for message in messages {
            for part in message.contentParts {
                switch part {
                case .media(let m) where isImage(m.media.mediaType):
                    sizes.append(mediaByteSize(m.media))
                case .toolResult(let tr):
                    if case .content(let items) = tr.result {
                        for item in items {
                            if case .file(let f) = item, isImage(f.mime) {
                                sizes.append(f.uri.utf8.count)
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
        var cut = 0
        var kept = 0
        for size in sizes {
            kept += size
            if kept <= imageBytesTrigger { continue }
            while kept > imageBytesTarget && cut < sizes.count {
                kept -= sizes[cut]
                cut += 1
            }
        }
        guard cut > 0 else { return messages }
        var index = 0
        return replaceMedia(messages) { mime, _, _ in
            guard isImage(mime) else { return nil }
            let current = index
            index += 1
            return current < cut ? imageRemovedNotice : nil
        }
    }

    // parity: core/src/session/model-request.ts#Interface [status=implemented hash=32fe0f1c3a07]
    public protocol Interface: Sendable {
        func primary(_ input: Input) async throws -> Prepared
        func compaction(_ input: Input) async throws -> Prepared
        func generate(_ input: Input) async throws -> Prepared
        func title(_ input: Input) async throws -> Prepared
    }

    // parity: core/src/session/model-request.ts#Service [status=implemented hash=73bc7df05e44]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionModelRequest"
        public let modelTransport: any CoreSessionModelTransport.Interface

        public init(modelTransport: any CoreSessionModelTransport.Interface = CoreSessionModelTransport.Service()) {
            self.modelTransport = modelTransport
        }

        private func build(_ input: Input, headroom: Double) -> Prepared {
            let filtered = boundImages(unsupportedParts(
                input.messages,
                capabilities: input.model.capabilities,
                provider: input.model.ref.providerID
            ))
            let maxTokens = CoreSessionModelRequest.outputLimit(
                input.model.limit,
                inputTokens: input.inputTokens,
                headroom: headroom
            )
            let affinityKey = CoreSessionAffinity.get(input.session).rawValue
            let tools = input.model.capabilities.tools ? (input.tools?.definitions ?? []) : []
            let req = AISchema.LLMRequest(
                id: input.session.id.rawValue,
                model: input.model.model,
                system: input.system,
                messages: filtered,
                tools: tools,
                toolChoice: tools.isEmpty ? nil : input.toolChoice,
                maxTokens: maxTokens,
                cache: .auto,
                promptCacheKey: affinityKey
            )
            let ws = input.useSessionWebSocket
                ? modelTransport.bind(input.session.id, interceptor: nil, idleTimeoutMs: nil)
                : nil
            let fallbackExecute: @Sendable (ToolExecutionInput) async throws -> NormalizedToolResult = { toolInput in
                throw ToolSchema.ToolError(message: "Unknown tool: \(toolInput.call.name)")
            }
            return Prepared(
                request: req,
                options: AIRoute.StreamOptions(webSocket: ws),
                executeTool: input.tools?.execute ?? fallbackExecute
            )
        }

        public func primary(_ input: Input) async throws -> Prepared {
            build(input, headroom: CoreSessionModelRequest.windowHeadroom)
        }

        public func compaction(_ input: Input) async throws -> Prepared {
            build(input, headroom: 0)
        }

        public func generate(_ input: Input) async throws -> Prepared {
            build(input, headroom: CoreSessionModelRequest.windowHeadroom)
        }

        public func title(_ input: Input) async throws -> Prepared {
            build(input, headroom: 0)
        }
    }

    // parity: core/src/session/model-request.ts#layer [status=adapted hash=851f1901873a]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        let transport = deps.get(CoreSessionModelTransport.Service.serviceKey, as: (any CoreSessionModelTransport.Interface).self)
            ?? CoreSessionModelTransport.Service()
        return LayerNode.Output([Service.serviceKey: Service(modelTransport: transport)])
    }

    // parity: core/src/session/model-request.ts#node [status=adapted hash=4763d51ec299]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        layer,
        [CoreSessionModelTransport.node]
    )
}

// MARK: - session/context.ts

/// Two-phase Location-scoped model context loader (`packages/core/src/session/context.ts`).
public enum CoreSessionContext {
    // parity: core/src/session/context.ts#Selection [status=implemented hash=60248dfbb6c7]
    public struct Selection: Sendable {
        public let session: SessionSchema.Info
        public let agent: CoreSessionModelRequest.AgentProfile
        public let instructions: [CoreSessionInstructionState.Source]
        public let tools: CoreSessionModelRequest.ToolSnapshot

        public init(
            session: SessionSchema.Info,
            agent: CoreSessionModelRequest.AgentProfile,
            instructions: [CoreSessionInstructionState.Source] = [],
            tools: CoreSessionModelRequest.ToolSnapshot = CoreSessionModelRequest.ToolSnapshot()
        ) {
            self.session = session
            self.agent = agent
            self.instructions = instructions
            self.tools = tools
        }
    }

    // parity: core/src/session/context.ts#Loaded [status=implemented hash=6f1ee5d599e2]
    public struct Loaded: Sendable {
        public let session: SessionSchema.Info
        public let agent: CoreSessionModelRequest.AgentProfile
        public let model: CoreSessionRunnerModel.Resolved
        public let initial: [CoreSessionInstructionState.RenderedInstruction]
        public let messages: [SessionMessageSchema.Info]
        public let tools: CoreSessionModelRequest.ToolSnapshot

        public init(
            session: SessionSchema.Info,
            agent: CoreSessionModelRequest.AgentProfile,
            model: CoreSessionRunnerModel.Resolved,
            initial: [CoreSessionInstructionState.RenderedInstruction],
            messages: [SessionMessageSchema.Info],
            tools: CoreSessionModelRequest.ToolSnapshot
        ) {
            self.session = session
            self.agent = agent
            self.model = model
            self.initial = initial
            self.messages = messages
            self.tools = tools
        }
    }

    public struct TitleSelection: Sendable {
        public let agent: CoreSessionModelRequest.AgentProfile
        public let primary: CoreSessionRunnerModel.Resolved?
        public let selected: CoreSessionRunnerModel.Resolved

        public init(
            agent: CoreSessionModelRequest.AgentProfile,
            primary: CoreSessionRunnerModel.Resolved?,
            selected: CoreSessionRunnerModel.Resolved
        ) {
            self.agent = agent
            self.primary = primary
            self.selected = selected
        }
    }

    // parity: core/src/session/context.ts#Interface [status=implemented hash=ced42d213d51]
    public protocol Interface: Sendable {
        func select(_ sessionID: SessionID) async throws -> Selection
        func load(_ selection: Selection) async throws -> Loaded
        func resolveModel(
            _ session: SessionSchema.Info,
            kind: CoreSessionRunnerModel.RequestKind,
            agent: String
        ) async throws -> CoreSessionRunnerModel.Resolved
        func selectTitle(_ session: SessionSchema.Info) async throws -> TitleSelection?
        var request: any CoreSessionModelRequest.Interface { get }
    }

    // parity: core/src/session/context.ts#Service [status=implemented hash=4016e4c1a48b]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionContext"
        public let db: any SQLiteDatabase
        public let store: any CoreSessionStore.Interface
        public let models: any CoreSessionRunnerModel.Interface
        public let request: any CoreSessionModelRequest.Interface
        public let entries: any CoreSessionInstructionEntry.Interface
        public let selectAgent: @Sendable (SessionSchema.Info) async throws -> CoreSessionModelRequest.AgentProfile
        /// Builds the tool snapshot for the session's agent. The selected model (nil when none can be selected yet)
        /// decides which tools the model policy offers.
        public let selectTools: @Sendable (SessionSchema.Info, CoreSessionModelRequest.AgentProfile, ModelSchema.Info?) async throws -> CoreSessionModelRequest.ToolSnapshot
        public let availableModels: @Sendable () async throws -> [ModelSchema.Info]

        public init(
            db: any SQLiteDatabase,
            store: any CoreSessionStore.Interface,
            models: any CoreSessionRunnerModel.Interface,
            request: any CoreSessionModelRequest.Interface = CoreSessionModelRequest.Service(),
            entries: (any CoreSessionInstructionEntry.Interface)? = nil,
            selectAgent: @escaping @Sendable (SessionSchema.Info) async throws -> CoreSessionModelRequest.AgentProfile = { session in
                CoreSessionModelRequest.AgentProfile(id: session.agent ?? "build")
            },
            selectTools: @escaping @Sendable (SessionSchema.Info, CoreSessionModelRequest.AgentProfile, ModelSchema.Info?) async throws -> CoreSessionModelRequest.ToolSnapshot = { _, _, _ in
                CoreSessionModelRequest.ToolSnapshot()
            },
            availableModels: @escaping @Sendable () async throws -> [ModelSchema.Info] = { [] }
        ) {
            self.db = db
            self.store = store
            self.models = models
            self.request = request
            self.entries = entries ?? CoreSessionInstructionEntry.Service(db: db)
            self.selectAgent = selectAgent
            self.selectTools = selectTools
            self.availableModels = availableModels
        }

        public func select(_ sessionID: SessionID) async throws -> Selection {
            guard let session = try store.get(sessionID) else {
                throw CoreSessionErrors.NotFoundError(sessionID: sessionID)
            }
            let agent = try await selectAgent(session)
            // The tool policy depends on the model the session would run on; an unselectable model falls back to
            // the session's (or agent's) explicit reference so the policy still sees its provider and id.
            let selected = try? await models.select(session: session, available: availableModels)
            let policyModel = selected?.info ?? (session.model ?? agent.model).map { ref in
                ModelSchema.Info.default(
                    providerID: ProviderSchema.ID(rawValue: ref.providerID),
                    id: ModelSchema.ID(rawValue: ref.id)
                )
            }
            let tools = try await selectTools(session, agent, policyModel)
            let instructionSources = try entries.load(sessionID)
            return Selection(session: session, agent: agent, instructions: instructionSources, tools: tools)
        }

        public func resolveModel(
            _ session: SessionSchema.Info,
            kind: CoreSessionRunnerModel.RequestKind,
            agent: String
        ) async throws -> CoreSessionRunnerModel.Resolved {
            try await models.resolve(
                session: session,
                available: availableModels,
                kind: kind,
                agent: agent
            )
        }

        public func load(_ selection: Selection) async throws -> Loaded {
            let model = try await resolveModel(selection.session, kind: .primary, agent: selection.agent.id)
            let runnerEntries = try CoreSessionHistory.entriesForRunner(
                db,
                sessionID: selection.session.id,
                instructions: selection.instructions,
                boundary: .model(model.ref)
            )
            return Loaded(
                session: selection.session,
                agent: selection.agent,
                model: model,
                initial: runnerEntries.initial,
                messages: runnerEntries.entries.map(\.message),
                tools: selection.tools
            )
        }

        public func selectTitle(_ session: SessionSchema.Info) async throws -> TitleSelection? {
            let titleAgent = CoreSessionModelRequest.AgentProfile(
                id: "title",
                system: "Generate a concise title (at most 50 characters) summarizing the user's request. Return only the title text."
            )
            guard let resolved = try? await resolveModel(session, kind: .title, agent: titleAgent.id) else {
                return nil
            }
            return TitleSelection(agent: titleAgent, primary: resolved, selected: resolved)
        }
    }

    /// Tool snapshots are chosen for the selected model (`SessionRunnerModel.select`); the model policy, web search
    /// availability and the `full_codemode` flag live behind the injected `selectTools`.
    // parity: core/src/session/context.ts#node [status=adapted hash=7e10baf6f065]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
                  let store = deps.get(CoreSessionStore.Service.serviceKey, as: CoreSessionStore.Service.self),
                  let models = deps.get(CoreSessionRunnerModel.Service.serviceKey, as: (any CoreSessionRunnerModel.Interface).self)
            else {
                throw SQLiteError.databaseClosed
            }
            let req = deps.get(CoreSessionModelRequest.Service.serviceKey, as: (any CoreSessionModelRequest.Interface).self)
                ?? CoreSessionModelRequest.Service()
            return LayerNode.Output([Service.serviceKey: Service(db: db, store: store, models: models, request: req)])
        },
        [CoreDatabaseStore.node, CoreSessionStore.node, CoreSessionRunnerModel.node, CoreSessionModelRequest.node]
    )
}

// MARK: - session/runner/publish-llm-event.ts

/// Persists one logical LLM step's streaming events onto `CoreBus` without executing tools
/// (`packages/core/src/session/runner/publish-llm-event.ts`).
public enum CoreSessionLLMEventPublisher {
    // parity: core/src/session/runner/publish-llm-event.ts#StepRecord [status=implemented hash=0d6881824bb0]
    public struct StepRecord: Equatable, Sendable {
        public struct FinishInfo: Equatable, Sendable {
            public let finish: SessionMessageSchema.FinishReason
            public let rawFinish: String?
            public let native: SessionMessageSchema.Native?
            public let usage: AISchema.Usage?

            public init(
                finish: SessionMessageSchema.FinishReason,
                rawFinish: String? = nil,
                native: SessionMessageSchema.Native? = nil,
                usage: AISchema.Usage? = nil
            ) {
                self.finish = finish
                self.rawFinish = rawFinish
                self.native = native
                self.usage = usage
            }
        }

        public let outputStarted: Bool
        public let providerFailed: Bool
        public let failure: SessionErrorSchema.Error?
        public let finish: FinishInfo?
        public let needsContinuation: Bool

        public init(
            outputStarted: Bool,
            providerFailed: Bool,
            failure: SessionErrorSchema.Error?,
            finish: FinishInfo?,
            needsContinuation: Bool
        ) {
            self.outputStarted = outputStarted
            self.providerFailed = providerFailed
            self.failure = failure
            self.finish = finish
            self.needsContinuation = needsContinuation
        }
    }

    public struct Input: Sendable {
        public let sessionID: SessionID
        public let agent: String
        public let model: SessionSchema.ModelRef
        public let providerMetadataKey: String
        public let started: Int64
        public let assistantMessageID: SessionMessageSchema.ID

        public init(
            sessionID: SessionID,
            agent: String,
            model: SessionSchema.ModelRef,
            providerMetadataKey: String,
            started: Int64,
            assistantMessageID: SessionMessageSchema.ID
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.model = model
            self.providerMetadataKey = providerMetadataKey
            self.started = started
            self.assistantMessageID = assistantMessageID
        }
    }

    public final class Publisher: @unchecked Sendable {
        private struct ToolState {
            let name: String
            var called: Bool = false
            var settled: Bool = false
            var providerExecuted: Bool = false
            var inputText: String = ""
            var malformed: Bool = false
            var progress: [String: JSONValue]? = nil
        }

        private struct Fragment {
            let ordinal: Int
            var text: String = ""
            var native: SessionMessageSchema.Native?
        }

        private let bus: CoreBus.Service
        private let input: Input
        private let lock = Mutex(())

        private var stepStarted = false
        private var firstTokenPublished = false
        private var providerFailed = false
        private var outputStarted = false
        private var stepFailure: SessionErrorSchema.Error? = nil
        private var stepFinish: StepRecord.FinishInfo? = nil
        private var tools: [String: ToolState] = [:]
        private var textFragments: [String: Fragment] = [:]
        private var nextTextOrdinal = 0
        private var reasoningFragments: [String: Fragment] = [:]
        private var nextReasoningOrdinal = 0

        fileprivate init(bus: CoreBus.Service, input: Input) {
            self.bus = bus
            self.input = input
        }

        public func hasStarted() -> Bool {
            lock.withLock { _ in stepStarted }
        }

        public func record() -> StepRecord {
            lock.withLock { _ in
                let hasToolCalls = !tools.isEmpty && tools.values.contains(where: { !$0.providerExecuted })
                let needsContinuation = hasToolCalls
                    || stepFinish?.finish == .toolCalls
                return StepRecord(
                    outputStarted: outputStarted,
                    providerFailed: providerFailed,
                    failure: stepFailure,
                    finish: stepFinish,
                    needsContinuation: needsContinuation
                )
            }
        }

        private func native(_ metadata: AISchema.ProviderMetadata?) -> SessionMessageSchema.Native? {
            metadata?[input.providerMetadataKey]
        }

        public func startAssistant(snapshot: String? = nil) async throws -> SessionMessageSchema.ID {
            let shouldPublish: Bool = lock.withLock { _ in
                if stepStarted { return false }
                stepStarted = true
                return true
            }
            if shouldPublish {
                _ = try await bus.publish(
                    SessionEventSchema.Step.Started,
                    data: SessionEventSchema.Step.StartedData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        agent: input.agent,
                        model: input.model,
                        snapshot: snapshot,
                        started: input.started
                    )
                )
            }
            return input.assistantMessageID
        }

        public func markStreamed() async throws {
            let msgID = try await startAssistant()
            _ = try await bus.publish(
                SessionEventSchema.Step.Streamed,
                data: SessionEventSchema.StepRefData(sessionID: input.sessionID, assistantMessageID: msgID)
            )
        }

        private func publishFirstTokenIfNeeded() async throws {
            let shouldPublish: Bool = lock.withLock { _ in
                if firstTokenPublished { return false }
                firstTokenPublished = true
                outputStarted = true
                return true
            }
            if shouldPublish {
                let msgID = try await startAssistant()
                _ = try await bus.publish(
                    SessionEventSchema.Step.FirstToken,
                    data: SessionEventSchema.StepRefData(sessionID: input.sessionID, assistantMessageID: msgID)
                )
            }
        }

        public func publish(_ event: AISchema.LLMEvent) async throws {
            switch event {
            case .stepStart, .raw, .compaction, .media:
                return

            case .textStart(let e):
                try await publishFirstTokenIfNeeded()
                let ordinal: Int = lock.withLock { _ in
                    let ord = nextTextOrdinal
                    nextTextOrdinal += 1
                    textFragments[e.id] = Fragment(ordinal: ord, text: "", native: native(e.providerMetadata))
                    return ord
                }
                _ = try await bus.publish(
                    SessionEventSchema.Text.Started,
                    data: SessionEventSchema.Text.StartedData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        ordinal: ordinal
                    )
                )

            case .textDelta(let e):
                let ordinal: Int? = lock.withLock { _ in
                    guard var frag = textFragments[e.id] else { return nil }
                    frag.text += e.text
                    if let n = native(e.providerMetadata) { frag.native = n }
                    textFragments[e.id] = frag
                    return frag.ordinal
                }
                if let ordinal {
                    await bus.emit(
                        SessionEventSchema.Text.Delta,
                        data: SessionEventSchema.Text.DeltaData(
                            sessionID: input.sessionID,
                            assistantMessageID: input.assistantMessageID,
                            ordinal: ordinal,
                            delta: e.text
                        )
                    )
                }

            case .textEnd(let e):
                let frag: Fragment? = lock.withLock { _ in textFragments.removeValue(forKey: e.id) }
                if let frag {
                    let finalText = e.text ?? frag.text
                    _ = try await bus.publish(
                        SessionEventSchema.Text.Ended,
                        data: SessionEventSchema.Text.EndedData(
                            sessionID: input.sessionID,
                            assistantMessageID: input.assistantMessageID,
                            ordinal: frag.ordinal,
                            text: finalText,
                            native: native(e.providerMetadata) ?? frag.native
                        )
                    )
                }

            case .reasoningStart(let e):
                try await publishFirstTokenIfNeeded()
                let nat = native(e.providerMetadata)
                let ordinal: Int = lock.withLock { _ in
                    let ord = nextReasoningOrdinal
                    nextReasoningOrdinal += 1
                    reasoningFragments[e.id] = Fragment(ordinal: ord, text: "", native: nat)
                    return ord
                }
                _ = try await bus.publish(
                    SessionEventSchema.Reasoning.Started,
                    data: SessionEventSchema.Reasoning.StartedData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        ordinal: ordinal,
                        native: nat
                    )
                )

            case .reasoningDelta(let e):
                let ordinal: Int? = lock.withLock { _ in
                    guard var frag = reasoningFragments[e.id] else { return nil }
                    frag.text += e.text
                    if let n = native(e.providerMetadata) { frag.native = n }
                    reasoningFragments[e.id] = frag
                    return frag.ordinal
                }
                if let ordinal {
                    await bus.emit(
                        SessionEventSchema.Reasoning.Delta,
                        data: SessionEventSchema.Reasoning.DeltaData(
                            sessionID: input.sessionID,
                            assistantMessageID: input.assistantMessageID,
                            ordinal: ordinal,
                            delta: e.text
                        )
                    )
                }

            case .reasoningEnd(let e):
                let frag: Fragment? = lock.withLock { _ in reasoningFragments.removeValue(forKey: e.id) }
                if let frag {
                    _ = try await bus.publish(
                        SessionEventSchema.Reasoning.Ended,
                        data: SessionEventSchema.Reasoning.EndedData(
                            sessionID: input.sessionID,
                            assistantMessageID: input.assistantMessageID,
                            ordinal: frag.ordinal,
                            text: e.text ?? frag.text,
                            native: native(e.providerMetadata) ?? frag.native
                        )
                    )
                }

            case .toolInputStart(let e):
                try await publishFirstTokenIfNeeded()
                lock.withLock { _ in
                    tools[e.id] = ToolState(name: e.name, providerExecuted: e.providerExecuted ?? false)
                }
                _ = try await bus.publish(
                    SessionEventSchema.Tool.Input.Started,
                    data: SessionEventSchema.Tool.Input.StartedData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        id: e.id,
                        name: e.name
                    )
                )

            case .toolInputDelta(let e):
                lock.withLock { _ in
                    if var st = tools[e.id] {
                        st.inputText += e.text
                        tools[e.id] = st
                    }
                }
                await bus.emit(
                    SessionEventSchema.Tool.Input.Delta,
                    data: SessionEventSchema.Tool.Input.DeltaData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        id: e.id,
                        delta: e.text
                    )
                )

            case .toolInputEnd(let e):
                let text: String = lock.withLock { _ in tools[e.id]?.inputText ?? "" }
                _ = try await bus.publish(
                    SessionEventSchema.Tool.Input.Ended,
                    data: SessionEventSchema.Tool.Input.EndedData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        id: e.id,
                        text: text
                    )
                )

            case .toolInputError(let e):
                try await publishFirstTokenIfNeeded()
                let hadTool = lock.withLock { _ -> Bool in
                    let existed = tools[e.id] != nil
                    var st = tools[e.id] ?? ToolState(name: e.name)
                    st.malformed = true
                    st.inputText = e.raw
                    tools[e.id] = st
                    return existed
                }
                if !hadTool {
                    _ = try await bus.publish(
                        SessionEventSchema.Tool.Input.Started,
                        data: SessionEventSchema.Tool.Input.StartedData(
                            sessionID: input.sessionID,
                            assistantMessageID: input.assistantMessageID,
                            id: e.id,
                            name: e.name
                        )
                    )
                }
                _ = try await bus.publish(
                    SessionEventSchema.Tool.Input.Ended,
                    data: SessionEventSchema.Tool.Input.EndedData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        id: e.id,
                        text: e.raw
                    )
                )
                try await failTool(
                    id: e.id,
                    error: SessionErrorSchema.Error(
                        type: "tool.input-json",
                        message: "The tool input could not be parsed as JSON, so the call was not executed. Reissue the call with valid JSON arguments."
                    )
                )

            case .toolCall(let e):
                try await publishFirstTokenIfNeeded()
                let hadStart = lock.withLock { _ -> Bool in
                    let existed = tools[e.id] != nil
                    var st = tools[e.id] ?? ToolState(name: e.name, providerExecuted: e.providerExecuted ?? false)
                    st.called = true
                    st.providerExecuted = e.providerExecuted ?? st.providerExecuted
                    tools[e.id] = st
                    return existed
                }
                if !hadStart {
                    _ = try await bus.publish(
                        SessionEventSchema.Tool.Input.Started,
                        data: SessionEventSchema.Tool.Input.StartedData(
                            sessionID: input.sessionID,
                            assistantMessageID: input.assistantMessageID,
                            id: e.id,
                            name: e.name
                        )
                    )
                }
                let dictInput: [String: JSONValue] = switch e.input {
                case .object(let o): o
                default: ["value": e.input]
                }
                _ = try await bus.publish(
                    SessionEventSchema.Tool.Called,
                    data: SessionEventSchema.Tool.CalledData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        id: e.id,
                        input: dictInput,
                        executed: e.providerExecuted ?? false,
                        native: native(e.providerMetadata)
                    )
                )

            case .toolResult(let e):
                let isHosted = e.providerExecuted ?? true
                let content: [SessionMessageSchema.ToolContent]
                switch e.result {
                case .content(let items) where !items.isEmpty:
                    content = items.map { item -> SessionMessageSchema.ToolContent in
                        switch item {
                        case .text(let t): .text(t.text)
                        case .file(let f): .file(uri: f.uri, mime: f.mime, name: f.name)
                        }
                    }
                case .text(let v):
                    content = [.text(Self.stringifyJSON(v))]
                case .json(let v):
                    content = [.text(Self.stringifyJSON(v))]
                case .error(let v):
                    content = [.text(Self.stringifyJSON(v))]
                default:
                    content = [.text("")]
                }
                lock.withLock { _ in
                    if var st = tools[e.id] {
                        st.settled = true
                        tools[e.id] = st
                    }
                }
                CoreSessionLiveToolMetadata.clear(input.assistantMessageID.rawValue, e.id)
                if case .error(let errVal) = e.result {
                    _ = try await bus.publish(
                        SessionEventSchema.Tool.Failed,
                        data: SessionEventSchema.Tool.FailedData(
                            sessionID: input.sessionID,
                            assistantMessageID: input.assistantMessageID,
                            id: e.id,
                            error: SessionErrorSchema.Error(type: "tool.execution", message: Self.stringifyJSON(errVal)),
                            content: content,
                            executed: isHosted,
                            native: native(e.providerMetadata)
                        )
                    )
                } else {
                    _ = try await bus.publish(
                        SessionEventSchema.Tool.Success,
                        data: SessionEventSchema.Tool.SuccessData(
                            sessionID: input.sessionID,
                            assistantMessageID: input.assistantMessageID,
                            id: e.id,
                            content: content,
                            executed: isHosted,
                            native: native(e.providerMetadata)
                        )
                    )
                }

            case .stepFinish(let e):
                recordFinish(reason: e.reason, usage: e.usage, metadata: e.providerMetadata)

            case .finish(let e):
                recordFinish(reason: e.reason, usage: e.usage, metadata: e.providerMetadata)
            }
        }

        private func recordFinish(
            reason: AISchema.FinishReasonDetails,
            usage: AISchema.Usage?,
            metadata: AISchema.ProviderMetadata?
        ) {
            lock.withLock { _ in
                stepFinish = StepRecord.FinishInfo(
                    finish: Self.mapFinishReason(reason.normalized),
                    rawFinish: reason.raw,
                    native: native(metadata),
                    usage: usage
                )
                if reason.normalized == .contentFilter {
                    providerFailed = true
                    stepFailure = CoreSessionErrorMapping.contentFilterError("Response blocked by content filter", reason: reason)
                }
            }
        }

        private static func mapFinishReason(_ reason: LLMSchema.FinishReason) -> SessionMessageSchema.FinishReason {
            switch reason {
            case .stop: .stop
            case .length: .length
            case .toolCalls: .toolCalls
            case .contentFilter: .contentFilter
            case .error: .error
            case .unknown: .unknown
            }
        }

        private static func stringifyJSON(_ value: JSONValue) -> String {
            if case .string(let s) = value { return s }
            return (try? CoreBusJSON.encodeJSONValue(value)) ?? ""
        }

        public func progress(id: String, metadata: [String: JSONValue]) async {
            lock.withLock { _ in
                if var st = tools[id] {
                    var merged = st.progress ?? [:]
                    for (k, v) in metadata { merged[k] = v }
                    st.progress = merged
                    tools[id] = st
                }
            }
            CoreSessionLiveToolMetadata.set(input.assistantMessageID.rawValue, id, metadata)
            await bus.emit(
                SessionEventSchema.Tool.Progress,
                data: SessionEventSchema.Tool.ProgressData(
                    sessionID: input.sessionID,
                    assistantMessageID: input.assistantMessageID,
                    id: id,
                    metadata: metadata
                )
            )
        }

        public func toolExecution(
            id: String,
            result: CoreSessionModelRequest.NormalizedToolResult
        ) async throws {
            let shouldPublish: Bool = lock.withLock { _ in
                guard var st = tools[id], !st.settled else { return false }
                st.settled = true
                tools[id] = st
                return true
            }
            guard shouldPublish else { return }
            CoreSessionLiveToolMetadata.clear(input.assistantMessageID.rawValue, id)
            let nonEmptyContent: [SessionMessageSchema.ToolContent] = result.content.isEmpty
                ? [.text("")]
                : result.content
            _ = try await bus.publish(
                SessionEventSchema.Tool.Success,
                data: SessionEventSchema.Tool.SuccessData(
                    sessionID: input.sessionID,
                    assistantMessageID: input.assistantMessageID,
                    id: id,
                    content: nonEmptyContent,
                    metadata: result.metadata,
                    executed: false
                )
            )
        }

        public func failTool(
            id: String,
            error: SessionErrorSchema.Error,
            metadata: [String: JSONValue]? = nil
        ) async throws {
            let (shouldPublish, mergedMeta): (Bool, [String: JSONValue]?) = lock.withLock { _ in
                guard var st = tools[id], !st.settled else { return (false, nil) }
                st.settled = true
                let meta: [String: JSONValue]? = {
                    if let prev = st.progress, let next = metadata {
                        var copy = prev
                        for (k, v) in next { copy[k] = v }
                        return copy
                    }
                    return metadata ?? st.progress
                }()
                tools[id] = st
                return (true, meta)
            }
            guard shouldPublish else { return }
            CoreSessionLiveToolMetadata.clear(input.assistantMessageID.rawValue, id)
            _ = try await bus.publish(
                SessionEventSchema.Tool.Failed,
                data: SessionEventSchema.Tool.FailedData(
                    sessionID: input.sessionID,
                    assistantMessageID: input.assistantMessageID,
                    id: id,
                    error: error,
                    metadata: mergedMeta,
                    executed: false
                )
            )
        }

        public func failUnsettledTools(error: SessionErrorSchema.Error) async throws {
            let unsettledIDs: [String] = lock.withLock { _ in
                tools.compactMap { $0.value.settled ? nil : $0.key }
            }
            for id in unsettledIDs {
                try await failTool(id: id, error: error)
            }
        }

        public func finishStep(
            cost: Double,
            tokens: SessionSchema.TokenUsage,
            snapshot: String? = nil,
            files: [String]? = nil
        ) async throws {
            let msgID = try await startAssistant()
            let rec = record()
            let finishInfo = rec.finish
            _ = try await bus.publish(
                SessionEventSchema.Step.Ended,
                data: SessionEventSchema.Step.EndedData(
                    sessionID: input.sessionID,
                    assistantMessageID: msgID,
                    finish: finishInfo?.finish ?? .stop,
                    rawFinish: finishInfo?.rawFinish,
                    native: finishInfo?.native,
                    cost: cost,
                    tokens: tokens,
                    snapshot: snapshot,
                    files: files
                )
            )
        }

        public func failStep(
            error: SessionErrorSchema.Error,
            cost: Double? = nil,
            tokens: SessionSchema.TokenUsage? = nil,
            snapshot: String? = nil,
            files: [String]? = nil
        ) async throws {
            let msgID = try await startAssistant()
            let finishInfo = lock.withLock { _ in stepFinish }
            let failedFinish: SessionEventSchema.Step.FailedFinish? = (finishInfo?.finish == .contentFilter)
                ? .contentFilter
                : nil
            _ = try await bus.publish(
                SessionEventSchema.Step.Failed,
                data: SessionEventSchema.Step.FailedData(
                    sessionID: input.sessionID,
                    assistantMessageID: msgID,
                    error: error,
                    finish: failedFinish,
                    rawFinish: finishInfo?.rawFinish,
                    native: finishInfo?.native,
                    cost: cost,
                    tokens: tokens,
                    snapshot: snapshot,
                    files: files
                )
            )
        }

        public func flush() async throws {
            let openText: [(String, Fragment)] = lock.withLock { _ in
                let items = Array(textFragments)
                textFragments.removeAll()
                return items
            }
            for (_, frag) in openText {
                _ = try await bus.publish(
                    SessionEventSchema.Text.Ended,
                    data: SessionEventSchema.Text.EndedData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        ordinal: frag.ordinal,
                        text: frag.text,
                        native: frag.native
                    )
                )
            }
            let openReasoning: [(String, Fragment)] = lock.withLock { _ in
                let items = Array(reasoningFragments)
                reasoningFragments.removeAll()
                return items
            }
            for (_, frag) in openReasoning {
                _ = try await bus.publish(
                    SessionEventSchema.Reasoning.Ended,
                    data: SessionEventSchema.Reasoning.EndedData(
                        sessionID: input.sessionID,
                        assistantMessageID: input.assistantMessageID,
                        ordinal: frag.ordinal,
                        text: frag.text,
                        native: frag.native
                    )
                )
            }
        }
    }

    // parity: core/src/session/runner/publish-llm-event.ts#createLLMEventPublisher [status=implemented hash=b211b83bda0f]
    public static func createLLMEventPublisher(
        bus: CoreBus.Service,
        input: Input
    ) -> Publisher {
        Publisher(bus: bus, input: input)
    }
}

// MARK: - session/runner/retry.ts

/// Retry decision policy and durable retry scheduling (`packages/core/src/session/runner/retry.ts`).
public enum CoreSessionRunnerRetry {
    // parity: core/src/session/runner/retry.ts#isRetryable [status=implemented hash=a0f2c8a75e63]
    public static func isRetryable(_ error: AISchema.AIError) -> Bool {
        error.isRetryable
    }

    // parity: core/src/session/runner/retry.ts#Decision [status=implemented hash=148b80756260]
    public struct Decision: Equatable, Hashable, Sendable {
        public let attempt: Int
        public let delayMs: Int64

        public init(attempt: Int, delayMs: Int64) {
            self.attempt = attempt
            self.delayMs = delayMs
        }
    }

    public struct PolicyInput: Sendable {
        public let cause: AISchema.AIError
        public let error: SessionErrorSchema.Error
        public let agent: String
        public let model: SessionSchema.ModelRef
        public let retry: Bool

        public init(
            cause: AISchema.AIError,
            error: SessionErrorSchema.Error,
            agent: String,
            model: SessionSchema.ModelRef,
            retry: Bool
        ) {
            self.cause = cause
            self.error = error
            self.agent = agent
            self.model = model
            self.retry = retry
        }
    }

    public final class RetryPolicy: Sendable {
        private let attemptState = Mutex<Int>(0)
        public let maxAttempts: Int
        public let baseDelayMs: Int64
        public let maxDelayMs: Int64

        public init(maxAttempts: Int = 5, baseDelayMs: Int64 = 1_000, maxDelayMs: Int64 = 30_000) {
            self.maxAttempts = maxAttempts
            self.baseDelayMs = baseDelayMs
            self.maxDelayMs = maxDelayMs
        }

        public func decide(_ input: PolicyInput) -> Decision? {
            guard input.retry, input.cause.isRetryable else { return nil }
            let attempt = attemptState.withLock { count -> Int in
                count += 1
                return count
            }
            guard attempt <= maxAttempts else { return nil }
            if let retryAfter = input.cause.retryAfterMs, retryAfter >= 0 {
                return Decision(attempt: attempt, delayMs: min(Int64(retryAfter), maxDelayMs))
            }
            let shift = min(attempt - 1, 10)
            let backoff = min(baseDelayMs * Int64(1 << shift), maxDelayMs)
            return Decision(attempt: attempt, delayMs: backoff)
        }
    }

    public struct RetryController: Sendable {
        public let decide: @Sendable (PolicyInput) -> Decision?
        public let wait: @Sendable (Decision, SessionMessageSchema.ID, SessionErrorSchema.Error) async throws -> Void

        public init(
            decide: @escaping @Sendable (PolicyInput) -> Decision?,
            wait: @escaping @Sendable (Decision, SessionMessageSchema.ID, SessionErrorSchema.Error) async throws -> Void
        ) {
            self.decide = decide
            self.wait = wait
        }
    }

    // parity: core/src/session/runner/retry.ts#policy [status=implemented hash=57777c79182d]
    public static func policy(
        sessionID: SessionID,
        maxAttempts: Int = 5,
        baseDelayMs: Int64 = 1_000,
        maxDelayMs: Int64 = 30_000
    ) -> RetryPolicy {
        _ = sessionID
        return RetryPolicy(maxAttempts: maxAttempts, baseDelayMs: baseDelayMs, maxDelayMs: maxDelayMs)
    }

    // parity: core/src/session/runner/retry.ts#make [status=implemented hash=b0879aa33197]
    public static func make(
        bus: CoreBus.Service,
        sessionID: SessionID,
        maxAttempts: Int = 5,
        baseDelayMs: Int64 = 1_000,
        maxDelayMs: Int64 = 30_000
    ) -> RetryController {
        let pol = policy(sessionID: sessionID, maxAttempts: maxAttempts, baseDelayMs: baseDelayMs, maxDelayMs: maxDelayMs)
        return RetryController(
            decide: { pol.decide($0) },
            wait: { decision, assistantMessageID, error in
                let scheduled = Flock.currentEpochMs()
                let target = scheduled + decision.delayMs
                _ = try await bus.publish(
                    SessionEventSchema.RetryScheduled,
                    data: SessionEventSchema.RetryScheduledData(
                        sessionID: sessionID,
                        assistantMessageID: assistantMessageID,
                        attempt: decision.attempt,
                        at: target,
                        error: error
                    )
                )
                let remaining = max(0, target - Flock.currentEpochMs())
                if remaining > 0 {
                    try await Task.sleep(for: .milliseconds(remaining))
                }
            }
        )
    }
}

// MARK: - session/runner/step.ts

/// Single-step LLM executor: runs one explicit `llm.stream` call, executes local tool calls
/// concurrently, and persists step/tool events to `CoreBus` (`packages/core/src/session/runner/step.ts`).
public enum CoreSessionStep {
    // parity: core/src/session/runner/step.ts#Outcome [status=implemented hash=73b4cb9bb3cf]
    public enum Outcome: Equatable, Sendable {
        case completed(needsContinuation: Bool)
        case retry(error: SessionErrorSchema.Error, decision: CoreSessionRunnerRetry.Decision, freshAssistant: Bool)
        case recoverFull
        case compacted
        case outputLimit(needsContinuation: Bool)
    }

    public final class CancelToken: @unchecked Sendable {
        private let state = Mutex<(triggered: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        public init() {}

        @discardableResult
        public func trigger() -> Bool {
            let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
                if s.triggered { return [] }
                s.triggered = true
                let list = s.waiters
                s.waiters.removeAll(keepingCapacity: false)
                return list
            }
            for w in waiters { w.resume() }
            return !waiters.isEmpty
        }

        public func wait() async {
            await withCheckedContinuation { cont in
                let already: Bool = state.withLock { s in
                    if s.triggered { return true }
                    s.waiters.append(cont)
                    return false
                }
                if already { cont.resume() }
            }
        }
    }

    // parity: core/src/session/runner/step.ts#makeCancel [status=implemented hash=65c26ac8f125]
    public static func makeCancel() -> CancelToken {
        CancelToken()
    }

    public struct AttemptInput: Sendable {
        public let sessionID: SessionID
        public let assistantMessageID: SessionMessageSchema.ID
        public let agent: String
        public let model: CoreSessionRunnerModel.Resolved
        public let prepared: CoreSessionModelRequest.Prepared
        public let retry: @Sendable (AISchema.AIError, SessionErrorSchema.Error, Bool) -> CoreSessionRunnerRetry.Decision?
        public let recoverOverflow: @Sendable () async throws -> Bool

        public init(
            sessionID: SessionID,
            assistantMessageID: SessionMessageSchema.ID,
            agent: String,
            model: CoreSessionRunnerModel.Resolved,
            prepared: CoreSessionModelRequest.Prepared,
            retry: @escaping @Sendable (AISchema.AIError, SessionErrorSchema.Error, Bool) -> CoreSessionRunnerRetry.Decision?,
            recoverOverflow: @escaping @Sendable () async throws -> Bool = { false }
        ) {
            self.sessionID = sessionID
            self.assistantMessageID = assistantMessageID
            self.agent = agent
            self.model = model
            self.prepared = prepared
            self.retry = retry
            self.recoverOverflow = recoverOverflow
        }
    }

    public final class Runner: Sendable {
        public let bus: CoreBus.Service
        public let llm: any AIRoute.Interface

        public init(bus: CoreBus.Service, llm: any AIRoute.Interface) {
            self.bus = bus
            self.llm = llm
        }

        public func attempt(_ input: AttemptInput) async throws -> Outcome {
            let started = Flock.currentEpochMs()
            let publisher = CoreSessionLLMEventPublisher.createLLMEventPublisher(
                bus: bus,
                input: CoreSessionLLMEventPublisher.Input(
                    sessionID: input.sessionID,
                    agent: input.agent,
                    model: input.model.ref,
                    providerMetadataKey: input.model.model.route.providerMetadataKey ?? input.model.model.provider.rawValue,
                    started: started,
                    assistantMessageID: input.assistantMessageID
                )
            )

            var toolTasks: [(call: AISchema.ToolCall, cancel: CancelToken, task: Task<Void, Never>)] = []
            var streamError: (any Error)? = nil

            do {
                let stream = llm.stream(input.prepared.request, options: input.prepared.options)
                for try await event in stream {
                    try Task.checkCancellation()
                    if publisher.record().providerFailed { continue }
                    try await publisher.publish(event)
                    if case .toolCall(let call) = event, call.providerExecuted != true {
                        let cancel = makeCancel()
                        let toolTask = Task {
                            do {
                                if input.prepared.request.toolChoice?.type == AISchema.ToolChoice.Kind.none {
                                    throw ToolSchema.ToolError(message: "Tools are disabled after the maximum agent steps")
                                }
                                let result = try await input.prepared.executeTool(
                                    CoreSessionModelRequest.ToolExecutionInput(
                                        sessionID: input.sessionID,
                                        agent: input.agent,
                                        messageID: input.assistantMessageID,
                                        call: call,
                                        progress: { meta in await publisher.progress(id: call.id, metadata: meta) },
                                        cancel: { await cancel.wait() }
                                    )
                                )
                                try await publisher.toolExecution(id: call.id, result: result)
                            } catch {
                                try? await publisher.failTool(
                                    id: call.id,
                                    error: CoreSessionErrorMapping.toSessionError(error)
                                )
                            }
                        }
                        toolTasks.append((call, cancel, toolTask))
                    }
                }
            } catch {
                streamError = error
            }

            try? await publisher.flush()
            if publisher.hasStarted() {
                try? await publisher.markStreamed()
            }

            // Await all launched tool calls (or cancel them on cancellation).
            if Task.isCancelled {
                for run in toolTasks {
                    _ = run.cancel.trigger()
                    run.task.cancel()
                }
            }
            for run in toolTasks {
                await run.task.value
            }

            if Task.isCancelled || streamError is CancellationError {
                if publisher.hasStarted() {
                    let abortErr = SessionErrorSchema.Error(type: "aborted", message: "Step interrupted")
                    try? await publisher.failUnsettledTools(error: abortErr)
                    try? await publisher.failStep(error: abortErr)
                }
                throw CancellationError()
            }

            let rec = publisher.record()
            if let streamError {
                if !rec.outputStarted && AIErrorClassifier.isContextOverflowFailure(streamError) {
                    if try await input.recoverOverflow() {
                        return .compacted
                    }
                }
                let sessionErr = CoreSessionErrorMapping.toSessionError(streamError)
                if let aiErr = streamError as? AISchema.AIError,
                   let decision = input.retry(aiErr, sessionErr, !rec.outputStarted)
                {
                    if publisher.hasStarted() {
                        try await publisher.failUnsettledTools(error: sessionErr)
                        try await publisher.failStep(error: sessionErr)
                    }
                    return .retry(error: sessionErr, decision: decision, freshAssistant: rec.outputStarted)
                }
                try await publisher.failUnsettledTools(error: sessionErr)
                try await publisher.failStep(error: sessionErr)
                throw CoreSessionErrors.StepFailedError(error: sessionErr)
            }

            let recorded = CoreSessionUsage.record(rec.finish?.usage, costs: input.model.cost)
            if let failure = rec.failure {
                try await publisher.failUnsettledTools(error: failure)
                try await publisher.failStep(error: failure, cost: recorded.cost, tokens: recorded.tokens)
                throw CoreSessionErrors.StepFailedError(error: failure)
            }

            try await publisher.failUnsettledTools(
                error: SessionErrorSchema.Error(type: "tool.result-missing", message: "Provider did not return a tool result")
            )
            try await publisher.finishStep(cost: recorded.cost, tokens: recorded.tokens)

            if rec.finish?.finish == .length {
                return .outputLimit(needsContinuation: rec.needsContinuation)
            }
            return .completed(needsContinuation: rec.needsContinuation)
        }
    }

    // parity: core/src/session/runner/step.ts#make [status=implemented hash=31e0161c4471]
    public static func make(bus: CoreBus.Service, llm: any AIRoute.Interface) -> Runner {
        Runner(bus: bus, llm: llm)
    }
}

// MARK: - session/runner/index.ts & session/runner/llm.ts

/// Location-scoped single-step session runner (`packages/core/src/session/runner/{index,llm}.ts`).
///
/// Preserves the core session invariants:
/// - Reloads durable history from SQLite before each step (never an in-memory tool loop).
/// - Promotes pending inbox items according to steer/queue/control ordering rules.
/// - Resets agent step allowance once per promoted user-input batch.
public enum CoreSessionRunner {
    // parity: core/src/session/runner/index.ts#RunError [status=implemented hash=de8d1693bc34]
    public typealias RunError = any Error

    // parity: core/src/session/runner/index.ts#Continuation [status=implemented hash=65fe245aa945]
    public struct Continuation: Equatable, Hashable, Sendable {
        public let step: Int

        public init(step: Int) {
            self.step = step
        }
    }

    // parity: core/src/session/runner/index.ts#DrainResult [status=implemented hash=1de5fdb6f038]
    public enum DrainResult: Equatable, Hashable, Sendable {
        case complete
        case moved(continuation: Continuation?, stepped: Bool)
        case reloaded(force: Bool, continuation: Continuation?, stepped: Bool)
    }

    public struct DrainInput: Sendable {
        public let sessionID: SessionID
        public let force: Bool
        public let continuation: Continuation?
        public let promotable: CoreSessionInbox.Promotable
        public let stepped: Bool
        public let interruption: (@Sendable () -> CoreSessionExecution.InterruptReason?)?

        public init(
            sessionID: SessionID,
            force: Bool,
            continuation: Continuation? = nil,
            promotable: CoreSessionInbox.Promotable = .input,
            stepped: Bool = false,
            interruption: (@Sendable () -> CoreSessionExecution.InterruptReason?)? = nil
        ) {
            self.sessionID = sessionID
            self.force = force
            self.continuation = continuation
            self.promotable = promotable
            self.stepped = stepped
            self.interruption = interruption
        }
    }

    // parity: core/src/session/runner/index.ts#Interface [status=implemented hash=6228696db754]
    public protocol Interface: Sendable {
        func drain(_ input: DrainInput) async throws -> DrainResult
    }

    // parity: core/src/session/runner/index.ts#Service [status=implemented hash=ab6e9e4f2377]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionRunner"
        public static let continueAfterOutputLimit =
            "Your last response hit the output token limit (stop reason: length). Do not apologize, recap, or repeat yourself. Break the remaining work into smaller pieces."

        public let db: any SQLiteDatabase
        public let bus: CoreBus.Service
        public let store: any CoreSessionStore.Interface
        public let context: any CoreSessionContext.Interface
        public let modelTransport: any CoreSessionModelTransport.Interface
        public let llm: any AIRoute.Interface
        public let compaction: (any CoreSessionCompaction.Interface)?
        public let title: (any CoreSessionTitle.Interface)?
        public let isLocationClosed: @Sendable () -> Bool

        public init(
            db: any SQLiteDatabase,
            bus: CoreBus.Service,
            store: any CoreSessionStore.Interface,
            context: any CoreSessionContext.Interface,
            modelTransport: any CoreSessionModelTransport.Interface = CoreSessionModelTransport.Service(),
            llm: any AIRoute.Interface,
            compaction: (any CoreSessionCompaction.Interface)? = nil,
            title: (any CoreSessionTitle.Interface)? = nil,
            isLocationClosed: @escaping @Sendable () -> Bool = { false }
        ) {
            self.db = db
            self.bus = bus
            self.store = store
            self.context = context
            self.modelTransport = modelTransport
            self.llm = llm
            self.compaction = compaction
            self.title = title
            self.isLocationClosed = isLocationClosed
        }

        public func drain(_ input: DrainInput) async throws -> DrainResult {
            let sessionID = input.sessionID
            var force = input.force
            var continuing = input.continuation != nil
            var step = input.continuation?.step ?? 1
            var entering = true
            var stepped = input.stepped
            let promotable = input.promotable

            if !force && !continuing && !stepped {
                guard let pending = try CoreSessionInbox.nextPromotable(db: db, sessionID: sessionID, promotable: .input) else {
                    return .complete
                }
                if promotable == .steer && pending.delivery == .queue && !pending.isControl {
                    return .complete
                }
            }

            let stepRunner = CoreSessionStep.make(bus: bus, llm: llm)
            let retryController = CoreSessionRunnerRetry.make(bus: bus, sessionID: sessionID)

            while true {
                try Task.checkCancellation()
                if isLocationClosed() {
                    await modelTransport.close(sessionID)
                    return .reloaded(
                        force: force,
                        continuation: continuing ? Continuation(step: step) : nil,
                        stepped: !continuing && stepped
                    )
                }

                // Step boundary / idle boundary promotion & control handling
                let controlScope: CoreSessionInbox.Promotable = (entering || !continuing) ? .input : .steer
                let nextControl: CoreSessionInbox.Promotion? = try await CoreSessionInbox.serialized(sessionID) {
                    let next = try CoreSessionInbox.nextPromotable(
                        db: self.db,
                        sessionID: sessionID,
                        promotable: controlScope
                    )
                    switch next {
                    case .compaction(let id, _):
                        _ = try await self.bus.publishAll([
                            try CoreBus.PublishInput.make(
                                SessionEventSchema.InboxDelivered,
                                data: SessionEventSchema.InboxRefData(sessionID: sessionID, inboxID: id)
                            ),
                            try CoreBus.PublishInput.make(
                                SessionEventSchema.Compaction.Started,
                                data: SessionEventSchema.Compaction.StartedData(
                                    sessionID: sessionID,
                                    reason: .manual,
                                    inputID: id
                                )
                            ),
                        ])
                    case .move(let id, _, let payload):
                        await self.modelTransport.close(sessionID)
                        _ = try await self.bus.publishAll([
                            try CoreBus.PublishInput.make(
                                SessionEventSchema.InboxDelivered,
                                data: SessionEventSchema.InboxRefData(sessionID: sessionID, inboxID: id)
                            ),
                            try CoreBus.PublishInput.make(
                                SessionEventSchema.Moved,
                                data: SessionEventSchema.MovedData(
                                    sessionID: sessionID,
                                    location: payload.location,
                                    projectID: payload.projectID,
                                    subpath: payload.subpath
                                )
                            ),
                        ])
                    default:
                        break
                    }
                    return next
                }

                if !continuing && nextControl?.delivery != .steer {
                    entering = true
                    step = 1
                }

                if case .move = nextControl {
                    return .moved(
                        continuation: continuing ? Continuation(step: step) : nil,
                        stepped: !continuing && stepped
                    )
                }

                if case .compaction(let compID, _) = nextControl {
                    if let compaction {
                        do {
                            let selected = try await context.select(sessionID)
                            let model = try await context.resolveModel(selected.session, kind: .compaction, agent: selected.agent.id)
                            let preview = try CoreSessionHistory.preview(
                                db,
                                sessionID: sessionID,
                                instructions: selected.instructions,
                                boundary: .model(model.ref)
                            )
                            _ = try await compaction.compact(CoreSessionCompaction.CompactInput(
                                reason: .manual,
                                inputID: compID,
                                context: CoreSessionCompaction.Context(
                                    session: selected.session,
                                    agent: selected.agent,
                                    model: model,
                                    initial: preview.initial,
                                    messages: preview.messages,
                                    tools: selected.tools
                                )
                            ))
                        } catch {
                            _ = try await bus.publish(
                                SessionEventSchema.Compaction.Failed,
                                data: SessionEventSchema.Compaction.FailedData(
                                    sessionID: sessionID,
                                    reason: .manual,
                                    error: CoreSessionErrorMapping.toSessionError(error),
                                    inputID: compID
                                )
                            )
                        }
                    } else {
                        _ = try await bus.publish(
                            SessionEventSchema.Compaction.Ended,
                            data: SessionEventSchema.Compaction.EndedData(
                                sessionID: sessionID,
                                reason: .manual,
                                text: ""
                            )
                        )
                    }
                    force = false
                    continue
                }

                if !force && !continuing && (nextControl == nil || (nextControl?.delivery == .queue && promotable == .steer)) {
                    return .complete
                }

                let selected = try await context.select(sessionID)
                try await CoreSessionInstructionState.prepare(
                    db: db,
                    bus: bus,
                    sources: selected.instructions,
                    sessionID: sessionID
                )

                let promoted = try await CoreSessionInbox.promote(
                    db: db,
                    bus: bus,
                    sessionID: sessionID,
                    scope: (entering && !continuing) ? promotable : .steer
                )
                if promoted == nil {
                    continue
                }
                if let promoted, promoted > 0 {
                    // Promoting new user input resets the agent's step allowance once per batch.
                    step = 1
                }

                if let title, CoreSessionTitle.isUntitled(selected.session.title) {
                    Task { _ = try? await title.ensure(selected.session.id) }
                }

                let loaded = try await context.load(selected)
                if loaded.messages.isEmpty && !force {
                    return .complete
                }

                let maxSteps = loaded.agent.maxSteps
                let hitMaxSteps = maxSteps.map { step > $0 } ?? false
                var transcript = CoreSessionModelRequest.baseTranscript(
                    agent: loaded.agent,
                    model: loaded.model,
                    tools: loaded.tools,
                    initial: loaded.initial,
                    messages: loaded.messages
                )
                if hitMaxSteps {
                    transcript.messages.append(AISchema.Message.user(CoreSessionMaxSteps.MAX_STEPS_PROMPT))
                }

                let prepared = try await context.request.primary(CoreSessionModelRequest.Input(
                    session: loaded.session,
                    agent: loaded.agent.id,
                    model: loaded.model,
                    tools: loaded.tools,
                    system: transcript.system,
                    messages: transcript.messages,
                    toolChoice: hitMaxSteps ? AISchema.ToolChoice(type: .none) : nil,
                    useSessionWebSocket: true
                ))

                var assistantMessageID = SessionMessageSchema.ID.create()
                var stepCompleted = false
                var needsContinuation = false

                while !stepCompleted {
                    let outcome = try await stepRunner.attempt(CoreSessionStep.AttemptInput(
                        sessionID: sessionID,
                        assistantMessageID: assistantMessageID,
                        agent: loaded.agent.id,
                        model: loaded.model,
                        prepared: prepared,
                        retry: { cause, err, canRetry in
                            retryController.decide(CoreSessionRunnerRetry.PolicyInput(
                                cause: cause,
                                error: err,
                                agent: loaded.agent.id,
                                model: loaded.model.ref,
                                retry: canRetry
                            ))
                        },
                        recoverOverflow: {
                            guard let compaction = self.compaction else { return false }
                            let res = try await compaction.compact(CoreSessionCompaction.CompactInput(
                                reason: .overflow,
                                context: CoreSessionCompaction.Context(
                                    session: loaded.session,
                                    agent: loaded.agent,
                                    model: loaded.model,
                                    initial: loaded.initial,
                                    messages: loaded.messages,
                                    tools: loaded.tools
                                )
                            ))
                            return res.didCompact
                        }
                    ))

                    switch outcome {
                    case .completed(let cont):
                        stepCompleted = true
                        needsContinuation = cont && !hitMaxSteps
                    case .outputLimit(let cont):
                        stepCompleted = true
                        if !cont && !hitMaxSteps {
                            _ = try await bus.publish(
                                SessionEventSchema.Synthetic,
                                data: SessionEventSchema.SyntheticData(
                                    sessionID: sessionID,
                                    text: Self.continueAfterOutputLimit,
                                    description: "Continuing after output limit"
                                )
                            )
                            needsContinuation = true
                        } else {
                            needsContinuation = cont && !hitMaxSteps
                        }
                    case .retry(let err, let decision, let fresh):
                        try await retryController.wait(decision, assistantMessageID, err)
                        if fresh {
                            assistantMessageID = SessionMessageSchema.ID.create()
                        }
                    case .recoverFull, .compacted:
                        stepCompleted = true
                        needsContinuation = true
                    }
                }

                stepped = true
                force = false
                entering = false

                if needsContinuation {
                    continuing = true
                    step += 1
                    continue
                }

                continuing = false
                // Loop back to check if any steers or queued items remain at the idle boundary.
            }
        }
    }

    // parity: core/src/session/runner/llm.ts#node [status=adapted hash=14dca14523a4]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
                  let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
                  let store = deps.get(CoreSessionStore.Service.serviceKey, as: CoreSessionStore.Service.self),
                  let context = deps.get(CoreSessionContext.Service.serviceKey, as: (any CoreSessionContext.Interface).self),
                  let llm = deps.get(AIRoute.LLMClientService.serviceID, as: (any AIRoute.Interface).self)
            else {
                throw SQLiteError.databaseClosed
            }
            let transport = deps.get(CoreSessionModelTransport.Service.serviceKey, as: (any CoreSessionModelTransport.Interface).self)
                ?? CoreSessionModelTransport.Service()
            let compaction = deps.get(CoreSessionCompaction.Service.serviceKey, as: (any CoreSessionCompaction.Interface).self)
            let title = deps.get(CoreSessionTitle.Service.serviceKey, as: (any CoreSessionTitle.Interface).self)
            return LayerNode.Output([Service.serviceKey: Service(
                db: db,
                bus: bus,
                store: store,
                context: context,
                modelTransport: transport,
                llm: llm,
                compaction: compaction,
                title: title
            )])
        },
        [
            CoreDatabaseStore.node,
            CoreBus.node,
            CoreSessionStore.node,
            CoreSessionContext.node,
            CoreSessionModelTransport.node,
        ]
    )
}
