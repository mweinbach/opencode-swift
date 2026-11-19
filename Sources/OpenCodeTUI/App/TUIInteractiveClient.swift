#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore

// MARK: - Interactive TUI State Models

public enum TUIThemePreference: String, Equatable, Hashable, Sendable, Codable {
    case auto
    case light
    case dark
}

public struct TUIAgentItem: Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let colorHex: String?
    public let defaultModel: ModelSchema.Ref?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        colorHex: String? = nil,
        defaultModel: ModelSchema.Ref? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.colorHex = colorHex
        self.defaultModel = defaultModel
    }

    public var displayName: String {
        TUIUtil.titlecase(name.isEmpty ? id : name)
    }

    public static let defaultFallback: [TUIAgentItem] = [
        TUIAgentItem(id: "build", name: "Build", description: "Default coding agent"),
        TUIAgentItem(id: "plan", name: "Plan", description: "Read-only planning and exploration"),
    ]
}

public struct TUIModelItem: Equatable, Hashable, Sendable {
    public let id: String
    public let providerID: String
    public let name: String
    public let providerName: String
    public let variants: [String]
    public let contextLimit: Int?

    public init(
        id: String,
        providerID: String,
        name: String,
        providerName: String,
        variants: [String] = [],
        contextLimit: Int? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.providerName = providerName
        self.variants = variants
        self.contextLimit = contextLimit
    }

    public var ref: ModelSchema.Ref {
        ModelSchema.Ref(
            id: ModelSchema.ID(rawValue: id),
            providerID: ProviderSchema.ID(rawValue: providerID)
        )
    }

    public func ref(variant: String?) -> ModelSchema.Ref {
        ModelSchema.Ref(
            id: ModelSchema.ID(rawValue: id),
            providerID: ProviderSchema.ID(rawValue: providerID),
            variant: variant.flatMap { $0.isEmpty ? nil : ModelSchema.VariantID(rawValue: $0) }
        )
    }
}

public enum TUIMCPServerStatus: Equatable, Hashable, Sendable {
    case connected
    case pending
    case disabled
    case failed(String)
    case needsAuth(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .connected: return "Connected"
        case .pending: return "Connecting"
        case .disabled: return "Disabled"
        case .failed: return "Error"
        case .needsAuth: return "Sign in"
        }
    }

    public var errorDetail: String? {
        switch self {
        case .failed(let msg), .needsAuth(let msg): return msg
        default: return nil
        }
    }

    public init(from status: McpSchema.Status) {
        switch status {
        case .connected: self = .connected
        case .pending: self = .pending
        case .disabled: self = .disabled
        case .failed(let error): self = .failed(error)
        case .needsAuth(let error): self = .needsAuth(error)
        }
    }
}

public struct TUIMCPServerItem: Equatable, Hashable, Sendable {
    public let name: String
    public let title: String?
    public let status: TUIMCPServerStatus

    public init(name: String, title: String? = nil, status: TUIMCPServerStatus) {
        self.name = name
        self.title = title
        self.status = status
    }
}

public struct TUISessionItem: Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let directory: String?
    public let updatedMs: Int64?
    public let parentID: String?

    public init(
        id: String,
        title: String,
        directory: String? = nil,
        updatedMs: Int64? = nil,
        parentID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.updatedMs = updatedMs
        self.parentID = parentID
    }
}

public struct TUIModifiedFileItem: Equatable, Hashable, Sendable {
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let status: String

    public init(path: String, additions: Int, deletions: Int, status: String) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.status = status
    }
}

public enum TUISessionRunStatus: Equatable, Hashable, Sendable {
    case idle
    case running
    case retry(String)

    public var isRunning: Bool {
        switch self {
        case .running, .retry: return true
        case .idle: return false
        }
    }
}

public enum TUIToolRunStatus: String, Equatable, Hashable, Sendable {
    case streaming
    case running
    case completed
    case error
}

public enum TUIAssistantPartItem: Equatable, Hashable, Sendable {
    case reasoning(id: String, text: String, completed: Bool)
    case text(id: String, text: String)
    case tool(
        id: String,
        name: String,
        status: TUIToolRunStatus,
        summary: String,
        outputPreview: String?,
        error: String?
    )

    public var partID: String {
        switch self {
        case .reasoning(let id, _, _): return id
        case .text(let id, _): return id
        case .tool(let id, _, _, _, _, _): return id
        }
    }
}

public enum TUITranscriptItem: Equatable, Hashable, Sendable {
    case user(id: String, text: String, agentName: String?, isOptimistic: Bool)
    case assistant(
        id: String,
        agentName: String?,
        modelLabel: String?,
        parts: [TUIAssistantPartItem],
        completed: Bool,
        error: String?
    )
    case system(id: String, text: String, isError: Bool)

    public var itemID: String {
        switch self {
        case .user(let id, _, _, _): return id
        case .assistant(let id, _, _, _, _, _): return id
        case .system(let id, _, _): return id
        }
    }
}

public enum TUIIntegrationMethod: Equatable, Hashable, Sendable {
    case key(label: String)
    case oauth(id: String, label: String)
    case external(id: String, label: String)
    case command(id: String, label: String)
    case env(names: [String])

    public var isInteractive: Bool {
        if case .env = self { return false }
        return true
    }

    public var displayLabel: String {
        switch self {
        case .key(let label): return label.isEmpty ? "API key" : label
        case .oauth(_, let label): return label.isEmpty ? "Sign in with OAuth" : label
        case .external(_, let label): return label.isEmpty ? "External auth" : label
        case .command(_, let label): return label.isEmpty ? "CLI sign in" : label
        case .env(let names): return names.map { "$\($0)" }.joined(separator: ", ")
        }
    }

    public var rowID: String {
        switch self {
        case .key: return "method:key"
        case .oauth(let id, _): return "method:oauth:\(id)"
        case .external(let id, _): return "method:external:\(id)"
        case .command(let id, _): return "method:command:\(id)"
        case .env(let names): return "method:env:\(names.joined(separator: ","))"
        }
    }
}

public enum TUIIntegrationConnection: Equatable, Hashable, Sendable {
    case credential(id: String, label: String, method: String, statusMessage: String?)
    case env(name: String, statusMessage: String?)

    public var statusMessage: String? {
        switch self {
        case .credential(_, _, _, let msg), .env(_, let msg): return msg
        }
    }
}

public struct TUIIntegrationItem: Equatable, Hashable, Sendable {
    public static let popularPriority: [String: Int] = [
        "opencode": 0,
        "opencode-go": 1,
        "openai": 2,
        "github-copilot": 3,
        "anthropic": 4,
        "google": 5,
    ]

    public let id: String
    public let name: String
    public let source: String?
    public let methods: [TUIIntegrationMethod]
    public let connections: [TUIIntegrationConnection]

    public init(
        id: String,
        name: String,
        source: String? = nil,
        methods: [TUIIntegrationMethod] = [.key(label: "API key")],
        connections: [TUIIntegrationConnection] = []
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.methods = methods
        self.connections = connections
    }

    public var priority: Int {
        Self.popularPriority[id] ?? 99
    }

    public var isPopular: Bool {
        Self.popularPriority[id] != nil
    }

    public var isConnected: Bool {
        !connections.isEmpty
    }

    /// Non-env interactive connect methods, matching upstream ordering (OAuth/external/command before API key).
    public var connectMethods: [TUIIntegrationMethod] {
        let nonEnv = methods.filter(\.isInteractive)
        return nonEnv.sorted { lhs, rhs in
            let lIsKey = (lhs.rowID == "method:key") ? 1 : 0
            let rIsKey = (rhs.rowID == "method:key") ? 1 : 0
            return lIsKey < rIsKey
        }
    }

    public var envVarNames: [String] {
        methods.flatMap { method -> [String] in
            if case .env(let names) = method { return names }
            return []
        }
    }

    public var credentialConnections: [(id: String, label: String, method: String, statusMessage: String?)] {
        connections.compactMap { conn in
            if case .credential(let id, let label, let method, let status) = conn {
                return (id, label, method, status)
            }
            return nil
        }
    }

    public var connectionSummary: String {
        if connections.count > 1 {
            return "\(connections.count) connections"
        }
        guard let first = connections.first else { return "" }
        switch first {
        case .credential(_, let label, _, _): return label
        case .env(let name, _): return "$\(name)"
        }
    }

    public static func from(_ info: IntegrationSchema.Info) -> TUIIntegrationItem {
        let mappedMethods: [TUIIntegrationMethod] = info.methods.map { method in
            switch method {
            case .key(let k):
                return .key(label: k.label ?? "API key")
            case .oauth(let o):
                return .oauth(id: o.id.rawValue, label: o.label)
            case .external(let e):
                return .external(id: e.id.rawValue, label: e.label)
            case .command(let c):
                return .command(id: c.id.rawValue, label: c.label)
            case .env(let env):
                return .env(names: env.names)
            }
        }
        let mappedConnections: [TUIIntegrationConnection] = info.connections.map { conn in
            switch conn {
            case .credential(let c):
                return .credential(
                    id: c.id.rawValue,
                    label: c.label,
                    method: c.method.rawValue,
                    statusMessage: c.status?.message
                )
            case .env(let e):
                return .env(name: e.name, statusMessage: e.status?.message)
            }
        }
        let sourceStr: String?
        if case .string(let s) = info.metadata?["source"] {
            sourceStr = s
        } else {
            sourceStr = nil
        }
        return TUIIntegrationItem(
            id: info.id.rawValue,
            name: info.name,
            source: sourceStr,
            methods: mappedMethods,
            connections: mappedConnections
        )
    }
}

public struct TUISkillItem: Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct TUIWorktreeItem: Equatable, Hashable, Sendable {
    public let directory: String
    public let branch: String?
    public let name: String?

    public init(directory: String, branch: String? = nil, name: String? = nil) {
        self.directory = directory
        self.branch = branch
        self.name = name
    }
}

public enum TUIActiveDialog: String, Equatable, Hashable, Sendable {
    case commandPalette
    case modelPicker
    case connectProvider
    case connectMethod
    case connectAPIKey
    case connectOAuth
    case manageConnections
    case agentPicker
    case variantPicker
    case sessionList
    case themePicker
    case mcpStatus
    case settings
    case status
    case usage
    case skills
    case timeline
    case pair
    case help
    case debug
    case renameSession
    case stashList
    case workspaces
    case diffViewer
    case queuedPrompts

    public var isInputPrompt: Bool {
        self == .connectAPIKey || self == .connectOAuth || self == .renameSession
    }

    public var isCustomOverlay: Bool {
        switch self {
        case .diffViewer, .pair, .status, .usage, .debug, .help, .renameSession:
            return true
        default:
            return false
        }
    }
}

public struct TUISlashCommand: Equatable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let isServerCommand: Bool

    public init(name: String, description: String, isServerCommand: Bool = false) {
        self.name = name
        self.description = description
        self.isServerCommand = isServerCommand
    }

    public static let builtIn: [TUISlashCommand] = [
        TUISlashCommand(name: "/connect", description: "Connect a provider or API key"),
        TUISlashCommand(name: "/models", description: "Switch active model"),
        TUISlashCommand(name: "/agents", description: "Switch active agent"),
        TUISlashCommand(name: "/sessions", description: "Switch or browse sessions"),
        TUISlashCommand(name: "/themes", description: "Switch theme or light/dark mode"),
        TUISlashCommand(name: "/mcps", description: "View MCP server status"),
        TUISlashCommand(name: "/diff", description: "Open syntax-highlighted diff viewer"),
        TUISlashCommand(name: "/settings", description: "Configure appearance, session & diff settings"),
        TUISlashCommand(name: "/skills", description: "Browse and activate skills"),
        TUISlashCommand(name: "/timeline", description: "Browse session timeline (fork/revert)"),
        TUISlashCommand(name: "/undo", description: "Undo / revert last user message"),
        TUISlashCommand(name: "/redo", description: "Restore reverted message"),
        TUISlashCommand(name: "/fork", description: "Fork current session"),
        TUISlashCommand(name: "/rename", description: "Rename current session"),
        TUISlashCommand(name: "/copy", description: "Copy session transcript to clipboard"),
        TUISlashCommand(name: "/export", description: "Export session transcript to Markdown"),
        TUISlashCommand(name: "/pair", description: "Pair device with QR code & link"),
        TUISlashCommand(name: "/status", description: "View server, provider & MCP status"),
        TUISlashCommand(name: "/usage", description: "View workspace usage limits"),
        TUISlashCommand(name: "/workspaces", description: "Browse git worktrees & workspaces"),
        TUISlashCommand(name: "/stash", description: "Browse or manage stashed prompts"),
        TUISlashCommand(name: "/editor", description: "Compose prompt in external $EDITOR"),
        TUISlashCommand(name: "/variants", description: "Switch model reasoning variant"),
        TUISlashCommand(name: "/reload", description: "Reload location configuration"),
        TUISlashCommand(name: "/debug", description: "View live runtime diagnostics"),
        TUISlashCommand(name: "/help", description: "View keyboard shortcuts & commands"),
        TUISlashCommand(name: "/new", description: "Start a new session"),
        TUISlashCommand(name: "/home", description: "Return to the home screen"),
        TUISlashCommand(name: "/sidebar", description: "Toggle session sidebar"),
        TUISlashCommand(name: "/compact", description: "Compact session context"),
        TUISlashCommand(name: "/queue", description: "Manage queued prompts"),
        TUISlashCommand(name: "/terminal", description: "Toggle embedded terminal pane"),
        TUISlashCommand(name: "/commands", description: "Open command palette"),
        TUISlashCommand(name: "/exit", description: "Exit OpenCode"),
    ]
}

public enum TUIPaletteActionID: String, Equatable, Hashable, Sendable {
    case switchSession
    case switchModel
    case connectProvider
    case switchAgent
    case cycleAgent
    case switchVariant
    case viewDiff
    case openSettings
    case openSkills
    case timeline
    case undoMessage
    case redoMessage
    case forkSession
    case renameSession
    case copyTranscript
    case exportTranscript
    case pairDevice
    case viewStatus
    case viewUsage
    case openWorkspaces
    case stashPrompt
    case openStashList
    case openExternalEditor
    case reloadConfig
    case switchTheme
    case toggleMode
    case mcpServers
    case newSession
    case goHome
    case toggleSidebar
    case compactSession
    case manageQueuedPrompts
    case toggleTerminalPane
    case showHelp
    case showDebug
    case exit
}

public struct TUIDialogRow: Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let trailing: String?
    public let isActive: Bool
    public let badgeColorKind: BadgeColorKind?

    public enum BadgeColorKind: Equatable, Hashable, Sendable {
        case success
        case error
        case warning
        case muted
    }

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        trailing: String? = nil,
        isActive: Bool = false,
        badgeColorKind: BadgeColorKind? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.isActive = isActive
        self.badgeColorKind = badgeColorKind
    }
}

public struct TUIThemeSnapshot: Equatable, Hashable, Sendable {
    public let themeName: String
    public let preference: TUIThemePreference

    public init(themeName: String, preference: TUIThemePreference) {
        self.themeName = themeName
        self.preference = preference
    }
}

public struct TUIInteractiveState: Equatable, Sendable {
    public static let promptPlaceholders: [String] = [
        "What is the tech stack of this project?",
        "Fix a TODO in the codebase",
        "Fix broken tests",
    ]

    public var route: TUIContext.Route
    public var themeName: String
    public var themePreference: TUIThemePreference
    public var detectedMode: ThemeMode
    public var themePreviewRestore: TUIThemeSnapshot?

    public var cols: Int
    public var rows: Int
    public var sidebarExplicitOverride: Bool?

    public var serverVersion: String
    public var serverURL: String
    public var directory: String
    public var homeDirectory: String
    public var gitBranch: String?

    public var agents: [TUIAgentItem]
    public var selectedAgentIndex: Int

    public var providers: [String: String]
    public var models: [TUIModelItem]
    public var selectedModel: TUIModelItem?
    public var selectedVariant: String?
    public var integrations: [TUIIntegrationItem]
    public var favoriteModels: [String]
    public var recentModels: [String]

