import Foundation
import OpenCodeUtil

// MARK: - Command Palette Definitions

/// Canonical command identifiers executable from the Command Palette (`Cmd+K` / `Cmd+P`) or menus.
public enum AppCommandID: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case newSession
    case renameSession
    case forkSession
    case deleteSession
    case abortSession
    case compactSession
    case connectProvider
    case pairDevice
    case openSettings
    case openDiffReview
    case toggleThemeMode
    case toggleInspector
    case toggleShellMode
    case showContextInspector
    case showTodosInspector
    case showMCPInspector
    case showDiffsInspector
    case refreshWorkspace
    case connectRemoteServer

    public var id: String { rawValue }
}

/// Command Palette entry with searchable title, category, slash alias, and shortcut hint.
public struct AppCommandItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: AppCommandID
    public let title: String
    public let subtitle: String
    public let category: String
    public let systemImage: String
    public let shortcutHint: String?
    public let slashAlias: String?
    public let keywords: [String]

    public init(
        id: AppCommandID,
        title: String,
        subtitle: String,
        category: String,
        systemImage: String,
        shortcutHint: String? = nil,
        slashAlias: String? = nil,
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.systemImage = systemImage
        self.shortcutHint = shortcutHint
        self.slashAlias = slashAlias
        self.keywords = keywords
    }
}

/// Slash command entry shown in the composer `/` autocomplete popover.
public struct AppSlashCommandItem: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { name.lowercased() }
    public let name: String
    public let description: String
    public let isServerCommand: Bool

    public init(name: String, description: String, isServerCommand: Bool = false) {
        self.name = name.hasPrefix("/") ? name : "/\(name)"
        self.description = description
        self.isServerCommand = isServerCommand
    }
}

/// Mention suggestion entry shown in the composer `@` mention picker popover.
public struct AppMentionItem: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case file
        case agent
    }

    public var id: String { "\(kind.rawValue):\(value)" }
    public let kind: Kind
    public let value: String
    public let displayTitle: String
    public let subtitle: String?

    public init(kind: Kind, value: String, displayTitle: String? = nil, subtitle: String? = nil) {
        self.kind = kind
        self.value = value
        self.displayTitle = displayTitle ?? (kind == .agent ? "@\(value)" : value)
        self.subtitle = subtitle
    }
}

/// Active `@query` trigger detected at the tail of composer input.
public struct AppMentionTrigger: Equatable, Hashable, Sendable {
    public let range: Range<String.Index>
    public let query: String

    public init(range: Range<String.Index>, query: String) {
        self.range = range
        self.query = query
    }
}

/// Parsed user submission intent from the composer (`!`, `/`, or standard prompt with `@` mentions).
public enum AppParsedComposerInput: Equatable, Hashable, Sendable {
    case empty
    case shell(command: String)
    case slash(name: String, arguments: String)
    case prompt(text: String, fileMentions: [String], agentMentions: [String], sessionMentions: [String])
}

// MARK: - Command Registry & Composer Parsers

