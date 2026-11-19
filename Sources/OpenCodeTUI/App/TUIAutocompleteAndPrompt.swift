#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeUtil
import OpenTUICore

// MARK: - Prompt History Navigator

/// Stateful up/down prompt history navigator matching upstream `usePromptHistory`.
public struct TUIPromptHistoryNavigator: Equatable, Sendable {
    public static let maxEntries = 200

    public var entries: [TUIPromptHistoryEntry]
    public var cursor: Int?
    public var stashedDraft: String

    public init(
        entries: [TUIPromptHistoryEntry] = [],
        cursor: Int? = nil,
        stashedDraft: String = ""
    ) {
        self.entries = entries.count > Self.maxEntries ? Array(entries.suffix(Self.maxEntries)) : entries
        self.cursor = cursor
        self.stashedDraft = stashedDraft
    }

    /// Returns the currently highlighted history entry while actively navigating, or `nil` when on the live draft.
    public var activeEntry: TUIPromptHistoryEntry? {
        guard let cursor, cursor >= 0, cursor < entries.count else { return nil }
        return entries[cursor]
    }

    /// Appends a submitted entry, deduplicating consecutive identical entries, capping at 200, and resetting navigation.
    public mutating func append(_ entry: TUIPromptHistoryEntry) {
        reset()
        guard !entry.input.isEmpty else { return }
        if entries.last == entry {
            return
        }
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
    }

    /// Moves backward toward older entries; saves `currentInput` into `stashedDraft` on the first upward step.
    public mutating func navigateUp(currentInput: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let current = cursor {
            let clamped = min(max(0, current), entries.count - 1)
            guard clamped > 0 else {
                cursor = 0
                return nil
            }
            let next = clamped - 1
            cursor = next
            return entries[next].input
        }
        stashedDraft = currentInput
        let newest = entries.count - 1
        cursor = newest
        return entries[newest].input
    }

    /// Moves forward toward newer entries; restores `stashedDraft` when stepping past the newest entry.
    public mutating func navigateDown() -> String? {
        guard let current = cursor else { return nil }
        let next = current + 1
        if next < entries.count {
            cursor = next
            return entries[next].input
        }
        cursor = nil
        let restored = stashedDraft
        stashedDraft = ""
        return restored
    }

    /// Clears the active history cursor and stashed draft.
    public mutating func reset() {
        cursor = nil
        stashedDraft = ""
    }
}

// MARK: - Shell Mode Helper (`!` Trigger)

/// Lightweight prompt shell-mode helpers matching upstream `!` trigger semantics.
public enum TUIShellMode {
    /// Returns `true` when entering `!` on an empty prompt should activate shell mode.
    public static func isShellTrigger(_ text: String) -> Bool {
        text == "!"
    }

