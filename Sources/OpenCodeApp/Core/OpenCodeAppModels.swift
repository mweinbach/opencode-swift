import Foundation
import OpenCodeClient
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore

// MARK: - Server Connection & Credentials

/// Authentication credentials for connecting to a remote or paired OpenCode server.
public enum AppServerCredentials: Equatable, Hashable, Sendable {
    case none
    case basic(username: String, password: String)
    case bearer(token: String)

    /// Encodes the corresponding HTTP `Authorization` header value, or `nil` for `.none`.
    public var authorizationHeader: String? {
        switch self {
        case .none:
            return nil
        case let .basic(username, password):
            return ClientHTTPHeaders.basicAuthorization(username: username, password: password)
        case .bearer(let token):
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "Bearer \(trimmed)"
        }
    }

    public var headers: [String: String] {
        guard let auth = authorizationHeader else { return [:] }
        return ["Authorization": auth]
    }
}

/// Target server backend for `OpenCodeAppStore`.
public enum AppConnectionTarget: Equatable, Hashable, Sendable {
    case embedded(directory: String? = nil, configContent: String? = nil)
    case remote(url: String, credentials: AppServerCredentials = .none)
    case paired(url: String, code: String)

    public var displayLabel: String {
        switch self {
        case .embedded(let dir, _):
            if let dir, !dir.isEmpty {
                return "Embedded (\(dir))"
            }
            return "Embedded Local"
        case .remote(let url, _):
            return url
        case .paired(let url, _):
            return "\(url) (paired)"
        }
    }
}

/// Observable connection lifecycle state.
public enum AppConnectionState: Equatable, Hashable, Sendable {
    case disconnected
    case connecting
    case connected(serverVersion: String, modeLabel: String)
    case reconnecting(attempt: Int)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var shortLabel: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected(_, let mode): return mode
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))…"
        case .failed: return "Connection Error"
        }
    }
}

// MARK: - Theme & Settings

/// User-selected appearance mode bridged onto `OpenCodeTUI.ThemeDefaults`.
public enum AppThemeMode: String, CaseIterable, Equatable, Hashable, Sendable, Codable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public func resolvedMode(systemIsDark: Bool) -> Mode {
        switch self {
        case .system: return systemIsDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }

    public var nextMode: AppThemeMode {
        switch self {
        case .system: return .dark
        case .dark: return .light
        case .light: return .system
        }
    }
}

/// Right-hand inspector tabs in `OpenCodeRootView`.
public enum AppInspectorTab: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case context
    case todos
    case mcp
    case diffs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .context: return "Context"
        case .todos: return "Todos"
        case .mcp: return "MCP"
        case .diffs: return "Diffs"
        }
    }

    public var systemImage: String {
        switch self {
        case .context: return "gauge.with.dots.needle.33percent"
        case .todos: return "checklist"
        case .mcp: return "puzzlepiece.extension"
        case .diffs: return "doc.text.magnifyingglass"
        }
    }
}

/// Persistent application settings for appearance, markdown, and workspace presentation.
public struct AppSettings: Equatable, Hashable, Sendable, Codable {
    public var themeName: String
    public var themeMode: AppThemeMode
    public var concealMarkdown: Bool
    public var expandReasoningByDefault: Bool
    public var splitDiffView: Bool
    public var showInspector: Bool

    public init(
        themeName: String = "opencode",
        themeMode: AppThemeMode = .system,
        concealMarkdown: Bool = true,
        expandReasoningByDefault: Bool = false,
        splitDiffView: Bool = false,
        showInspector: Bool = true
    ) {
        self.themeName = themeName
        self.themeMode = themeMode
        self.concealMarkdown = concealMarkdown
        self.expandReasoningByDefault = expandReasoningByDefault
        self.splitDiffView = splitDiffView
        self.showInspector = showInspector
    }
}

// MARK: - Sessions

/// Live session execution / attention badge rendered in the session sidebar.
public enum AppSessionStatusBadge: Equatable, Hashable, Sendable {
    case idle
    case working
    case retrying(String)
    case blocked(permissions: Int, forms: Int)

