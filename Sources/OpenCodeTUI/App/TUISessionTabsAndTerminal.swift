import OpenCodeUtil
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView

// MARK: - Large Paste Summaries (`TUIPasteSummary` / `component/prompt/index.tsx`)

/// A stored large pasted text block referenced inline in the prompt by `[Pasted ~N lines]`.
public struct TUIPastedBlock: Equatable, Hashable, Sendable {
    public let id: Int
    public let text: String
    public let lineCount: Int
    public let label: String

    public init(
        id: Int,
        text: String,
        lineCount: Int,
        label: String? = nil
    ) {
        self.id = id
        self.text = text
        self.lineCount = lineCount
        self.label = label ?? "[Pasted ~\(lineCount) lines]"
    }
}

/// Manages large bracketed paste detection, inline `[Pasted ~N lines]` summarization,
/// and exact full-text expansion on prompt submit.
public enum TUIPasteManager {
    public static let summaryLineThreshold: Int = 4
    public static let summaryCharThreshold: Int = 300

    /// Strips ANSI escape sequences and normalizes CRLF/CR line endings to LF (`\n`).
    public static func normalize(_ raw: String) -> String {
        stripAnsiSequences(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Counts logical lines in `text` (`0` for empty, otherwise `newlineCount + 1`).
    public static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        for ch in text where ch == "\n" {
            count += 1
        }
        return count
    }

    /// Returns `true` when `pasteSummaryEnabled` is active and the normalized text meets the
    /// large-paste threshold (`>= 4` lines or `>= 300` characters).
    public static func shouldSummarize(_ normalizedText: String, pasteSummaryEnabled: Bool) -> Bool {
        guard pasteSummaryEnabled, !normalizedText.isEmpty else { return false }
        return lineCount(of: normalizedText) >= summaryLineThreshold
            || normalizedText.count >= summaryCharThreshold
    }

    /// Processes a pasted text payload: stores a `TUIPastedBlock` and returns `[Pasted ~N lines]`
    /// when `pasteSummaryEnabled` is enabled and the payload is large; otherwise returns the
    /// normalized text verbatim.
    public static func preparePaste(
        _ rawText: String,
        pasteSummaryEnabled: Bool,
        blocks: inout [TUIPastedBlock]
    ) -> String {
        let normalized = normalize(rawText)
        guard !normalized.isEmpty else { return "" }
        guard shouldSummarize(normalized, pasteSummaryEnabled: pasteSummaryEnabled) else {
            return normalized
        }
        let nextID = (blocks.map(\.id).max() ?? 0) + 1
        let lines = lineCount(of: normalized)
        let block = TUIPastedBlock(
            id: nextID,
            text: normalized,
            lineCount: lines,
            label: "[Pasted ~\(lines) lines]"
        )
        blocks.append(block)
        return block.label
    }

    /// Expands all `[Pasted ~N lines]` tokens in `text` back to their exact full pasted text
    /// in a single non-overlapping pass (never recursively re-expanding expanded content).
    public static func expand(_ text: String, blocks: [TUIPastedBlock]) -> String {
        guard !blocks.isEmpty, !text.isEmpty else { return text }

        struct MatchReplacement {
            let range: Range<String.Index>
            let replacement: String
        }

        var claimed: [Range<String.Index>] = []
        var replacements: [MatchReplacement] = []
        replacements.reserveCapacity(blocks.count)

        func overlapsClaimed(_ candidate: Range<String.Index>) -> Bool {
            for existing in claimed {
                if candidate.lowerBound < existing.upperBound && existing.lowerBound < candidate.upperBound {
                    return true
                }
            }
            return false
        }

        for block in blocks {
            guard !block.label.isEmpty else { continue }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: block.label, range: searchStart..<text.endIndex)
            {
                if !overlapsClaimed(found) {
                    claimed.append(found)
                    replacements.append(MatchReplacement(range: found, replacement: block.text))
                    break
                }
                searchStart = found.upperBound
            }
        }

        guard !replacements.isEmpty else { return text }
        replacements.sort { $0.range.lowerBound < $1.range.lowerBound }

        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for item in replacements {
            if cursor < item.range.lowerBound {
                result.append(contentsOf: text[cursor..<item.range.lowerBound])
            }
            result.append(item.replacement)
            cursor = item.range.upperBound
        }
        if cursor < text.endIndex {
            result.append(contentsOf: text[cursor..<text.endIndex])
        }
        return result
    }