    public var mcpServers: [TUIMCPServerItem]
    public var serverCommands: [TUISlashCommand]
    public var skills: [TUISkillItem]
    public var worktrees: [TUIWorktreeItem]
    public var todos: [TUITodoItem]
    public var projectID: String?
    public var sessions: [TUISessionItem]
    public var openSessionTabs: [String]
    public var closedSessionTabs: [String]
    public var activeSessionID: String?
    public var activeSessionTitle: String
    public var sessionStatus: TUISessionRunStatus
    public var contextTokens: Int
    public var contextLimit: Int?
    public var sessionCost: Double
    public var modifiedFiles: [TUIModifiedFileItem]
    public var messages: [TUITranscriptItem]
    public var hasRevertedMessage: Bool
    public var revertedMessageID: String?

    public var preferences: TUIPersistedPreferences
    public var promptText: String
    public var pastedBlocks: [TUIPastedBlock]
    public var queuedPrompts: [TUIQueuedPromptItem]
    public var terminalPane: TUIEmbeddedTerminalState
    public var shellMode: Bool
    public var placeholderIndex: Int
    public var slashAutocompleteIndex: Int
    public var slashAutocompleteDismissed: Bool
    public var mentionFiles: [String]
    public var mentionAutocompleteIndex: Int
    public var mentionAutocompleteDismissed: Bool
    public var historyNavigator: TUIPromptHistoryNavigator
    public var stashEntries: [TUIPromptStashEntry]
    public var interruptArmed: Bool
    public var interruptArmedAtMs: Double
    public var leaderArmed: Bool
    public var leaderArmedAtMs: Double
    public var spinnerTick: Int
    public var scrollDeltaPending: Int

    public var pendingPermissions: [TUIPendingPermissionItem]
    public var permissionPromptState: TUIPermissionPromptState
    public var pendingForms: [TUIPendingFormItem]
    public var formPromptState: TUIFormPromptState
    public var diffViewerState: TUIDiffViewerState
    public var pairingInfo: TUIPairingInfo?
    public var usageLimits: [TUIUsageLimitRow]
    public var usageWorkspaceName: String?
    public var usageSignedIn: Bool
    public var renameDraft: String
    public var renameTargetSessionID: String?
    public var pendingDeleteSessionID: String?

    public var sseConnected: Bool
    public var sseReconnecting: Bool
    public var kittyKeyboardFlags: UInt32

    public var activeDialog: TUIActiveDialog?
    public var dialogFilter: String
    public var dialogSelectedIndex: Int
    public var modelPickerProviderID: String?
    public var connectTargetIntegrationID: String?
    public var connectTargetIntegrationName: String
    public var connectMethodLabel: String
    public var connectOAuthMethodID: String?
    public var connectOAuthAttemptID: String?
    public var connectOAuthURL: String?
    public var connectOAuthInstructions: String?
    public var connectOAuthNeedsCode: Bool
    public var connectSubmitting: Bool
    public var connectErrorMessage: String?
    public var pendingDeleteCredentialID: String?

    public var toastMessage: String?
    public var toastIsError: Bool

    public var shouldQuit: Bool
    public var exitReason: String?

    public init(
        route: TUIContext.Route = .home(TUIContext.HomeRoute()),
        themeName: String = "opencode",
        themePreference: TUIThemePreference = .auto,
        detectedMode: ThemeMode = .dark,
        cols: Int = 100,
        rows: Int = 34,
        sidebarExplicitOverride: Bool? = nil,
        serverVersion: String = "2.3.2",
        serverURL: String = "http://127.0.0.1:4096",
        directory: String = "/workspace",
        homeDirectory: String = Global.Path.home,
        gitBranch: String? = nil,
        agents: [TUIAgentItem] = TUIAgentItem.defaultFallback,
        selectedAgentIndex: Int = 0,
        providers: [String: String] = [:],
        models: [TUIModelItem] = [],
        selectedModel: TUIModelItem? = nil,
        selectedVariant: String? = nil,
        integrations: [TUIIntegrationItem] = [],
        favoriteModels: [String] = [],
        recentModels: [String] = [],
        mcpServers: [TUIMCPServerItem] = [],
        sessions: [TUISessionItem] = [],
        activeSessionID: String? = nil,
        activeSessionTitle: String = "New Session",
        sessionStatus: TUISessionRunStatus = .idle,
        contextTokens: Int = 0,
        contextLimit: Int? = nil,
        sessionCost: Double = 0,
        modifiedFiles: [TUIModifiedFileItem] = [],
        messages: [TUITranscriptItem] = [],
        promptText: String = "",
        placeholderIndex: Int = 0
    ) {
        self.route = route
        self.themeName = themeName
        self.themePreference = themePreference
        self.detectedMode = detectedMode
        self.themePreviewRestore = nil
        self.cols = cols
        self.rows = rows
        self.sidebarExplicitOverride = sidebarExplicitOverride
        self.serverVersion = serverVersion
        self.serverURL = serverURL
        self.directory = directory
        self.homeDirectory = homeDirectory
        self.gitBranch = gitBranch
        self.agents = agents.isEmpty ? TUIAgentItem.defaultFallback : agents
        self.selectedAgentIndex = min(max(0, selectedAgentIndex), max(0, self.agents.count - 1))
        self.providers = providers
        self.models = models
        self.selectedModel = selectedModel
        self.selectedVariant = selectedVariant
        self.integrations = integrations
        self.favoriteModels = favoriteModels
        self.recentModels = recentModels
        self.mcpServers = mcpServers
        self.serverCommands = []
        self.skills = []
        self.worktrees = []
        self.todos = []
        self.projectID = nil
        self.sessions = sessions
        self.openSessionTabs = activeSessionID.map { [$0] } ?? []
        self.closedSessionTabs = []
        self.activeSessionID = activeSessionID
        self.activeSessionTitle = activeSessionTitle
        self.sessionStatus = sessionStatus
        self.contextTokens = contextTokens
        self.contextLimit = contextLimit
        self.sessionCost = sessionCost
        self.modifiedFiles = modifiedFiles
        self.messages = messages
        self.hasRevertedMessage = false
        self.revertedMessageID = nil
        self.preferences = TUIPersistedPreferences(themeName: themeName, themePreference: themePreference)
        self.promptText = promptText
        self.pastedBlocks = []
        self.queuedPrompts = []
        self.terminalPane = TUIEmbeddedTerminalState()
        self.shellMode = false
        self.placeholderIndex = placeholderIndex
        self.slashAutocompleteIndex = 0
        self.slashAutocompleteDismissed = false
        self.mentionFiles = []
        self.mentionAutocompleteIndex = 0
        self.mentionAutocompleteDismissed = false
        self.historyNavigator = TUIPromptHistoryNavigator()
        self.stashEntries = []
        self.interruptArmed = false
        self.interruptArmedAtMs = 0
        self.leaderArmed = false
        self.leaderArmedAtMs = 0
        self.spinnerTick = 0
        self.scrollDeltaPending = 0
        self.pendingPermissions = []
        self.permissionPromptState = TUIPermissionPromptState()
        self.pendingForms = []
        self.formPromptState = TUIFormPromptState()
        self.diffViewerState = TUIDiffViewerState()
        self.pairingInfo = nil
        self.usageLimits = []
        self.usageWorkspaceName = nil
        self.usageSignedIn = false
        self.renameDraft = ""
        self.renameTargetSessionID = nil
        self.pendingDeleteSessionID = nil
        self.sseConnected = false
        self.sseReconnecting = false
        self.kittyKeyboardFlags = 0
        self.activeDialog = nil
        self.dialogFilter = ""
        self.dialogSelectedIndex = 0
        self.modelPickerProviderID = nil
        self.connectTargetIntegrationID = nil
        self.connectTargetIntegrationName = ""
        self.connectMethodLabel = "API key"
        self.connectOAuthMethodID = nil
        self.connectOAuthAttemptID = nil
        self.connectOAuthURL = nil
        self.connectOAuthInstructions = nil
        self.connectOAuthNeedsCode = false
        self.connectSubmitting = false
        self.connectErrorMessage = nil
        self.pendingDeleteCredentialID = nil
        self.toastMessage = nil
        self.toastIsError = false
        self.shouldQuit = false
        self.exitReason = nil
    }

    public var isHome: Bool {
        if case .home = route { return true }
        return false
    }

    public var effectiveMode: ThemeMode {
        switch themePreference {
        case .auto: return detectedMode
        case .light: return .light
        case .dark: return .dark
        }
    }

    public var effectiveShowSidebar: Bool {
        if let override = sidebarExplicitOverride { return override }
        if preferences.sidebarMode == "hide" { return false }
        return cols > 120
    }

    public var activePermission: TUIPendingPermissionItem? {
        if let activeID = activeSessionID,
           let matched = pendingPermissions.first(where: { $0.sessionID == activeID }) {
            return matched
        }
        return pendingPermissions.first
    }

    public var activeForm: TUIPendingFormItem? {
        if let activeID = activeSessionID,
           let matched = pendingForms.first(where: { $0.sessionID == activeID }) {
            return matched
        }
        return pendingForms.first
    }

    public var statusSnapshot: TUIStatusSnapshot {
        let connectedCount = visibleProviderIntegrations.filter(\.isConnected).count
        return TUIStatusSnapshot(
            serverURL: serverURL,
            serverVersion: serverVersion,
            directory: TUIUtil.abbreviateHome(directory, home: homeDirectory),
            gitBranch: gitBranch,
            connectedProvidersCount: max(connectedCount, providers.count),
            totalModelsCount: models.count,
            mcpServers: mcpServers,
            skillsCount: skills.count,
            commandsCount: serverCommands.count
        )
    }

    public var debugSnapshot: TUIDebugSnapshot {
        TUIDebugSnapshot(
            serverURL: serverURL,
            serverVersion: serverVersion,
            sessionID: activeSessionID,
            sseConnected: sseConnected,
            sseReconnecting: sseReconnecting,
            terminalCols: cols,
            terminalRows: rows,
            themeName: themeName,
            themeMode: effectiveMode,
            kittyKeyboardFlags: Int(kittyKeyboardFlags),
            providersCount: max(providers.count, visibleProviderIntegrations.filter(\.isConnected).count),
            modelsCount: models.count,
            agentsCount: agents.count,
            commandsCount: serverCommands.count,
            skillsCount: skills.count,
            toolsCount: 0
        )
    }

    public var activeAgent: TUIAgentItem {
        guard !agents.isEmpty else { return TUIAgentItem.defaultFallback[0] }
        let idx = min(max(0, selectedAgentIndex), agents.count - 1)
        return agents[idx]
    }

    public var locationDisplayLabel: String {
        let abbreviated = TUIUtil.abbreviateHome(directory, home: homeDirectory)
        if let branch = gitBranch, !branch.isEmpty {
            return "\(abbreviated):\(branch)"
        }
        return abbreviated
    }

    public var currentPlaceholder: String {
        let list = Self.promptPlaceholders
        let sample = list[placeholderIndex % list.count]
        return "Ask anything… \"\(sample)\""
    }

    public var isAnyProviderConnected: Bool {
        !models.isEmpty || integrations.contains { $0.source != "mcp" && $0.isConnected }
    }