    public var isWorking: Bool {
        switch self {
        case .working, .retrying: return true
        case .idle, .blocked: return false
        }
    }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var accessibilityLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .working:
            return "Working"
        case .retrying(let reason):
            return "Retrying: \(reason)"
        case let .blocked(permissions, forms):
            let total = permissions + forms
            return total == 1 ? "Needs attention" : "\(total) items need attention"
        }
    }
}

/// Sidebar summary row for a session.
public struct AppSessionSummary: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var directory: String
    public var projectID: String
    public var parentID: String?
    public var createdMs: Int64
    public var updatedMs: Int64
    public var archived: Bool
    public var cost: Double
    public var tokensTotal: Int
    public var badge: AppSessionStatusBadge

    public init(
        id: String,
        title: String,
        directory: String = "",
        projectID: String = ProjectID.global.rawValue,
        parentID: String? = nil,
        createdMs: Int64 = 0,
        updatedMs: Int64 = 0,
        archived: Bool = false,
        cost: Double = 0,
        tokensTotal: Int = 0,
        badge: AppSessionStatusBadge = .idle
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.projectID = projectID
        self.parentID = parentID
        self.createdMs = createdMs
        self.updatedMs = updatedMs
        self.archived = archived
        self.cost = cost
        self.tokensTotal = tokensTotal
        self.badge = badge
    }

    public init(from info: SessionSchema.Info, badge: AppSessionStatusBadge = .idle) {
        self.id = info.id.rawValue
        self.title = SessionTitleFallback.displayLabel(title: info.title, parentID: info.parentID?.rawValue)
        self.directory = info.location.directory
        self.projectID = info.projectID.rawValue
        self.parentID = info.parentID?.rawValue
        self.createdMs = info.time.created
        self.updatedMs = info.time.updated
        self.archived = info.time.archived != nil
        self.cost = info.cost
        self.tokensTotal = Int(info.tokens.total.rounded())
        self.badge = badge
    }
}

/// Time-grouped bucket of sessions displayed in `SessionSidebarView`.
public struct AppSessionGroup: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let sessions: [AppSessionSummary]

    public init(id: String, title: String, sessions: [AppSessionSummary]) {
        self.id = id
        self.title = title
        self.sessions = sessions
    }

    /// Groups sessions into `Today`, `Yesterday`, `Previous 7 Days`, and `Earlier` relative to `nowMs`.
    public static func group(
        _ sessions: [AppSessionSummary],
        nowMs: Int64 = Flock.currentEpochMs()
    ) -> [AppSessionGroup] {
        let dayMs: Int64 = 86_400_000
        let sorted = sessions
            .filter { !$0.archived }
            .sorted { lhs, rhs in
                if lhs.updatedMs != rhs.updatedMs { return lhs.updatedMs > rhs.updatedMs }
                return lhs.id > rhs.id
            }

        var today: [AppSessionSummary] = []
        var yesterday: [AppSessionSummary] = []
        var week: [AppSessionSummary] = []
        var earlier: [AppSessionSummary] = []

        for session in sorted {
            let age = max(0, nowMs - session.updatedMs)
            if session.updatedMs == 0 || age < dayMs {
                today.append(session)
            } else if age < dayMs * 2 {
                yesterday.append(session)
            } else if age < dayMs * 7 {
                week.append(session)
            } else {
                earlier.append(session)
            }
        }

        var groups: [AppSessionGroup] = []
        if !today.isEmpty { groups.append(AppSessionGroup(id: "today", title: "Today", sessions: today)) }
        if !yesterday.isEmpty { groups.append(AppSessionGroup(id: "yesterday", title: "Yesterday", sessions: yesterday)) }
        if !week.isEmpty { groups.append(AppSessionGroup(id: "week", title: "Previous 7 Days", sessions: week)) }
        if !earlier.isEmpty { groups.append(AppSessionGroup(id: "earlier", title: "Earlier", sessions: earlier)) }
        return groups
    }
}

// MARK: - Conversation Transcript

/// Lifecycle status of a tool invocation or shell execution.
public enum AppToolStatus: String, Equatable, Hashable, Sendable {
    case streaming
    case running
    case completed
    case error

    public var displayLabel: String {
        switch self {
        case .streaming: return "Preparing"
        case .running: return "Running"
        case .completed: return "Done"
        case .error: return "Failed"
        }
    }
}

