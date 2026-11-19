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

public enum TUIActiveDialog: String, Equatable, Hashable, Sendable {
    case commandPalette
    case modelPicker
    case sessionList
    case themePicker
    case mcpStatus
}

public struct TUISlashCommand: Equatable, Hashable, Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }

    public static let builtIn: [TUISlashCommand] = [
        TUISlashCommand(name: "/models", description: "Switch active model"),
        TUISlashCommand(name: "/sessions", description: "Switch or browse sessions"),
        TUISlashCommand(name: "/themes", description: "Switch theme or light/dark mode"),
        TUISlashCommand(name: "/mcps", description: "View MCP server status"),
        TUISlashCommand(name: "/new", description: "Start a new session"),
        TUISlashCommand(name: "/home", description: "Return to the home screen"),
        TUISlashCommand(name: "/sidebar", description: "Toggle session sidebar"),
        TUISlashCommand(name: "/compact", description: "Compact session context"),
        TUISlashCommand(name: "/commands", description: "Open command palette"),
        TUISlashCommand(name: "/exit", description: "Exit OpenCode"),
    ]
}

public enum TUIPaletteActionID: String, Equatable, Hashable, Sendable {
    case switchSession
    case switchModel
    case cycleAgent
    case switchTheme
    case toggleMode
    case mcpServers
    case newSession
    case goHome
    case toggleSidebar
    case compactSession
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

    public var mcpServers: [TUIMCPServerItem]
    public var sessions: [TUISessionItem]
    public var activeSessionID: String?
    public var activeSessionTitle: String
    public var sessionStatus: TUISessionRunStatus
    public var contextTokens: Int
    public var contextLimit: Int?
    public var sessionCost: Double
    public var modifiedFiles: [TUIModifiedFileItem]
    public var messages: [TUITranscriptItem]

    public var promptText: String
    public var placeholderIndex: Int
    public var slashAutocompleteIndex: Int
    public var slashAutocompleteDismissed: Bool
    public var interruptArmed: Bool
    public var interruptArmedAtMs: Double
    public var spinnerTick: Int
    public var scrollDeltaPending: Int

    public var activeDialog: TUIActiveDialog?
    public var dialogFilter: String
    public var dialogSelectedIndex: Int

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
        self.mcpServers = mcpServers
        self.sessions = sessions
        self.activeSessionID = activeSessionID
        self.activeSessionTitle = activeSessionTitle
        self.sessionStatus = sessionStatus
        self.contextTokens = contextTokens
        self.contextLimit = contextLimit
        self.sessionCost = sessionCost
        self.modifiedFiles = modifiedFiles
        self.messages = messages
        self.promptText = promptText
        self.placeholderIndex = placeholderIndex
        self.slashAutocompleteIndex = 0
        self.slashAutocompleteDismissed = false
        self.interruptArmed = false
        self.interruptArmedAtMs = 0
        self.spinnerTick = 0
        self.scrollDeltaPending = 0
        self.activeDialog = nil
        self.dialogFilter = ""
        self.dialogSelectedIndex = 0
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
        sidebarExplicitOverride ?? (cols > 120)
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