    public var visibleProviderIntegrations: [TUIIntegrationItem] {
        integrations
            .filter { $0.source != "mcp" }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            }
    }

    public var activeModelLabel: String {
        if let selected = selectedModel {
            return selected.name.isEmpty ? selected.id : selected.name
        }
        return isAnyProviderConnected ? "Select model" : "Connect a provider (/connect)"
    }

    public var activeProviderLabel: String {
        if let selected = selectedModel {
            if !selected.providerName.isEmpty { return selected.providerName }
            if let mapped = providers[selected.providerID], !mapped.isEmpty { return mapped }
            return TUIUtil.titlecase(selected.providerID)
        }
        return ""
    }

    public var contextPercent: Int? {
        guard contextTokens > 0, let limit = contextLimit ?? selectedModel?.contextLimit, limit > 0 else {
            return nil
        }
        return Int((Double(contextTokens) / Double(limit) * 100.0).rounded())
    }

    public var allSlashCommands: [TUISlashCommand] {
        var seen = Set(TUISlashCommand.builtIn.map { $0.name.lowercased() })
        var combined = TUISlashCommand.builtIn
        for cmd in serverCommands {
            let normalized = cmd.name.hasPrefix("/") ? cmd.name : "/\(cmd.name)"
            if seen.insert(normalized.lowercased()).inserted {
                combined.append(TUISlashCommand(name: normalized, description: cmd.description, isServerCommand: true))
            }
        }
        return combined
    }

    public var slashMatches: [TUISlashCommand] {
        guard activeDialog == nil, !shellMode, !slashAutocompleteDismissed else { return [] }
        guard promptText.hasPrefix("/"), !promptText.contains(" "), !promptText.contains("\n") else { return [] }
        let needle = promptText.lowercased()
        let pool = allSlashCommands
        if needle == "/" { return pool }
        return pool.filter {
            $0.name.lowercased().hasPrefix(needle) || $0.description.lowercased().contains(needle.dropFirst())
        }
    }

    public var isSlashAutocompleteVisible: Bool {
        !slashMatches.isEmpty
    }

    public var activeMentionTrigger: TUIMentionTrigger? {
        guard activeDialog == nil, !shellMode, !mentionAutocompleteDismissed else { return nil }
        guard !isSlashAutocompleteVisible else { return nil }
        return detectMentionTrigger(in: promptText)
    }

    public var mentionSuggestions: [TUIMentionSuggestion] {
        guard let trigger = activeMentionTrigger else { return [] }
        return buildMentionSuggestions(query: trigger.query, files: mentionFiles, agents: agents)
    }

    public var isMentionAutocompleteVisible: Bool {
        !mentionSuggestions.isEmpty
    }

    public func resolveTheme() -> ResolvedTheme {
        let mode = effectiveMode
        if themeName == "opencode" {
            return ThemeDefaults.resolveOrDefault(ThemeDefaults.opencode, mode: mode)
        }
        if themeName == "opencode2" {
            return ThemeDefaults.resolveOrDefault(ThemeDefaults.opencode2, mode: mode)
        }
        let all = TUIThemeBridge.allThemes()
        if let source = all[themeName], let doc = try? TUIThemeBridge.parseTheme(source, name: themeName) {
            return ThemeDefaults.resolveOrDefault(doc, mode: mode)
        }
        return ThemeDefaults.resolveOrDefault(nil, mode: mode)
    }

    /// Resolves the agent highlight accent color matching upstream `local.tsx`:
    /// uses explicit `agent.color` hex if present, else deduplicated `theme.categorical[i][.s200]`.
    public func agentColor(for agent: TUIAgentItem? = nil, theme: ResolvedTheme) -> RGBA {
        let target = agent ?? activeAgent
        if let hex = target.colorHex, hex.hasPrefix("#") {
            return RGBA.fromHex(hex)
        }
        var palette: [RGBA] = []
        for scale in theme.categorical {
            let color = scale[.s200]
            if !palette.contains(color) {
                palette.append(color)
            }
        }
        if palette.isEmpty {
            return theme.text.action.primary.selected
        }
        let index = agents.firstIndex(where: { $0.id == target.id }) ?? selectedAgentIndex
        return palette[max(0, index) % palette.count]
    }

    public func dialogRows() -> [TUIDialogRow] {
        guard let dialog = activeDialog else { return [] }
        let needle = dialogFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func matches(_ text: String, _ secondary: String? = nil) -> Bool {
            guard !needle.isEmpty else { return true }
            if text.lowercased().contains(needle) { return true }
            if let secondary, secondary.lowercased().contains(needle) { return true }
            return false
        }

        switch dialog {
        case .commandPalette:
            let items: [(TUIPaletteActionID, String, String)] = [
                (.switchSession, "Switch session", "/sessions"),
                (.switchModel, "Switch model", "/models"),
                (.connectProvider, "Connect a provider", "/connect"),
                (.switchAgent, "Switch agent", "/agents"),
                (.switchTheme, "Switch theme", "/themes"),
                (.mcpServers, "MCP servers", "/mcps"),
                (.viewDiff, "Open diff viewer", "/diff"),
                (.openSettings, "Open settings", "/settings"),
                (.openSkills, "Browse skills", "/skills"),
                (.pairDevice, "Pair device (QR code)", "/pair"),
                (.timeline, "Session timeline", "/timeline"),
                (.cycleAgent, "Cycle agent (\(activeAgent.displayName))", "shift+tab"),
                (.switchVariant, "Switch model variant", "/variants"),
                (.undoMessage, "Undo last message", "/undo"),
                (.redoMessage, "Redo reverted message", "/redo"),
                (.forkSession, "Fork session", "/fork"),
                (.renameSession, "Rename session", "ctrl+r"),
                (.copyTranscript, "Copy transcript", "/copy"),
                (.exportTranscript, "Export transcript", "/export"),
                (.viewStatus, "View status", "/status"),
                (.viewUsage, "View usage limits", "/usage"),
                (.openWorkspaces, "Manage workspaces", "/workspaces"),
                (.stashPrompt, "Stash current prompt", "/stash"),
                (.openStashList, "Browse stashed prompts", "/stash"),
                (.openExternalEditor, "Open external $EDITOR", "/editor"),
                (.reloadConfig, "Reload configuration", "/reload"),
                (.toggleMode, "Toggle Light / Dark mode (\(effectiveMode.rawValue))", "ctrl+t"),
                (.newSession, "New session", "ctrl+n"),
                (.goHome, "Go to home", "/home"),
                (.toggleSidebar, effectiveShowSidebar ? "Hide sidebar" : "Show sidebar", "ctrl+b"),
                (.compactSession, "Compact session", "/compact"),
                (.manageQueuedPrompts, "Manage queued prompts", "/queue"),
                (.toggleTerminalPane, terminalPane.isOpen ? "Close terminal pane" : "Toggle terminal pane", "/terminal"),
                (.showHelp, "Help & keybindings", "/help"),
                (.showDebug, "Debug diagnostics", "/debug"),
                (.exit, "Exit OpenCode", "ctrl+c"),
            ]
            return items.compactMap { action, title, shortcut in
                guard matches(title, shortcut) else { return nil }
                return TUIDialogRow(id: action.rawValue, title: title, trailing: shortcut)
            }

        case .modelPicker:
            let favSet = Set(favoriteModels)
            let filtered = models.filter { item in
                if let filterPID = modelPickerProviderID, !filterPID.isEmpty, item.providerID != filterPID {
                    return false
                }
                let prov = item.providerName.isEmpty
                    ? (providers[item.providerID] ?? TUIUtil.titlecase(item.providerID))
                    : item.providerName
                return matches(item.name, "\(item.id) \(prov)")
            }
            let ordered = filtered.sorted { lhs, rhs in
                let lk = "\(lhs.providerID)/\(lhs.id)"
                let rk = "\(rhs.providerID)/\(rhs.id)"
                let lf = favSet.contains(lk)
                let rf = favSet.contains(rk)
                if lf != rf { return lf }
                if let li = recentModels.firstIndex(of: lk), let ri = recentModels.firstIndex(of: rk), li != ri {
                    return li < ri
                } else if recentModels.contains(lk) != recentModels.contains(rk) {
                    return recentModels.contains(lk)
                }
                return false
            }
            var rows: [TUIDialogRow] = ordered.map { item in
                let prov = item.providerName.isEmpty
                    ? (providers[item.providerID] ?? TUIUtil.titlecase(item.providerID))
                    : item.providerName
                let key = "\(item.providerID)/\(item.id)"
                let active = selectedModel?.id == item.id && selectedModel?.providerID == item.providerID
                let isFav = favSet.contains(key)
                let trailing: String?
                if active && isFav {
                    trailing = "★ active"
                } else if isFav {
                    trailing = "★"
                } else if active {
                    trailing = "active"
                } else {
                    trailing = nil
                }
                return TUIDialogRow(
                    id: key,
                    title: item.name.isEmpty ? item.id : item.name,
                    subtitle: prov,
                    trailing: trailing,
                    isActive: active
                )
            }
            if rows.isEmpty && needle.isEmpty {
                rows.append(TUIDialogRow(
                    id: "__connect_provider__",
                    title: "+ Connect a provider",
                    subtitle: "Add an API key or account to unlock models",
                    trailing: "ctrl+a",
                    badgeColorKind: .success
                ))
            }
            return rows

        case .connectProvider:
            return visibleProviderIntegrations.compactMap { integration in
                let envHint = integration.envVarNames.joined(separator: " ")
                let category = integration.isPopular ? "Popular" : "Provider"
                guard matches(integration.name, "\(integration.id) \(category) \(envHint)") else { return nil }
                let hasStatus = integration.connections.first?.statusMessage != nil
                let subtitle: String?
                if integration.connectMethods.isEmpty && integration.credentialConnections.isEmpty {
                    subtitle = "Environment only"
                } else if integration.isPopular {
                    subtitle = "Popular"
                } else {
                    subtitle = nil
                }
                let trailing: String?
                if hasStatus {
                    trailing = "Sign in required →"
                } else if !integration.connectionSummary.isEmpty {
                    trailing = integration.connectionSummary
                } else if let firstMethod = integration.connectMethods.first {
                    trailing = firstMethod.displayLabel
                } else if let firstEnv = integration.envVarNames.first {
                    trailing = "$\(firstEnv)"
                } else {
                    trailing = nil
                }
                let badge: TUIDialogRow.BadgeColorKind? = integration.isConnected
                    ? (hasStatus ? .warning : .success)
                    : nil
                return TUIDialogRow(
                    id: integration.id,
                    title: integration.name,
                    subtitle: subtitle,
                    trailing: trailing,
                    isActive: integration.isConnected,
                    badgeColorKind: badge
                )
            }

        case .connectMethod:
            guard let targetID = connectTargetIntegrationID,
                  let integration = integrations.first(where: { $0.id == targetID })
            else {
                return []
            }
            return integration.connectMethods.compactMap { method in
                let label = method.displayLabel
                guard matches(label, method.rowID) else { return nil }
                return TUIDialogRow(id: method.rowID, title: label)
            }

        case .manageConnections:
            guard let targetID = connectTargetIntegrationID,
                  let integration = integrations.first(where: { $0.id == targetID })
            else {
                return []
            }
            var rows: [TUIDialogRow] = []
            if !integration.connectMethods.isEmpty, matches("Add account", "connect") {
                rows.append(TUIDialogRow(
                    id: "__add_account__",
                    title: "+ Add account",
                    subtitle: "Connect another API key or account",
                    badgeColorKind: .success
                ))
            }
            let creds = integration.credentialConnections
            for (idx, cred) in creds.enumerated() {
                guard matches(cred.label, "\(cred.id) \(cred.method)") else { continue }
                let isConfirming = pendingDeleteCredentialID == cred.id
                let title = isConfirming ? "Press ctrl+d again to remove \(cred.label)" : cred.label
                let trailing = cred.statusMessage != nil
                    ? "Sign in required →"
                    : (idx == 0 ? "active" : cred.method)
                rows.append(TUIDialogRow(
                    id: "cred:\(cred.id)",
                    title: title,
                    subtitle: isConfirming ? "Confirm removal" : cred.method,
                    trailing: trailing,
                    isActive: idx == 0,
                    badgeColorKind: isConfirming ? .error : (cred.statusMessage != nil ? .warning : .success)
                ))
            }
            return rows

        case .connectAPIKey, .connectOAuth, .status, .usage, .pair, .help, .debug, .renameSession, .diffViewer:
            return []

        case .settings:
            return TUISettingsCatalog.rows(
                filter: dialogFilter,
                preferences: preferences,
                detectedMode: detectedMode
            )

        case .skills:
            return skills.compactMap { skill in
                guard matches(skill.name, "\(skill.id) \(skill.description ?? "")") else { return nil }
                return TUIDialogRow(
                    id: skill.id,
                    title: skill.name,
                    subtitle: skill.description
                )
            }

        case .timeline:
            let userMessages: [(id: String, text: String)] = messages.compactMap { item in
                if case .user(let id, let text, _, _) = item {
                    return (id, text.replacingOccurrences(of: "\n", with: " "))
                }
                return nil
            }.reversed()
            return userMessages.compactMap { entry in
                guard matches(entry.text, entry.id) else { return nil }
                let isRev = revertedMessageID == entry.id
                return TUIDialogRow(
                    id: entry.id,
                    title: TUIUtil.truncateWidth(entry.text, 52),
                    subtitle: isRev ? "reverted" : nil,
                    trailing: "enter revert · f fork",
                    isActive: isRev
                )
            }

        case .stashList:
            return stashEntries.compactMap { entry in
                let singleLine = entry.input.replacingOccurrences(of: "\n", with: " ")
                guard matches(singleLine) else { return nil }
                return TUIDialogRow(
                    id: entry.id,
                    title: TUIUtil.truncateWidth(singleLine, 54),
                    trailing: "enter pop"
                )
            }

        case .workspaces:
            var rows: [TUIDialogRow] = []
            let curDisplay = TUIUtil.abbreviateHome(directory, home: homeDirectory)
            if worktrees.isEmpty {
                if matches(curDisplay, gitBranch) {
                    rows.append(TUIDialogRow(
                        id: directory,
                        title: curDisplay,
                        subtitle: gitBranch,
                        trailing: "current",
                        isActive: true
                    ))
                }
            } else {
                for wt in worktrees {
                    let display = TUIUtil.abbreviateHome(wt.directory, home: homeDirectory)
                    let label = wt.name ?? display
                    guard matches(label, "\(display) \(wt.branch ?? "")") else { continue }
                    let isCur = wt.directory == directory
                    rows.append(TUIDialogRow(
                        id: wt.directory,
                        title: label,
                        subtitle: wt.branch ?? display,
                        trailing: isCur ? "current" : nil,
                        isActive: isCur
                    ))
                }
            }
            return rows

        case .agentPicker:
            return agents.compactMap { agent in
                guard matches(agent.displayName, "\(agent.id) \(agent.description ?? "")") else { return nil }
                let active = activeAgent.id == agent.id
                return TUIDialogRow(
                    id: agent.id,
                    title: agent.displayName,
                    subtitle: agent.description,
                    trailing: active ? "active" : nil,
                    isActive: active
                )
            }

        case .variantPicker:
            let variants = selectedModel?.variants ?? []
            var rows: [TUIDialogRow] = []
            let isDefault = (selectedVariant == nil || selectedVariant == "default")
            if matches("Default", "default") {
                rows.append(TUIDialogRow(
                    id: "default",
                    title: "Default",
                    subtitle: "Model default reasoning",
                    trailing: isDefault ? "active" : nil,
                    isActive: isDefault
                ))
            }
            for variant in variants where variant != "default" {
                guard matches(variant) else { continue }
                let active = selectedVariant == variant
                rows.append(TUIDialogRow(
                    id: variant,
                    title: variant,
                    trailing: active ? "active" : nil,
                    isActive: active
                ))
            }
            return rows

        case .sessionList:
            let pinnedSet = Set(preferences.pinnedSessionIDs)
            let ordered = sessions.sorted { lhs, rhs in
                let lp = pinnedSet.contains(lhs.id)
                let rp = pinnedSet.contains(rhs.id)
                if lp != rp { return lp }
                return false
            }
            return ordered.compactMap { session in
                let sub = session.directory.map { TUIUtil.abbreviateHome($0, home: homeDirectory) } ?? session.id
                guard matches(session.title, sub) else { return nil }
                let active = session.id == activeSessionID
                let isPinned = pinnedSet.contains(session.id)
                let isConfirmingDelete = pendingDeleteSessionID == session.id
                let title = isConfirmingDelete ? "Press ctrl+d again to delete \(session.title)" : session.title
                let trailing: String?
                if isConfirmingDelete {
                    trailing = "delete?"
                } else if active && isPinned {
                    trailing = "★ active"
                } else if isPinned {
                    trailing = "★"
                } else if active {
                    trailing = "active"
                } else {
                    trailing = nil
                }
                return TUIDialogRow(
                    id: session.id,
                    title: title,
                    subtitle: isConfirmingDelete ? "Confirm deletion" : sub,
                    trailing: trailing,
                    isActive: active,
                    badgeColorKind: isConfirmingDelete ? .error : nil
                )
            }

        case .themePicker:
            var rows: [TUIDialogRow] = []
            let modeEntries: [(String, String, String, Bool)] = [
                ("mode:auto", "Appearance: Auto (Terminal)", "OSC 11 (\(detectedMode.rawValue))", themePreference == .auto),
                ("mode:light", "Appearance: Light", "Light mode", themePreference == .light),
                ("mode:dark", "Appearance: Dark", "Dark mode", themePreference == .dark),
            ]
            for (id, title, sub, active) in modeEntries where matches(title, sub) {
                rows.append(TUIDialogRow(id: id, title: title, subtitle: sub, trailing: active ? "active" : nil, isActive: active))
            }
            let builtInNames = ["opencode", "opencode2"] + TUIThemeBridge.DEFAULT_THEMES.keys.sorted()
            for name in builtInNames {
                guard matches(name) else { continue }
                let active = themeName == name
                rows.append(TUIDialogRow(
                    id: "theme:\(name)",
                    title: name,
                    subtitle: name == "opencode" ? "default" : nil,
                    trailing: active ? "active" : nil,
                    isActive: active
                ))
            }
            return rows

        case .mcpStatus:
            return mcpServers.compactMap { server in
                guard matches(server.name, server.status.label) else { return nil }
                let kind: TUIDialogRow.BadgeColorKind
                switch server.status {
                case .connected: kind = .success
                case .failed: kind = .error
                case .needsAuth: kind = .warning
                case .pending, .disabled: kind = .muted
                }
                return TUIDialogRow(
                    id: server.name,
                    title: server.name,
                    subtitle: server.status.errorDetail,
                    trailing: server.status.label,
                    isActive: server.status.isConnected,
                    badgeColorKind: kind
                )
            }

        case .queuedPrompts:
            let total = queuedPrompts.count
            return queuedPrompts.enumerated().compactMap { idx, item in
                let singleLine = item.text.replacingOccurrences(of: "\n", with: " ")
                guard matches(singleLine, item.delivery) else { return nil }
                return TUIDialogRow(
                    id: item.id,
                    title: TUIUtil.truncateWidth(singleLine, 50),
                    subtitle: item.delivery == "steer" ? "steer" : nil,
                    trailing: "\(idx + 1) of \(total)"
                )
            }
        }
    }

    public static func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let scaled = Double(tokens) / 1_000_000.0
            let tenths = Int((scaled * 10.0).rounded())
            return "\(tenths / 10).\(tenths % 10)M"
        }
        if tokens >= 1_000 {
            let scaled = Double(tokens) / 1_000.0
            let tenths = Int((scaled * 10.0).rounded())
            return "\(tenths / 10).\(tenths % 10)K"
        }
        return "\(tokens)"
    }

    public static func formatUSD(_ amount: Double) -> String {
        let cents = Int((amount * 100.0).rounded())
        let dollars = cents / 100
        let rem = abs(cents % 100)
        let remStr = rem < 10 ? "0\(rem)" : "\(rem)"
        return "$\(dollars).\(remStr)"
    }
}

// MARK: - Thread-Safe Store

public final class TUIInteractiveStore: Sendable {
    private let state: Mutex<TUIInteractiveState>

    public init(_ initial: TUIInteractiveState) {
        self.state = Mutex(initial)
    }

    public func withLock<R>(_ body: (inout TUIInteractiveState) -> sending R) -> sending R {
        state.withLock(body)
    }

    public func snapshot() -> TUIInteractiveState {
        state.withLock { $0 }
    }
}

// MARK: - Live OpenCode Client & SSE Event Stream Controller

public final class TUIInteractiveClient: Sendable {
    public struct EventSideEffect: Equatable, Sendable {
        public var refreshAgents: Bool = false
        public var refreshModels: Bool = false
        public var refreshIntegrations: Bool = false
        public var refreshMCP: Bool = false
        public var refreshVCS: Bool = false
        public var refreshSessions: Bool = false
        public var refreshCommands: Bool = false
        public var refreshSkills: Bool = false
        public var refreshPermissions: Bool = false
        public var refreshForms: Bool = false
        public var refreshMessagesForSession: String? = nil
        public var selectSessionID: String? = nil