/// Ordered content part inside an assistant response message.
public enum AppMessagePart: Identifiable, Equatable, Hashable, Sendable {
    case text(id: String, text: String)
    case reasoning(id: String, text: String, completed: Bool)
    case tool(
        id: String,
        name: String,
        status: AppToolStatus,
        summary: String,
        inputJSON: String?,
        output: String?,
        error: String?
    )

    public var id: String {
        switch self {
        case .text(let id, _): return id
        case .reasoning(let id, _, _): return id
        case .tool(let id, _, _, _, _, _, _): return id
        }
    }
}

/// Projected message item displayed in `SessionConversationView`.
public enum AppTranscriptMessage: Identifiable, Equatable, Hashable, Sendable {
    case user(id: String, text: String, timestampMs: Int64, mentions: [String], isOptimistic: Bool)
    case assistant(
        id: String,
        agent: String,
        model: String,
        parts: [AppMessagePart],
        completed: Bool,
        error: String?,
        cost: Double?,
        tokens: Int?,
        timestampMs: Int64
    )
    case shell(
        id: String,
        shellID: String,
        command: String,
        status: AppToolStatus,
        output: String?,
        exitCode: Int?,
        timestampMs: Int64
    )
    case system(id: String, text: String, isError: Bool, timestampMs: Int64)

    public var id: String {
        switch self {
        case .user(let id, _, _, _, _): return id
        case .assistant(let id, _, _, _, _, _, _, _, _): return id
        case .shell(let id, _, _, _, _, _, _): return id
        case .system(let id, _, _, _): return id
        }
    }
}

// MARK: - Permissions & Interactive Forms

/// Pending tool/action permission approval request.
public struct AppPermissionItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public let action: String
    public let resources: [String]
    public let savePatterns: [String]
    public let commandPreview: String?
    public let filePath: String?
    public let diffPatch: String?
    public let message: String?

    public init(
        id: String,
        sessionID: String,
        action: String,
        resources: [String] = [],
        savePatterns: [String] = [],
        commandPreview: String? = nil,
        filePath: String? = nil,
        diffPatch: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.resources = resources
        self.savePatterns = savePatterns
        self.commandPreview = commandPreview
        self.filePath = filePath
        self.diffPatch = diffPatch
        self.message = message
    }

    public init(from request: PermissionSchema.Request) {
        let meta = request.metadata ?? [:]
        func metaString(_ key: String) -> String? {
            if case .string(let s) = meta[key], !s.isEmpty { return s }
            return nil
        }
        self.id = request.id.rawValue
        self.sessionID = request.sessionID.rawValue
        self.action = request.action
        self.resources = request.resources
        self.savePatterns = request.save ?? request.resources
        self.commandPreview = metaString("command")
        self.filePath = metaString("filepath") ?? metaString("filePath") ?? metaString("path")
        self.diffPatch = metaString("diff") ?? metaString("patch")
        self.message = request.message
    }
}

/// Option inside a single-select or multi-select form field.
public struct AppFormOption: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { value }
    public let value: String
    public let label: String
    public let description: String?

    public init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }
}

/// Supported interactive field kinds in `FormPromptSheet`.
public enum AppFormFieldKind: Equatable, Hashable, Sendable {
    case text(placeholder: String?, defaultValue: String?)
    case singleSelect(options: [AppFormOption], allowCustom: Bool, defaultValue: String?)
    case multiSelect(options: [AppFormOption], allowCustom: Bool, defaultValues: [String])
    case boolean(defaultValue: Bool)
    case number(isInteger: Bool, minimum: Double?, maximum: Double?, defaultValue: Double?)
    case external(url: String)
}