public enum AppCommandRegistry {
    public static let builtInCommands: [AppCommandItem] = [
        AppCommandItem(
            id: .newSession,
            title: "New Session",
            subtitle: "Create a fresh conversation in the current workspace",
            category: "Session",
            systemImage: "plus.bubble",
            shortcutHint: "⌘N",
            slashAlias: "/new",
            keywords: ["create", "start", "chat", "thread"]
        ),
        AppCommandItem(
            id: .renameSession,
            title: "Rename Session",
            subtitle: "Change the active session title",
            category: "Session",
            systemImage: "pencil",
            slashAlias: "/rename",
            keywords: ["title", "edit"]
        ),
        AppCommandItem(
            id: .forkSession,
            title: "Fork Session",
            subtitle: "Branch the current conversation into a new session",
            category: "Session",
            systemImage: "arrow.triangle.branch",
            slashAlias: "/fork",
            keywords: ["branch", "duplicate", "clone"]
        ),
        AppCommandItem(
            id: .compactSession,
            title: "Compact Session Context",
            subtitle: "Summarize history to free context window capacity",
            category: "Session",
            systemImage: "arrow.down.right.and.arrow.up.left",
            slashAlias: "/compact",
            keywords: ["summarize", "trim", "tokens"]
        ),
        AppCommandItem(
            id: .abortSession,
            title: "Abort Active Run",
            subtitle: "Interrupt the currently executing model step",
            category: "Session",
            systemImage: "stop.circle",
            shortcutHint: "⌘.",
            slashAlias: "/abort",
            keywords: ["stop", "cancel", "interrupt"]
        ),
        AppCommandItem(
            id: .deleteSession,
            title: "Delete Active Session",
            subtitle: "Permanently remove the selected session",
            category: "Session",
            systemImage: "trash",
            keywords: ["remove", "trash"]
        ),
        AppCommandItem(
            id: .connectProvider,
            title: "Connect Provider",
            subtitle: "Configure an AI provider API key",
            category: "Providers",
            systemImage: "key.fill",
            slashAlias: "/connect",
            keywords: ["api", "key", "anthropic", "openai", "google", "auth", "models"]
        ),
        AppCommandItem(
            id: .openDiffReview,
            title: "Review Diffs",
            subtitle: "Inspect unified and side-by-side workspace file diffs",
            category: "Workspace",
            systemImage: "doc.text.magnifyingglass",
            shortcutHint: "⇧⌘D",
            slashAlias: "/diff",
            keywords: ["git", "changes", "patch", "split", "unified"]
        ),
        AppCommandItem(
            id: .pairDevice,
            title: "Pair Device (QR Code)",
            subtitle: "Generate a live pairing QR code and connect link",
            category: "Connection",
            systemImage: "qrcode",
            shortcutHint: "⇧⌘Q",
            slashAlias: "/pair",
            keywords: ["qr", "mobile", "phone", "link", "remote"]
        ),
        AppCommandItem(
            id: .connectRemoteServer,
            title: "Connect to Remote Server",
            subtitle: "Switch between embedded SDK and a remote/paired server URL",
            category: "Connection",
            systemImage: "network",
            keywords: ["url", "remote", "server", "host", "embedded", "credentials"]
        ),
        AppCommandItem(
            id: .toggleShellMode,
            title: "Toggle Shell Mode (!)",
            subtitle: "Run direct shell commands inside the active session",
            category: "Composer",
            systemImage: "terminal",
            keywords: ["bash", "zsh", "terminal", "command", "!"]
        ),
        AppCommandItem(
            id: .toggleThemeMode,
            title: "Cycle Theme Mode (System / Light / Dark)",
            subtitle: "Switch light, dark, or system appearance",
            category: "Appearance",
            systemImage: "circle.lefthalf.filled",
            slashAlias: "/theme",
            keywords: ["dark", "light", "appearance", "colors"]
        ),
        AppCommandItem(
            id: .openSettings,
            title: "Open Settings",
            subtitle: "Configure themes, markdown concealing, and inspect MCP servers",
            category: "Appearance",
            systemImage: "gearshape",
            shortcutHint: "⌘,",
            slashAlias: "/settings",
            keywords: ["preferences", "config", "conceal", "mcp"]
        ),
        AppCommandItem(
            id: .toggleInspector,
            title: "Toggle Inspector Sidebar",
            subtitle: "Show or hide Context, Todos, MCP, and Diffs panel",
            category: "Workspace",
            systemImage: "sidebar.right",
            shortcutHint: "⌥⌘I",
            slashAlias: "/inspector",
            keywords: ["panel", "right", "sidebar"]
        ),
        AppCommandItem(
            id: .showContextInspector,
            title: "Inspect Context & Usage",
            subtitle: "Open token usage, cost, and workspace budget limits",
            category: "Inspector",
            systemImage: "gauge.with.dots.needle.33percent",
            slashAlias: "/usage",
            keywords: ["tokens", "cost", "budget", "limits"]
        ),
        AppCommandItem(
            id: .showTodosInspector,
            title: "Inspect Session Todos",
            subtitle: "Open active task checklist in the inspector",
            category: "Inspector",
            systemImage: "checklist",
            keywords: ["tasks", "checklist"]
        ),
        AppCommandItem(
            id: .showMCPInspector,
            title: "Inspect MCP Servers",
            subtitle: "View Model Context Protocol server connections and statuses",
            category: "Inspector",
            systemImage: "puzzlepiece.extension",
            slashAlias: "/mcp",
            keywords: ["servers", "tools", "protocol"]
        ),
        AppCommandItem(
            id: .showDiffsInspector,
            title: "Inspect Modified Files",
            subtitle: "Show changed files in the inspector",
            category: "Inspector",
            systemImage: "doc.badge.gearshape",
            keywords: ["vcs", "git", "modified"]
        ),
        AppCommandItem(
            id: .refreshWorkspace,
            title: "Refresh Workspace State",
            subtitle: "Reload sessions, models, agents, VCS status, MCP, and usage limits",
            category: "Workspace",
            systemImage: "arrow.clockwise",
            slashAlias: "/reload",
            keywords: ["sync", "reload", "fetch"]
        ),
    ]