    /// Removes stored paste blocks whose placeholder labels have been deleted from `text`.
    public static func pruneUnusedBlocks(in text: String, blocks: inout [TUIPastedBlock]) {
        guard !blocks.isEmpty else { return }
        var remainingBudget: [String: Int] = [:]
        var uniqueLabels: Set<String> = []
        for block in blocks {
            uniqueLabels.insert(block.label)
        }
        for label in uniqueLabels where !label.isEmpty {
            var count = 0
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: label, range: searchStart..<text.endIndex)
            {
                count += 1
                searchStart = found.upperBound
            }
            remainingBudget[label] = count
        }

        var kept: [TUIPastedBlock] = []
        kept.reserveCapacity(blocks.count)
        for block in blocks {
            let avail = remainingBudget[block.label] ?? 0
            if avail > 0 {
                kept.append(block)
                remainingBudget[block.label] = avail - 1
            }
        }
        blocks = kept
    }
}

// MARK: - Multiline Prompt Helpers

/// Pure line-splitting and editing helpers for the auto-growing multiline prompt composer.
public enum TUIMultilinePrompt {
    public static let maxVisibleLines: Int = 6

    /// Splits a prompt draft into preceding lines (before the final `\n`) and the active bottom editing line.
    public static func splitLines(_ text: String) -> (prefixLines: [String], activeLine: String) {
        guard text.contains("\n") else { return ([], text) }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return ([], text) }
        return (Array(parts.dropLast()), parts.last ?? "")
    }

    /// Replaces only the active bottom editing line while preserving any preceding multiline lines.
    public static func replaceActiveLine(in fullText: String, with newActiveLine: String) -> String {
        guard let lastNewline = fullText.lastIndex(of: "\n") else {
            return newActiveLine
        }
        return String(fullText[...lastNewline]) + newActiveLine
    }

    /// Appends a real newline (`\n`) to the draft text.
    public static func appendNewline(to text: String) -> String {
        text + "\n"
    }

    /// When the active bottom line is empty after a trailing `\n`, removes that `\n` to merge back onto the prior line.
    public static func removeTrailingNewlineIfAtEmptyLine(_ text: String) -> String? {
        guard text.hasSuffix("\n") else { return nil }
        return String(text.dropLast())
    }

    /// Caps visible prefix lines so the composer grows up to `maxTotalLines` (default 6, including active line).
    public static func visiblePrefixSlice(
        _ prefixLines: [String],
        maxTotalLines: Int = maxVisibleLines
    ) -> (hiddenCount: Int, visible: [String]) {
        let maxPrefix = max(0, maxTotalLines - 1)
        if prefixLines.count <= maxPrefix {
            return (0, prefixLines)
        }
        let hidden = prefixLines.count - maxPrefix
        return (hidden, Array(prefixLines.suffix(maxPrefix)))
    }
}

// MARK: - Queued Prompts Model (`session.queued_prompts`)

/// Represents a queued (or steered) user prompt awaiting delivery in the session inbox.
public struct TUIQueuedPromptItem: Equatable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let delivery: String

    public init(id: String, text: String, delivery: String = "queue") {
        self.id = id
        self.text = text
        self.delivery = delivery
    }
}

// MARK: - Top Session Tabs Strip (`component/session-tabs.tsx`)