/// One typed field inside an `AppFormItem`.
public struct AppFormField: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let description: String?
    public let required: Bool
    public let kind: AppFormFieldKind

    public init(
        key: String,
        title: String,
        description: String? = nil,
        required: Bool = false,
        kind: AppFormFieldKind
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.required = required
        self.kind = kind
    }

    public init(from field: FormSchema.Field) {
        switch field {
        case .string(let f):
            self.key = f.key
            self.title = f.title ?? f.key
            self.description = f.description
            self.required = f.required ?? false
            if let options = f.options, !options.isEmpty {
                self.kind = .singleSelect(
                    options: options.map { AppFormOption(value: $0.value, label: $0.label, description: $0.description) },
                    allowCustom: f.custom ?? false,
                    defaultValue: f.defaultValue
                )
            } else {
                self.kind = .text(placeholder: f.placeholder, defaultValue: f.defaultValue)
            }
        case .multiselect(let f):
            self.key = f.key
            self.title = f.title ?? f.key
            self.description = f.description
            self.required = f.required ?? false
            self.kind = .multiSelect(
                options: f.options.map { AppFormOption(value: $0.value, label: $0.label, description: $0.description) },
                allowCustom: f.custom ?? false,
                defaultValues: f.defaultValue ?? []
            )
        case .boolean(let f):
            self.key = f.key
            self.title = f.title ?? f.key
            self.description = f.description
            self.required = f.required ?? false
            self.kind = .boolean(defaultValue: f.defaultValue ?? false)
        case .number(let f):
            self.key = f.key
            self.title = f.title ?? f.key
            self.description = f.description
            self.required = f.required ?? false
            self.kind = .number(isInteger: false, minimum: f.minimum, maximum: f.maximum, defaultValue: f.defaultValue)
        case .integer(let f):
            self.key = f.key
            self.title = f.title ?? f.key
            self.description = f.description
            self.required = f.required ?? false
            self.kind = .number(isInteger: true, minimum: f.minimum, maximum: f.maximum, defaultValue: f.defaultValue)
        case .external(let f):
            self.key = f.key
            self.title = f.title ?? f.key
            self.description = f.description
            self.required = false
            self.kind = .external(url: f.url)
        }
    }
}

/// Pending interactive form/question prompt requested by the agent or an MCP tool.
public struct AppFormItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public let title: String
    public let message: String?
    public let fields: [AppFormField]

    public init(
        id: String,
        sessionID: String,
        title: String,
        message: String? = nil,
        fields: [AppFormField]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.message = message
        self.fields = fields
    }

    public init(from info: FormSchema.Info) {
        let msg: String?
        if case .string(let s) = info.metadata?["message"] {
            msg = s
        } else if case .string(let s) = info.metadata?["description"] {
            msg = s
        } else {
            msg = nil
        }
        self.id = info.id.rawValue
        self.sessionID = info.sessionID
        self.title = info.title
        self.message = msg
        self.fields = info.fields.elements.map(AppFormField.init(from:))
    }

    /// Produces initial default values keyed by field key.
    public func defaultDraftAnswers() -> FormSchema.Answer {
        var out: FormSchema.Answer = [:]
        for field in fields {
            switch field.kind {
            case .text(_, let def):
                if let def { out[field.key] = .string(def) }
            case .singleSelect(let opts, _, let def):
                if let def {
                    out[field.key] = .string(def)
                } else if let first = opts.first {
                    out[field.key] = .string(first.value)
                }
            case .multiSelect(_, _, let defs):
                out[field.key] = .strings(defs)
            case .boolean(let def):
                out[field.key] = .bool(def)
            case .number(_, _, _, let def):
                if let def { out[field.key] = .number(def) }
            case .external:
                break
            }
        }
        return out
    }
}

// MARK: - Catalogs: Agents, Models, Integrations, MCP, Todos, Usage, Pairing

public struct AppAgentItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let colorHex: String?
    public let isPrimary: Bool
    public let defaultModel: ModelSchema.Ref?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        colorHex: String? = nil,
        isPrimary: Bool = true,
        defaultModel: ModelSchema.Ref? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.colorHex = colorHex
        self.isPrimary = isPrimary
        self.defaultModel = defaultModel
    }

    public init(from info: AgentSchema.Info) {
        self.id = info.id.rawValue
        self.name = info.name.rawValue.isEmpty ? TUIUtil.titlecase(info.id.rawValue) : info.name.rawValue
        self.description = info.description
        self.colorHex = info.color?.rawValue
        self.isPrimary = info.mode != .subagent
        self.defaultModel = info.model
    }

    public static let defaults: [AppAgentItem] = [
        AppAgentItem(id: "build", name: "Build", description: "Default coding agent", isPrimary: true),
        AppAgentItem(id: "plan", name: "Plan", description: "Read-only planning & exploration", isPrimary: true),
    ]
}