    public static let builtInSlashCommands: [AppSlashCommandItem] = [
        AppSlashCommandItem(name: "/new", description: "Start a new session"),
        AppSlashCommandItem(name: "/fork", description: "Fork the current session"),
        AppSlashCommandItem(name: "/rename", description: "Rename current session (/rename <title>)"),
        AppSlashCommandItem(name: "/compact", description: "Compact session context"),
        AppSlashCommandItem(name: "/abort", description: "Abort active run"),
        AppSlashCommandItem(name: "/connect", description: "Connect an AI provider API key"),
        AppSlashCommandItem(name: "/pair", description: "Generate device pairing QR code"),
        AppSlashCommandItem(name: "/diff", description: "Open diff review viewer"),
        AppSlashCommandItem(name: "/theme", description: "Toggle light / dark / system theme"),
        AppSlashCommandItem(name: "/settings", description: "Open app settings"),
        AppSlashCommandItem(name: "/mcp", description: "Inspect MCP server statuses"),
        AppSlashCommandItem(name: "/usage", description: "Inspect context & workspace usage limits"),
        AppSlashCommandItem(name: "/inspector", description: "Toggle right workspace inspector"),
        AppSlashCommandItem(name: "/reload", description: "Refresh workspace state"),
    ]

    /// Ranked filter for Command Palette queries.
    public static func filterCommands(
        _ commands: [AppCommandItem] = builtInCommands,
        query: String
    ) -> [AppCommandItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return commands }