/// Declarative 1-row top session tab bar matching upstream `component/session-tabs.tsx`.
public enum TUISessionTabsBar {
    public static func buildSessionTabsBar(
        tabs: [String],
        activeSessionID: String?,
        sessions: [TUISessionItem],
        cols: Int,
        theme: ResolvedTheme,
        onSelectTab: @escaping @Sendable (String) -> Void = { _ in },
        onNewTab: @escaping @Sendable () -> Void = {}
    ) -> AnyTUIView {
        guard !tabs.isEmpty else {
            return AnyTUIView(EmptyTUIView())
        }

        let stripBg = theme.background.raised.base
        let activeBg = theme.background.raised.high
        let activeNumberFg = theme.text.action.primary.selected
        let activeTitleFg = theme.text.base
        let inactiveNumberFg = theme.text.faint
        let inactiveTitleFg = theme.text.muted

        let showAddButton = cols >= 14
        let addWidth = showAddButton ? 3 : 0
        let totalTabBudget = max(8, cols - addWidth)

        let activeGlobalIndex = activeSessionID.flatMap { tabs.firstIndex(of: $0) } ?? 0
        let minSlotWidth = 10
        let maxSlots = max(1, totalTabBudget / minSlotWidth)

        let startIdx: Int
        let endIdx: Int
        if tabs.count <= maxSlots {
            startIdx = 0
            endIdx = tabs.count
        } else {
            let half = maxSlots / 2
            let clampedStart = max(0, min(activeGlobalIndex - half, tabs.count - maxSlots))
            startIdx = clampedStart
            endIdx = min(tabs.count, clampedStart + maxSlots)
        }

        let hiddenBefore = startIdx
        let hiddenAfter = tabs.count - endIdx
        let beforeBadge = hiddenBefore > 0 ? "<\(hiddenBefore)" : nil
        let afterBadge = hiddenAfter > 0 ? "\(hiddenAfter)>" : nil
        let overflowReserve = (beforeBadge.map { TUIUtil.stringWidth($0) + 1 } ?? 0)
            + (afterBadge.map { TUIUtil.stringWidth($0) + 1 } ?? 0)

        let visibleSlice = Array(tabs[startIdx..<endIdx])
        let visibleCount = max(1, visibleSlice.count)
        let usableTabWidth = max(visibleCount * 6, totalTabBudget - overflowReserve)
        let perTabWidth = max(6, min(28, usableTabWidth / visibleCount))

        let sessionTitleByID: [String: String] = Dictionary(
            sessions.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(stripBg),
                shouldFill: true
            ) {
                HStack(spacing: 0, alignment: .center) {
                    if let beforeBadge {
                        TUIText(
                            " \(beforeBadge)",
                            fg: .rgba(theme.text.muted),
                            bg: .rgba(stripBg),
                            wrapMode: TextWrapMode.none
                        )
                        .flexShrink(0)
                    }

                    for (offset, tabID) in visibleSlice.enumerated() {
                        let globalIndex = startIdx + offset
                        let isActive = tabID == activeSessionID
                        let rawTitle = sessionTitleByID[tabID] ?? "Session"
                        let numberText = "\(globalIndex + 1)"
                        let overhead = 2 + numberText.count + 1 // leading space + number + space + trailing space
                        let titleBudget = max(3, perTabWidth - overhead)
                        let fittedTitle = TUIUtil.truncateWidth(rawTitle, titleBudget)
                        let tabBg = isActive ? activeBg : stripBg
                        let numFg = isActive ? activeNumberFg : inactiveNumberFg
                        let titleFg = isActive ? activeTitleFg : inactiveTitleFg
                        let attrs = isActive ? TextAttributes.bold : TextAttributes.none

                        TUIBox(
                            border: false,
                            backgroundColor: .rgba(tabBg),
                            shouldFill: true
                        ) {
                            TUIText(
                                StyledText(chunks: [
                                    TextChunk(text: " \(numberText) ", fg: numFg, bg: tabBg, attributes: attrs),
                                    TextChunk(text: fittedTitle, fg: titleFg, bg: tabBg, attributes: attrs),
                                    TextChunk(text: " ", fg: titleFg, bg: tabBg),
                                ]),
                                bg: .rgba(tabBg),
                                wrapMode: TextWrapMode.none,
                                selectable: false,
                                truncate: true
                            )
                            .width(.percent(100))
                        }
                        .key("session-tab-\(tabID)")
                        .id("session-tab-\(globalIndex)")
                        .width(perTabWidth)
                        .height(1)
                        .flexShrink(0)
                        .onMouseUp { _ in
                            onSelectTab(tabID)
                        }
                    }

                    if let afterBadge {
                        TUIText(
                            "\(afterBadge) ",
                            fg: .rgba(theme.text.muted),
                            bg: .rgba(stripBg),
                            wrapMode: TextWrapMode.none
                        )
                        .flexShrink(0)
                    }

                    TUISpacer()

                    if showAddButton {
                        TUIBox(
                            border: false,
                            backgroundColor: .rgba(stripBg),
                            shouldFill: true
                        ) {
                            TUIText(
                                " + ",
                                fg: .rgba(theme.text.muted),
                                bg: .rgba(stripBg),
                                wrapMode: TextWrapMode.none,
                                selectable: false
                            )
                        }
                        .key("session-tab-new")
                        .id("session-tab-new")
                        .width(3)
                        .height(1)
                        .flexShrink(0)
                        .onMouseUp { _ in
                            onNewTab()
                        }
                    }
                }
                .width(.percent(100))
                .height(1)
            }
            .id("opencode-session-tabs")
            .width(.percent(100))
            .height(1)
            .flexShrink(0)
        )
    }
}