    /// Extracts an executable shell command from prompt text when in shell mode or prefixed with `!`.
    public static func extractShellCommand(from text: String, isShellMode: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isShellMode {
            return trimmed.isEmpty ? nil : trimmed
        }
        guard trimmed.hasPrefix("!") else { return nil }
        let command = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

// MARK: - `@` File & Agent Mention Autocomplete

/// Active trailing `@query` mention trigger detected inside a prompt string.
public struct TUIMentionTrigger: Equatable, Hashable, Sendable {
    public let range: Range<String.Index>
    public let startOffset: Int
    public let query: String

    public init(range: Range<String.Index>, startOffset: Int, query: String) {
        self.range = range
        self.startOffset = startOffset
        self.query = query
    }

    public static func detect(in text: String) -> TUIMentionTrigger? {
        detectMentionTrigger(in: text)
    }

    public func apply(_ suggestion: TUIMentionSuggestion, to text: String) -> String {
        applyMention(suggestion, to: text, trigger: self)
    }
}

/// Ranked `@` mention suggestion representing either a workspace file path or an agent.
public struct TUIMentionSuggestion: Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable, Codable {
        case file
        case agent
    }

    public let kind: Kind
    public let value: String
    public let display: String
    public let subtitle: String?

    public init(
        kind: Kind,
        value: String,
        display: String? = nil,
        subtitle: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.display = display ?? (kind == .agent ? "@\(value)" : value)
        self.subtitle = subtitle
    }

    public static func build(
        query: String,
        files: [String],
        agents: [TUIAgentItem]
    ) -> [TUIMentionSuggestion] {
        buildMentionSuggestions(query: query, files: files, agents: agents)
    }
}

/// Detects an active trailing `@query` token preceded by start-of-string or whitespace with no whitespace after `@`.
public func detectMentionTrigger(in text: String) -> TUIMentionTrigger? {
    guard let atIndex = text.lastIndex(of: "@") else { return nil }
    if atIndex > text.startIndex {
        let before = text[text.index(before: atIndex)]
        guard before.isWhitespace else { return nil }
    }
    let token = text[atIndex...]
    guard !token.contains(where: \.isWhitespace) else { return nil }
    let queryStart = text.index(after: atIndex)
    let query = String(text[queryStart...])
    let startOffset = text.utf16.distance(from: text.utf16.startIndex, to: atIndex)
    return TUIMentionTrigger(
        range: atIndex..<text.endIndex,
        startOffset: startOffset,
        query: query
    )
}

/// Replaces the detected `@query` segment in `text` with `@<value> ` cleanly, preserving surrounding UTF-8/emoji text.
public func applyMention(
    _ suggestion: TUIMentionSuggestion,
    to text: String,
    trigger: TUIMentionTrigger
) -> String {
    let cleanValue = suggestion.value.hasPrefix("@")
        ? String(suggestion.value.dropFirst())
        : suggestion.value
    let range: Range<String.Index>
    if trigger.range.lowerBound >= text.startIndex && trigger.range.upperBound <= text.endIndex {
        range = trigger.range
    } else {
        let clampedOffset = min(max(0, trigger.startOffset), text.utf16.count)
        let utf16Start = text.utf16.index(text.utf16.startIndex, offsetBy: clampedOffset)
        let start = String.Index(utf16Start, within: text) ?? text.endIndex
        range = start..<text.endIndex
    }
    let hasTrailingSpace = range.upperBound < text.endIndex && text[range.upperBound] == " "
    let inserted = "@\(cleanValue)\(hasTrailingSpace ? "" : " ")"
    return String(text[..<range.lowerBound]) + inserted + String(text[range.upperBound...])
}

/// Ranks exact, prefix, and substring matches across agents and file paths, returning up to 12 suggestions.
public func buildMentionSuggestions(
    query: String,
    files: [String],
    agents: [TUIAgentItem]
) -> [TUIMentionSuggestion] {
    let maxSuggestions = 12
    let normalized = TUIPrompt.stripFileLineRange(query.trimmingCharacters(in: .whitespaces))
    let needle = (normalized.hasPrefix("@") ? String(normalized.dropFirst()) : normalized).lowercased()

    // Deduplicate inputs while preserving stable ordering.
    var seenAgents: Set<String> = []
    let uniqueAgents = agents.filter { !$0.id.isEmpty && seenAgents.insert($0.id).inserted }
    var seenFiles: Set<String> = []
    let uniqueFiles = files.filter { !$0.isEmpty && seenFiles.insert($0).inserted }

    if needle.isEmpty {
        var combined: [TUIMentionSuggestion] = []
        combined.reserveCapacity(min(maxSuggestions, uniqueAgents.count + uniqueFiles.count))
        for agent in uniqueAgents {
            combined.append(TUIMentionSuggestion(
                kind: .agent,
                value: agent.id,
                display: "@\(agent.id)",
                subtitle: agent.description ?? "agent"
            ))
            if combined.count == maxSuggestions { return combined }
        }
        for file in uniqueFiles {
            combined.append(TUIMentionSuggestion(
                kind: .file,
                value: file,
                display: file,
                subtitle: nil
            ))
            if combined.count == maxSuggestions { return combined }
        }
        return combined
    }

    struct ScoredSuggestion {
        let suggestion: TUIMentionSuggestion
        let score: Int
        let kindOrder: Int // 0 = agent, 1 = file
        let length: Int
        let sortKey: String
    }

    var scored: [ScoredSuggestion] = []
    scored.reserveCapacity(uniqueAgents.count + uniqueFiles.count)

    for agent in uniqueAgents {
        let idLower = agent.id.lowercased()
        let nameLower = agent.name.lowercased()
        let score: Int?
        if idLower == needle {
            score = 1000
        } else if nameLower == needle {
            score = 950
        } else if idLower.hasPrefix(needle) {
            score = 800
        } else if nameLower.hasPrefix(needle) {
            score = 750
        } else if idLower.contains(needle) || nameLower.contains(needle) {
            score = 450
        } else {
            score = nil
        }
        if let score {
            scored.append(ScoredSuggestion(
                suggestion: TUIMentionSuggestion(
                    kind: .agent,
                    value: agent.id,
                    display: "@\(agent.id)",
                    subtitle: agent.description ?? "agent"
                ),
                score: score,
                kindOrder: 0,
                length: agent.id.utf16.count,
                sortKey: idLower
            ))
        }
    }

    for file in uniqueFiles {
        let pathLower = file.lowercased()
        let baseLower = (file.split(separator: "/").last.map(String.init) ?? file).lowercased()
        let score: Int?
        if pathLower == needle {
            score = 1000
        } else if baseLower == needle {
            score = 950
        } else if pathLower.hasPrefix(needle) {
            score = 800
        } else if baseLower.hasPrefix(needle) {
            score = 750
        } else if pathLower.contains("/\(needle)") {
            score = 600
        } else if baseLower.contains(needle) {
            score = 450
        } else if pathLower.contains(needle) {
            score = 350
        } else {
            score = nil
        }
        if let score {
            scored.append(ScoredSuggestion(
                suggestion: TUIMentionSuggestion(
                    kind: .file,
                    value: file,
                    display: file,
                    subtitle: nil
                ),
                score: score,
                kindOrder: 1,
                length: file.utf16.count,
                sortKey: pathLower
            ))
        }
    }

    scored.sort { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.kindOrder != rhs.kindOrder { return lhs.kindOrder < rhs.kindOrder }
        if lhs.length != rhs.length { return lhs.length < rhs.length }
        return lhs.sortKey < rhs.sortKey
    }

    return scored.prefix(maxSuggestions).map(\.suggestion)
}

// MARK: - Settings Catalog (`dialog-config.tsx`)

/// Identifiers for every setting exposed in the TUI Settings dialog (`dialog-config.tsx`).
public enum TUISettingID: String, CaseIterable, Equatable, Hashable, Sendable {
    case theme
    case colorMode
    case animations
    case sidebar
    case scrollbar
    case scrollOnSend
    case thinking
    case markdown
    case diffView
    case diffWrap
    case pasteSummary
}

/// Metadata describing a single Settings dialog row.
public struct TUISettingDefinition: Equatable, Hashable, Sendable {
    public let id: TUISettingID
    public let title: String
    public let category: String
    public let description: String
    public let keywords: [String]

