#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Helper types, fixtures, and Foundation/JSON utilities for `CLIACPBridgeTests`.
/// Intentionally does NOT `import Testing` (macOS Command Line Tools cross-import rule).

final class CLIACPTestFS: OpenCodeFileSystem, Sendable {
    private let files = Mutex<[String: [UInt8]]>([:])
    private let dirs = Mutex<Set<String>>(["/", "/workspace"])

    init(files: [String: String] = [:]) {
        var map: [String: [UInt8]] = [:]
        for (path, text) in files {
            map[path] = Array(text.utf8)
        }
        self.files.withLock { $0 = map }
    }

    func setFile(_ path: String, text: String) {
        files.withLock { $0[path] = Array(text.utf8) }
    }

    func exists(at path: String) async -> Bool {
        if files.withLock({ $0[path] != nil }) { return true }
        return dirs.withLock { $0.contains(path) }
    }

    func stat(at path: String) async throws -> FileStat {
        if let bytes = files.withLock({ $0[path] }) {
            return FileStat(type: .file, size: Int64(bytes.count), modifiedAtMs: 0)
        }
        if dirs.withLock({ $0.contains(path) }) {
            return FileStat(type: .directory, size: 0, modifiedAtMs: 0)
        }
        throw PlatformError.notFound(path)
    }

    func readFile(at path: String) async throws -> [UInt8] {
        guard let bytes = files.withLock({ $0[path] }) else {
            throw PlatformError.notFound(path)
        }
        return bytes
    }

    func writeFile(_ bytes: [UInt8], to path: String, createDirectories: Bool) async throws {
        files.withLock { $0[path] = bytes }
    }

    func remove(at path: String) async throws {
        files.withLock { _ = $0.removeValue(forKey: path) }
    }

    func makeDirectory(at path: String, recursive: Bool) async throws {
        dirs.withLock { _ = $0.insert(path) }
    }

    func readDirectory(at path: String) async throws -> [String] {
        []
    }

    func realPath(at path: String) async throws -> String {
        path
    }

    func chmod(at path: String, mode: UInt16) async throws {}
}

struct CLIACPRecordedPrompt: Equatable, Sendable {
    let sessionID: String
    let id: String
    let text: String
    let files: [PromptInputSchema.FileAttachment]
    let delivery: SessionInboxSchema.Delivery
    let resume: Bool?
}

struct CLIACPRecordedCommand: Equatable, Sendable {
    let sessionID: String
    let name: String
    let text: String
    let files: [PromptInputSchema.FileAttachment]
    let delivery: SessionInboxSchema.Delivery
}

struct CLIACPRecordedSynthetic: Equatable, Sendable {
    let sessionID: String
    let text: String
    let description: String?
    let delivery: SessionInboxSchema.Delivery
    let resume: Bool?
}

struct CLIACPRecordedCompact: Equatable, Sendable {
    let sessionID: String
    let id: String
}

struct CLIACPRecordedPermissionReply: Equatable, Sendable {
    let sessionID: String
    let requestID: String
    let decision: PermissionSchema.Reply
}

struct CLIACPRecordedFormReply: Equatable, Sendable {
    let sessionID: String
    let formID: String
    let answer: FormSchema.Answer
}

struct CLIACPRecordedFormCancel: Equatable, Sendable {
    let sessionID: String
    let formID: String
    let message: String?
}

struct CLIACPRecordedMcpAdd: Equatable, Sendable {
    let server: String
    let directory: String
    let config: McpSchema.ServerConfig
}

final class CLIACPTestBackend: CLIACP.BackendClient, Sendable {
    typealias PromptHook = @Sendable (CLIACPRecordedPrompt) async throws -> [OpenCodeEvent]
    typealias CompactHook = @Sendable (CLIACPRecordedCompact) async throws -> [OpenCodeEvent]
    typealias InterruptHook = @Sendable (String) async throws -> [OpenCodeEvent]
    typealias FormReplyHook = @Sendable (CLIACPRecordedFormReply) async throws -> [OpenCodeEvent]
    typealias FormCancelHook = @Sendable (CLIACPRecordedFormCancel) async throws -> [OpenCodeEvent]

