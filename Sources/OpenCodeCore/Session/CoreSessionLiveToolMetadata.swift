import Synchronization
import OpenCodeSchema

/// Latest progress metadata of locally running tool calls, keyed by assistant message and call id.
/// Progress is only published as an ephemeral event, so message reads overlay it onto running tool parts; this keeps
/// clients that load a session mid-call from seeing empty metadata.
/// Ports `packages/core/src/session/runner/live-tool-metadata.ts`.
public enum CoreSessionLiveToolMetadata {
    private static let live = Mutex<[String: [String: [String: JSONValue]]]>([:])

    /// Records the latest progress metadata of a running call.
    // parity: core/src/session/runner/live-tool-metadata.ts#set [status=implemented hash=809dc5ecc8a1]
    public static func set(_ messageID: String, _ callID: String, _ metadata: [String: JSONValue]) {
        live.withLock { live in
            live[messageID, default: [:]][callID] = metadata
        }
    }

    /// Forgets one settled call, or every call of the message when `callID` is nil.
    // parity: core/src/session/runner/live-tool-metadata.ts#clear [status=implemented hash=0456c1659fdd]
    public static func clear(_ messageID: String, _ callID: String? = nil) {
        live.withLock { live in
            guard let callID else {
                live.removeValue(forKey: messageID)
                return
            }
            guard var calls = live[messageID] else { return }
            calls.removeValue(forKey: callID)
            live[messageID] = calls.isEmpty ? nil : calls
        }
    }

    /// The message with each running tool part's metadata overlaid by its latest live progress.
    // parity: core/src/session/runner/live-tool-metadata.ts#overlay [status=implemented hash=34fd018d1e62]
    public static func overlay(_ message: SessionMessageSchema.Info) -> SessionMessageSchema.Info {
        guard case .assistant(let assistant) = message else { return message }
        return .assistant(overlay(assistant))
    }

    /// `overlay` for the media-URI message union.
    public static func overlay(_ message: SessionMessageSchema.MediaInfo) -> SessionMessageSchema.MediaInfo {
        guard case .assistant(let assistant) = message else { return message }
        return .assistant(overlay(assistant))
    }

    private static func overlay(_ assistant: SessionMessageSchema.Assistant) -> SessionMessageSchema.Assistant {
        guard let calls = live.withLock({ $0[assistant.id.rawValue] }) else { return assistant }
        var changed = false
        let content = assistant.content.map { part -> SessionMessageSchema.AssistantContent in
            guard let next = overlayPart(part, calls: calls) else { return part }
            changed = true
            return next
        }
        guard changed else { return assistant }
        let a = assistant
        return SessionMessageSchema.Assistant(
            id: a.id, metadata: a.metadata, agent: a.agent, model: a.model,
            content: content, snapshot: a.snapshot, finish: a.finish,
            rawFinish: a.rawFinish, native: a.native, cost: a.cost,
            tokens: a.tokens, error: a.error, retry: a.retry, time: a.time
        )
    }

    private static func overlayPart(
        _ part: SessionMessageSchema.AssistantContent,
        calls: [String: [String: JSONValue]]
    ) -> SessionMessageSchema.AssistantContent? {
        guard case .tool(let tool) = part,
              case .running(let running) = tool.state,
              let metadata = calls[tool.id] else { return nil }
        var merged = running.metadata
        for (key, value) in metadata { merged[key] = value }
        return .tool(SessionMessageSchema.AssistantTool(
            id: tool.id,
            name: tool.name,
            executed: tool.executed,
            native: tool.native,
            state: .running(SessionMessageSchema.ToolStateRunning(input: running.input, metadata: merged)),
            time: tool.time
        ))
    }
}