    public init(
        id: TUISettingID,
        title: String,
        category: String,
        description: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.description = description
        self.keywords = keywords
    }
}

/// Complete upstream `DialogConfig` settings catalog, value formatting, cycling, and `TUIDialogRow` projection.
public enum TUISettingsCatalog {
    public static let definitions: [TUISettingDefinition] = [
        TUISettingDefinition(
            id: .theme,
            title: "Theme",
            category: "Appearance",
            description: "Color theme used across the interface",
            keywords: ["color scheme", "colors", "palette"]
        ),
        TUISettingDefinition(
            id: .colorMode,
            title: "Color mode",
            category: "Appearance",
            description: "Dark or light variant, or follow the system",
            keywords: ["dark mode", "light mode", "system theme", "auto"]
        ),
        TUISettingDefinition(
            id: .animations,
            title: "Animations",
            category: "Appearance",
            description: "Whether spinners and transitions animate",
            keywords: ["motion", "effects", "spinner"]
        ),
        TUISettingDefinition(
            id: .sidebar,
            title: "Sidebar",
            category: "Session",
            description: "Whether the sidebar shows when there is room",
            keywords: ["side panel", "auto", "hide"]
        ),
        TUISettingDefinition(
            id: .scrollbar,
            title: "Scrollbar",
            category: "Session",
            description: "Whether a scrollbar is shown next to the chat",
            keywords: ["scroll bar"]
        ),
        TUISettingDefinition(
            id: .scrollOnSend,
            title: "Scroll on send",
            category: "Session",
            description: "Whether sending a prompt jumps to the latest message",
            keywords: ["submit", "scroll position", "jump to latest", "keep position", "follow"]
        ),
        TUISettingDefinition(
            id: .thinking,
            title: "Thinking",
            category: "Session",
            description: "Whether model thinking is shown in the chat",
            keywords: ["reasoning", "chain of thought"]
        ),
        TUISettingDefinition(
            id: .markdown,
            title: "Markdown",
            category: "Session",
            description: "Whether chat markdown is rendered or shown as source",
            keywords: ["syntax", "concealment", "rendering", "source"]
        ),
        TUISettingDefinition(
            id: .diffView,
            title: "Diff layout",
            category: "Diffs",
            description: "Whether diffs are side by side or in one column",
            keywords: ["diff layout", "split diff", "unified diff", "view"]
        ),
        TUISettingDefinition(
            id: .diffWrap,
            title: "Diff wrapping",
            category: "Diffs",
            description: "Whether long lines in diffs wrap",
            keywords: ["diff wrap", "word wrap", "line wrap", "none"]
        ),
        TUISettingDefinition(
            id: .pasteSummary,
            title: "Large pastes",
            category: "Input",
            description: "Whether large pastes are summarized or shown in full",
            keywords: ["paste summary", "clipboard", "pasted content", "compact", "full"]
        ),
    ]