        let scored: [(rank: Int, index: Int, item: AppCommandItem)] = commands.enumerated().compactMap { idx, item in
            let titleLower = item.title.lowercased()
            let slashLower = item.slashAlias?.lowercased() ?? ""
            let catLower = item.category.lowercased()
            let subLower = item.subtitle.lowercased()
            let kwLower = item.keywords.map { $0.lowercased() }

            if titleLower == needle || slashLower == needle || slashLower == "/\(needle)" {
                return (0, idx, item)
            }
            if titleLower.hasPrefix(needle) || slashLower.hasPrefix(needle) {
                return (1, idx, item)
            }
            if titleLower.split(separator: " ").contains(where: { $0.hasPrefix(needle) })
                || kwLower.contains(where: { $0.hasPrefix(needle) }) {
                return (2, idx, item)
            }
            if titleLower.contains(needle) || catLower.contains(needle) || subLower.contains(needle)
                || kwLower.contains(where: { $0.contains(needle) }) {
                return (3, idx, item)
            }
            return nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.index < rhs.index
            }
            .map(\.item)
    }

    /// Combines built-in slash commands with live server commands without duplicates.
    public static func mergedSlashCommands(serverCommands: [AppSlashCommandItem]) -> [AppSlashCommandItem] {
        var seen = Set(builtInSlashCommands.map { $0.name.lowercased() })
        var out = builtInSlashCommands
        for cmd in serverCommands {
            let key = cmd.name.lowercased()
            if seen.insert(key).inserted {
                out.append(cmd)
            }
        }
        return out
    }

    /// Filters slash autocomplete candidates when the composer starts with `/`.
    public static func filterSlashCommands(
        _ commands: [AppSlashCommandItem],
        input: String
    ) -> [AppSlashCommandItem] {
        guard input.hasPrefix("/"), !input.contains(" "), !input.contains("\n") else {
            return []
        }
        let needle = input.lowercased()
        if needle == "/" { return commands }
        let bare = String(needle.dropFirst())
        return commands
            .filter { $0.name.lowercased().hasPrefix(needle) || $0.description.lowercased().contains(bare) }
            .sorted { lhs, rhs in
                let lName = lhs.name.lowercased()
                let rName = rhs.name.lowercased()
                let lRank = (lName == needle) ? 0 : (lName.hasPrefix(needle) ? 1 : 2)
                let rRank = (rName == needle) ? 0 : (rName.hasPrefix(needle) ? 1 : 2)
                if lRank != rRank { return lRank < rRank }
                return lName < rName
            }
    }

    /// Detects an active trailing `@query` token preceded by start-of-string or whitespace.
    public static func detectMentionTrigger(in text: String) -> AppMentionTrigger? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        if atIndex > text.startIndex {
            let before = text[text.index(before: atIndex)]
            guard before.isWhitespace else { return nil }
        }
        let token = text[atIndex...]
        guard !token.contains(where: \.isWhitespace) else { return nil }
        let query = String(text[text.index(after: atIndex)...])
        return AppMentionTrigger(range: atIndex..<text.endIndex, query: query)
    }

    /// Builds ranked `@` mention suggestions combining agents and workspace file paths.
    public static func buildMentionSuggestions(
        query: String,
        files: [String],
        agents: [AppAgentItem]
    ) -> [AppMentionItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [AppMentionItem] = []

        for agent in agents {
            let matches = needle.isEmpty
                || agent.id.lowercased().contains(needle)
                || agent.name.lowercased().contains(needle)
            if matches {
                out.append(AppMentionItem(
                    kind: .agent,
                    value: agent.id,
                    displayTitle: "@\(agent.id)",
                    subtitle: agent.description ?? agent.name
                ))
            }
        }

        for path in files {
            if needle.isEmpty || path.lowercased().contains(needle) {
                let lastComponent = path.split(separator: "/").last.map(String.init) ?? path
                out.append(AppMentionItem(
                    kind: .file,
                    value: path,
                    displayTitle: lastComponent,
                    subtitle: path
                ))
            }
        }

        return Array(out.prefix(24))
    }

    /// Replaces the active `@query` trigger inside `text` with the chosen mention token.
    public static func applyMention(
        _ suggestion: AppMentionItem,
        to text: String,
        trigger: AppMentionTrigger
    ) -> String {
        var copy = text
        copy.replaceSubrange(trigger.range, with: "@\(suggestion.value) ")
        return copy
    }

    /// Parses composer text into shell execution, slash command, or structured prompt with extracted mentions.
    public static func parseComposerInput(
        _ raw: String,
        shellMode: Bool,
        knownAgentIDs: Set<String> = []
    ) -> AppParsedComposerInput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        if shellMode {
            return .shell(command: trimmed)
        }
        if trimmed.hasPrefix("!") {
            let cmd = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd.isEmpty ? .empty : .shell(command: cmd)
        }
        if trimmed.hasPrefix("/") {
            let withoutSlash = String(trimmed.dropFirst())
            if let space = withoutSlash.firstIndex(where: \.isWhitespace) {
                let name = String(withoutSlash[..<space])
                let args = String(withoutSlash[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? .empty : .slash(name: name, arguments: args)
            }
            return withoutSlash.isEmpty ? .empty : .slash(name: withoutSlash, arguments: "")
        }

        // Extract @agent, @file, and @session mentions
        let sessionMatches = OpenCodeUtil.sessionMentions(trimmed).map(\.id)
        var agents: [String] = []
        var files: [String] = []
        var seenAgents = Set<String>()
        var seenFiles = Set<String>()

        for token in trimmed.split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix("@"), token.count > 1 else { continue }
            let rawMention = String(token.dropFirst())
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}"))
            guard !rawMention.isEmpty, !rawMention.hasPrefix("session:") else { continue }
            if knownAgentIDs.contains(rawMention) {
                if seenAgents.insert(rawMention).inserted {
                    agents.append(rawMention)
                }
            } else if rawMention.contains("/") || rawMention.contains(".") {
                if seenFiles.insert(rawMention).inserted {
                    files.append(rawMention)
                }
            }
        }

        return .prompt(
            text: trimmed,
            fileMentions: files,
            agentMentions: agents,
            sessionMentions: sessionMatches
        )
    }
}