    private struct State: Sendable {
        var plugins: [PluginSchema.Info]
        var models: [ModelSchema.Info]
        var defaultModel: ModelSchema.Ref?
        var agents: [AgentSchema.Info]
        var commands: [CommandSchema.Info]
        var sessions: [String: SessionSchema.Info] = [:]
        var messages: [String: [SessionMessageSchema.Info]] = [:]
        var activeSessions: [String: SessionActiveInfo] = [:]
        var nextSessionSeq: Int = 1

        var prompts: [CLIACPRecordedPrompt] = []
        var submittedCommands: [CLIACPRecordedCommand] = []
        var synthetics: [CLIACPRecordedSynthetic] = []
        var compacts: [CLIACPRecordedCompact] = []
        var interrupts: [String] = []
        var permissionReplies: [CLIACPRecordedPermissionReply] = []
        var formReplies: [CLIACPRecordedFormReply] = []
        var formCancels: [CLIACPRecordedFormCancel] = []
        var mcpAdds: [CLIACPRecordedMcpAdd] = []
        var sessionUpdateCount: Int = 0
        var switchedModels: [(String, ModelSchema.Ref)] = []
        var switchedAgents: [(String, String)] = []

        var nextSubID: UInt64 = 1
        var subscribers: [UInt64: AsyncThrowingStream<OpenCodeEvent, any Swift.Error>.Continuation] = [:]
        var failListWithUnavailable: Bool = false

        var onPrompt: PromptHook?
        var onCompact: CompactHook?
        var onInterrupt: InterruptHook?
        var onFormReply: FormReplyHook?
        var onFormCancel: FormCancelHook?
    }

    private let state: Mutex<State>