    public static let colorModeChoices: [TUIThemePreference] = [.auto, .dark, .light]
    public static let sidebarChoices: [String] = ["auto", "hide"]
    public static let scrollOnSendChoices: [String] = ["bottom", "keep"]
    public static let diffViewChoices: [String] = ["auto", "split", "unified"]
    public static let diffWrapChoices: [String] = ["word", "none"]

    public static var availableThemes: [String] {
        var result: [String] = ["opencode", "opencode2"]
        var seen: Set<String> = Set(result)
        for name in TUIThemeBridge.DEFAULT_THEMES.keys.sorted() {
            if seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }

    public static func definition(for id: TUISettingID) -> TUISettingDefinition {
        definitions.first(where: { $0.id == id }) ?? definitions[0]
    }

    /// Formats the current human-readable display value for `id`.
    public static func valueLabel(
        for id: TUISettingID,
        preferences: TUIPersistedPreferences,
        detectedMode: ThemeMode = .dark
    ) -> String {
        switch id {
        case .theme:
            return preferences.themeName.isEmpty ? "opencode" : preferences.themeName
        case .colorMode:
            switch preferences.themePreference {
            case .auto: return "auto (\(detectedMode.rawValue))"
            case .dark: return "dark"
            case .light: return "light"
            }
        case .animations:
            return preferences.animations ? "on" : "off"
        case .sidebar:
            return preferences.sidebarMode == "hide" ? "hide" : "auto"
        case .scrollbar:
            return preferences.showScrollbar ? "on" : "off"
        case .scrollOnSend:
            return preferences.scrollOnSend == "keep" ? "keep position" : "jump to latest"
        case .thinking:
            return preferences.showThinking ? "show" : "hide"
        case .markdown:
            return preferences.concealMarkdown ? "rendered" : "source"
        case .diffView:
            if diffViewChoices.contains(preferences.diffView) {
                return preferences.diffView
            }
            return "auto"
        case .diffWrap:
            return preferences.diffWrap == "none" ? "none" : "word"
        case .pasteSummary:
            return preferences.pasteSummary ? "compact" : "full"
        }
    }

    /// Cycles the setting identified by `id` forward (`direction > 0`) or backward (`direction < 0`).
    public static func cycle(
        _ id: TUISettingID,
        direction: Int = 1,
        preferences: inout TUIPersistedPreferences
    ) {
        guard direction != 0 else { return }
        switch id {
        case .theme:
            preferences.themeName = cycleChoice(preferences.themeName, in: availableThemes, direction: direction)
        case .colorMode:
            preferences.themePreference = cycleChoice(preferences.themePreference, in: colorModeChoices, direction: direction)
        case .animations:
            preferences.animations = cycleBool(preferences.animations, direction: direction)
        case .sidebar:
            preferences.sidebarMode = cycleChoice(preferences.sidebarMode, in: sidebarChoices, direction: direction)
        case .scrollbar:
            preferences.showScrollbar = cycleBool(preferences.showScrollbar, direction: direction)
        case .scrollOnSend:
            preferences.scrollOnSend = cycleChoice(preferences.scrollOnSend, in: scrollOnSendChoices, direction: direction)
        case .thinking:
            preferences.showThinking = cycleBool(preferences.showThinking, direction: direction)
        case .markdown:
            preferences.concealMarkdown = cycleBool(preferences.concealMarkdown, direction: direction)
        case .diffView:
            preferences.diffView = cycleChoice(preferences.diffView, in: diffViewChoices, direction: direction)
        case .diffWrap:
            preferences.diffWrap = cycleChoice(preferences.diffWrap, in: diffWrapChoices, direction: direction)
        case .pasteSummary:
            preferences.pasteSummary = cycleBool(preferences.pasteSummary, direction: direction)
        }
    }

    /// Builds filtered `TUIDialogRow` entries ready for `TUIScreens.buildDialogOverlay`.
    public static func rows(
        filter: String = "",
        preferences: TUIPersistedPreferences,
        detectedMode: ThemeMode = .dark
    ) -> [TUIDialogRow] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return definitions.compactMap { def in
            let currentValue = valueLabel(for: def.id, preferences: preferences, detectedMode: detectedMode)
            if !needle.isEmpty {
                let haystack = ([def.id.rawValue, def.title, def.category, def.description, currentValue] + def.keywords)
                    .joined(separator: " ")
                    .lowercased()
                guard haystack.contains(needle) else { return nil }
            }
            return TUIDialogRow(
                id: def.id.rawValue,
                title: def.title,
                subtitle: def.category,
                trailing: currentValue,
                isActive: false
            )
        }
    }