/// Top-level convenience forwarding to `TUISessionTabsBar.buildSessionTabsBar`.
public func buildSessionTabsBar(
    tabs: [String],
    activeSessionID: String?,
    sessions: [TUISessionItem],
    cols: Int,
    theme: ResolvedTheme,
    onSelectTab: @escaping @Sendable (String) -> Void = { _ in },
    onNewTab: @escaping @Sendable () -> Void = {}
) -> AnyTUIView {
    TUISessionTabsBar.buildSessionTabsBar(
        tabs: tabs,
        activeSessionID: activeSessionID,
        sessions: sessions,
        cols: cols,
        theme: theme,
        onSelectTab: onSelectTab,
        onNewTab: onNewTab
    )
}

// MARK: - Embedded Live Terminal Pane (`component/terminal-pane.tsx` + `composer/terminals-tab.tsx`)

/// State for the bottom-docked interactive terminal split pane (`<leader>t` toggle, `<leader>up` close).
public struct TUIEmbeddedTerminalState: Equatable, Hashable, Sendable {
    public var isOpen: Bool
    public var isFocused: Bool
    public var ptyID: String?
    public var title: String
    public var outputLines: [String]
    public var exitCode: Int?
    public var inputBuffer: String

    public init(
        isOpen: Bool = false,
        isFocused: Bool = false,
        ptyID: String? = nil,
        title: String = "Terminal",
        outputLines: [String] = [],
        exitCode: Int? = nil,
        inputBuffer: String = ""
    ) {
        self.isOpen = isOpen
        self.isFocused = isFocused
        self.ptyID = ptyID
        self.title = title
        self.outputLines = outputLines
        self.exitCode = exitCode
        self.inputBuffer = inputBuffer
    }
}

/// Declarative bottom-docked terminal split pane builder.
public enum TUIEmbeddedTerminalPane {
    public static let maxStoredOutputLines: Int = 500

    private static let topDividerBorderChars = BorderCharacters(
        topLeft: "─", topRight: "─", bottomLeft: " ", bottomRight: " ",
        horizontal: "─", vertical: " ",
        topT: "─", bottomT: " ", leftT: "─", rightT: "─", cross: "─"
    )

    /// Computes upstream-proportioned split pane height: `min(12, max(6, rows / 3))`.
    public static func paneHeight(forRows rows: Int) -> Int {
        min(12, max(6, rows / 3))
    }