    static func defaultModels() -> [ModelSchema.Info] {
        [
            ModelSchema.Info(
                id: ModelSchema.ID(rawValue: "first-model"),
                modelID: ModelSchema.ID(rawValue: "first-model"),
                providerID: ProviderSchema.ID(rawValue: "test"),
                name: "First Model",
                capabilities: ModelSchema.Capabilities.default(),
                variants: [
                    ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "default")),
                    ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "high")),
                ],
                time: ModelSchema.Info.Time(released: 0),
                cost: [],
                status: .active,
                enabled: true,
                limit: ModelSchema.Info.Limit(context: 128_000, output: 16_000)
            ),
            ModelSchema.Info(
                id: ModelSchema.ID(rawValue: "second-model"),
                modelID: ModelSchema.ID(rawValue: "second-model"),
                providerID: ProviderSchema.ID(rawValue: "test"),
                name: "Second Model",
                capabilities: ModelSchema.Capabilities.default(),
                variants: [
                    ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "low")),
                    ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "medium")),
                    ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "high")),
                ],
                time: ModelSchema.Info.Time(released: 0),
                cost: [],
                status: .active,
                enabled: true,
                limit: ModelSchema.Info.Limit(context: 200_000, output: 32_000)
            ),
        ]
    }

    static func defaultAgents() -> [AgentSchema.Info] {
        [
            AgentSchema.Info(
                id: AgentSchema.ID(rawValue: "build"),
                name: AgentSchema.Name(rawValue: "Build"),
                request: ProviderSchema.Request(),
                description: "Build agent",
                mode: .primary,
                hidden: false,
                permissions: []
            ),
            AgentSchema.Info(
                id: AgentSchema.ID(rawValue: "plan"),
                name: AgentSchema.Name(rawValue: "Plan"),
                request: ProviderSchema.Request(),
                description: "Plan agent",
                mode: .primary,
                hidden: false,
                permissions: []
            ),
            AgentSchema.Info(
                id: AgentSchema.ID(rawValue: "helper"),
                name: AgentSchema.Name(rawValue: "Helper"),
                request: ProviderSchema.Request(),
                mode: .subagent,
                hidden: false,
                permissions: []
            ),
        ]
    }

    static func defaultCommands() -> [CommandSchema.Info] {
        [
            CommandSchema.Info(name: "review", description: "Review changes"),
        ]
    }

    static func makeSession(
        id: String,
        cwd: String = "/workspace",
        title: String? = nil,
        agent: String? = nil,
        model: SessionSchema.ModelRef? = nil,
        cost: Double = 0,
        created: Int64 = 1_700_000_000_000,
        updated: Int64 = 1_700_000_001_000,
        metadata: [String: JSONValue]? = nil,
        permissions: SessionSchema.PermissionRuleset? = nil
    ) -> SessionSchema.Info {
        SessionSchema.Info(
            id: SessionID(rawValue: id)!,
            projectID: ProjectID(rawValue: "prj_test"),
            agent: agent,
            model: model,
            cost: cost,
            tokens: .zero,
            time: SessionSchema.Info.Time(created: created, updated: updated),
            title: title,
            location: OpenCodeLocation(directory: cwd),
            metadata: metadata,
            permissions: permissions
        )
    }

    init(
        models: [ModelSchema.Info] = CLIACPTestBackend.defaultModels(),
        defaultModel: ModelSchema.Ref? = ModelSchema.Ref(
            id: ModelSchema.ID(rawValue: "first-model"),
            providerID: ProviderSchema.ID(rawValue: "test")
        ),
        agents: [AgentSchema.Info] = CLIACPTestBackend.defaultAgents(),
        commands: [CommandSchema.Info] = CLIACPTestBackend.defaultCommands()
    ) {
        let plugin = PluginSchema.Info(
            id: PluginSchema.ID(rawValue: "builtin"),
            source: .builtin,
            features: PluginSchema.Features(server: true),
            state: .active
        )
        self.state = Mutex(
            State(
                plugins: [plugin],
                models: models,
                defaultModel: defaultModel,
                agents: agents,
                commands: commands
            )
        )
    }

    func setHooks(
        onPrompt: PromptHook? = nil,
        onCompact: CompactHook? = nil,
        onInterrupt: InterruptHook? = nil,
        onFormReply: FormReplyHook? = nil,
        onFormCancel: FormCancelHook? = nil
    ) {
        state.withLock { s in
            if let onPrompt { s.onPrompt = onPrompt }
            if let onCompact { s.onCompact = onCompact }
            if let onInterrupt { s.onInterrupt = onInterrupt }
            if let onFormReply { s.onFormReply = onFormReply }
            if let onFormCancel { s.onFormCancel = onFormCancel }
        }
    }

    func putSession(_ session: SessionSchema.Info) {
        state.withLock { $0.sessions[session.id.rawValue] = session }
    }

    func getSession(_ id: String) -> SessionSchema.Info? {
        state.withLock { $0.sessions[id] }
    }

    func sessionCount() -> Int {
        state.withLock { $0.sessions.count }
    }

    func setMessages(sessionID: String, _ messages: [SessionMessageSchema.Info]) {
        state.withLock { $0.messages[sessionID] = messages }
    }

    func setActive(sessionID: String, active: Bool) {
        state.withLock { s in
            if active {
                s.activeSessions[sessionID] = SessionActiveInfo(type: "running")
            } else {
                s.activeSessions.removeValue(forKey: sessionID)
            }
        }
    }

    func addModel(_ model: ModelSchema.Info) {
        state.withLock { $0.models.append(model) }
    }

    func setFailListWithUnavailable(_ flag: Bool) {
        state.withLock { $0.failListWithUnavailable = flag }
    }

    func sendEvents(_ events: [OpenCodeEvent]) {
        let subs = state.withLock { Array($0.subscribers.values) }
        for event in events {
            for sub in subs {
                sub.yield(event)
            }
        }
    }

    func closeAllEventStreams() {
        let subs = state.withLock { s -> [AsyncThrowingStream<OpenCodeEvent, any Swift.Error>.Continuation] in
            let all = Array(s.subscribers.values)
            s.subscribers.removeAll()
            return all
        }
        for sub in subs {
            sub.finish()
        }
    }

    var prompts: [CLIACPRecordedPrompt] { state.withLock { $0.prompts } }
    var submittedCommands: [CLIACPRecordedCommand] { state.withLock { $0.submittedCommands } }
    var synthetics: [CLIACPRecordedSynthetic] { state.withLock { $0.synthetics } }
    var compacts: [CLIACPRecordedCompact] { state.withLock { $0.compacts } }
    var interrupts: [String] { state.withLock { $0.interrupts } }
    var permissionReplies: [CLIACPRecordedPermissionReply] { state.withLock { $0.permissionReplies } }
    var formReplies: [CLIACPRecordedFormReply] { state.withLock { $0.formReplies } }
    var formCancels: [CLIACPRecordedFormCancel] { state.withLock { $0.formCancels } }
    var mcpAdds: [CLIACPRecordedMcpAdd] { state.withLock { $0.mcpAdds } }
    var sessionUpdateCount: Int { state.withLock { $0.sessionUpdateCount } }
    var switchedModels: [(String, ModelSchema.Ref)] { state.withLock { $0.switchedModels } }
    var switchedAgents: [(String, String)] { state.withLock { $0.switchedAgents } }

    func eventSubscribe() -> AsyncThrowingStream<OpenCodeEvent, any Swift.Error> {
        AsyncThrowingStream { continuation in
            let id = state.withLock { s -> UInt64 in
                let id = s.nextSubID
                s.nextSubID += 1
                s.subscribers[id] = continuation
                return id
            }
            continuation.yield(OpenCodeEvent(id: "evt_connected", type: "server.connected", data: .object([:])))
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func pluginList(directory: String) async throws -> [PluginSchema.Info] {
        state.withLock { $0.plugins }
    }

    func modelList(directory: String) async throws -> [ModelSchema.Info] {
        state.withLock { $0.models }
    }

    func modelDefault(directory: String) async throws -> ModelSchema.Ref? {
        state.withLock { $0.defaultModel }
    }

    func agentList(directory: String) async throws -> [AgentSchema.Info] {
        state.withLock { $0.agents }
    }

    func commandList(directory: String) async throws -> [CommandSchema.Info] {
        state.withLock { $0.commands }
    }

    func sessionCreate(
        location: LocationSchema.PublicRef,
        permissions: PermissionSchema.Ruleset?,
        metadata: [String: JSONValue]?
    ) async throws -> SessionSchema.Info {
        state.withLock { s in
            let seq = s.nextSessionSeq
            s.nextSessionSeq += 1
            let id = "ses_test_\(seq)"
            let mappedPerms: SessionSchema.PermissionRuleset? = permissions?.map { r in
                SessionSchema.PermissionRule(
                    action: r.action,
                    resource: r.resource,
                    effect: SessionSchema.PermissionEffect(rawValue: r.effect.rawValue) ?? .allow
                )
            }
            let info = Self.makeSession(
                id: id,
                cwd: location.directory.rawValue,
                metadata: metadata,
                permissions: mappedPerms
            )
            s.sessions[id] = info
            return info
        }
    }

    func sessionGet(sessionID: String) async throws -> SessionSchema.Info {
        guard let info = state.withLock({ $0.sessions[sessionID] }) else {
            throw OpenCodeProtocol.SessionNotFoundError(sessionID: sessionID, message: "not found")
        }
        return info
    }

    func sessionList(
        directory: String?,
        order: ProtocolSortOrder?,
        limit: Int?,
        cursor: String?
    ) async throws -> SessionsResponse {
        let unavailable = state.withLock { $0.failListWithUnavailable }
        if unavailable {
            throw ClientError(reason: .transport, detail: "connection refused")
        }
        let all = state.withLock { Array($0.sessions.values) }
            .filter { directory == nil || $0.location.directory == directory }
            .sorted { $0.time.updated > $1.time.updated }
        return SessionsResponse(data: all, cursor: SessionsCursorPage())
    }

    func sessionUpdate(
        sessionID: String,
        permissions: PermissionSchema.Ruleset?,
        metadata: [String: JSONValue]?
    ) async throws {
        try state.withLock { s in
            guard let existing = s.sessions[sessionID] else {
                throw OpenCodeProtocol.SessionNotFoundError(sessionID: sessionID, message: "not found")
            }
            s.sessionUpdateCount += 1
            let nextPerms: SessionSchema.PermissionRuleset? = permissions.map { list in
                list.map { r in
                    SessionSchema.PermissionRule(
                        action: r.action,
                        resource: r.resource,
                        effect: SessionSchema.PermissionEffect(rawValue: r.effect.rawValue) ?? .allow
                    )
                }
            } ?? existing.permissions
            let nextMeta = metadata ?? existing.metadata
            s.sessions[sessionID] = SessionSchema.Info(
                id: existing.id,
                parentID: existing.parentID,
                fork: existing.fork,
                projectID: existing.projectID,
                agent: existing.agent,
                model: existing.model,
                cost: existing.cost,
                tokens: existing.tokens,
                outcome: existing.outcome,
                time: existing.time,
                title: existing.title,
                location: existing.location,
                subpath: existing.subpath,
                metadata: nextMeta,
                permissions: nextPerms,
                revert: existing.revert
            )
        }
    }

    func sessionRemove(sessionID: String) async throws {
        try state.withLock { s in
            guard s.sessions.removeValue(forKey: sessionID) != nil else {
                throw OpenCodeProtocol.SessionNotFoundError(sessionID: sessionID, message: "not found")
            }
        }
    }

    func sessionFork(sessionID: String) async throws -> SessionSchema.Info {
        try state.withLock { s in
            guard let src = s.sessions[sessionID] else {
                throw OpenCodeProtocol.SessionNotFoundError(sessionID: sessionID, message: "not found")
            }
            let seq = s.nextSessionSeq
            s.nextSessionSeq += 1
            let forkId = "ses_fork_\(seq)"
            let forked = SessionSchema.Info(
                id: SessionID(rawValue: forkId)!,
                parentID: src.parentID,
                projectID: src.projectID,
                agent: src.agent,
                model: src.model,
                cost: src.cost,
                tokens: src.tokens,
                time: src.time,
                title: src.title,
                location: src.location,
                metadata: src.metadata,
                permissions: src.permissions
            )
            s.sessions[forkId] = forked
            return forked
        }
    }

    func sessionActive() async throws -> [String: SessionActiveInfo] {
        state.withLock { $0.activeSessions }
    }

    func sessionSwitchModel(sessionID: String, model: ModelSchema.Ref) async throws {
        state.withLock { $0.switchedModels.append((sessionID, model)) }
    }

    func sessionSwitchAgent(sessionID: String, agent: String) async throws {
        state.withLock { $0.switchedAgents.append((sessionID, agent)) }
    }

    func sessionPrompt(
        sessionID: String,
        id: String,
        text: String,
        files: [PromptInputSchema.FileAttachment],
        delivery: SessionInboxSchema.Delivery,
        resume: Bool?
    ) async throws {
        let recorded = CLIACPRecordedPrompt(
            sessionID: sessionID,
            id: id,
            text: text,
            files: files,
            delivery: delivery,
            resume: resume
        )
        let hook = state.withLock { s -> PromptHook? in
            s.prompts.append(recorded)
            return s.onPrompt
        }
        if let hook {
            let events = try await hook(recorded)
            if !events.isEmpty {
                sendEvents(events)
            }
        }
    }

    func sessionCommand(
        sessionID: String,
        name: String,
        text: String,
        files: [PromptInputSchema.FileAttachment],
        delivery: SessionInboxSchema.Delivery
    ) async throws {
        state.withLock {
            $0.submittedCommands.append(
                CLIACPRecordedCommand(sessionID: sessionID, name: name, text: text, files: files, delivery: delivery)
            )
        }
    }

    func sessionSynthetic(
        sessionID: String,
        text: String,
        description: String?,
        delivery: SessionInboxSchema.Delivery,
        resume: Bool?
    ) async throws {
        state.withLock {
            $0.synthetics.append(
                CLIACPRecordedSynthetic(
                    sessionID: sessionID,
                    text: text,
                    description: description,
                    delivery: delivery,
                    resume: resume
                )
            )
        }
    }

    func sessionCompact(sessionID: String, id: String) async throws {
        let recorded = CLIACPRecordedCompact(sessionID: sessionID, id: id)
        let hook = state.withLock { s -> CompactHook? in
            s.compacts.append(recorded)
            return s.onCompact
        }
        if let hook {
            let events = try await hook(recorded)
            if !events.isEmpty {
                sendEvents(events)
            }
        }
    }

    func sessionInterrupt(sessionID: String) async throws {
        let hook = state.withLock { s -> InterruptHook? in
            s.interrupts.append(sessionID)
            return s.onInterrupt
        }
        if let hook {
            let events = try await hook(sessionID)
            if !events.isEmpty {
                sendEvents(events)
            }
        }
    }

    func sessionFormReply(sessionID: String, formID: String, answer: FormSchema.Answer) async throws {
        let recorded = CLIACPRecordedFormReply(sessionID: sessionID, formID: formID, answer: answer)
        let hook = state.withLock { s -> FormReplyHook? in
            s.formReplies.append(recorded)
            return s.onFormReply
        }
        if let hook {
            let events = try await hook(recorded)
            if !events.isEmpty {
                sendEvents(events)
            }
        }
    }

    func sessionFormCancel(sessionID: String, formID: String, message: String?) async throws {
        let recorded = CLIACPRecordedFormCancel(sessionID: sessionID, formID: formID, message: message)
        let hook = state.withLock { s -> FormCancelHook? in
            s.formCancels.append(recorded)
            return s.onFormCancel
        }
        if let hook {
            let events = try await hook(recorded)
            if !events.isEmpty {
                sendEvents(events)
            }
        }
    }

    func messageList(
        sessionID: String,
        limit: Int?,
        order: ProtocolSortOrder?,
        cursor: String?
    ) async throws -> SessionMessagesResponse {
        let all = state.withLock { $0.messages[sessionID] ?? [] }
        let pageSize = limit ?? 200
        let offset = cursor.flatMap(Int.init) ?? 0
        guard offset < all.count else {
            return SessionMessagesResponse(data: [], cursor: MessagesCursorPage())
        }
        let end = min(all.count, offset + pageSize)
        let slice = Array(all[offset..<end])
        let next = end < all.count ? String(end) : nil
        return SessionMessagesResponse(data: slice, cursor: MessagesCursorPage(next: next))
    }

    func permissionReply(sessionID: String, requestID: String, decision: PermissionSchema.Reply) async throws {
        state.withLock {
            $0.permissionReplies.append(
                CLIACPRecordedPermissionReply(sessionID: sessionID, requestID: requestID, decision: decision)
            )
        }
    }

    func experimentalMcpAdd(server: String, directory: String, config: McpSchema.ServerConfig) async throws {
        state.withLock {
            $0.mcpAdds.append(CLIACPRecordedMcpAdd(server: server, directory: directory, config: config))
        }
    }
}

/// Full end-to-end ACP wire fixture pairing `CLIACP.Agent.connect` and `CLIACP.PeerClient` over `NDJSONStream.pair()`.
final class CLIACPWireFixture: Sendable {
    private final class Recording: Sendable {
        private struct Data: Sendable {
            var updates: [CLIACP.SessionNotification] = []
            var childUpdates: [CLIACP.Child.Update] = []
            var permissions: [CLIACP.RequestPermissionRequest] = []
            var elicitations: [CLIACP.CreateElicitationRequest] = []
        }

        private let data = Mutex(Data())

        func addUpdate(_ v: CLIACP.SessionNotification) { data.withLock { $0.updates.append(v) } }
        func addChildUpdate(_ v: CLIACP.Child.Update) { data.withLock { $0.childUpdates.append(v) } }
        func addPermission(_ v: CLIACP.RequestPermissionRequest) { data.withLock { $0.permissions.append(v) } }
        func addElicitation(_ v: CLIACP.CreateElicitationRequest) { data.withLock { $0.elicitations.append(v) } }

        var updates: [CLIACP.SessionNotification] { data.withLock { $0.updates } }
        var childUpdates: [CLIACP.Child.Update] { data.withLock { $0.childUpdates } }
        var permissions: [CLIACP.RequestPermissionRequest] { data.withLock { $0.permissions } }
        var elicitations: [CLIACP.CreateElicitationRequest] { data.withLock { $0.elicitations } }
    }

    let backend: CLIACPTestBackend
    let fs: CLIACPTestFS
    let agent: CLIACP.Agent.ConnectedAgent
    let peer: CLIACP.PeerClient
    private let recording: Recording

    init(
        backend: CLIACPTestBackend = CLIACPTestBackend(),
        fs: CLIACPTestFS = CLIACPTestFS(),
        version: String = "2.0.0-test",
        drainTimeoutNanoseconds: UInt64 = 150_000_000,
        permissionHandler: CLIACP.PeerClient.PermissionHandler? = nil,
        elicitationHandler: CLIACP.PeerClient.ElicitationHandler? = nil
    ) {
        self.backend = backend
        self.fs = fs
        let recording = Recording()
        self.recording = recording
        let (agentStream, clientStream) = CLIACP.NDJSONStream.pair()
        self.agent = CLIACP.Agent.connect(
            client: backend,
            stream: agentStream,
            fileSystem: fs,
            version: version,
            pollIntervalNanoseconds: 5_000_000,
            pollTimeoutNanoseconds: 250_000_000,
            drainTimeoutNanoseconds: drainTimeoutNanoseconds
        )
        self.peer = CLIACP.PeerClient(
            stream: clientStream,
            onUpdate: { note in
                recording.addUpdate(note)
            },
            onChildUpdate: { child in
                recording.addChildUpdate(child)
            },
            onPermission: { req, signal in
                recording.addPermission(req)
                if let permissionHandler {
                    return try await permissionHandler(req, signal)
                }
                return CLIACP.RequestPermissionResponse(outcome: .selected(optionId: "once"))
            },
            onElicitation: { req, signal in
                recording.addElicitation(req)
                if let elicitationHandler {
                    return try await elicitationHandler(req, signal)
                }
                return CLIACP.CreateElicitationResponse(action: "cancel")
            }
        )
    }

    var updates: [CLIACP.SessionNotification] { recording.updates }
    var childUpdates: [CLIACP.Child.Update] { recording.childUpdates }
    var permissions: [CLIACP.RequestPermissionRequest] { recording.permissions }
    var elicitations: [CLIACP.CreateElicitationRequest] { recording.elicitations }

    func close() async {
        await peer.close()
        await agent.close()
    }

    func waitUntil(
        timeoutMs: Int = 2000,
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

enum CLIACPTestEvents {
    static func delivered(sessionID: String, inboxID: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_delivered_\(inboxID)",
            type: "session.inbox.delivered",
            data: .object(["sessionID": .string(sessionID), "inboxID": .string(inboxID)])
        )
    }

    static func textDelta(sessionID: String, messageID: String, delta: String, ordinal: Int = 0) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_text",
            type: "session.text.delta",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string(messageID),
                "ordinal": .int(Int64(ordinal)),
                "delta": .string(delta),
            ])
        )
    }

    static func reasoningDelta(sessionID: String, messageID: String, delta: String, ordinal: Int = 0) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_reason",
            type: "session.reasoning.delta",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string(messageID),
                "ordinal": .int(Int64(ordinal)),
                "delta": .string(delta),
            ])
        )
    }

    static func toolStarted(sessionID: String, id: String, name: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_tool_start_\(id)",
            type: "session.tool.input.started",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string("msg_a"),
                "id": .string(id),
                "name": .string(name),
            ])
        )
    }

    static func toolCalled(sessionID: String, id: String, input: [String: JSONValue]) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_tool_called_\(id)",
            type: "session.tool.called",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string("msg_a"),
                "id": .string(id),
                "input": .object(input),
                "executed": .bool(false),
            ])
        )
    }

    static func toolProgress(sessionID: String, id: String, metadata: [String: JSONValue]) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_tool_progress_\(id)",
            type: "session.tool.progress",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string("msg_a"),
                "id": .string(id),
                "metadata": .object(metadata),
            ])
        )
    }

    static func toolSucceeded(
        sessionID: String,
        id: String,
        metadata: [String: JSONValue]? = nil,
        text: String
    ) -> OpenCodeEvent {
        var data: [String: JSONValue] = [
            "sessionID": .string(sessionID),
            "assistantMessageID": .string("msg_a"),
            "id": .string(id),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "executed": .bool(true),
        ]
        if let metadata {
            data["metadata"] = .object(metadata)
        }
        return OpenCodeEvent(id: "evt_tool_ok_\(id)", type: "session.tool.success", data: .object(data))
    }

    static func toolFailed(sessionID: String, id: String, message: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_tool_err_\(id)",
            type: "session.tool.failed",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string("msg_a"),
                "id": .string(id),
                "error": .object(["type": .string("tool.error"), "message": .string(message)]),
            ])
        )
    }

    static func stepEnded(
        sessionID: String,
        messageID: String = "msg_a",
        finish: String = "stop",
        input: Double = 10,
        output: Double = 5,
        reasoning: Double = 0,
        cacheRead: Double = 0,
        cacheWrite: Double = 0
    ) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_step_end",
            type: "session.step.ended",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string(messageID),
                "finish": .string(finish),
                "cost": .double(0.01),
                "tokens": .object([
                    "input": .double(input),
                    "output": .double(output),
                    "reasoning": .double(reasoning),
                    "cache": .object(["read": .double(cacheRead), "write": .double(cacheWrite)]),
                ]),
            ])
        )
    }

    static func stepFailed(sessionID: String, type: String, message: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_step_fail",
            type: "session.step.failed",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string("msg_a"),
                "error": .object(["type": .string(type), "message": .string(message)]),
            ])
        )
    }

    static func retryScheduled(sessionID: String, attempt: Int, atMs: Int64, type: String, message: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_retry",
            type: "session.retry.scheduled",
            data: .object([
                "sessionID": .string(sessionID),
                "assistantMessageID": .string("msg_a"),
                "attempt": .int(Int64(attempt)),
                "at": .int(atMs),
                "error": .object(["type": .string(type), "message": .string(message)]),
            ])
        )
    }

    static func stepStarted(sessionID: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_step_start",
            type: "session.step.started",
            data: .object(["sessionID": .string(sessionID), "assistantMessageID": .string("msg_a")])
        )
    }

    static func succeeded(sessionID: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_exec_ok",
            type: "session.execution.succeeded",
            data: .object(["sessionID": .string(sessionID)])
        )
    }

    static func interrupted(sessionID: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_exec_int",
            type: "session.execution.interrupted",
            data: .object(["sessionID": .string(sessionID), "reason": .string("user")])
        )
    }

    static func failed(sessionID: String, type: String, message: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_exec_fail",
            type: "session.execution.failed",
            data: .object([
                "sessionID": .string(sessionID),
                "error": .object(["type": .string(type), "message": .string(message)]),
            ])
        )
    }

    static func childCreated(id: String, parentID: String, title: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_child_\(id)",
            type: "session.created",
            data: .object([
                "sessionID": .string(id),
                "parentID": .string(parentID),
                "title": .string(title),
            ])
        )
    }

    static func childStarted(id: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_child_start_\(id)",
            type: "session.execution.started",
            data: .object(["sessionID": .string(id)])
        )
    }

    static func permissionAsked(
        sessionID: String,
        id: String,
        action: String = "shell",
        resources: [String] = [],
        metadata: [String: JSONValue]? = nil,
        sourceToolID: String? = nil
    ) -> OpenCodeEvent {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "sessionID": .string(sessionID),
            "action": .string(action),
            "resources": .array(resources.map { .string($0) }),
        ]
        if let metadata { obj["metadata"] = .object(metadata) }
        if let sourceToolID {
            obj["source"] = .object(["type": .string("tool"), "messageID": .string("msg_a"), "id": .string(sourceToolID)])
        }
        return OpenCodeEvent(id: "evt_perm_\(id)", type: "permission.asked", data: .object(obj))
    }

    static func formCreated(_ form: CLIACP.Elicitation.AskedForm) -> OpenCodeEvent {
        let encoded = (try? ClientCodec.toJSONValue(form)) ?? .object([:])
        return OpenCodeEvent(
            id: "evt_form_\(form.id)",
            type: "form.created",
            data: .object(["form": encoded])
        )
    }

    static func formReplied(sessionID: String, id: String) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt_form_rep_\(id)",
            type: "form.replied",
            data: .object(["sessionID": .string(sessionID), "id": .string(id), "answer": .object([:])])
        )
    }

    static func encodeJSONString<T: Encodable>(_ value: T) -> String {
        (try? ClientCodec.encodeString(value)) ?? ""
    }

    static func decodeJSONString<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        try? ClientCodec.decode(type, from: json)
    }

    static func makeErrorWithSecret(_ text: String) -> any Swift.Error {
        struct SecretBearingError: Swift.Error, CustomStringConvertible {
            let description: String
        }
        return SecretBearingError(description: text)
    }
}

final class CLIACPByteCollector: Sendable {
    private let storage = Mutex<[UInt8]>([])

    func append(_ bytes: [UInt8]) {
        storage.withLock { $0.append(contentsOf: bytes) }
    }

    var bytes: [UInt8] {
        storage.withLock { $0 }
    }
}