    private static func cycleChoice<T: Equatable>(_ current: T, in choices: [T], direction: Int) -> T {
        guard !choices.isEmpty else { return current }
        let count = choices.count
        guard let idx = choices.firstIndex(of: current) else {
            return direction >= 0 ? choices[0] : choices[count - 1]
        }
        let next = ((idx + direction) % count + count) % count
        return choices[next]
    }

    private static func cycleBool(_ current: Bool, direction: Int) -> Bool {
        abs(direction) % 2 == 1 ? !current : current
    }
}

// MARK: - External `$EDITOR` Integration

/// Resolves `$VISUAL` / `$EDITOR` commands and edits prompt drafts in an external terminal editor.
public enum TUIExternalEditor {
    public enum ExternalEditorError: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedPlatform
        case emptyCommand
        case nonZeroExit(Int32)

        public var description: String {
            switch self {
            case .unsupportedPlatform:
                return "External editor is not supported on this platform"
            case .emptyCommand:
                return "Resolved external editor command is empty"
            case .nonZeroExit(let code):
                return "External editor exited with code \(code)"
            }
        }
    }

    /// Resolves the external editor command argv: checks `VISUAL`, then `EDITOR`, falling back to `["vi"]`.
    /// Splits quoted and unquoted arguments cleanly (supporting single quotes, double quotes, and backslash escapes).
    public static func resolveEditorCommand(environment: [String: String]) -> [String] {
        if let visual = environment["VISUAL"] {
            let parts = splitCommandLine(visual)
            if !parts.isEmpty { return parts }
        }
        if let editor = environment["EDITOR"] {
            let parts = splitCommandLine(editor)
            if !parts.isEmpty { return parts }
        }
        return ["vi"]
    }