    public static func buildEmbeddedTerminalPane(
        state: TUIEmbeddedTerminalState,
        theme: ResolvedTheme,
        height: Int,
        onClose: @escaping @Sendable () -> Void = {},
        onFocus: @escaping @Sendable () -> Void = {},
        onInput: @escaping @Sendable (String) -> Void = { _ in },
        onSubmit: @escaping @Sendable (String) -> Void = { _ in }
    ) -> AnyTUIView {
        let clampedHeight = max(5, height)
        let paneBg = theme.background.raised.base
        let headerBg = theme.background.raised.high
        let borderColor = state.isFocused ? theme.text.action.primary.selected : theme.border.base

        let headerTitle: String
        if state.title.isEmpty || state.title.lowercased() == "terminal" {
            headerTitle = "Terminal"
        } else {
            headerTitle = "Terminal · \(state.title)"
        }

        let statusText: String
        let statusColor: RGBA
        if let code = state.exitCode {
            statusText = "exited (\(code))"
            statusColor = code == 0 ? theme.text.muted : theme.text.feedback.error.base
        } else if state.ptyID != nil {
            statusText = "● pty"
            statusColor = theme.text.feedback.success.base
        } else {
            statusText = state.isFocused ? "● active" : "● ready"
            statusColor = state.isFocused ? theme.text.feedback.success.base : theme.text.muted
        }

        // 1 row top border + 1 row header + 1 row command input = 3 chrome rows
        let visibleOutputBudget = max(1, clampedHeight - 3)
        let visibleLines = Array(state.outputLines.suffix(visibleOutputBudget))

        return AnyTUIView(
            TUIBox(
                border: .sides([.top]),
                borderColor: .rgba(borderColor),
                backgroundColor: .rgba(paneBg),
                shouldFill: true,
                customBorderChars: topDividerBorderChars
            ) {
                VStack(spacing: 0) {
                    // Header Bar (`Terminal` + status + `ctrl+x ↑ close`)
                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(headerBg),
                        shouldFill: true
                    ) {
                        HStack(spacing: 2, alignment: .center) {
                            TUIText(
                                StyledText(chunks: [
                                    TextChunk(
                                        text: headerTitle,
                                        fg: theme.text.base,
                                        bg: headerBg,
                                        attributes: TextAttributes.bold
                                    ),
                                    TextChunk(text: "  ", fg: theme.text.muted, bg: headerBg),
                                    TextChunk(text: statusText, fg: statusColor, bg: headerBg),
                                ]),
                                bg: .rgba(headerBg),
                                wrapMode: TextWrapMode.none,
                                selectable: false,
                                truncate: true
                            )
                            .flexShrink(1)

                            TUISpacer()

                            TUIText(
                                "ctrl+x ↑ close",
                                fg: .rgba(theme.text.muted),
                                bg: .rgba(headerBg),
                                wrapMode: TextWrapMode.none,
                                selectable: false
                            )
                            .id("terminal-pane-close")
                            .flexShrink(0)
                            .onMouseUp { event in
                                event.stopPropagation()
                                onClose()
                            }
                        }
                        .padding(right: 1, left: 1)
                        .width(.percent(100))
                        .height(1)
                    }
                    .id("terminal-pane-header")
                    .width(.percent(100))
                    .height(1)
                    .flexShrink(0)

                    // Scrolling / Tail Output Area
                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(paneBg),
                        shouldFill: true
                    ) {
                        VStack(spacing: 0) {
                            if visibleLines.isEmpty {
                                TUIText(
                                    "Type a shell command below and press Enter (ctrl+x ← to return to prompt)",
                                    fg: .rgba(theme.text.muted),
                                    bg: .rgba(paneBg),
                                    attributes: TextAttributes.italic,
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                                .width(.percent(100))
                            } else {
                                for (idx, line) in visibleLines.enumerated() {
                                    let isCommandLine = line.hasPrefix("$ ")
                                    TUIText(
                                        line,
                                        fg: .rgba(isCommandLine ? theme.text.base : theme.text.muted),
                                        bg: .rgba(paneBg),
                                        attributes: isCommandLine ? TextAttributes.bold : TextAttributes.none,
                                        wrapMode: TextWrapMode.none,
                                        truncate: true
                                    )
                                    .key("terminal-out-\(idx)")
                                    .width(.percent(100))
                                    .height(1)
                                }
                            }
                        }
                        .padding(right: 1, left: 1)
                        .width(.percent(100))
                    }
                    .id("terminal-pane-output")
                    .width(.percent(100))
                    .flexGrow(1)
                    .minHeight(1)

                    // Command Input Line (`$ <input>`)
                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(paneBg),
                        shouldFill: true
                    ) {
                        HStack(spacing: 1, alignment: .center) {
                            TUIText(
                                "$",
                                fg: .rgba(state.isFocused ? theme.text.action.primary.selected : theme.text.muted),
                                bg: .rgba(paneBg),
                                attributes: TextAttributes.bold,
                                wrapMode: TextWrapMode.none
                            )
                            .width(1)
                            .flexShrink(0)

                            TUIInput(
                                value: state.inputBuffer,
                                placeholder: "Run command…",
                                placeholderColor: .rgba(theme.text.muted),
                                maxLength: 1000,
                                textColor: .rgba(theme.text.base),
                                backgroundColor: .rgba(paneBg),
                                focusedTextColor: .rgba(theme.text.base),
                                focusedBackgroundColor: .rgba(paneBg),
                                showCursor: state.isFocused,
                                cursorColor: .rgba(theme.text.base),
                                onInput: onInput,
                                onSubmit: onSubmit
                            )
                            .key("terminal-pane-input")
                            .id("terminal-pane-input")
                            .flexGrow(1)
                            .focused(state.isFocused)
                        }
                        .padding(right: 1, left: 1)
                        .width(.percent(100))
                        .height(1)
                    }
                    .width(.percent(100))
                    .height(1)
                    .flexShrink(0)
                }
                .width(.percent(100))
                .height(.percent(100))
            }
            .id("opencode-terminal-pane")
            .width(.percent(100))
            .height(clampedHeight)
            .flexShrink(0)
            .onMouseUp { _ in
                onFocus()
            }
        )
    }
}

/// Top-level convenience forwarding to `TUIEmbeddedTerminalPane.buildEmbeddedTerminalPane`.
public func buildEmbeddedTerminalPane(
    state: TUIEmbeddedTerminalState,
    theme: ResolvedTheme,
    height: Int,
    onClose: @escaping @Sendable () -> Void = {}
) -> AnyTUIView {
    TUIEmbeddedTerminalPane.buildEmbeddedTerminalPane(
        state: state,
        theme: theme,
        height: height,
        onClose: onClose
    )
}