        public init(
            refreshAgents: Bool = false,
            refreshModels: Bool = false,
            refreshIntegrations: Bool = false,
            refreshMCP: Bool = false,
            refreshVCS: Bool = false,
            refreshSessions: Bool = false,
            refreshCommands: Bool = false,
            refreshSkills: Bool = false,
            refreshPermissions: Bool = false,
            refreshForms: Bool = false,
            refreshMessagesForSession: String? = nil,
            selectSessionID: String? = nil
        ) {
            self.refreshAgents = refreshAgents
            self.refreshModels = refreshModels
            self.refreshIntegrations = refreshIntegrations
            self.refreshMCP = refreshMCP
            self.refreshVCS = refreshVCS
            self.refreshSessions = refreshSessions
            self.refreshCommands = refreshCommands
            self.refreshSkills = refreshSkills
            self.refreshPermissions = refreshPermissions
            self.refreshForms = refreshForms
            self.refreshMessagesForSession = refreshMessagesForSession
            self.selectSessionID = selectSessionID
        }
    }

    public let client: OpenCodeClient
    public let store: TUIInteractiveStore
    public let directory: String
    public let persistence: TUIPersistenceStore?
    internal let markDirty: @Sendable () -> Void
    internal let onRequestExternalEditor: (@Sendable () -> Void)?
    private let optimisticCounter = Mutex<Int>(0)
    internal let mentionQueryGeneration = Mutex<Int>(0)

    public init(
        client: OpenCodeClient,
        store: TUIInteractiveStore,
        directory: String,
        persistence: TUIPersistenceStore? = nil,
        onRequestExternalEditor: (@Sendable () -> Void)? = nil,
        markDirty: @escaping @Sendable () -> Void
    ) {
        self.client = client
        self.store = store
        self.directory = directory
        self.persistence = persistence
        self.onRequestExternalEditor = onRequestExternalEditor
        self.markDirty = markDirty
    }

    internal var locationQuery: LocationQuery.LocationField {
        LocationQuery.LocationField(directory: store.withLock { $0.directory })
    }

    internal func nextOptimisticID() -> String {
        let next = optimisticCounter.withLock { count -> Int in
            count += 1
            return count
        }
        return "optimistic-\(next)"
    }

    // MARK: - Startup & Refresh