public struct AppModelItem: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(providerID)/\(modelID)" }
    public let modelID: String
    public let providerID: String
    public let name: String
    public let providerName: String
    public let variants: [String]
    public let contextLimit: Int?

    public init(
        modelID: String,
        providerID: String,
        name: String,
        providerName: String,
        variants: [String] = [],
        contextLimit: Int? = nil
    ) {
        self.modelID = modelID
        self.providerID = providerID
        self.name = name
        self.providerName = providerName
        self.variants = variants
        self.contextLimit = contextLimit
    }

    public func ref(variant: String? = nil) -> ModelSchema.Ref {
        ModelSchema.Ref(
            id: ModelSchema.ID(rawValue: modelID),
            providerID: ProviderSchema.ID(rawValue: providerID),
            variant: variant.flatMap { $0.isEmpty ? nil : ModelSchema.VariantID(rawValue: $0) }
        )
    }
}

public struct AppProviderIntegration: Identifiable, Equatable, Hashable, Sendable {
    public static let popularOrder: [String: Int] = [
        "opencode": 0,
        "anthropic": 1,
        "openai": 2,
        "google": 3,
        "github-copilot": 4,
        "openrouter": 5,
    ]

    public let id: String
    public let name: String
    public let isConnected: Bool
    public let supportsAPIKey: Bool
    public let connectionSummary: String
    public let envVars: [String]

    public init(
        id: String,
        name: String,
        isConnected: Bool = false,
        supportsAPIKey: Bool = true,
        connectionSummary: String = "",
        envVars: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.supportsAPIKey = supportsAPIKey
        self.connectionSummary = connectionSummary
        self.envVars = envVars
    }

    public var isPopular: Bool {
        Self.popularOrder[id] != nil
    }

    public var sortPriority: Int {
        Self.popularOrder[id] ?? 99
    }

    public init(from info: IntegrationSchema.Info) {
        self.id = info.id.rawValue
        self.name = info.name
        self.isConnected = !info.connections.isEmpty
        var hasKey = false
        var envList: [String] = []
        for method in info.methods {
            switch method {
            case .key:
                hasKey = true
            case .env(let e):
                envList.append(contentsOf: e.names)
            default:
                break
            }
        }
        self.supportsAPIKey = hasKey
        self.envVars = envList
        if info.connections.count > 1 {
            self.connectionSummary = "\(info.connections.count) connections"
        } else if let first = info.connections.first {
            switch first {
            case .credential(let c): self.connectionSummary = c.label
            case .env(let e): self.connectionSummary = "$\(e.name)"
            }
        } else {
            self.connectionSummary = ""
        }
    }
}

public struct AppMCPServerItem: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let title: String?
    public let statusLabel: String
    public let isConnected: Bool
    public let isFailed: Bool
    public let detail: String?

    public init(
        name: String,
        title: String? = nil,
        statusLabel: String,
        isConnected: Bool,
        isFailed: Bool,
        detail: String? = nil
    ) {
        self.name = name
        self.title = title
        self.statusLabel = statusLabel
        self.isConnected = isConnected
        self.isFailed = isFailed
        self.detail = detail
    }

    public init(from server: McpSchema.Server) {
        self.name = server.name
        self.title = server.title
        switch server.status {
        case .connected:
            self.statusLabel = "Connected"
            self.isConnected = true
            self.isFailed = false
            self.detail = nil
        case .pending:
            self.statusLabel = "Connecting"
            self.isConnected = false
            self.isFailed = false
            self.detail = nil
        case .disabled:
            self.statusLabel = "Disabled"
            self.isConnected = false
            self.isFailed = false
            self.detail = nil
        case .failed(let err):
            self.statusLabel = "Error"
            self.isConnected = false
            self.isFailed = true
            self.detail = err
        case .needsAuth(let err):
            self.statusLabel = "Needs Auth"
            self.isConnected = false
            self.isFailed = false
            self.detail = err
        }
    }
}