    /// Writes `initialText` to a temporary `.md` file, launches the resolved external editor with inherited stdio,
    /// reads back the updated content (or `nil` if empty), and removes the temporary file.
    public static func editInExternalEditor(
        initialText: String,
        environment: [String: String],
        tempDir: String = Global.make().tmp
    ) throws -> String? {
        #if os(macOS) || os(Linux) || os(Windows)
        let parts = resolveEditorCommand(environment: environment)
        guard let executable = parts.first, !executable.isEmpty else {
            throw ExternalEditorError.emptyCommand
        }

        let targetDir = tempDir.isEmpty ? NSTemporaryDirectory() : tempDir
        try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        let fileURL = URL(fileURLWithPath: targetDir, isDirectory: true)
            .appendingPathComponent("opencode-prompt-\(UUID().uuidString).md")
        try Data(initialText.utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let process = Process()
        let extraArgs = Array(parts.dropFirst()) + [fileURL.path]
        if executable.contains("/") || executable.contains("\\") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = extraArgs
        } else {
            #if os(Windows)
            process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
            process.arguments = ["/c", executable] + extraArgs
            #else
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + extraArgs
            #endif
        }

        var mergedEnv = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnv[key] = value
        }
        process.environment = mergedEnv
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExternalEditorError.nonZeroExit(process.terminationStatus)
        }

        let updatedData = try Data(contentsOf: fileURL)
        let updated = String(decoding: updatedData, as: UTF8.self)
        return updated.isEmpty ? nil : updated
        #else
        _ = (initialText, environment, tempDir)
        throw ExternalEditorError.unsupportedPlatform
        #endif
    }

    internal static func splitCommandLine(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inToken = false
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false

        for ch in raw {
            if escaping {
                current.append(ch)
                escaping = false
                inToken = true
                continue
            }
            if inSingleQuote {
                if ch == "'" {
                    inSingleQuote = false
                } else {
                    current.append(ch)
                }
                inToken = true
                continue
            }
            if inDoubleQuote {
                if ch == "\\" {
                    escaping = true
                } else if ch == "\"" {
                    inDoubleQuote = false
                } else {
                    current.append(ch)
                }
                inToken = true
                continue
            }
            if ch == "\\" {
                escaping = true
                inToken = true
            } else if ch == "'" {
                inSingleQuote = true
                inToken = true
            } else if ch == "\"" {
                inDoubleQuote = true
                inToken = true
            } else if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                if inToken {
                    args.append(current)
                    current = ""
                    inToken = false
                }
            } else {
                current.append(ch)
                inToken = true
            }
        }

        if escaping {
            current.append("\\")
        }
        if inToken {
            args.append(current)
        }
        return args
    }
}

// MARK: - Markdown Transcript Formatter (`/copy` & `/export`)

/// Formats a TUI conversation transcript into clean Markdown for `/copy` and `/export`.
public enum TUITranscriptFormatter {
    public static func formatMarkdownTranscript(
        title: String,
        messages: [TUITranscriptItem],
        includeThinking: Bool = true,
        includeTools: Bool = true
    ) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerTitle = trimmedTitle.isEmpty ? "OpenCode Session" : trimmedTitle

        var sections: [String] = []
        sections.reserveCapacity(messages.count)

        for message in messages {
            switch message {
            case .user(_, let text, _, _):
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                sections.append("## User\n\n\(text)")

            case .assistant(_, let agentName, let modelLabel, let parts, _, let error):
                var blocks: [String] = []
                for part in parts {
                    switch part {
                    case .reasoning(_, let text, _):
                        guard includeThinking else { continue }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        blocks.append("_Thinking:_\n\n\(trimmed)")

                    case .text(_, let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        blocks.append(trimmed)

                    case .tool(_, let name, let status, let summary, let outputPreview, let toolError):
                        guard includeTools else { continue }
                        var toolLines: [String] = []
                        let summarySuffix = summary.isEmpty ? "" : " `\(summary)`"
                        toolLines.append("**Tool: \(name)**\(summarySuffix) (\(status.rawValue))")
                        if let toolError, !toolError.isEmpty {
                            toolLines.append("**Error:** \(toolError)")
                        } else if let outputPreview, !outputPreview.isEmpty {
                            toolLines.append("```\n\(outputPreview)\n```")
                        }
                        blocks.append(toolLines.joined(separator: "\n\n"))
                    }
                }
                if let error, !error.isEmpty {
                    blocks.append("**Error:** \(error)")
                }
                guard !blocks.isEmpty else { continue }

                let metaParts = [agentName, modelLabel].compactMap { val -> String? in
                    guard let val, !val.isEmpty else { return nil }
                    return val
                }
                let heading = metaParts.isEmpty
                    ? "## Assistant"
                    : "## Assistant (\(metaParts.joined(separator: " · ")))"
                sections.append("\(heading)\n\n\(blocks.joined(separator: "\n\n"))")

            case .system(_, let text, let isError):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let heading = isError ? "## System Error" : "## System"
                sections.append("\(heading)\n\n\(trimmed)")
            }
        }

        if sections.isEmpty {
            return "# \(headerTitle)\n"
        }
        return "# \(headerTitle)\n\n---\n\n\(sections.joined(separator: "\n\n---\n\n"))\n"
    }
}