    public func bootstrap(startupArgs: TUIContext.Args? = nil) {
        Task { [weak self] in
            guard let self else { return }
            if let persistence = self.persistence {
                async let prefsTask = persistence.loadPreferences()
                async let modelStateTask = persistence.loadModelState()
                async let historyTask = persistence.loadHistory()
                async let stashTask = persistence.loadStash()
                let prefs = await prefsTask
                let modelState = await modelStateTask
                let history = await historyTask
                let stash = await stashTask

                self.store.withLock { state in
                    state.preferences = prefs
                    if !prefs.themeName.isEmpty {
                        state.themeName = prefs.themeName
                    }
                    if state.themePreference == .auto && prefs.themePreference != .auto {
                        state.themePreference = prefs.themePreference
                    }
                    if prefs.sidebarMode == "hide" && state.sidebarExplicitOverride == nil {
                        state.sidebarExplicitOverride = false
                    }
                    state.favoriteModels = modelState.favorite.map(\.key)
                    state.recentModels = modelState.recent.map(\.key)
                    state.historyNavigator = TUIPromptHistoryNavigator(entries: history)
                    state.stashEntries = stash
                }
                self.markDirty()
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.refreshServerInfo() }
                group.addTask { await self.refreshAgents() }
                group.addTask { await self.refreshIntegrations() }
                group.addTask { await self.refreshProvidersAndModels() }
                group.addTask { await self.refreshMCP() }
                group.addTask { await self.refreshVCS() }
                group.addTask { await self.refreshSessions() }
                group.addTask { await self.refreshCommands() }
                group.addTask { await self.refreshSkills() }
                group.addTask { await self.refreshPermissions() }
                group.addTask { await self.refreshForms() }
            }

            if let args = startupArgs {
                await self.applyStartupArgs(args)
            } else if let activeID = self.store.withLock({ $0.activeSessionID }) {
                await self.loadMessages(sessionID: activeID)
            }
        }
    }

    public func applyStartupArgs(_ args: TUIContext.Args) async {
        if let agentArg = args.agent, !agentArg.isEmpty {
            selectAgent(id: agentArg)
        }
        if let modelArg = args.model, !modelArg.isEmpty {
            let parts = modelArg.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let matched = store.withLock { state in
                    state.models.first(where: { $0.providerID == parts[0] && $0.id == parts[1] })
                }
                if let matched {
                    selectModel(matched)
                }
            }
        }
        if args.continue == true {
            let currentDir = store.withLock { $0.directory }
            if let list = try? await client.session.list(SessionListInput(limit: 1, order: .desc, directory: currentDir)),
               let match = list.data.first {
                let targetID = match.id.rawValue
                if args.fork == true {
                    if let forked = try? await client.session.fork(SessionForkInput(sessionID: targetID)) {
                        openSession(id: forked.id.rawValue, title: SessionTitleFallback.displayLabel(title: forked.title, parentID: forked.parentID?.rawValue))
                    }
                } else {
                    openSession(id: targetID, title: SessionTitleFallback.displayLabel(title: match.title, parentID: match.parentID?.rawValue))
                }
                return
            }
        }
        if let sid = args.sessionID, !sid.isEmpty {
            if args.fork == true {
                if let forked = try? await client.session.fork(SessionForkInput(sessionID: sid)) {
                    openSession(id: forked.id.rawValue, title: SessionTitleFallback.displayLabel(title: forked.title, parentID: forked.parentID?.rawValue))
                }
            } else {
                await loadMessages(sessionID: sid)
            }
            return
        }
        if let activeID = store.withLock({ $0.activeSessionID }) {
            await loadMessages(sessionID: activeID)
        }
    }

    public func refreshCommands() async {
        guard let resp = try? await client.command.list(CommandListInput(location: locationQuery)) else { return }
        let items = resp.data.map { cmd in
            let name = cmd.name.hasPrefix("/") ? cmd.name : "/\(cmd.name)"
            return TUISlashCommand(name: name, description: cmd.description ?? "Custom command", isServerCommand: true)
        }
        store.withLock { state in
            state.serverCommands = items
        }
        markDirty()
    }

    public func refreshSkills() async {
        guard let resp = try? await client.skill.list(SkillListInput(location: locationQuery)) else { return }
        let items = resp.data.map { skill in
            TUISkillItem(id: skill.id.rawValue, name: skill.name.rawValue, description: skill.description)
        }
        store.withLock { state in
            state.skills = items
        }
        markDirty()
    }

    public func refreshPermissions() async {
        guard let resp = try? await client.permission.request.list(PermissionRequestListInput(location: locationQuery)) else { return }
        let items = resp.data.map(Self.mapPermissionRequest)
        store.withLock { state in
            state.pendingPermissions = items
            if items.isEmpty {
                state.permissionPromptState = TUIPermissionPromptState()
            }
        }
        markDirty()
    }

    public func refreshForms() async {
        guard let resp = try? await client.form.list(FormListInput(location: locationQuery)) else { return }
        let items = resp.data.map(Self.mapFormInfo)
        store.withLock { state in
            state.pendingForms = items
            if items.isEmpty {
                state.formPromptState = TUIFormPromptState()
            }
        }
        markDirty()
    }

    public func refreshWorktrees() async {
        let projectID = store.withLock { state -> String? in
            if let pid = state.projectID, !pid.isEmpty { return pid }
            return nil
        }
        if let pid = projectID,
           let resp = try? await client.worktree.list(WorktreeListInput(projectID: pid)) {
            let mapped = resp.map { wt in
                TUIWorktreeItem(directory: wt.directory.rawValue, branch: wt.strategy, name: nil)
            }
            store.withLock { state in
                state.worktrees = mapped
            }
            markDirty()
        }
    }

    private static func mapPermissionRequest(_ req: PermissionSchema.Request) -> TUIPendingPermissionItem {
        var cmdPreview: String? = nil
        var filePath: String? = nil
        var diffPatch: String? = nil
        if let meta = req.metadata {
            if case .string(let cmd) = meta["command"] { cmdPreview = cmd }
            if case .string(let fp) = meta["filepath"] ?? meta["filePath"] ?? meta["path"] { filePath = fp }
            if case .string(let diff) = meta["diff"] ?? meta["patch"] { diffPatch = diff }
        }
        return TUIPendingPermissionItem(
            id: req.id.rawValue,
            sessionID: req.sessionID.rawValue,
            permission: req.action,
            patterns: req.resources,
            alwaysPatterns: req.save ?? req.resources,
            toolName: req.action,
            commandPreview: cmdPreview,
            filePath: filePath,
            diffPatch: diffPatch
        )
    }

    private static func mapFormInfo(_ info: FormSchema.Info) -> TUIPendingFormItem {
        let msg: String?
        if case .string(let s) = info.metadata?["message"] {
            msg = s
        } else {
            msg = nil
        }
        let fields: [TUIFormFieldItem] = info.fields.elements.compactMap { field in
            switch field {
            case .string(let sf):
                let label = sf.title ?? sf.key
                if let opts = sf.options, !opts.isEmpty {
                    let mapped = opts.map { TUIFormOptionItem(label: $0.label, value: $0.value, description: $0.description) }
                    return TUIFormFieldItem(
                        key: sf.key,
                        label: label,
                        description: sf.description,
                        kind: .singleSelect(mapped),
                        allowCustom: sf.custom ?? false,
                        required: sf.required ?? true
                    )
                }
                return TUIFormFieldItem(
                    key: sf.key,
                    label: label,
                    description: sf.description,
                    kind: .text(placeholder: sf.placeholder),
                    allowCustom: false,
                    required: sf.required ?? true
                )
            case .multiselect(let mf):
                let label = mf.title ?? mf.key
                let mapped = mf.options.map { TUIFormOptionItem(label: $0.label, value: $0.value, description: $0.description) }
                return TUIFormFieldItem(
                    key: mf.key,
                    label: label,
                    description: mf.description,
                    kind: .multiSelect(mapped),
                    allowCustom: mf.custom ?? false,
                    required: mf.required ?? true
                )
            case .boolean(let bf):
                return TUIFormFieldItem(
                    key: bf.key,
                    label: bf.title ?? bf.key,
                    description: bf.description,
                    kind: .boolean,
                    allowCustom: false,
                    required: bf.required ?? true
                )
            case .number(let nf):
                return TUIFormFieldItem(
                    key: nf.key,
                    label: nf.title ?? nf.key,
                    description: nf.description,
                    kind: .text(placeholder: "Enter a number"),
                    allowCustom: false,
                    required: nf.required ?? true
                )
            case .integer(let inf):
                return TUIFormFieldItem(
                    key: inf.key,
                    label: inf.title ?? inf.key,
                    description: inf.description,
                    kind: .text(placeholder: "Enter an integer"),
                    allowCustom: false,
                    required: inf.required ?? true
                )
            case .external:
                return nil
            }
        }
        return TUIPendingFormItem(
            id: info.id.rawValue,
            sessionID: info.sessionID,
            title: info.title,
            message: msg,
            fields: fields
        )
    }

    internal func persistPreferencesAsync() {
        guard let persistence else { return }
        let prefs = store.withLock { state -> TUIPersistedPreferences in
            var copy = state.preferences
            copy.themeName = state.themeName
            copy.themePreference = state.themePreference
            return copy
        }
        Task { await persistence.savePreferences(prefs) }
    }

    internal func persistModelStateAsync() {
        guard let persistence else { return }
        let modelState = store.withLock { state -> TUIPersistedModelState in
            let recent = state.recentModels.compactMap { key -> TUIPersistedModelState.ModelEntry? in
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return TUIPersistedModelState.ModelEntry(providerID: parts[0], modelID: parts[1])
            }
            let favs = state.favoriteModels.compactMap { key -> TUIPersistedModelState.ModelEntry? in
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return TUIPersistedModelState.ModelEntry(providerID: parts[0], modelID: parts[1])
            }
            var variants: [String: String] = [:]
            if let sel = state.selectedModel, let v = state.selectedVariant, !v.isEmpty {
                variants["\(sel.providerID)/\(sel.id)"] = v
            }
            return TUIPersistedModelState(recent: recent, favorite: favs, variant: variants)
        }
        Task { await persistence.saveModelState(modelState) }
    }

    public func refreshIntegrations() async {
        guard let resp = try? await client.integration.list(IntegrationListInput(location: locationQuery)) else { return }
        let items = resp.data.map(TUIIntegrationItem.from)
        store.withLock { state in
            state.integrations = items
        }
        markDirty()
    }

    public func refreshServerInfo() async {
        guard let info = try? await client.server.info() else { return }
        store.withLock { state in
            if !info.version.isEmpty {
                state.serverVersion = info.version
            }
        }
        markDirty()
    }

    public func refreshAgents() async {
        guard let resp = try? await client.agent.list(AgentListInput(location: locationQuery)) else { return }
        let visible = resp.data
            .filter { $0.mode != .subagent && !$0.hidden }
            .map { agent in
                TUIAgentItem(
                    id: agent.id.rawValue,
                    name: agent.name.rawValue,
                    description: agent.description,
                    colorHex: agent.color?.rawValue,
                    defaultModel: agent.model
                )
            }
        guard !visible.isEmpty else { return }
        store.withLock { state in
            let previousID = state.activeAgent.id
            state.agents = visible
            if let matched = visible.firstIndex(where: { $0.id == previousID }) {
                state.selectedAgentIndex = matched
            } else {
                state.selectedAgentIndex = 0
            }
        }
        markDirty()
    }

    public func refreshProvidersAndModels() async {
        async let providersTask = try? client.provider.list(ProviderListInput(location: locationQuery))
        async let modelsTask = try? client.model.list(ModelListInput(location: locationQuery))
        async let defaultTask = try? client.model.default(ModelDefaultInput(location: locationQuery))

        let providersResp = await providersTask
        let modelsResp = await modelsTask
        let defaultResp = await defaultTask

        var providerMap: [String: String] = [:]
        if let providersResp {
            for p in providersResp.data {
                providerMap[p.id.rawValue] = p.name
            }
        }

        let mappedModels: [TUIModelItem]
        if let modelsResp {
            mappedModels = modelsResp.data
                .filter { $0.enabled && ($0.type == nil || $0.type == .chat) }
                .map { m in
                    let provName = providerMap[m.providerID.rawValue] ?? TUIUtil.titlecase(m.providerID.rawValue)
                    return TUIModelItem(
                        id: m.id.rawValue,
                        providerID: m.providerID.rawValue,
                        name: m.name,
                        providerName: provName,
                        variants: m.variants.map { $0.id.rawValue },
                        contextLimit: m.limit.context
                    )
                }
        } else {
            mappedModels = []
        }

        let defaultInfo = defaultResp?.data
        let defaultItem: TUIModelItem? = defaultInfo.map { m in
            let provName = providerMap[m.providerID.rawValue] ?? TUIUtil.titlecase(m.providerID.rawValue)
            return TUIModelItem(
                id: m.id.rawValue,
                providerID: m.providerID.rawValue,
                name: m.name,
                providerName: provName,
                variants: m.variants.map { $0.id.rawValue },
                contextLimit: m.limit.context
            )
        }

        store.withLock { state in
            if !providerMap.isEmpty {
                state.providers = providerMap
            }
            if !mappedModels.isEmpty {
                state.models = mappedModels
            }
            if state.selectedModel == nil {
                state.selectedModel = defaultItem ?? mappedModels.first
            } else if let current = state.selectedModel,
                      let refreshed = mappedModels.first(where: { $0.id == current.id && $0.providerID == current.providerID }) {
                state.selectedModel = refreshed
            }
            if state.contextLimit == nil {
                state.contextLimit = state.selectedModel?.contextLimit
            }
        }
        markDirty()
    }

    public func refreshMCP() async {
        guard let resp = try? await client.mcp.list(McpListInput(location: locationQuery)) else { return }
        let items = resp.data
            .map { TUIMCPServerItem(name: $0.name, title: $0.title, status: TUIMCPServerStatus(from: $0.status)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        store.withLock { state in
            state.mcpServers = items
        }
        markDirty()
    }

    public func refreshVCS() async {
        async let vcsInfo = try? client.vcs.get(VcsGetInput(location: locationQuery))
        async let vcsStatus = try? client.vcs.status(VcsStatusInput(location: locationQuery))
        let info = await vcsInfo
        let status = await vcsStatus

        store.withLock { state in
            if let branch = info?.data.branch.current, !branch.isEmpty {
                state.gitBranch = branch
            }
            if let files = status?.data {
                state.modifiedFiles = files.map { file in
                    TUIModifiedFileItem(
                        path: file.file,
                        additions: file.additions.rawValue,
                        deletions: file.deletions.rawValue,
                        status: file.status.rawValue
                    )
                }
            }
        }
        markDirty()
    }

    public func refreshSessions() async {
        guard let list = try? await client.session.list(SessionListInput(limit: 50)) else { return }
        let summaries = list.data.map { s in
            TUISessionItem(
                id: s.id.rawValue,
                title: SessionTitleFallback.displayLabel(title: s.title, parentID: s.parentID?.rawValue),
                directory: s.location.directory,
                updatedMs: s.time.updated,
                parentID: s.parentID?.rawValue
            )
        }
        store.withLock { state in
            state.sessions = summaries
            if let activeID = state.activeSessionID,
               let matched = summaries.first(where: { $0.id == activeID }) {
                state.activeSessionTitle = matched.title
            }
        }
        markDirty()
    }

    public func loadMessages(sessionID: String) async {
        async let listTask = try? client.message.list(MessageListInput(sessionID: sessionID, limit: 100))
        async let sessionTask = try? client.session.get(SessionGetInput(sessionID: sessionID))
        let resp = await listTask
        let info = await sessionTask

        if let info {
            let resolvedTitle = SessionTitleFallback.displayLabel(
                title: info.title,
                parentID: info.parentID?.rawValue
            )
            let infoAgent = info.agent
            let infoModelID = info.model?.id
            let infoProviderID = info.model?.providerID
            let infoVariant = info.model?.variant
            store.withLock { state in
                guard state.activeSessionID == sessionID else { return }
                state.activeSessionTitle = resolvedTitle
                if let agentIdx = state.agents.firstIndex(where: { $0.id == infoAgent }) {
                    state.selectedAgentIndex = agentIdx
                }
                if let infoModelID, let infoProviderID,
                   let matchedModel = state.models.first(where: {
                       $0.id == infoModelID && $0.providerID == infoProviderID
                   }) {
                    state.selectedModel = matchedModel
                    state.contextLimit = matchedModel.contextLimit
                }
                if infoModelID != nil {
                    state.selectedVariant = infoVariant
                }
            }
        }

        guard let resp else { return }
        var totalCost = 0.0
        var latestTokens = 0
        var mapped: [TUITranscriptItem] = []

        for msg in resp.data {
            switch msg {
            case .user(let u):
                mapped.append(.user(id: u.id.rawValue, text: u.text, agentName: nil, isOptimistic: false))
            case .synthetic(let s):
                mapped.append(.system(id: s.id.rawValue, text: s.text, isError: false))
            case .system(let s):
                mapped.append(.system(id: s.id.rawValue, text: s.text, isError: false))
            case .shell(let sh):
                let status: TUIToolRunStatus = sh.status == .running ? .running : ((sh.exit ?? 0) == 0 ? .completed : .error)
                let part = TUIAssistantPartItem.tool(
                    id: sh.shellID,
                    name: "shell",
                    status: status,
                    summary: sh.command,
                    outputPreview: Self.previewLines(sh.output?.output),
                    error: status == .error ? "Exited with code \(Int(sh.exit ?? 1))" : nil
                )
                mapped.append(.assistant(
                    id: sh.id.rawValue,
                    agentName: "Shell",
                    modelLabel: nil,
                    parts: [part],
                    completed: sh.time.completed != nil,
                    error: nil
                ))
            case .assistant(let a):
                if let cost = a.cost { totalCost += cost }
                if let usage = a.tokens {
                    let sum = usage.input + usage.output + usage.reasoning + usage.cache.read + usage.cache.write
                    latestTokens = Int(sum.rounded())
                }
                let parts: [TUIAssistantPartItem] = a.content.enumerated().compactMap { idx, content in
                    switch content {
                    case .reasoning(let r):
                        let cleaned = r.text.replacingOccurrences(of: "[REDACTED]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleaned.isEmpty else { return nil }
                        return .reasoning(id: "\(a.id.rawValue)-r-\(idx)", text: cleaned, completed: r.time?.completed != nil || a.time.completed != nil)
                    case .text(let t):
                        guard !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        return .text(id: "\(a.id.rawValue)-t-\(idx)", text: t.text)
                    case .tool(let tl):
                        return Self.mapAssistantTool(tl)
                    }
                }
                if !parts.isEmpty || a.error != nil {
                    mapped.append(.assistant(
                        id: a.id.rawValue,
                        agentName: TUIUtil.titlecase(a.agent),
                        modelLabel: a.model.id,
                        parts: parts,
                        completed: a.time.completed != nil,
                        error: a.error?.message
                    ))
                }
            case .idle(let idle):
                if let err = idle.error {
                    mapped.append(.system(id: idle.id.rawValue, text: "Error: \(err.message)", isError: true))
                }
            default:
                break
            }
        }

        store.withLock { state in
            guard state.activeSessionID == sessionID else { return }
            // Preserve optimistic user messages that haven't been projected on the server yet
            let serverUserTexts = Set(mapped.compactMap { item -> String? in
                if case .user(_, let text, _, _) = item { return text }
                return nil
            })
            let remainingOptimistic = state.messages.filter { item in
                if case .user(_, let text, _, let isOpt) = item, isOpt {
                    return !serverUserTexts.contains(text)
                }
                return false
            }
            // Preserve active in-flight streaming assistant message if server hasn't persisted it yet
            let serverIDs = Set(mapped.map(\.itemID))
            let inFlightStreaming = state.messages.filter { item in
                if case .assistant(let id, _, _, let parts, let completed, _) = item,
                   !completed,
                   !parts.isEmpty,
                   !serverIDs.contains(id) {
                    return true
                }
                return false
            }
            state.messages = mapped + remainingOptimistic + inFlightStreaming
            if totalCost > 0 { state.sessionCost = totalCost }
            if latestTokens > 0 { state.contextTokens = latestTokens }
        }
        markDirty()
    }

    private static func mapAssistantTool(_ tool: SessionMessageSchema.AssistantTool) -> TUIAssistantPartItem {
        switch tool.state {
        case .streaming(let s):
            return .tool(
                id: tool.id,
                name: tool.name,
                status: .streaming,
                summary: String(s.input.prefix(80)),
                outputPreview: nil,
                error: nil
            )
        case .running(let r):
            return .tool(
                id: tool.id,
                name: tool.name,
                status: .running,
                summary: summarizeToolInput(r.input),
                outputPreview: nil,
                error: nil
            )
        case .completed(let c):
            let textOut = c.content.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            return .tool(
                id: tool.id,
                name: tool.name,
                status: .completed,
                summary: summarizeToolInput(c.input),
                outputPreview: previewLines(textOut),
                error: nil
            )
        case .error(let e):
            return .tool(
                id: tool.id,
                name: tool.name,
                status: .error,
                summary: summarizeToolInput(e.input),
                outputPreview: nil,
                error: e.error.message
            )
        }
    }

    public static func summarizeToolInput(_ input: [String: JSONValue]) -> String {
        let preferred = ["path", "filePath", "command", "pattern", "query", "url", "description", "id", "code"]
        for key in preferred {
            if let value = input[key] {
                if case .string(let s) = value, !s.isEmpty {
                    return firstLineTruncated(s, limit: 72)
                }
            }
        }
        for key in input.keys.sorted() {
            if case .string(let s) = input[key], !s.isEmpty {
                return firstLineTruncated(s, limit: 72)
            }
        }
        return ""
    }

    public static func previewLines(_ text: String?, maxLines: Int = 2, maxCols: Int = 78) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .map { firstLineTruncated(String($0), limit: maxCols) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func firstLineTruncated(_ value: String, limit: Int) -> String {
        let first = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        return TUIUtil.truncateWidth(first.trimmingCharacters(in: .whitespaces), limit)
    }

    // MARK: - Live SSE `/api/event` Stream

    public func startEventStream() -> Task<Void, Never> {
        Task { [weak self] in
            var backoffMs: UInt64 = 250
            var everConnected = false
            while !Task.isCancelled {
                guard let self else { return }
                if self.store.withLock({ $0.shouldQuit }) { return }
                let stream = self.client.event.subscribe()
                do {
                    for try await event in stream {
                        if Task.isCancelled || self.store.withLock({ $0.shouldQuit }) { return }
                        backoffMs = 250
                        everConnected = true
                        let effect = self.store.withLock { state -> EventSideEffect in
                            state.sseConnected = true
                            state.sseReconnecting = false
                            return Self.applyServerEvent(event, to: &state)
                        }
                        self.markDirty()
                        self.dispatch(effect: effect)
                    }
                } catch {
                    // Transient disconnect or server restart — reconnect with bounded backoff.
                }
                if Task.isCancelled || self.store.withLock({ $0.shouldQuit }) { return }
                if everConnected {
                    self.store.withLock { state in
                        state.sseConnected = false
                        state.sseReconnecting = true
                    }
                    self.markDirty()
                }
                try? await Task.sleep(for: .milliseconds(backoffMs))
                backoffMs = min(backoffMs * 2, 2_000)
            }
        }
    }

    private func dispatch(effect: EventSideEffect) {
        if effect.refreshAgents {
            Task { await self.refreshAgents() }
        }
        if effect.refreshIntegrations {
            Task { await self.refreshIntegrations() }
        }
        if effect.refreshModels {
            Task { await self.refreshProvidersAndModels() }
        }
        if effect.refreshMCP {
            Task { await self.refreshMCP() }
        }
        if effect.refreshVCS {
            Task { await self.refreshVCS() }
        }
        if effect.refreshSessions {
            Task { await self.refreshSessions() }
        }
        if effect.refreshCommands {
            Task { await self.refreshCommands() }
        }
        if effect.refreshSkills {
            Task { await self.refreshSkills() }
        }
        if effect.refreshPermissions {
            Task { await self.refreshPermissions() }
        }
        if effect.refreshForms {
            Task { await self.refreshForms() }
        }
        if let sid = effect.refreshMessagesForSession {
            Task { await self.loadMessages(sessionID: sid) }
        }
        if let sid = effect.selectSessionID {
            let title = store.withLock { state in
                state.sessions.first(where: { $0.id == sid })?.title ?? "Session"
            }
            openSession(id: sid, title: title)
        }
    }

    /// Pure deterministic SSE event reducer — directly testable without sockets.
    @discardableResult
    public static func applyServerEvent(
        _ event: OpenCodeEvent,
        to state: inout TUIInteractiveState
    ) -> EventSideEffect {
        var effect = EventSideEffect()
        let obj = jsonObject(event.data)
        let eventSessionID = stringField(obj, "sessionID")
        let isForActiveSession = eventSessionID != nil && eventSessionID == state.activeSessionID

        switch event.type {
        case "session.text.started":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let ordinal = intField(obj, "ordinal") ?? 0
            let partID = "\(msgID)-text-\(ordinal)"
            upsertAssistantPart(in: &state, messageID: msgID, partID: partID) { existing in
                if let existing { return existing }
                return .text(id: partID, text: "")
            }
            state.sessionStatus = .running

        case "session.text.delta":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let ordinal = intField(obj, "ordinal") ?? 0
            let delta = stringField(obj, "delta") ?? stringField(obj, "text") ?? ""
            guard !delta.isEmpty else { break }
            let partID = "\(msgID)-text-\(ordinal)"
            upsertAssistantPart(in: &state, messageID: msgID, partID: partID) { existing in
                if case .text(let id, let prev) = existing {
                    return .text(id: id, text: prev + delta)
                }
                return .text(id: partID, text: delta)
            }
            state.sessionStatus = .running

        case "session.text.ended":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let ordinal = intField(obj, "ordinal") ?? 0
            let partID = "\(msgID)-text-\(ordinal)"
            if let text = stringField(obj, "text") {
                upsertAssistantPart(in: &state, messageID: msgID, partID: partID) { _ in
                    .text(id: partID, text: text)
                }
            }

        case "session.reasoning.started":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let ordinal = intField(obj, "ordinal") ?? 0
            let partID = "\(msgID)-reasoning-\(ordinal)"
            upsertAssistantPart(in: &state, messageID: msgID, partID: partID) { existing in
                if let existing { return existing }
                return .reasoning(id: partID, text: "", completed: false)
            }
            state.sessionStatus = .running

        case "session.reasoning.delta":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let ordinal = intField(obj, "ordinal") ?? 0
            let delta = stringField(obj, "delta") ?? stringField(obj, "text") ?? ""
            guard !delta.isEmpty else { break }
            let partID = "\(msgID)-reasoning-\(ordinal)"
            upsertAssistantPart(in: &state, messageID: msgID, partID: partID) { existing in
                if case .reasoning(let id, let prev, let done) = existing {
                    return .reasoning(id: id, text: prev + delta, completed: done)
                }
                return .reasoning(id: partID, text: delta, completed: false)
            }
            state.sessionStatus = .running

        case "session.reasoning.ended":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let ordinal = intField(obj, "ordinal") ?? 0
            let partID = "\(msgID)-reasoning-\(ordinal)"
            let finalText = stringField(obj, "text")
            upsertAssistantPart(in: &state, messageID: msgID, partID: partID) { existing in
                let prevText: String
                if case .reasoning(_, let text, _) = existing { prevText = text } else { prevText = "" }
                return .reasoning(id: partID, text: finalText ?? prevText, completed: true)
            }

        case "session.tool.input.started":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let toolID = stringField(obj, "id") ?? "tool"
            let name = stringField(obj, "name") ?? "tool"
            upsertAssistantPart(in: &state, messageID: msgID, partID: toolID) { _ in
                .tool(id: toolID, name: name, status: .streaming, summary: "", outputPreview: nil, error: nil)
            }
            state.sessionStatus = .running

        case "session.tool.called":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let toolID = stringField(obj, "id") ?? "tool"
            let name = stringField(obj, "name")
            let inputDict = jsonObject(obj["input"])
            let summary = summarizeToolInput(inputDict)
            upsertAssistantPart(in: &state, messageID: msgID, partID: toolID) { existing in
                let resolvedName: String
                if let name, !name.isEmpty {
                    resolvedName = name
                } else if case .tool(_, let prevName, _, _, _, _) = existing {
                    resolvedName = prevName
                } else {
                    resolvedName = "tool"
                }
                return .tool(id: toolID, name: resolvedName, status: .running, summary: summary, outputPreview: nil, error: nil)
            }
            state.sessionStatus = .running

        case "session.tool.progress":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let toolID = stringField(obj, "id") ?? "tool"
            let meta = jsonObject(obj["metadata"])
            let preview = stringField(meta, "output") ?? stringField(meta, "title")
            upsertAssistantPart(in: &state, messageID: msgID, partID: toolID) { existing in
                if case .tool(let id, let name, _, let summary, let prevOut, let err) = existing {
                    return .tool(id: id, name: name, status: .running, summary: summary, outputPreview: previewLines(preview) ?? prevOut, error: err)
                }
                return .tool(id: toolID, name: "tool", status: .running, summary: "", outputPreview: previewLines(preview), error: nil)
            }

        case "session.tool.success":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let toolID = stringField(obj, "id") ?? "tool"
            var previewText: String? = nil
            if case .array(let items) = obj["content"] {
                let texts = items.compactMap { item -> String? in
                    let dict = jsonObject(item)
                    return stringField(dict, "text")
                }
                if !texts.isEmpty {
                    previewText = previewLines(texts.joined(separator: "\n"))
                }
            }
            upsertAssistantPart(in: &state, messageID: msgID, partID: toolID) { existing in
                if case .tool(let id, let name, _, let summary, _, _) = existing {
                    return .tool(id: id, name: name, status: .completed, summary: summary, outputPreview: previewText, error: nil)
                }
                return .tool(id: toolID, name: stringField(obj, "name") ?? "tool", status: .completed, summary: "", outputPreview: previewText, error: nil)
            }

        case "session.tool.failed":
            guard isForActiveSession else { break }
            let msgID = stringField(obj, "assistantMessageID") ?? stringField(obj, "messageID") ?? "stream"
            let toolID = stringField(obj, "id") ?? "tool"
            let errObj = jsonObject(obj["error"])
            let errMsg = stringField(errObj, "message") ?? stringField(obj, "error") ?? "Tool failed"
            upsertAssistantPart(in: &state, messageID: msgID, partID: toolID) { existing in
                if case .tool(let id, let name, _, let summary, let out, _) = existing {
                    return .tool(id: id, name: name, status: .error, summary: summary, outputPreview: out, error: errMsg)
                }
                return .tool(id: toolID, name: stringField(obj, "name") ?? "tool", status: .error, summary: "", outputPreview: nil, error: errMsg)
            }

        case "session.status":
            guard isForActiveSession else { break }
            let statusObj = jsonObject(obj["status"])
            let kind = stringField(statusObj, "type") ?? stringField(obj, "status") ?? ""
            switch kind {
            case "busy", "running":
                state.sessionStatus = .running
            case "retry":
                let msg = stringField(statusObj, "message") ?? "Retrying…"
                state.sessionStatus = .retry(msg)
            case "idle":
                state.sessionStatus = .idle
                state.interruptArmed = false
                markLastAssistantCompleted(in: &state)
                if let sid = state.activeSessionID {
                    effect.refreshMessagesForSession = sid
                }
            default:
                break
            }

        case "session.execution.started", "session.step.started":
            if isForActiveSession {
                state.sessionStatus = .running
            }

        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.idle":
            if isForActiveSession {
                state.sessionStatus = .idle
                state.interruptArmed = false
                markLastAssistantCompleted(in: &state)
                if let sid = state.activeSessionID {
                    effect.refreshMessagesForSession = sid
                }
            }

        case "session.step.ended":
            if isForActiveSession {
                markLastAssistantCompleted(in: &state)
                if let sid = state.activeSessionID {
                    effect.refreshMessagesForSession = sid
                }
            }

        case "session.message.created", "session.message.content.updated":
            if isForActiveSession, let sid = state.activeSessionID {
                effect.refreshMessagesForSession = sid
            }

        case "session.inbox.delivered":
            if isForActiveSession {
                if let deliveredID = stringField(obj, "id") ?? stringField(obj, "inboxID") {
                    state.queuedPrompts.removeAll { $0.id == deliveredID }
                }
                if let sid = state.activeSessionID {
                    effect.refreshMessagesForSession = sid
                }
            }

        case "session.inbox.cancelled":
            if isForActiveSession,
               let cancelledID = stringField(obj, "id") ?? stringField(obj, "inboxID") {
                state.queuedPrompts.removeAll { $0.id == cancelledID }
            }

        case "pty.exited":
            if let ptyID = stringField(obj, "id"), state.terminalPane.ptyID == ptyID {
                state.terminalPane.exitCode = intField(obj, "exitCode") ?? 0
            }

        case "pty.deleted":
            if let ptyID = stringField(obj, "id"), state.terminalPane.ptyID == ptyID {
                state.terminalPane.ptyID = nil
            }

        case "session.usage.updated", "session.usage.recorded":
            guard isForActiveSession else { break }
            if let cost = doubleField(obj, "cost") {
                state.sessionCost = max(state.sessionCost, cost)
            }
            let tokensObj = jsonObject(obj["tokens"] ?? obj["usage"])
            let total = (intField(tokensObj, "input") ?? 0)
                + (intField(tokensObj, "output") ?? 0)
                + (intField(tokensObj, "reasoning") ?? 0)
            if total > 0 {
                state.contextTokens = total
            }

        case "session.created", "session.deleted":
            effect.refreshSessions = true

        case "session.renamed":
            if let sid = eventSessionID, let title = stringField(obj, "title"), !title.isEmpty {
                if state.activeSessionID == sid {
                    state.activeSessionTitle = title
                }
                if let idx = state.sessions.firstIndex(where: { $0.id == sid }) {
                    let prev = state.sessions[idx]
                    state.sessions[idx] = TUISessionItem(
                        id: prev.id,
                        title: title,
                        directory: prev.directory,
                        updatedMs: prev.updatedMs,
                        parentID: prev.parentID
                    )
                }
            }

        case "session.agent.selected":
            if isForActiveSession, let agentID = stringField(obj, "agent"),
               let idx = state.agents.firstIndex(where: { $0.id == agentID }) {
                state.selectedAgentIndex = idx
            }

        case "session.model.selected":
            if isForActiveSession {
                let modelObj = jsonObject(obj["model"])
                if let modelID = stringField(modelObj, "id"),
                   let providerID = stringField(modelObj, "providerID"),
                   let matched = state.models.first(where: { $0.id == modelID && $0.providerID == providerID }) {
                    state.selectedModel = matched
                    state.contextLimit = matched.contextLimit
                    state.selectedVariant = stringField(modelObj, "variant")
                }
            }

        case "mcp.status.changed", "mcp.updated":
            effect.refreshMCP = true

        case "vcs.branch.updated", "vcs.updated":
            if let branch = stringField(obj, "branch"), !branch.isEmpty {
                state.gitBranch = branch
            }
            effect.refreshVCS = true

        case "server.connected":
            state.sseConnected = true
            state.sseReconnecting = false

        case "permission.asked":
            if let reqID = stringField(obj, "id"),
               let sid = stringField(obj, "sessionID") ?? state.activeSessionID,
               let action = stringField(obj, "action") ?? stringField(obj, "permission") {
                var resources: [String] = []
                if case .array(let arr) = obj["resources"] ?? obj["patterns"] {
                    resources = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                }
                var savePatterns: [String] = resources
                if case .array(let arr) = obj["save"] {
                    savePatterns = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                }
                let meta = jsonObject(obj["metadata"])
                let item = TUIPendingPermissionItem(
                    id: reqID,
                    sessionID: sid,
                    permission: action,
                    patterns: resources,
                    alwaysPatterns: savePatterns,
                    toolName: action,
                    commandPreview: stringField(meta, "command"),
                    filePath: stringField(meta, "filepath") ?? stringField(meta, "filePath") ?? stringField(meta, "path"),
                    diffPatch: stringField(meta, "diff") ?? stringField(meta, "patch")
                )
                state.pendingPermissions.removeAll { $0.id == reqID }
                state.pendingPermissions.append(item)
                state.permissionPromptState = TUIPermissionPromptState()
            } else {
                effect.refreshPermissions = true
            }

        case "permission.replied":
            if let reqID = stringField(obj, "requestID") ?? stringField(obj, "id") {
                state.pendingPermissions.removeAll { $0.id == reqID }
                if state.pendingPermissions.isEmpty {
                    state.permissionPromptState = TUIPermissionPromptState()
                }
            } else {
                effect.refreshPermissions = true
            }

        case "form.asked", "form.created":
            effect.refreshForms = true

        case "form.replied", "form.cancelled", "form.settled":
            if let formID = stringField(obj, "formID") ?? stringField(obj, "id") {
                state.pendingForms.removeAll { $0.id == formID }
                if state.pendingForms.isEmpty {
                    state.formPromptState = TUIFormPromptState()
                }
            } else {
                effect.refreshForms = true
            }

        case "command.updated":
            effect.refreshCommands = true

        case "skill.updated":
            effect.refreshSkills = true

        case "todo.updated", "session.todo.updated":
            if !isForActiveSession && eventSessionID != nil { break }
            if case .array(let arr) = obj["todos"] ?? obj["items"] {
                let parsed: [TUITodoItem] = arr.compactMap { entry in
                    let d = jsonObject(entry)
                    guard let content = stringField(d, "content") ?? stringField(d, "text") else { return nil }
                    let id = stringField(d, "id") ?? content
                    let rawStatus = stringField(d, "status") ?? "pending"
                    let status = TUITodoStatus(rawValue: rawStatus) ?? .pending
                    return TUITodoItem(id: id, content: content, status: status, priority: stringField(d, "priority"))
                }
                state.todos = parsed
            }

        case "tui.toast.show":
            if let msg = stringField(obj, "message"), !msg.isEmpty {
                state.toastMessage = msg
                state.toastIsError = (stringField(obj, "variant") == "error")
            }

        case "tui.session.select":
            if let sid = eventSessionID, !sid.isEmpty {
                effect.selectSessionID = sid
            }

        case "agent.updated":
            effect.refreshAgents = true

        case "integration.updated":
            effect.refreshIntegrations = true
            effect.refreshModels = true

        case "model.updated", "provider.updated":
            effect.refreshModels = true
            effect.refreshIntegrations = true

        default:
            break
        }

        return effect
    }

    private static func upsertAssistantPart(
        in state: inout TUIInteractiveState,
        messageID: String,
        partID: String,
        transform: (TUIAssistantPartItem?) -> TUIAssistantPartItem
    ) {
        if let msgIdx = state.messages.lastIndex(where: {
            if case .assistant(let id, _, _, _, _, _) = $0 { return id == messageID }
            return false
        }) {
            if case .assistant(let id, let agent, let model, var parts, let completed, let error) = state.messages[msgIdx] {
                if let pIdx = parts.firstIndex(where: { $0.partID == partID }) {
                    parts[pIdx] = transform(parts[pIdx])
                } else {
                    parts.append(transform(nil))
                }
                state.messages[msgIdx] = .assistant(
                    id: id,
                    agentName: agent,
                    modelLabel: model,
                    parts: parts,
                    completed: completed,
                    error: error
                )
            }
        } else {
            let newPart = transform(nil)
            state.messages.append(.assistant(
                id: messageID,
                agentName: state.activeAgent.displayName,
                modelLabel: state.activeModelLabel,
                parts: [newPart],
                completed: false,
                error: nil
            ))
        }
    }

    private static func markLastAssistantCompleted(in state: inout TUIInteractiveState) {
        guard let idx = state.messages.lastIndex(where: {
            if case .assistant(_, _, _, _, let completed, _) = $0 { return !completed }
            return false
        }) else { return }
        if case .assistant(let id, let agent, let model, let parts, _, let error) = state.messages[idx] {
            let finalizedParts = parts.map { part -> TUIAssistantPartItem in
                if case .reasoning(let pid, let text, _) = part {
                    return .reasoning(id: pid, text: text, completed: true)
                }
                return part
            }
            state.messages[idx] = .assistant(
                id: id,
                agentName: agent,
                modelLabel: model,
                parts: finalizedParts,
                completed: true,
                error: error
            )
        }
    }

    // MARK: - User Actions

    public func submitPrompt(rawText: String) {
        let (isShell, pastedBlocks) = store.withLock { ($0.shellMode, $0.pastedBlocks) }
        let expanded = TUIPasteManager.expand(rawText, blocks: pastedBlocks)
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isShell {
            let cmd = TUIShellMode.extractShellCommand(from: trimmed, isShellMode: true) ?? trimmed
            submitShellCommand(cmd)
            return
        }

        if handleSlashCommand(trimmed) {
            return
        }

        // Record prompt in history + persist
        let historyEntry = TUIPromptHistoryEntry(input: trimmed, mode: "normal")
        store.withLock { state in
            state.historyNavigator.append(historyEntry)
        }
        if let persistence {
            Task { await persistence.appendHistory(historyEntry) }
        }

        let optimisticID = nextOptimisticID()
        let submission = store.withLock { state -> (sessionID: String?, agentID: String, modelRef: ModelSchema.Ref?, dir: String) in
            state.promptText = ""
            state.pastedBlocks = []
            state.slashAutocompleteDismissed = false
            state.slashAutocompleteIndex = 0
            state.mentionAutocompleteDismissed = false
            state.mentionAutocompleteIndex = 0
            state.toastMessage = nil
            state.sessionStatus = .running
            state.interruptArmed = false
            state.messages.append(.user(
                id: optimisticID,
                text: trimmed,
                agentName: state.activeAgent.displayName,
                isOptimistic: true
            ))
            let title = String(trimmed.prefix(48))
            if state.activeSessionID == nil {
                state.activeSessionTitle = title
            }
            return (
                state.activeSessionID,
                state.activeAgent.id,
                state.selectedModel?.ref(variant: state.selectedVariant),
                state.directory
            )
        }
        markDirty()

        Task { [weak self] in
            guard let self else { return }
            do {
                let targetSessionID: String
                if let existing = submission.sessionID {
                    targetSessionID = existing
                } else {
                    let title = String(trimmed.prefix(48))
                    let loc = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: submission.dir))
                    let created = try await self.client.session.create(SessionCreateInput(
                        title: title,
                        agent: submission.agentID,
                        model: submission.modelRef,
                        location: loc
                    ))
                    targetSessionID = created.id.rawValue
                    self.store.withLock { state in
                        state.activeSessionID = targetSessionID
                        state.activeSessionTitle = title
                        state.route = .session(TUIContext.SessionRoute(sessionID: targetSessionID))
                        if !state.openSessionTabs.contains(targetSessionID) {
                            state.openSessionTabs.append(targetSessionID)
                        }
                    }
                    self.markDirty()
                }
                _ = try await self.client.session.prompt(SessionPromptInput(
                    sessionID: targetSessionID,
                    text: trimmed
                ))
                self.store.withLock { state in
                    state.route = .session(TUIContext.SessionRoute(sessionID: targetSessionID))
                }
                self.markDirty()
                await self.loadMessages(sessionID: targetSessionID)
                await self.refreshSessions()
            } catch {
                self.store.withLock { state in
                    state.sessionStatus = .idle
                    state.messages.append(.system(
                        id: self.nextOptimisticID(),
                        text: "Failed to send prompt: \(error)",
                        isError: true
                    ))
                    state.toastMessage = "Error: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    @discardableResult
    public func handleSlashCommand(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("/") else { return false }
        let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let cmdToken = String(pieces.first ?? "").lowercased()
        let argsText = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        switch cmdToken {
        case "/quit", "/exit", "/q":
            store.withLock {
                $0.shouldQuit = true
                $0.exitReason = "slash_quit"
            }
            markDirty()
            return true

        case "/home":
            store.withLock {
                $0.route = .home(TUIContext.HomeRoute())
                $0.promptText = ""
                $0.pastedBlocks = []
                $0.activeDialog = nil
                $0.slashAutocompleteDismissed = false
            }
            markDirty()
            return true

        case "/new", "/clear":
            startNewSession()
            return true

        case "/connect", "/providers", "/provider", "/login":
            openConnectProvider()
            return true

        case "/models", "/model":
            openModelPicker(providerID: nil)
            return true

        case "/agents", "/agent":
            openAgentPicker()
            return true

        case "/variants", "/variant", "/thinking", "/effort":
            openVariantPicker()
            return true

        case "/sessions", "/session", "/resume", "/continue":
            openDialog(.sessionList)
            Task { await self.refreshSessions() }
            return true

        case "/themes", "/theme":
            openDialog(.themePicker)
            return true

        case "/mcps", "/mcp":
            openDialog(.mcpStatus)
            Task { await self.refreshMCP() }
            return true

        case "/diff", "/diffs":
            store.withLock { $0.promptText = "" }
            openDiffViewer()
            return true

        case "/settings", "/config":
            openSettingsDialog()
            return true

        case "/status":
            openStatusDialog()
            return true

        case "/usage":
            openUsageDialog()
            return true

        case "/skills", "/skill":
            openSkillsDialog()
            return true

        case "/timeline":
            openTimelineDialog()
            return true

        case "/undo":
            store.withLock { $0.promptText = "" }
            undoLastUserMessage()
            return true

        case "/redo":
            store.withLock { $0.promptText = "" }
            redoRevertedMessage()
            return true

        case "/fork":
            store.withLock { $0.promptText = "" }
            forkActiveSession()
            return true

        case "/rename":
            store.withLock { $0.promptText = "" }
            if !argsText.isEmpty, let sid = store.withLock({ $0.activeSessionID }) {
                renameSession(id: sid, newTitle: argsText)
            } else {
                openRenameSessionDialog()
            }
            return true

        case "/copy":
            store.withLock { $0.promptText = "" }
            copySessionTranscript()
            return true

        case "/export":
            store.withLock { $0.promptText = "" }
            exportSessionTranscript()
            return true

        case "/pair", "/web":
            openPairDialog()
            return true

        case "/workspaces", "/workspace", "/cd":
            openWorkspacesDialog()
            return true

        case "/stash":
            if argsText.lowercased() == "pop" {
                store.withLock { $0.promptText = "" }
                popMostRecentStash()
            } else if !argsText.isEmpty {
                store.withLock { $0.promptText = "" }
                stashPromptText(argsText)
            } else {
                openStashListDialog()
            }
            return true

        case "/editor":
            store.withLock { $0.promptText = "" }
            requestExternalEditor()
            return true

        case "/reload":
            store.withLock { $0.promptText = "" }
            reloadLocationConfig()
            return true

        case "/debug":
            openDebugDialog()
            return true

        case "/help":
            openHelpDialog()
            return true

        case "/commands":
            openDialog(.commandPalette)
            return true

        case "/sidebar":
            toggleSidebar()
            store.withLock { $0.promptText = "" }
            markDirty()
            return true

        case "/compact":
            store.withLock { $0.promptText = "" }
            markDirty()
            compactActiveSession()
            return true

        case "/queue", "/queued":
            openQueuedPromptsDialog()
            return true

        case "/terminal", "/term":
            store.withLock {
                $0.promptText = ""
                $0.pastedBlocks = []
            }
            toggleTerminalPane()
            return true

        default:
            // Dispatch custom server slash commands (e.g. `/init`, `/review`, `.opencode/commands/*.md`)
            let matchedServerCmd = store.withLock { state in
                state.serverCommands.first { cmd in
                    let normalized = cmd.name.hasPrefix("/") ? cmd.name.lowercased() : "/\(cmd.name.lowercased())"
                    return normalized == cmdToken
                }
            }
            if let serverCmd = matchedServerCmd {
                let rawName = serverCmd.name.hasPrefix("/") ? String(serverCmd.name.dropFirst()) : serverCmd.name
                submitServerCommand(name: rawName, arguments: argsText)
                return true
            }
            return false
        }
    }

    public func openDialog(_ dialog: TUIActiveDialog) {
        store.withLock { state in
            if dialog == .themePicker && state.themePreviewRestore == nil {
                state.themePreviewRestore = TUIThemeSnapshot(
                    themeName: state.themeName,
                    preference: state.themePreference
                )
            }
            if dialog != .modelPicker {
                state.modelPickerProviderID = nil
            }
            state.activeDialog = dialog
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.pendingDeleteCredentialID = nil
            state.connectErrorMessage = nil
            state.connectSubmitting = false
            state.leaderArmed = false
            if state.promptText.hasPrefix("/") {
                state.promptText = ""
            }
            state.slashAutocompleteDismissed = false
        }
        markDirty()
    }

    public func openModelPicker(providerID: String? = nil) {
        store.withLock { state in
            state.modelPickerProviderID = providerID
            state.activeDialog = .modelPicker
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.pendingDeleteCredentialID = nil
            state.connectErrorMessage = nil
            state.connectSubmitting = false
            state.leaderArmed = false
            if state.promptText.hasPrefix("/") {
                state.promptText = ""
            }
            state.slashAutocompleteDismissed = false
        }
        markDirty()
        Task { [weak self] in
            guard let self else { return }
            await self.refreshProvidersAndModels()
            await self.refreshIntegrations()
        }
    }

    public func openConnectProvider() {
        openDialog(.connectProvider)
        Task { [weak self] in
            await self?.refreshIntegrations()
        }
    }

    public func openAgentPicker() {
        openDialog(.agentPicker)
        Task { [weak self] in
            await self?.refreshAgents()
        }
    }

    public func openVariantPicker() {
        let variants = store.withLock { $0.selectedModel?.variants ?? [] }
        if variants.isEmpty {
            store.withLock { state in
                state.toastMessage = "Current model has no configurable variants"
                state.toastIsError = false
                if state.promptText.hasPrefix("/") {
                    state.promptText = ""
                }
            }
            markDirty()
            return
        }
        openDialog(.variantPicker)
    }

    public func closeDialog(commitTheme: Bool = false) {
        let activeOAuth = store.withLock { state -> (String, String)? in
            if state.activeDialog == .connectOAuth,
               let intID = state.connectTargetIntegrationID,
               let attemptID = state.connectOAuthAttemptID {
                return (intID, attemptID)
            }
            return nil
        }
        if let (intID, attemptID) = activeOAuth {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.client.integration.oauth.cancel(
                    IntegrationOauthCancelInput(integrationID: intID, attemptID: attemptID, location: self.locationQuery)
                )
            }
        }
        store.withLock { state in
            if !commitTheme, let restore = state.themePreviewRestore {
                state.themeName = restore.themeName
                state.themePreference = restore.preference
            }
            state.themePreviewRestore = nil
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.modelPickerProviderID = nil
            state.connectErrorMessage = nil
            state.connectSubmitting = false
            state.connectOAuthAttemptID = nil
            state.connectOAuthURL = nil
            state.connectOAuthInstructions = nil
            state.connectOAuthNeedsCode = false
            state.pendingDeleteCredentialID = nil
        }
        markDirty()
    }

    public func startNewSession() {
        store.withLock { state in
            state.activeSessionID = nil
            state.activeSessionTitle = "New Session"
            state.messages = []
            state.queuedPrompts = []
            state.contextTokens = 0
            state.sessionCost = 0
            state.sessionStatus = .idle
            state.interruptArmed = false
            state.route = .home(TUIContext.HomeRoute())
            state.promptText = ""
            state.pastedBlocks = []
            state.activeDialog = nil
            state.slashAutocompleteDismissed = false
            state.placeholderIndex = (state.placeholderIndex + 1) % TUIInteractiveState.promptPlaceholders.count
        }
        markDirty()
    }

    public func openSession(id: String, title: String) {
        store.withLock { state in
            state.activeSessionID = id
            state.activeSessionTitle = title
            state.messages = []
            state.todos = []
            state.queuedPrompts = []
            state.pastedBlocks = []
            state.contextTokens = 0
            state.sessionCost = 0
            state.sessionStatus = .idle
            state.interruptArmed = false
            state.hasRevertedMessage = false
            state.revertedMessageID = nil
            state.route = .session(TUIContext.SessionRoute(sessionID: id))
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.pendingDeleteSessionID = nil
            if !state.openSessionTabs.contains(id) {
                state.openSessionTabs.append(id)
            }
        }
        markDirty()
        Task { [weak self] in
            await self?.loadMessages(sessionID: id)
            await self?.refreshPermissions()
            await self?.refreshForms()
            await self?.refreshQueuedPrompts()
        }
    }

    public func cycleAgent(direction: Int = 1) {
        let info = store.withLock { state -> (sessionID: String?, agentID: String) in
            guard !state.agents.isEmpty else { return (state.activeSessionID, "build") }
            let count = state.agents.count
            state.selectedAgentIndex = ((state.selectedAgentIndex + direction) % count + count) % count
            return (state.activeSessionID, state.activeAgent.id)
        }
        markDirty()
        if let sid = info.sessionID {
            Task { [weak self] in
                _ = try? await self?.client.session.switchAgent(
                    SessionSwitchAgentInput(sessionID: sid, agent: info.agentID)
                )
            }
        }
    }

    public func selectAgent(id: String) {
        let info = store.withLock { state -> (sessionID: String?, agentID: String)? in
            guard let idx = state.agents.firstIndex(where: { $0.id == id }) else { return nil }
            state.selectedAgentIndex = idx
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            return (state.activeSessionID, state.agents[idx].id)
        }
        markDirty()
        if let info, let sid = info.sessionID {
            Task { [weak self] in
                _ = try? await self?.client.session.switchAgent(
                    SessionSwitchAgentInput(sessionID: sid, agent: info.agentID)
                )
            }
        }
    }

    public func selectModel(_ model: TUIModelItem) {
        let activeSID = store.withLock { state -> String? in
            state.selectedModel = model
            state.contextLimit = model.contextLimit
            if let variant = state.selectedVariant, !model.variants.contains(variant) {
                state.selectedVariant = nil
            }
            let key = "\(model.providerID)/\(model.id)"
            state.recentModels.removeAll { $0 == key }
            state.recentModels.insert(key, at: 0)
            if state.recentModels.count > 10 {
                state.recentModels = Array(state.recentModels.prefix(10))
            }
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.modelPickerProviderID = nil
            return state.activeSessionID
        }
        markDirty()
        persistModelStateAsync()
        if let sid = activeSID {
            let ref = store.withLock { $0.selectedModel?.ref(variant: $0.selectedVariant) } ?? model.ref
            Task { [weak self] in
                _ = try? await self?.client.session.switchModel(
                    SessionSwitchModelInput(sessionID: sid, model: ref)
                )
            }
        }
    }

    public func selectVariant(_ variant: String?) {
        let normalized = (variant == nil || variant == "default" || variant?.isEmpty == true) ? nil : variant
        let syncInfo = store.withLock { state -> (String, ModelSchema.Ref)? in
            state.selectedVariant = normalized
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            guard let sid = state.activeSessionID, let model = state.selectedModel else { return nil }
            return (sid, model.ref(variant: normalized))
        }
        markDirty()
        persistModelStateAsync()
        if let (sid, ref) = syncInfo {
            Task { [weak self] in
                _ = try? await self?.client.session.switchModel(
                    SessionSwitchModelInput(sessionID: sid, model: ref)
                )
            }
        }
    }

    public func cycleVariant() {
        let nextVariant = store.withLock { state -> (String?, Bool) in
            guard let model = state.selectedModel, !model.variants.isEmpty else { return (nil, false) }
            let options: [String?] = [nil] + model.variants.filter { $0 != "default" }.map { Optional($0) }
            let curIdx = options.firstIndex(where: { $0 == state.selectedVariant }) ?? 0
            let next = options[(curIdx + 1) % options.count]
            return (next, true)
        }
        guard nextVariant.1 else { return }
        selectVariant(nextVariant.0)
    }

    public func toggleFavoriteSelectedModel() {
        store.withLock { state in
            guard state.activeDialog == .modelPicker else { return }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            let key = rows[idx].id
            guard key != "__connect_provider__" else { return }
            if let existing = state.favoriteModels.firstIndex(of: key) {
                state.favoriteModels.remove(at: existing)
            } else {
                state.favoriteModels.insert(key, at: 0)
            }
        }
        persistModelStateAsync()
        markDirty()
    }

    public func cycleRecentModel(direction: Int = 1) {
        let chosen = store.withLock { state -> TUIModelItem? in
            let pool: [TUIModelItem]
            let recentItems = state.recentModels.compactMap { key in
                state.models.first(where: { "\($0.providerID)/\($0.id)" == key })
            }
            if recentItems.count >= 2 {
                pool = recentItems
            } else {
                pool = state.models
            }
            guard pool.count >= 2 else { return nil }
            let currentIdx = state.selectedModel.flatMap { cur in
                pool.firstIndex(where: { $0.id == cur.id && $0.providerID == cur.providerID })
            } ?? 0
            let nextIdx = ((currentIdx + direction) % pool.count + pool.count) % pool.count
            return pool[nextIdx]
        }
        if let chosen {
            selectModel(chosen)
        }
    }

    // MARK: - Provider & Integration Connection Flows (`dialog-integration.tsx`)

    public func selectIntegration(_ item: TUIIntegrationItem) {
        if !item.credentialConnections.isEmpty {
            store.withLock { state in
                state.connectTargetIntegrationID = item.id
                state.connectTargetIntegrationName = item.name
                state.activeDialog = .manageConnections
                state.dialogFilter = ""
                state.dialogSelectedIndex = 0
                state.pendingDeleteCredentialID = nil
                state.connectErrorMessage = nil
            }
            markDirty()
            return
        }
        beginConnectIntegration(item)
    }

    public func beginConnectIntegration(_ item: TUIIntegrationItem) {
        let methods = item.connectMethods
        if methods.isEmpty {
            let envHint = item.envVarNames.isEmpty ? "environment variables" : item.envVarNames.map { "$\($0)" }.joined(separator: " or ")
            store.withLock { state in
                state.toastMessage = "Set \(envHint) to connect \(item.name)"
                state.toastIsError = false
            }
            markDirty()
            return
        }
        if methods.count == 1 {
            beginConnectMethod(item, method: methods[0])
            return
        }
        store.withLock { state in
            state.connectTargetIntegrationID = item.id
            state.connectTargetIntegrationName = item.name
            state.activeDialog = .connectMethod
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.connectErrorMessage = nil
        }
        markDirty()
    }

    public func beginConnectMethod(_ item: TUIIntegrationItem, method: TUIIntegrationMethod) {
        switch method {
        case .key(let label):
            store.withLock { state in
                state.connectTargetIntegrationID = item.id
                state.connectTargetIntegrationName = item.name
                state.connectMethodLabel = label.isEmpty ? "API key" : label
                state.activeDialog = .connectAPIKey
                state.dialogFilter = ""
                state.dialogSelectedIndex = 0
                state.connectErrorMessage = nil
                state.connectSubmitting = false
            }
            markDirty()

        case .external(let methodID, _):
            store.withLock { state in
                state.connectSubmitting = true
                state.connectErrorMessage = nil
                state.toastMessage = "Connecting \(item.name)…"
                state.toastIsError = false
            }
            markDirty()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.integration.connect.external(
                        IntegrationConnectExternalInput(
                            integrationID: item.id,
                            location: self.locationQuery,
                            methodID: methodID
                        )
                    )
                    await self.finishProviderConnected(integrationID: item.id, integrationName: item.name)
                } catch {
                    self.store.withLock { state in
                        state.connectSubmitting = false
                        state.connectErrorMessage = "\(error)"
                        state.toastMessage = "Failed to connect \(item.name): \(error)"
                        state.toastIsError = true
                    }
                    self.markDirty()
                }
            }

        case .oauth(let methodID, let label):
            store.withLock { state in
                state.connectTargetIntegrationID = item.id
                state.connectTargetIntegrationName = item.name
                state.connectMethodLabel = label.isEmpty ? "OAuth" : label
                state.connectOAuthMethodID = methodID
                state.connectOAuthAttemptID = nil
                state.connectOAuthURL = nil
                state.connectOAuthInstructions = "Starting authorization…"
                state.connectOAuthNeedsCode = false
                state.connectSubmitting = true
                state.connectErrorMessage = nil
                state.activeDialog = .connectOAuth
                state.dialogFilter = ""
                state.dialogSelectedIndex = 0
            }
            markDirty()
            Task { [weak self] in
                guard let self else { return }
                do {
                    let started = try await self.client.integration.oauth.connect(
                        IntegrationOauthConnectInput(
                            integrationID: item.id,
                            location: self.locationQuery,
                            methodID: methodID
                        )
                    )
                    let data = started.data
                    let attemptID = data.attemptID.rawValue
                    let needsCode = (data.mode == .code)
                    self.store.withLock { state in
                        guard state.activeDialog == .connectOAuth else { return }
                        state.connectOAuthAttemptID = attemptID
                        state.connectOAuthURL = data.url
                        state.connectOAuthInstructions = data.instructions
                        state.connectOAuthNeedsCode = needsCode
                        state.connectSubmitting = false
                    }
                    self.markDirty()
                    if !needsCode {
                        await self.pollOAuthAttempt(
                            integrationID: item.id,
                            integrationName: item.name,
                            attemptID: attemptID
                        )
                    }
                } catch {
                    self.store.withLock { state in
                        state.connectSubmitting = false
                        state.connectErrorMessage = "\(error)"
                    }
                    self.markDirty()
                }
            }

        case .command(let methodID, let label):
            store.withLock { state in
                state.connectTargetIntegrationID = item.id
                state.connectTargetIntegrationName = item.name
                state.connectMethodLabel = label
                state.connectSubmitting = true
                state.toastMessage = "Running \(label)…"
                state.toastIsError = false
            }
            markDirty()
            Task { [weak self] in
                guard let self else { return }
                do {
                    let started = try await self.client.integration.command.connect(
                        IntegrationCommandConnectInput(
                            integrationID: item.id,
                            location: self.locationQuery,
                            methodID: methodID
                        )
                    )
                    let attemptID = started.data.attemptID.rawValue
                    for _ in 0..<120 {
                        try? await Task.sleep(for: .milliseconds(500))
                        let status = try await self.client.integration.command.status(
                            IntegrationCommandStatusInput(
                                integrationID: item.id,
                                attemptID: attemptID,
                                location: self.locationQuery
                            )
                        )
                        switch status.data {
                        case .pending:
                            continue
                        case .complete:
                            await self.finishProviderConnected(integrationID: item.id, integrationName: item.name)
                            return
                        case .failed(let msg, _):
                            self.store.withLock { state in
                                state.connectSubmitting = false
                                state.toastMessage = msg
                                state.toastIsError = true
                            }
                            self.markDirty()
                            return
                        case .expired:
                            self.store.withLock { state in
                                state.connectSubmitting = false
                                state.toastMessage = "Authentication expired"
                                state.toastIsError = true
                            }
                            self.markDirty()
                            return
                        }
                    }
                } catch {
                    self.store.withLock { state in
                        state.connectSubmitting = false
                        state.toastMessage = "Failed to connect \(item.name): \(error)"
                        state.toastIsError = true
                    }
                    self.markDirty()
                }
            }

        case .env(let names):
            let hint = names.map { "$\($0)" }.joined(separator: " or ")
            store.withLock { state in
                state.toastMessage = "Set \(hint) to connect \(item.name)"
                state.toastIsError = false
            }
            markDirty()
        }
    }

    public func submitAPIKey(_ rawKey: String? = nil) {
        let info = store.withLock { state -> (id: String, name: String, key: String)? in
            guard state.activeDialog == .connectAPIKey,
                  !state.connectSubmitting,
                  let id = state.connectTargetIntegrationID
            else {
                return nil
            }
            let key = (rawKey ?? state.dialogFilter).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                state.connectErrorMessage = "Please enter an API key"
                return nil
            }
            state.connectSubmitting = true
            state.connectErrorMessage = nil
            return (id, state.connectTargetIntegrationName, key)
        }
        markDirty()
        guard let info else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.integration.connect.key(
                    IntegrationConnectKeyInput(
                        integrationID: info.id,
                        location: self.locationQuery,
                        key: info.key
                    )
                )
                await self.finishProviderConnected(integrationID: info.id, integrationName: info.name)
            } catch {
                self.store.withLock { state in
                    state.connectSubmitting = false
                    state.connectErrorMessage = "\(error)"
                }
                self.markDirty()
            }
        }
    }

    public func submitOAuthCode(_ rawCode: String? = nil) {
        let info = store.withLock { state -> (id: String, name: String, attemptID: String, code: String)? in
            guard state.activeDialog == .connectOAuth,
                  !state.connectSubmitting,
                  let id = state.connectTargetIntegrationID,
                  let attemptID = state.connectOAuthAttemptID
            else {
                return nil
            }
            let code = (rawCode ?? state.dialogFilter).trimmingCharacters(in: .whitespacesAndNewlines)
            if state.connectOAuthNeedsCode && code.isEmpty {
                state.connectErrorMessage = "Please paste the authorization code"
                return nil
            }
            state.connectSubmitting = true
            state.connectErrorMessage = nil
            return (id, state.connectTargetIntegrationName, attemptID, code)
        }
        markDirty()
        guard let info else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.integration.oauth.complete(
                    IntegrationOauthCompleteInput(
                        integrationID: info.id,
                        attemptID: info.attemptID,
                        location: self.locationQuery,
                        code: info.code.isEmpty ? nil : info.code
                    )
                )
                await self.finishProviderConnected(integrationID: info.id, integrationName: info.name)
            } catch {
                self.store.withLock { state in
                    state.connectSubmitting = false
                    state.connectErrorMessage = "\(error)"
                }
                self.markDirty()
            }
        }
    }

    private func pollOAuthAttempt(integrationID: String, integrationName: String, attemptID: String) async {
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            let stillActive = store.withLock { state in
                state.activeDialog == .connectOAuth && state.connectOAuthAttemptID == attemptID
            }
            guard stillActive else { return }
            guard let resp = try? await client.integration.oauth.status(
                IntegrationOauthStatusInput(
                    integrationID: integrationID,
                    attemptID: attemptID,
                    location: locationQuery
                )
            ) else {
                continue
            }
            switch resp.data {
            case .pending:
                continue
            case .complete:
                await finishProviderConnected(integrationID: integrationID, integrationName: integrationName)
                return
            case .failed(let msg, _):
                store.withLock { state in
                    state.connectSubmitting = false
                    state.connectErrorMessage = msg
                }
                markDirty()
                return
            case .expired:
                store.withLock { state in
                    state.connectSubmitting = false
                    state.connectErrorMessage = "Authorization expired"
                }
                markDirty()
                return
            }
        }
    }

    private func finishProviderConnected(integrationID: String, integrationName: String) async {
        await refreshIntegrations()
        await refreshProvidersAndModels()
        let firstProviderModel = store.withLock { state -> TUIModelItem? in
            state.connectSubmitting = false
            state.connectErrorMessage = nil
            state.connectOAuthAttemptID = nil
            state.connectOAuthURL = nil
            state.connectOAuthInstructions = nil
            state.connectOAuthNeedsCode = false
            state.toastMessage = "Connected \(integrationName)"
            state.toastIsError = false
            let matched = state.models.first(where: { $0.providerID == integrationID })
            if state.selectedModel == nil, let matched {
                state.selectedModel = matched
                state.contextLimit = matched.contextLimit
            }
            return matched
        }
        if firstProviderModel != nil {
            openModelPicker(providerID: integrationID)
        } else {
            closeDialog(commitTheme: true)
        }
    }

    public func activateCredential(_ credID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.credential.activate(CredentialActivateInput(credentialID: credID))
                await self.refreshIntegrations()
                await self.refreshProvidersAndModels()
                self.store.withLock { state in
                    state.pendingDeleteCredentialID = nil
                    state.toastMessage = "Switched active account"
                    state.toastIsError = false
                }
                self.markDirty()
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Failed to switch account: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    public func requestRemoveSelectedCredential() {
        let action = store.withLock { state -> (removeID: String?, integrationName: String) in
            guard state.activeDialog == .manageConnections else { return (nil, "") }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return (nil, state.connectTargetIntegrationName) }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            let row = rows[idx]
            guard row.id.hasPrefix("cred:") else { return (nil, state.connectTargetIntegrationName) }
            let credID = String(row.id.dropFirst("cred:".count))
            if state.pendingDeleteCredentialID == credID {
                state.pendingDeleteCredentialID = nil
                return (credID, state.connectTargetIntegrationName)
            } else {
                state.pendingDeleteCredentialID = credID
                return (nil, state.connectTargetIntegrationName)
            }
        }
        markDirty()
        guard let credID = action.removeID else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.credential.remove(CredentialRemoveInput(credentialID: credID))
                await self.refreshIntegrations()
                await self.refreshProvidersAndModels()
                self.store.withLock { state in
                    state.toastMessage = "Removed account from \(action.integrationName)"
                    state.toastIsError = false
                    if let targetID = state.connectTargetIntegrationID,
                       let updated = state.integrations.first(where: { $0.id == targetID }),
                       updated.credentialConnections.isEmpty {
                        state.activeDialog = .connectProvider
                        state.dialogFilter = ""
                        state.dialogSelectedIndex = 0
                    }
                }
                self.markDirty()
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Failed to remove account: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    public func navigateBackFromSubDialog() {
        let current = store.withLock { $0.activeDialog }
        switch current {
        case .connectAPIKey, .connectMethod, .manageConnections:
            openConnectProvider()
        case .connectOAuth:
            closeDialog(commitTheme: false)
            openConnectProvider()
        default:
            closeDialog(commitTheme: false)
        }
    }

    public func toggleThemeMode() {
        store.withLock { state in
            let next: TUIThemePreference = (state.effectiveMode == .dark) ? .light : .dark
            state.themePreference = next
            state.themePreviewRestore = nil
        }
        markDirty()
    }

    public func toggleSidebar() {
        store.withLock { state in
            state.sidebarExplicitOverride = !state.effectiveShowSidebar
        }
        markDirty()
    }

    public func interruptActiveSession() {
        let activeSID = store.withLock { state -> String? in
            state.interruptArmed = false
            state.sessionStatus = .idle
            return state.activeSessionID
        }
        markDirty()
        if let sid = activeSID {
            Task { [weak self] in
                _ = try? await self?.client.session.interrupt(SessionInterruptInput(sessionID: sid))
            }
        }
    }

    public func compactActiveSession() {
        guard let sid = store.withLock({ $0.activeSessionID }) else { return }
        store.withLock {
            $0.toastMessage = "Compacting session…"
            $0.toastIsError = false
        }
        markDirty()
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.client.session.compact(SessionCompactInput(sessionID: sid))
            await self.loadMessages(sessionID: sid)
            self.store.withLock { $0.toastMessage = nil }
            self.markDirty()
        }
    }

    public func toggleMCPServer(named name: String) {
        let isConnected = store.withLock { state in
            state.mcpServers.first(where: { $0.name == name })?.status.isConnected ?? false
        }
        Task { [weak self] in
            guard let self else { return }
            if isConnected {
                _ = try? await self.client.mcp.disconnect(McpDisconnectInput(server: name, location: self.locationQuery))
            } else {
                _ = try? await self.client.mcp.connect(McpConnectInput(server: name, location: self.locationQuery))
            }
            await self.refreshMCP()
        }
    }

    public func previewThemeRowIfNeeded() {
        store.withLock { state in
            guard state.activeDialog == .themePicker else { return }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            let row = rows[idx]
            if row.id == "mode:auto" {
                state.themePreference = .auto
            } else if row.id == "mode:light" {
                state.themePreference = .light
            } else if row.id == "mode:dark" {
                state.themePreference = .dark
            } else if row.id.hasPrefix("theme:") {
                state.themeName = String(row.id.dropFirst("theme:".count))
            }
        }
    }

    public func confirmSelectedDialogRow() {
        let currentDialog = store.withLock { $0.activeDialog }
        if currentDialog == .connectAPIKey {
            submitAPIKey()
            return
        }
        if currentDialog == .connectOAuth {
            submitOAuthCode()
            return
        }
        if currentDialog == .renameSession {
            submitRenameSession()
            return
        }
        if currentDialog == .settings {
            cycleSelectedSetting(direction: 1)
            return
        }
        if currentDialog?.isCustomOverlay == true {
            closeDialog(commitTheme: true)
            return
        }

        let selection = store.withLock { state -> (TUIActiveDialog, TUIDialogRow)? in
            guard let dialog = state.activeDialog else { return nil }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return nil }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            return (dialog, rows[idx])
        }
        guard let (dialog, row) = selection else {
            closeDialog(commitTheme: false)
            return
        }

        switch dialog {
        case .commandPalette:
            closeDialog(commitTheme: true)
            switch TUIPaletteActionID(rawValue: row.id) {
            case .switchSession:
                openDialog(.sessionList)
                Task { await self.refreshSessions() }
            case .switchModel:
                openModelPicker(providerID: nil)
            case .connectProvider:
                openConnectProvider()
            case .switchAgent:
                openAgentPicker()
            case .cycleAgent:
                cycleAgent(direction: 1)
            case .switchVariant:
                openVariantPicker()
            case .viewDiff:
                openDiffViewer()
            case .openSettings:
                openSettingsDialog()
            case .openSkills:
                openSkillsDialog()
            case .timeline:
                openTimelineDialog()
            case .undoMessage:
                undoLastUserMessage()
            case .redoMessage:
                redoRevertedMessage()
            case .forkSession:
                forkActiveSession()
            case .renameSession:
                openRenameSessionDialog()
            case .copyTranscript:
                copySessionTranscript()
            case .exportTranscript:
                exportSessionTranscript()
            case .pairDevice:
                openPairDialog()
            case .viewStatus:
                openStatusDialog()
            case .viewUsage:
                openUsageDialog()
            case .openWorkspaces:
                openWorkspacesDialog()
            case .stashPrompt:
                stashCurrentPrompt()
            case .openStashList:
                openStashListDialog()
            case .openExternalEditor:
                requestExternalEditor()
            case .reloadConfig:
                reloadLocationConfig()
            case .switchTheme:
                openDialog(.themePicker)
            case .toggleMode:
                toggleThemeMode()
            case .mcpServers:
                openDialog(.mcpStatus)
                Task { await self.refreshMCP() }
            case .newSession:
                startNewSession()
            case .goHome:
                _ = handleSlashCommand("/home")
            case .toggleSidebar:
                toggleSidebar()
            case .compactSession:
                compactActiveSession()
            case .manageQueuedPrompts:
                openQueuedPromptsDialog()
            case .toggleTerminalPane:
                toggleTerminalPane()
            case .showHelp:
                openHelpDialog()
            case .showDebug:
                openDebugDialog()
            case .exit:
                store.withLock {
                    $0.shouldQuit = true
                    $0.exitReason = "palette_quit"
                }
                markDirty()
            case .none:
                break
            }

        case .modelPicker:
            if row.id == "__connect_provider__" {
                openConnectProvider()
                return
            }
            let model = store.withLock { state in
                state.models.first(where: { "\($0.providerID)/\($0.id)" == row.id })
            }
            if let model {
                selectModel(model)
            } else {
                closeDialog(commitTheme: true)
            }

        case .connectProvider:
            let integration = store.withLock { state in
                state.integrations.first(where: { $0.id == row.id })
            }
            if let integration {
                selectIntegration(integration)
            } else {
                closeDialog(commitTheme: false)
            }

        case .connectMethod:
            let match = store.withLock { state -> (TUIIntegrationItem, TUIIntegrationMethod)? in
                guard let id = state.connectTargetIntegrationID,
                      let item = state.integrations.first(where: { $0.id == id }),
                      let method = item.connectMethods.first(where: { $0.rowID == row.id })
                else {
                    return nil
                }
                return (item, method)
            }
            if let (item, method) = match {
                beginConnectMethod(item, method: method)
            } else {
                openConnectProvider()
            }

        case .manageConnections:
            if row.id == "__add_account__" {
                let integration = store.withLock { state in
                    state.connectTargetIntegrationID.flatMap { id in
                        state.integrations.first(where: { $0.id == id })
                    }
                }
                if let integration {
                    beginConnectIntegration(integration)
                }
                return
            }
            if row.id.hasPrefix("cred:") {
                let credID = String(row.id.dropFirst("cred:".count))
                activateCredential(credID)
            }

        case .connectAPIKey:
            submitAPIKey()

        case .connectOAuth:
            submitOAuthCode()

        case .renameSession:
            submitRenameSession()

        case .settings:
            cycleSelectedSetting(direction: 1)

        case .skills:
            closeDialog(commitTheme: true)
            activateSkill(id: row.id)

        case .timeline:
            closeDialog(commitTheme: true)
            revertToMessage(id: row.id)

        case .stashList:
            popStashEntry(id: row.id)

        case .workspaces:
            switchWorkspace(directory: row.id)

        case .status, .usage, .pair, .help, .debug, .diffViewer:
            closeDialog(commitTheme: true)

        case .agentPicker:
            selectAgent(id: row.id)

        case .variantPicker:
            selectVariant(row.id == "default" ? nil : row.id)

        case .sessionList:
            openSession(id: row.id, title: row.title)

        case .themePicker:
            previewThemeRowIfNeeded()
            closeDialog(commitTheme: true)
            persistPreferencesAsync()

        case .mcpStatus:
            toggleMCPServer(named: row.id)

        case .queuedPrompts:
            steerQueuedPrompt(id: row.id)
        }
    }

    // MARK: - JSON Extraction Helpers

    private static func jsonObject(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let dict) = value else { return [:] }
        return dict
    }

    private static func stringField(_ dict: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let s) = dict[key] else { return nil }
        return s
    }

    private static func intField(_ dict: [String: JSONValue], _ key: String) -> Int? {
        guard let v = dict[key] else { return nil }
        switch v {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    private static func doubleField(_ dict: [String: JSONValue], _ key: String) -> Double? {
        guard let v = dict[key] else { return nil }
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}