    public var activeModelLabel: String {
        if let selected = selectedModel {
            return selected.name.isEmpty ? selected.id : selected.name
        }
        return "Select model"
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

    public var slashMatches: [TUISlashCommand] {
        guard activeDialog == nil, !slashAutocompleteDismissed else { return [] }
        guard promptText.hasPrefix("/"), !promptText.contains(" "), !promptText.contains("\n") else { return [] }
        let needle = promptText.lowercased()
        if needle == "/" { return TUISlashCommand.builtIn }
        return TUISlashCommand.builtIn.filter {
            $0.name.lowercased().hasPrefix(needle) || $0.description.lowercased().contains(needle.dropFirst())
        }
    }

    public var isSlashAutocompleteVisible: Bool {
        !slashMatches.isEmpty
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
                (.cycleAgent, "Cycle agent (\(activeAgent.displayName))", "shift+tab"),
                (.switchTheme, "Switch theme", "/themes"),
                (.toggleMode, "Toggle Light / Dark mode (\(effectiveMode.rawValue))", "ctrl+t"),
                (.mcpServers, "MCP servers", "/mcps"),
                (.newSession, "New session", "ctrl+n"),
                (.goHome, "Go to home", "/home"),
                (.toggleSidebar, effectiveShowSidebar ? "Hide sidebar" : "Show sidebar", "ctrl+b"),
                (.compactSession, "Compact session", "/compact"),
                (.exit, "Exit OpenCode", "ctrl+c"),
            ]
            return items.compactMap { action, title, shortcut in
                guard matches(title, shortcut) else { return nil }
                return TUIDialogRow(id: action.rawValue, title: title, trailing: shortcut)
            }

        case .modelPicker:
            return models.compactMap { item in
                let prov = item.providerName.isEmpty
                    ? (providers[item.providerID] ?? TUIUtil.titlecase(item.providerID))
                    : item.providerName
                guard matches(item.name, "\(item.id) \(prov)") else { return nil }
                let active = selectedModel?.id == item.id && selectedModel?.providerID == item.providerID
                return TUIDialogRow(
                    id: "\(item.providerID)/\(item.id)",
                    title: item.name.isEmpty ? item.id : item.name,
                    subtitle: prov,
                    trailing: active ? "active" : nil,
                    isActive: active
                )
            }

        case .sessionList:
            return sessions.compactMap { session in
                let sub = session.directory.map { TUIUtil.abbreviateHome($0, home: homeDirectory) } ?? session.id
                guard matches(session.title, sub) else { return nil }
                let active = session.id == activeSessionID
                return TUIDialogRow(
                    id: session.id,
                    title: session.title,
                    subtitle: sub,
                    trailing: active ? "active" : nil,
                    isActive: active
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
        public var refreshMCP: Bool = false
        public var refreshVCS: Bool = false
        public var refreshSessions: Bool = false
        public var refreshMessagesForSession: String? = nil

        public init(
            refreshAgents: Bool = false,
            refreshModels: Bool = false,
            refreshMCP: Bool = false,
            refreshVCS: Bool = false,
            refreshSessions: Bool = false,
            refreshMessagesForSession: String? = nil
        ) {
            self.refreshAgents = refreshAgents
            self.refreshModels = refreshModels
            self.refreshMCP = refreshMCP
            self.refreshVCS = refreshVCS
            self.refreshSessions = refreshSessions
            self.refreshMessagesForSession = refreshMessagesForSession
        }
    }

    public let client: OpenCodeClient
    public let store: TUIInteractiveStore
    public let directory: String
    private let markDirty: @Sendable () -> Void
    private let optimisticCounter = Mutex<Int>(0)

    public init(
        client: OpenCodeClient,
        store: TUIInteractiveStore,
        directory: String,
        markDirty: @escaping @Sendable () -> Void
    ) {
        self.client = client
        self.store = store
        self.directory = directory
        self.markDirty = markDirty
    }

    private var locationQuery: LocationQuery.LocationField {
        LocationQuery.LocationField(directory: directory)
    }

    private func nextOptimisticID() -> String {
        let next = optimisticCounter.withLock { count -> Int in
            count += 1
            return count
        }
        return "optimistic-\(next)"
    }

    // MARK: - Startup & Refresh

    public func bootstrap() {
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.refreshServerInfo() }
                group.addTask { await self.refreshAgents() }
                group.addTask { await self.refreshProvidersAndModels() }
                group.addTask { await self.refreshMCP() }
                group.addTask { await self.refreshVCS() }
                group.addTask { await self.refreshSessions() }
            }
            if let activeID = self.store.withLock({ $0.activeSessionID }) {
                await self.loadMessages(sessionID: activeID)
            }
        }
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
            while !Task.isCancelled {
                guard let self else { return }
                if self.store.withLock({ $0.shouldQuit }) { return }
                let stream = self.client.event.subscribe()
                do {
                    for try await event in stream {
                        if Task.isCancelled || self.store.withLock({ $0.shouldQuit }) { return }
                        backoffMs = 250
                        let effect = self.store.withLock { state in
                            Self.applyServerEvent(event, to: &state)
                        }
                        self.markDirty()
                        self.dispatch(effect: effect)
                    }
                } catch {
                    // Transient disconnect or server restart — reconnect with bounded backoff.
                }
                if Task.isCancelled || self.store.withLock({ $0.shouldQuit }) { return }
                try? await Task.sleep(for: .milliseconds(backoffMs))
                backoffMs = min(backoffMs * 2, 2_000)
            }
        }
    }

    private func dispatch(effect: EventSideEffect) {
        if effect.refreshAgents {
            Task { await self.refreshAgents() }
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
        if let sid = effect.refreshMessagesForSession {
            Task { await self.loadMessages(sessionID: sid) }
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

        case "session.message.created", "session.inbox.delivered", "session.message.content.updated":
            if isForActiveSession, let sid = state.activeSessionID {
                effect.refreshMessagesForSession = sid
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

        case "agent.updated":
            effect.refreshAgents = true

        case "model.updated", "provider.updated":
            effect.refreshModels = true

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
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if handleSlashCommand(trimmed) {
            return
        }

        let optimisticID = nextOptimisticID()
        let submission = store.withLock { state -> (sessionID: String?, agentID: String, modelRef: ModelSchema.Ref?) in
            state.promptText = ""
            state.slashAutocompleteDismissed = false
            state.slashAutocompleteIndex = 0
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
                state.selectedModel?.ref(variant: state.selectedVariant)
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
                    let loc = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: self.directory))
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
        let lower = trimmed.lowercased()
        switch lower {
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
                $0.activeDialog = nil
                $0.slashAutocompleteDismissed = false
            }
            markDirty()
            return true

        case "/new":
            startNewSession()
            return true

        case "/models", "/model":
            openDialog(.modelPicker)
            Task { await self.refreshProvidersAndModels() }
            return true

        case "/sessions", "/session":
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

        case "/commands", "/help":
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

        default:
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
            state.activeDialog = dialog
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            if state.promptText.hasPrefix("/") {
                state.promptText = ""
            }
            state.slashAutocompleteDismissed = false
        }
        markDirty()
    }

    public func closeDialog(commitTheme: Bool = false) {
        store.withLock { state in
            if !commitTheme, let restore = state.themePreviewRestore {
                state.themeName = restore.themeName
                state.themePreference = restore.preference
            }
            state.themePreviewRestore = nil
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
        }
        markDirty()
    }

    public func startNewSession() {
        store.withLock { state in
            state.activeSessionID = nil
            state.activeSessionTitle = "New Session"
            state.messages = []
            state.contextTokens = 0
            state.sessionCost = 0
            state.sessionStatus = .idle
            state.interruptArmed = false
            state.route = .home(TUIContext.HomeRoute())
            state.promptText = ""
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
            state.contextTokens = 0
            state.sessionCost = 0
            state.sessionStatus = .idle
            state.interruptArmed = false
            state.route = .session(TUIContext.SessionRoute(sessionID: id))
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
        }
        markDirty()
        Task { [weak self] in
            await self?.loadMessages(sessionID: id)
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

    public func selectModel(_ model: TUIModelItem) {
        let activeSID = store.withLock { state -> String? in
            state.selectedModel = model
            state.contextLimit = model.contextLimit
            if let variant = state.selectedVariant, !model.variants.contains(variant) {
                state.selectedVariant = nil
            }
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            return state.activeSessionID
        }
        markDirty()
        if let sid = activeSID {
            let ref = store.withLock { $0.selectedModel?.ref(variant: $0.selectedVariant) } ?? model.ref
            Task { [weak self] in
                _ = try? await self?.client.session.switchModel(
                    SessionSwitchModelInput(sessionID: sid, model: ref)
                )
            }
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
                openDialog(.modelPicker)
                Task { await self.refreshProvidersAndModels() }
            case .cycleAgent:
                cycleAgent(direction: 1)
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
            let model = store.withLock { state in
                state.models.first(where: { "\($0.providerID)/\($0.id)" == row.id })
            }
            if let model {
                selectModel(model)
            } else {
                closeDialog(commitTheme: true)
            }

        case .sessionList:
            openSession(id: row.id, title: row.title)

        case .themePicker:
            previewThemeRowIfNeeded()
            closeDialog(commitTheme: true)

        case .mcpStatus:
            toggleMCPServer(named: row.id)
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