public enum AppTodoStatus: String, Equatable, Hashable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled
}

public struct AppTodoItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let content: String
    public let status: AppTodoStatus
    public let priority: String?

    public init(id: String, content: String, status: AppTodoStatus = .pending, priority: String? = nil) {
        self.id = id
        self.content = content
        self.status = status
        self.priority = priority
    }
}

public struct AppUsageLimitItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let provider: String
    public let scope: String
    public let spentDollars: Double
    public let limitDollars: Double
    public let remainingPercent: Int
    public let resetsLabel: String
    public let isLow: Bool
    public let isReached: Bool

    public init(
        id: String,
        title: String,
        provider: String,
        scope: String,
        spentDollars: Double,
        limitDollars: Double,
        remainingPercent: Int,
        resetsLabel: String,
        isLow: Bool,
        isReached: Bool
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.scope = scope
        self.spentDollars = spentDollars
        self.limitDollars = limitDollars
        self.remainingPercent = remainingPercent
        self.resetsLabel = resetsLabel
        self.isLow = isLow
        self.isReached = isReached
    }
}

/// Generated device pairing payload backed by `OpenCodeUtil.QR`.
public struct AppPairingPayload: Equatable, Hashable, Sendable {
    public let code: String
    public let links: [String]
    public let primaryLink: String
    public let expiresInMinutes: Int
    public let isLoopbackOnly: Bool
    public let qrMatrix: [[Bool]]
    public let qrSVG: String?

    public init(
        code: String,
        links: [String],
        primaryLink: String,
        expiresInMinutes: Int,
        isLoopbackOnly: Bool,
        qrMatrix: [[Bool]],
        qrSVG: String?
    ) {
        self.code = code
        self.links = links
        self.primaryLink = primaryLink
        self.expiresInMinutes = expiresInMinutes
        self.isLoopbackOnly = isLoopbackOnly
        self.qrMatrix = qrMatrix
        self.qrSVG = qrSVG
    }

    /// Builds a pairing payload and encodes `primaryLink` into a crisp ISO QR matrix via `OpenCodeUtil.QR`.
    public static func make(
        code: String,
        baseURLs: [String],
        expiresInSeconds: Int
    ) throws -> AppPairingPayload {
        let normalizedURLs = baseURLs.isEmpty ? ["http://127.0.0.1:4096"] : baseURLs
        let links = normalizedURLs.map { url -> String in
            let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
            return "\(trimmed)/auth/connect/\(code)"
        }
        let primary = links.first ?? "http://127.0.0.1:4096/auth/connect/\(code)"
        let isLoopback = normalizedURLs.allSatisfy {
            $0.contains("127.0.0.1") || $0.contains("localhost") || $0.contains("[::1]")
        }
        let matrix = try QR.encode(primary)
        let svg = try? QR.renderSVG(primary, border: 2)
        let minutes = max(1, Int((Double(expiresInSeconds) / 60.0).rounded()))
        return AppPairingPayload(
            code: code,
            links: links,
            primaryLink: primary,
            expiresInMinutes: minutes,
            isLoopbackOnly: isLoopback,
            qrMatrix: matrix,
            qrSVG: svg
        )
    }
}

// MARK: - Unified & Split Diff Model

public enum AppDiffLineKind: String, Equatable, Hashable, Sendable {
    case context
    case added
    case removed
    case header
}

public struct AppDiffLine: Identifiable, Equatable, Hashable, Sendable {
    public let id: Int
    public let kind: AppDiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(id: Int, kind: AppDiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct AppSplitDiffRow: Identifiable, Equatable, Hashable, Sendable {
    public let id: Int
    public let left: AppDiffLine?
    public let right: AppDiffLine?

    public init(id: Int, left: AppDiffLine?, right: AppDiffLine?) {
        self.id = id
        self.left = left
        self.right = right
    }
}

/// File diff entry with pre-parsed unified lines and paired split-view rows.
public struct AppFileDiffItem: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
    public let additions: Int
    public let deletions: Int
    public let patch: String
    public let unifiedLines: [AppDiffLine]
    public let splitRows: [AppSplitDiffRow]

    public init(path: String, status: String, additions: Int, deletions: Int, patch: String) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
        let parsed = Self.parseUnifiedPatch(patch)
        self.unifiedLines = parsed
        self.splitRows = Self.pairForSplitView(parsed)
    }

    public static func parseUnifiedPatch(_ patch: String) -> [AppDiffLine] {
        guard !patch.isEmpty else { return [] }
        let rawLines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [AppDiffLine] = []
        out.reserveCapacity(rawLines.count)
        var oldNum = 0
        var newNum = 0
        var nextID = 0

        for raw in rawLines {
            if raw.hasPrefix("@@") {
                if let range = parseHunkHeader(raw) {
                    oldNum = range.oldStart
                    newNum = range.newStart
                }
                out.append(AppDiffLine(id: nextID, kind: .header, oldLineNumber: nil, newLineNumber: nil, text: raw))
            } else if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
                out.append(AppDiffLine(id: nextID, kind: .header, oldLineNumber: nil, newLineNumber: nil, text: raw))
            } else if raw.hasPrefix("+") {
                out.append(AppDiffLine(id: nextID, kind: .added, oldLineNumber: nil, newLineNumber: newNum, text: String(raw.dropFirst())))
                newNum += 1
            } else if raw.hasPrefix("-") {
                out.append(AppDiffLine(id: nextID, kind: .removed, oldLineNumber: oldNum, newLineNumber: nil, text: String(raw.dropFirst())))
                oldNum += 1
            } else if raw.hasPrefix(" ") {
                out.append(AppDiffLine(id: nextID, kind: .context, oldLineNumber: oldNum, newLineNumber: newNum, text: String(raw.dropFirst())))
                oldNum += 1
                newNum += 1
            } else if !raw.isEmpty {
                out.append(AppDiffLine(id: nextID, kind: .context, oldLineNumber: oldNum > 0 ? oldNum : nil, newLineNumber: newNum > 0 ? newNum : nil, text: raw))
                if oldNum > 0 { oldNum += 1 }
                if newNum > 0 { newNum += 1 }
            }
            nextID += 1
        }
        return out
    }

    public static func pairForSplitView(_ lines: [AppDiffLine]) -> [AppSplitDiffRow] {
        var rows: [AppSplitDiffRow] = []
        var idx = 0
        var rowID = 0

        while idx < lines.count {
            let line = lines[idx]
            switch line.kind {
            case .header, .context:
                rows.append(AppSplitDiffRow(id: rowID, left: line, right: line))
                rowID += 1
                idx += 1
            case .removed:
                var removed: [AppDiffLine] = []
                while idx < lines.count, lines[idx].kind == .removed {
                    removed.append(lines[idx])
                    idx += 1
                }
                var added: [AppDiffLine] = []
                while idx < lines.count, lines[idx].kind == .added {
                    added.append(lines[idx])
                    idx += 1
                }
                let pairCount = max(removed.count, added.count)
                for p in 0..<pairCount {
                    rows.append(AppSplitDiffRow(
                        id: rowID,
                        left: p < removed.count ? removed[p] : nil,
                        right: p < added.count ? added[p] : nil
                    ))
                    rowID += 1
                }
            case .added:
                rows.append(AppSplitDiffRow(id: rowID, left: nil, right: line))
                rowID += 1
                idx += 1
            }
        }
        return rows
    }

    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int)? {
        // Parses `@@ -<oldStart>[,count] +<newStart>[,count] @@`
        let tokens = header.split(separator: " ")
        var oldStart: Int?
        var newStart: Int?
        for token in tokens {
            if token.hasPrefix("-") && oldStart == nil {
                let body = token.dropFirst().split(separator: ",").first
                oldStart = body.flatMap { Int($0) }
            } else if token.hasPrefix("+") && newStart == nil {
                let body = token.dropFirst().split(separator: ",").first
                newStart = body.flatMap { Int($0) }
            }
        }
        guard let o = oldStart, let n = newStart else { return nil }
        return (o, n)
    }
}

/// Toast notification shown at the bottom/top of the workspace window.
public struct AppToastNotice: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let message: String
    public let isError: Bool

    public init(id: String = UUID().uuidString, message: String, isError: Bool = false) {
        self.id = id
        self.message = message
        self.isError = isError
    }
}
