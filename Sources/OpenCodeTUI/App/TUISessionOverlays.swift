import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView

// MARK: - 1. Interactive Permission Prompt Models

/// Pending tool or action permission request displayed above the session composer.
public struct TUIPendingPermissionItem: Equatable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public let permission: String
    public let patterns: [String]
    public let alwaysPatterns: [String]
    public let toolName: String?
    public let commandPreview: String?
    public let filePath: String?
    public let diffPatch: String?

    public init(
        id: String,
        sessionID: String,
        permission: String,
        patterns: [String] = [],
        alwaysPatterns: [String] = [],
        toolName: String? = nil,
        commandPreview: String? = nil,
        filePath: String? = nil,
        diffPatch: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.permission = permission
        self.patterns = patterns
        self.alwaysPatterns = alwaysPatterns
        self.toolName = toolName
        self.commandPreview = commandPreview
        self.filePath = filePath
        self.diffPatch = diffPatch
    }
}

/// Selectable response actions for a pending permission request.
public enum TUIPermissionOption: Int, CaseIterable, Equatable, Hashable, Sendable {
    case once = 0
    case always = 1
    case reject = 2

    public var label: String {
        switch self {
        case .once: return "Allow once"
        case .always: return "Allow always"
        case .reject: return "Reject"
        }
    }

    public var replyDecision: String {
        switch self {
        case .once: return "once"
        case .always: return "always"
        case .reject: return "reject"
        }
    }
}

/// Interactive state for the permission approval / reject-with-feedback prompt.
public struct TUIPermissionPromptState: Equatable, Hashable, Sendable {
    public var selectedOption: TUIPermissionOption
    public var isRejectingWithFeedback: Bool
    public var rejectFeedback: String

    public init(
        selectedOption: TUIPermissionOption = .once,
        isRejectingWithFeedback: Bool = false,
        rejectFeedback: String = ""
    ) {
        self.selectedOption = selectedOption
        self.isRejectingWithFeedback = isRejectingWithFeedback
        self.rejectFeedback = rejectFeedback
    }

    public mutating func selectNext() {
        let all = TUIPermissionOption.allCases
        let nextRaw = (selectedOption.rawValue + 1) % all.count
        selectedOption = TUIPermissionOption(rawValue: nextRaw) ?? .once
    }

    public mutating func selectPrevious() {
        let all = TUIPermissionOption.allCases
        let prevRaw = (selectedOption.rawValue - 1 + all.count) % all.count
        selectedOption = TUIPermissionOption(rawValue: prevRaw) ?? .once
    }

    public mutating func beginRejectWithFeedback() {
        selectedOption = .reject
        isRejectingWithFeedback = true
    }

    public mutating func cancelRejectWithFeedback() {
        isRejectingWithFeedback = false
    }
}

// MARK: - 2. Interactive Form / Question Prompt Models

/// Selectable option entry for single-select and multi-select form fields.
public struct TUIFormOptionItem: Equatable, Hashable, Sendable {
    public let label: String
    public let value: String
    public let description: String?

    public init(label: String, value: String, description: String? = nil) {
        self.label = label
        self.value = value
        self.description = description
    }
}

/// Supported interactive field kinds in a session form prompt.
public enum TUIFormFieldKind: Equatable, Hashable, Sendable {
    case singleSelect([TUIFormOptionItem])
    case multiSelect([TUIFormOptionItem])
    case boolean
    case text(placeholder: String? = nil)
}

/// Declarative definition of one question / field inside `TUIPendingFormItem`.
public struct TUIFormFieldItem: Equatable, Hashable, Sendable {
    public let key: String
    public let label: String
    public let description: String?
    public let kind: TUIFormFieldKind
    public let allowCustom: Bool
    public let required: Bool

    public init(
        key: String,
        label: String,
        description: String? = nil,
        kind: TUIFormFieldKind,
        allowCustom: Bool = false,
        required: Bool = false
    ) {
        self.key = key
        self.label = label
        self.description = description
        self.kind = kind
        self.allowCustom = allowCustom
        self.required = required
    }
}

/// Pending interactive form / question prompt requested by the agent runtime.
public struct TUIPendingFormItem: Equatable, Hashable, Sendable {
    public let id: String
    public let sessionID: String?
    public let title: String?
    public let message: String?
    public let fields: [TUIFormFieldItem]

    public init(
        id: String,
        sessionID: String? = nil,
        title: String? = nil,
        message: String? = nil,
        fields: [TUIFormFieldItem]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.message = message
        self.fields = fields
    }
}

/// Interactive navigation, selection, and answer state for `TUIPendingFormItem`.
public struct TUIFormPromptState: Equatable, Hashable, Sendable {
    public var activeFieldIndex: Int
    public var selectedRowIndex: Int
    public var answers: [String: JSONValue]
    public var customText: String
    public var editingCustom: Bool
    public var errorMessage: String?

    public init(
        activeFieldIndex: Int = 0,
        selectedRowIndex: Int = 0,
        answers: [String: JSONValue] = [:],
        customText: String = "",
        editingCustom: Bool = false,
        errorMessage: String? = nil
    ) {
        self.activeFieldIndex = activeFieldIndex
        self.selectedRowIndex = selectedRowIndex
        self.answers = answers
        self.customText = customText
        self.editingCustom = editingCustom
        self.errorMessage = errorMessage
    }

    /// True when the form consists of a single single-select or boolean field that submits on confirm.
    public func isSingleFieldImmediate(form: TUIPendingFormItem) -> Bool {
        guard form.fields.count == 1, let first = form.fields.first else { return false }
        switch first.kind {
        case .singleSelect, .boolean:
            return true
        case .multiSelect, .text:
            return false
        }
    }

    /// Total number of navigable tabs (fields plus the final Submit review tab when applicable).
    public func tabCount(for form: TUIPendingFormItem) -> Int {
        guard !form.fields.isEmpty else { return 0 }
        return isSingleFieldImmediate(form: form) ? 1 : (form.fields.count + 1)
    }

    /// True when the user is currently viewing the final Submit review tab.
    public func isOnReviewTab(form: TUIPendingFormItem) -> Bool {
        !isSingleFieldImmediate(form: form) && !form.fields.isEmpty && activeFieldIndex >= form.fields.count
    }

    /// The currently active field, or `nil` when on the Submit review tab.
    public func activeField(in form: TUIPendingFormItem) -> TUIFormFieldItem? {
        guard activeFieldIndex >= 0 && activeFieldIndex < form.fields.count else { return nil }
        return form.fields[activeFieldIndex]
    }

    /// Selectable option rows for a non-text field.
    public static func optionRows(for field: TUIFormFieldItem) -> [TUIFormOptionItem] {
        switch field.kind {
        case .singleSelect(let options), .multiSelect(let options):
            return options
        case .boolean:
            return [
                TUIFormOptionItem(label: "Yes", value: "true"),
                TUIFormOptionItem(label: "No", value: "false"),
            ]
        case .text:
            return []
        }
    }

    /// Moves the highlighted option row by `delta` with wrap-around.
    public mutating func moveRow(by delta: Int, form: TUIPendingFormItem) {
        guard let field = activeField(in: form) else { return }
        if case .text = field.kind { return }
        let rows = Self.optionRows(for: field)
        let total = rows.count + (field.allowCustom ? 1 : 0)
        guard total > 0 else { return }
        selectedRowIndex = ((selectedRowIndex + delta) % total + total) % total
        if !field.allowCustom || selectedRowIndex < rows.count {
            editingCustom = false
        }
        errorMessage = nil
    }

    /// Selects or toggles the currently highlighted option (or submits on the review tab).
    /// Returns `true` when the form is complete and ready to submit immediately.
    @discardableResult
    public mutating func toggleOrSelectCurrent(form: TUIPendingFormItem) -> Bool {
        guard !form.fields.isEmpty else { return false }

        if isOnReviewTab(form: form) {
            if let missing = form.fields.first(where: { $0.required && !hasValidAnswer(for: $0) }) {
                errorMessage = "\(missing.label) is required"
                return false
            }
            errorMessage = nil
            return true
        }

        guard let field = activeField(in: form) else { return false }
        let singleImmediate = isSingleFieldImmediate(form: form)

        switch field.kind {
        case .text:
            let trimmed = trimWhitespace(customText)
            if trimmed.isEmpty {
                if field.required {
                    errorMessage = "\(field.label) is required"
                    return false
                }
                answers.removeValue(forKey: field.key)
            } else {
                answers[field.key] = .string(trimmed)
            }
            editingCustom = false
            errorMessage = nil
            advanceTab(by: 1, form: form)
            return false

        case .boolean:
            let boolValue = (selectedRowIndex == 0)
            answers[field.key] = .bool(boolValue)
            errorMessage = nil
            if singleImmediate {
                return true
            }
            advanceTab(by: 1, form: form)
            return false

        case .singleSelect(let options):
            if field.allowCustom && selectedRowIndex == options.count {
                if !editingCustom {
                    editingCustom = true
                    errorMessage = nil
                    if case .string(let existing) = answers[field.key],
                       !options.contains(where: { $0.value == existing }) {
                        customText = existing
                    }
                    return false
                }
                let trimmed = trimWhitespace(customText)
                if trimmed.isEmpty {
                    if field.required {
                        errorMessage = "\(field.label) is required"
                        return false
                    }
                    editingCustom = false
                    return false
                }
                answers[field.key] = .string(trimmed)
                editingCustom = false
                errorMessage = nil
                if singleImmediate {
                    return true
                }
                advanceTab(by: 1, form: form)
                return false
            }

            guard selectedRowIndex >= 0 && selectedRowIndex < options.count else { return false }
            answers[field.key] = .string(options[selectedRowIndex].value)
            editingCustom = false
            errorMessage = nil
            if singleImmediate {
                return true
            }
            advanceTab(by: 1, form: form)
            return false

        case .multiSelect(let options):
            if field.allowCustom && selectedRowIndex == options.count {
                if !editingCustom {
                    editingCustom = true
                    errorMessage = nil
                    return false
                }
                let trimmed = trimWhitespace(customText)
                if !trimmed.isEmpty {
                    toggleMultiValue(trimmed, forKey: field.key)
                }
                editingCustom = false
                errorMessage = nil
                return false
            }

            guard selectedRowIndex >= 0 && selectedRowIndex < options.count else { return false }
            toggleMultiValue(options[selectedRowIndex].value, forKey: field.key)
            errorMessage = nil
            return false
        }
    }

    /// Advances to the next field tab (or the Submit review tab).
    public mutating func nextField(form: TUIPendingFormItem) {
        commitActiveTextIfNeeded(form: form)
        advanceTab(by: 1, form: form)
    }

    /// Moves to the previous field tab (wrapping around).
    public mutating func prevField(form: TUIPendingFormItem) {
        commitActiveTextIfNeeded(form: form)
        advanceTab(by: -1, form: form)
    }

    /// Returns the encoded `JSONValue` answer for a single field, if answered.
    public func encodedAnswer(for field: TUIFormFieldItem) -> JSONValue? {
        if let existing = answers[field.key] {
            return existing
        }
        if case .text = field.kind {
            let trimmed = trimWhitespace(customText)
            if !trimmed.isEmpty {
                return .string(trimmed)
            }
        }
        return nil
    }

    /// Returns the complete encoded answer dictionary for all answered fields in `form`.
    public func encodedAnswer(for form: TUIPendingFormItem) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for field in form.fields {
            if let value = encodedAnswer(for: field) {
                result[field.key] = value
            }
        }
        return result
    }

    /// Returns a concise human-readable display string for a field's current answer.
    public func displayAnswer(for field: TUIFormFieldItem) -> String? {
        guard let value = encodedAnswer(for: field) else { return nil }
        switch (field.kind, value) {
        case (.boolean, .bool(let flag)):
            return flag ? "Yes" : "No"
        case (.singleSelect(let options), .string(let raw)):
            return options.first(where: { $0.value == raw })?.label ?? raw
        case (.multiSelect(let options), .array(let items)):
            let labels = items.compactMap { item -> String? in
                guard case .string(let raw) = item else { return nil }
                return options.first(where: { $0.value == raw })?.label ?? raw
            }
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        case (_, .string(let str)):
            return str.isEmpty ? nil : str
        case (_, .bool(let flag)):
            return flag ? "Yes" : "No"
        case (_, .int(let num)):
            return "\(num)"
        case (_, .double(let num)):
            return "\(num)"
        default:
            return nil
        }
    }

    /// Checks whether a multi-select or single-select option value is currently selected.
    public func isOptionSelected(_ value: String, for field: TUIFormFieldItem) -> Bool {
        guard let answer = answers[field.key] else { return false }
        switch (field.kind, answer) {
        case (.boolean, .bool(let flag)):
            return (value == "true" && flag) || (value == "false" && !flag)
        case (.singleSelect, .string(let selected)):
            return selected == value
        case (.multiSelect, .array(let list)):
            return list.contains(.string(value))
        default:
            return false
        }
    }

    private func hasValidAnswer(for field: TUIFormFieldItem) -> Bool {
        guard let val = encodedAnswer(for: field) else { return false }
        switch val {
        case .null:
            return false
        case .string(let s):
            return !trimWhitespace(s).isEmpty
        case .array(let arr):
            return !arr.isEmpty
        default:
            return true
        }
    }

    private mutating func toggleMultiValue(_ value: String, forKey key: String) {
        var current: [String] = []
        if case .array(let existing) = answers[key] {
            for item in existing {
                if case .string(let str) = item {
                    current.append(str)
                }
            }
        }
        if let idx = current.firstIndex(of: value) {
            current.remove(at: idx)
        } else {
            current.append(value)
        }
        if current.isEmpty {
            answers.removeValue(forKey: key)
        } else {
            answers[key] = .array(current.map(JSONValue.string))
        }
    }

    private mutating func commitActiveTextIfNeeded(form: TUIPendingFormItem) {
        guard let field = activeField(in: form) else { return }
        if case .text = field.kind {
            let trimmed = trimWhitespace(customText)
            if trimmed.isEmpty {
                answers.removeValue(forKey: field.key)
            } else {
                answers[field.key] = .string(trimmed)
            }
        }
    }

    private mutating func advanceTab(by delta: Int, form: TUIPendingFormItem) {
        let total = tabCount(for: form)
        guard total > 0 else { return }
        activeFieldIndex = ((activeFieldIndex + delta) % total + total) % total
        errorMessage = nil

        guard let next = activeField(in: form) else {
            selectedRowIndex = 0
            editingCustom = false
            return
        }

        switch next.kind {
        case .text:
            selectedRowIndex = 0
            editingCustom = true
            if case .string(let saved) = answers[next.key] {
                customText = saved
            } else {
                customText = ""
            }
        case .boolean:
            editingCustom = false
            if case .bool(let flag) = answers[next.key] {
                selectedRowIndex = flag ? 0 : 1
            } else {
                selectedRowIndex = 0
            }
        case .singleSelect(let options):
            editingCustom = false
            if case .string(let saved) = answers[next.key],
               let idx = options.firstIndex(where: { $0.value == saved }) {
                selectedRowIndex = idx
            } else if next.allowCustom, case .string(let saved) = answers[next.key], !saved.isEmpty {
                selectedRowIndex = options.count
                customText = saved
            } else {
                selectedRowIndex = 0
            }
        case .multiSelect:
            editingCustom = false
            selectedRowIndex = 0
        }
    }
}

// MARK: - 3. Full Diff Viewer Overlay Models

/// Single changed file and unified patch entry rendered in the Diff Viewer overlay.
public struct TUIDiffFileEntry: Equatable, Hashable, Sendable {
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let status: String
    public let patch: String

    public init(
        path: String,
        additions: Int,
        deletions: Int,
        status: String = "modified",
        patch: String
    ) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.status = status
        self.patch = patch
    }
}

/// Interactive state for the full Diff Viewer overlay.
public struct TUIDiffViewerState: Equatable, Hashable, Sendable {
    public var title: String
    public var files: [TUIDiffFileEntry]
    public var selectedFileIndex: Int
    public var splitView: Bool
    public var fullscreen: Bool
    public var showFileTree: Bool
    public var wrapLines: Bool

    public init(
        title: String = "Diff Viewer",
        files: [TUIDiffFileEntry] = [],
        selectedFileIndex: Int = 0,
        splitView: Bool = false,
        fullscreen: Bool = false,
        showFileTree: Bool = true,
        wrapLines: Bool = true
    ) {
        self.title = title
        self.files = files
        self.selectedFileIndex = files.isEmpty ? 0 : min(max(0, selectedFileIndex), files.count - 1)
        self.splitView = splitView
        self.fullscreen = fullscreen
        self.showFileTree = showFileTree
        self.wrapLines = wrapLines
    }

    public var selectedFile: TUIDiffFileEntry? {
        guard !files.isEmpty else { return nil }
        let clamped = min(max(0, selectedFileIndex), files.count - 1)
        return files[clamped]
    }

    public var totalAdditions: Int {
        files.reduce(0) { $0 + max(0, $1.additions) }
    }

    public var totalDeletions: Int {
        files.reduce(0) { $0 + max(0, $1.deletions) }
    }

    public mutating func selectNextFile() {
        guard !files.isEmpty else { return }
        selectedFileIndex = (selectedFileIndex + 1) % files.count
    }

    public mutating func selectPreviousFile() {
        guard !files.isEmpty else { return }
        selectedFileIndex = (selectedFileIndex - 1 + files.count) % files.count
    }

    public mutating func toggleSplitView() {
        splitView.toggle()
    }

    public mutating func toggleFullscreen() {
        fullscreen.toggle()
    }

    public mutating func toggleFileTree() {
        showFileTree.toggle()
    }

    public mutating func toggleWrapLines() {
        wrapLines.toggle()
    }
}

// MARK: - 4. Rich Info, Action Dialog & Sidebar Todo Models

/// One-time remote client pairing payload rendered by `/pair` with a scannable Unicode QR code.
public struct TUIPairingInfo: Equatable, Hashable, Sendable {
    public let links: [String]
    public let localhostURL: String?
    public let expiresInMinutes: Int
    public let isLoopbackOnly: Bool
    public let errorMessage: String?

    public init(
        links: [String],
        localhostURL: String? = nil,
        expiresInMinutes: Int = 5,
        isLoopbackOnly: Bool = false,
        errorMessage: String? = nil
    ) {
        self.links = links
        self.localhostURL = localhostURL
        self.expiresInMinutes = expiresInMinutes
        self.isLoopbackOnly = isLoopbackOnly
        self.errorMessage = errorMessage
    }
}

/// Server, workspace, provider, MCP, skills, and commands snapshot for `/status`.
public struct TUIStatusSnapshot: Equatable, Hashable, Sendable {
    public let serverURL: String
    public let serverVersion: String
    public let directory: String
    public let gitBranch: String?
    public let connectedProvidersCount: Int
    public let totalModelsCount: Int
    public let mcpServers: [TUIMCPServerItem]
    public let skillsCount: Int
    public let commandsCount: Int

    public init(
        serverURL: String,
        serverVersion: String,
        directory: String,
        gitBranch: String? = nil,
        connectedProvidersCount: Int = 0,
        totalModelsCount: Int = 0,
        mcpServers: [TUIMCPServerItem] = [],
        skillsCount: Int = 0,
        commandsCount: Int = 0
    ) {
        self.serverURL = serverURL
        self.serverVersion = serverVersion
        self.directory = directory
        self.gitBranch = gitBranch
        self.connectedProvidersCount = connectedProvidersCount
        self.totalModelsCount = totalModelsCount
        self.mcpServers = mcpServers
        self.skillsCount = skillsCount
        self.commandsCount = commandsCount
    }
}

/// Per-model or workspace usage budget row displayed in `/usage`.
public struct TUIUsageLimitRow: Equatable, Hashable, Sendable {
    public let modelID: String
    public let modelName: String
    public let providerName: String?
    public let scopeLabel: String?
    public let spentDollars: Double
    public let limitDollars: Double
    public let remainingDollars: Double
    public let remainingPercent: Int?
    public let resetsLabel: String?
    public let isReached: Bool
    public let isLow: Bool

    public init(
        modelID: String,
        modelName: String,
        providerName: String? = nil,
        scopeLabel: String? = nil,
        spentDollars: Double,
        limitDollars: Double,
        remainingDollars: Double? = nil,
        remainingPercent: Int? = nil,
        resetsLabel: String? = nil,
        isReached: Bool = false,
        isLow: Bool = false
    ) {
        let computedRemaining = remainingDollars ?? max(0, limitDollars - spentDollars)
        let computedPercent: Int?
        if let explicitPercent = remainingPercent {
            computedPercent = min(100, max(0, explicitPercent))
        } else if limitDollars > 0 {
            let ratio = max(0.0, min(1.0, computedRemaining / limitDollars))
            computedPercent = Int((ratio * 100.0).rounded())
        } else {
            computedPercent = nil
        }

        self.modelID = modelID
        self.modelName = modelName
        self.providerName = providerName
        self.scopeLabel = scopeLabel
        self.spentDollars = spentDollars
        self.limitDollars = limitDollars
        self.remainingDollars = computedRemaining
        self.remainingPercent = computedPercent
        self.resetsLabel = resetsLabel
        self.isReached = isReached || (limitDollars > 0 && computedRemaining <= 0)
        self.isLow = isLow
    }
}

/// Live runtime diagnostic snapshot displayed in `/debug`.
public struct TUIDebugSnapshot: Equatable, Hashable, Sendable {
    public let serverURL: String
    public let serverVersion: String
    public let sessionID: String?
    public let sseConnected: Bool
    public let sseReconnecting: Bool
    public let terminalCols: Int
    public let terminalRows: Int
    public let themeName: String
    public let themeMode: ThemeMode
    public let kittyKeyboardFlags: Int
    public let providersCount: Int
    public let modelsCount: Int
    public let agentsCount: Int
    public let commandsCount: Int
    public let skillsCount: Int
    public let toolsCount: Int

    public init(
        serverURL: String,
        serverVersion: String,
        sessionID: String? = nil,
        sseConnected: Bool = true,
        sseReconnecting: Bool = false,
        terminalCols: Int = 100,
        terminalRows: Int = 34,
        themeName: String = "opencode",
        themeMode: ThemeMode = .dark,
        kittyKeyboardFlags: Int = 0,
        providersCount: Int = 0,
        modelsCount: Int = 0,
        agentsCount: Int = 0,
        commandsCount: Int = 0,
        skillsCount: Int = 0,
        toolsCount: Int = 0
    ) {
        self.serverURL = serverURL
        self.serverVersion = serverVersion
        self.sessionID = sessionID
        self.sseConnected = sseConnected
        self.sseReconnecting = sseReconnecting
        self.terminalCols = terminalCols
        self.terminalRows = terminalRows
        self.themeName = themeName
        self.themeMode = themeMode
        self.kittyKeyboardFlags = kittyKeyboardFlags
        self.providersCount = providersCount
        self.modelsCount = modelsCount
        self.agentsCount = agentsCount
        self.commandsCount = commandsCount
        self.skillsCount = skillsCount
        self.toolsCount = toolsCount
    }
}

/// Todo item lifecycle status rendered in the Session Sidebar checklist.
public enum TUITodoStatus: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled

    public var marker: String {
        switch self {
        case .completed: return "[✓]"
        case .inProgress: return "[◐]"
        case .pending: return "[ ]"
        case .cancelled: return "[-]"
        }
    }
}

/// Single task entry displayed in the Session Sidebar Todo section.
public struct TUITodoItem: Equatable, Hashable, Sendable {
    public let id: String
    public let content: String
    public let status: TUITodoStatus
    public let priority: String?

    public init(
        id: String = "",
        content: String,
        status: TUITodoStatus = .pending,
        priority: String? = nil
    ) {
        self.id = id
        self.content = content
        self.status = status
        self.priority = priority
    }

    public init(from todo: TUIUtil.Todo, id: String = "") {
        self.id = id.isEmpty ? todo.content : id
        self.content = todo.content
        self.status = TUITodoStatus(rawValue: todo.status.rawValue) ?? .pending
        self.priority = nil
    }
}

// MARK: - Declarative Session Overlay & Dialog Builders

/// Production declarative OpenTUI view builders for interactive session prompts,
/// diff viewer, modal info/action dialogs, reconnecting banner, and sidebar todo checklist,
/// matching upstream OpenCode 2.3.2 (`routes/session/permission.tsx`, `routes/session/form.tsx`,
/// `feature-plugins/system/diff-viewer.tsx`, `component/dialog-pair.tsx`,
/// `component/dialog-status.tsx`, `component/usage.tsx`, `component/dialog-debug.tsx`,
/// `ui/dialog-help.tsx`, `component/dialog-session-rename.tsx`, `component/reconnecting.tsx`,
/// `feature-plugins/sidebar/todo.tsx`).
public enum TUISessionOverlays {
    private static let backdropColor = RGBA.fromInts(0, 0, 0, 140)
    private static let reconnectingBackdropColor = RGBA.fromInts(0, 0, 0, 120)
    private static let spinnerFrames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    // MARK: - 1. Interactive Permission Prompt (`routes/session/permission.tsx`)

    public static func buildPermissionPrompt(
        request: TUIPendingPermissionItem,
        state: TUIPermissionPromptState,
        theme: ResolvedTheme,
        syntaxStyle: SyntaxStyle,
        columnWidth: Int,
        onRejectInput: @escaping @Sendable (String) -> Void = { _ in },
        onRejectSubmit: @escaping @Sendable (String) -> Void = { _ in }
    ) -> AnyTUIView {
        let panelBg = theme.background.raised.base
        let footerBg = theme.decrease(panelBg)
        let innerWidth = max(20, columnWidth - 5)

        if state.isRejectingWithFeedback {
            let errorAccent = theme.text.feedback.error.base
            return AnyTUIView(
                TUIBox(
                    border: .sides([.left]),
                    borderColor: .rgba(errorAccent),
                    backgroundColor: .rgba(panelBg),
                    shouldFill: true,
                    customBorderChars: TUIScreens.splitBorderChars
                ) {
                    VStack(spacing: 0) {
                        VStack(spacing: 1) {
                            HStack(spacing: 1) {
                                TUIText("△", fg: .rgba(errorAccent), bg: .rgba(panelBg), wrapMode: TextWrapMode.none)
                                TUIText(
                                    "Reject permission: \(request.permission)",
                                    fg: .rgba(theme.text.base),
                                    bg: .rgba(panelBg),
                                    attributes: TextAttributes.bold,
                                    wrapMode: .word
                                )
                            }
                            .width(.percent(100))

                            TUIText(
                                "Tell OpenCode what to do differently",
                                fg: .rgba(theme.text.muted),
                                bg: .rgba(panelBg),
                                wrapMode: .word
                            )
                            .width(.percent(100))
                        }
                        .padding(top: 1, right: 2, bottom: 1, left: 2)
                        .width(.percent(100))

                        TUIBox(
                            border: false,
                            backgroundColor: .rgba(footerBg),
                            shouldFill: true
                        ) {
                            VStack(spacing: 1) {
                                TUIInput(
                                    value: state.rejectFeedback,
                                    placeholder: "Tell the model what to do instead…",
                                    placeholderColor: .rgba(theme.text.muted),
                                    maxLength: 2000,
                                    textColor: .rgba(theme.text.base),
                                    backgroundColor: .rgba(footerBg),
                                    focusedTextColor: .rgba(theme.text.base),
                                    focusedBackgroundColor: .rgba(footerBg),
                                    showCursor: true,
                                    cursorColor: .rgba(theme.text.base),
                                    onInput: onRejectInput,
                                    onSubmit: onRejectSubmit
                                )
                                .key("permission-reject-input-\(request.id)")
                                .id("permission-reject-input")
                                .width(.percent(100))
                                .focused(true)

                                TUIText(
                                    StyledText(chunks: [
                                        TextChunk(text: "enter ", fg: theme.text.base, bg: footerBg),
                                        TextChunk(text: "reject with feedback", fg: theme.text.muted, bg: footerBg),
                                        TextChunk(text: "  esc ", fg: theme.text.base, bg: footerBg),
                                        TextChunk(text: "back", fg: theme.text.muted, bg: footerBg),
                                    ]),
                                    bg: .rgba(footerBg),
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                            }
                            .width(.percent(100))
                        }
                        .padding(top: 1, right: 2, bottom: 1, left: 2)
                        .width(.percent(100))
                    }
                    .width(.percent(100))
                }
                .id("opencode-permission-prompt")
                .width(.percent(100))
                .flexShrink(0)
            )
        }

        let warningAccent = theme.text.feedback.warning.base
        let sideBySideFooter = columnWidth >= 90

        let actionPills = HStack(spacing: 1, alignment: .center) {
            for option in TUIPermissionOption.allCases {
                let isSelected = (state.selectedOption == option)
                let pillBg = isSelected
                    ? theme.background.action.primary.focused
                    : theme.background.action.primary.base
                let pillFg = isSelected
                    ? theme.text.action.primary.focused
                    : theme.text.action.primary.base

                TUIBox(
                    border: false,
                    backgroundColor: .rgba(pillBg),
                    shouldFill: true
                ) {
                    TUIText(
                        option.label,
                        fg: .rgba(pillFg),
                        bg: .rgba(pillBg),
                        attributes: isSelected ? TextAttributes.bold : TextAttributes.none,
                        wrapMode: TextWrapMode.none
                    )
                }
                .key("perm-opt-\(option.replyDecision)")
                .id("perm-opt-\(option.replyDecision)")
                .padding(right: 1, left: 1)
                .flexShrink(0)
            }
        }
        .flexShrink(0)

        let footerHint = TUIText(
            StyledText(chunks: [
                TextChunk(text: "←/→ ", fg: theme.text.base, bg: footerBg),
                TextChunk(text: "select", fg: theme.text.muted, bg: footerBg),
                TextChunk(text: "  enter ", fg: theme.text.base, bg: footerBg),
                TextChunk(text: "confirm", fg: theme.text.muted, bg: footerBg),
                TextChunk(text: "  a ", fg: theme.text.base, bg: footerBg),
                TextChunk(text: "always", fg: theme.text.muted, bg: footerBg),
                TextChunk(text: "  r ", fg: theme.text.base, bg: footerBg),
                TextChunk(text: "reject", fg: theme.text.muted, bg: footerBg),
            ]),
            bg: .rgba(footerBg),
            wrapMode: TextWrapMode.none,
            truncate: true
        )
        .flexShrink(0)

        return AnyTUIView(
            TUIBox(
                border: .sides([.left]),
                borderColor: .rgba(warningAccent),
                backgroundColor: .rgba(panelBg),
                shouldFill: true,
                customBorderChars: TUIScreens.splitBorderChars
            ) {
                VStack(spacing: 0) {
                    VStack(spacing: 1) {
                        // Header row
                        VStack(spacing: 0) {
                            HStack(spacing: 1) {
                                TUIText("△", fg: .rgba(warningAccent), bg: .rgba(panelBg), wrapMode: TextWrapMode.none)
                                TUIText(
                                    "Permission required: \(request.permission)",
                                    fg: .rgba(theme.text.base),
                                    bg: .rgba(panelBg),
                                    attributes: TextAttributes.bold,
                                    wrapMode: .word
                                )
                            }
                            .width(.percent(100))

                            if let toolOrPath = permissionSubtitle(for: request) {
                                TUIText(
                                    TUIUtil.truncateWidth(toolOrPath, innerWidth),
                                    fg: .rgba(theme.text.muted),
                                    bg: .rgba(panelBg),
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                                .padding(left: 2)
                                .width(.percent(100))
                            }
                        }
                        .width(.percent(100))

                        // Always-allow scope note when `.always` is highlighted
                        if state.selectedOption == .always && !request.alwaysPatterns.isEmpty {
                            VStack(spacing: 0) {
                                TUIText(
                                    "Always allow:",
                                    fg: .rgba(theme.text.muted),
                                    bg: .rgba(panelBg),
                                    wrapMode: TextWrapMode.none
                                )
                                for (idx, pat) in request.alwaysPatterns.prefix(4).enumerated() {
                                    TUIText(
                                        "  \(pat)",
                                        fg: .rgba(theme.text.base),
                                        bg: .rgba(panelBg),
                                        wrapMode: .word
                                    )
                                    .key("perm-always-\(idx)")
                                    .width(.percent(100))
                                }
                            }
                            .width(.percent(100))
                        }

                        // Resource patterns
                        if !request.patterns.isEmpty {
                            VStack(spacing: 0) {
                                for (idx, pat) in request.patterns.prefix(5).enumerated() {
                                    TUIText(
                                        pat,
                                        fg: .rgba(theme.text.muted),
                                        bg: .rgba(panelBg),
                                        wrapMode: .word
                                    )
                                    .key("perm-pattern-\(idx)")
                                    .padding(left: 2)
                                    .width(.percent(100))
                                }
                            }
                            .width(.percent(100))
                        }

                        // Optional command preview
                        if let cmd = request.commandPreview, !cmd.isEmpty {
                            TUIBox(
                                border: false,
                                backgroundColor: .rgba(footerBg),
                                shouldFill: true
                            ) {
                                TUIText(
                                    "$ \(cmd)",
                                    fg: .rgba(theme.text.base),
                                    bg: .rgba(footerBg),
                                    wrapMode: .word
                                )
                                .width(.percent(100))
                            }
                            .id("permission-command-preview")
                            .padding(right: 1, left: 1)
                            .width(.percent(100))
                        }

                        // Optional inline syntax-highlighted diff preview
                        if let patch = request.diffPatch, !patch.isEmpty {
                            let patchLineCount = patch.split(separator: "\n", omittingEmptySubsequences: false).count
                            let previewHeight = min(8, max(3, patchLineCount))
                            let diffMode: DiffViewMode = columnWidth >= 110 ? .split : .unified
                            TUIScrollBox(
                                scrollX: false,
                                scrollY: true,
                                viewportCulling: false,
                                showVerticalScrollbar: false,
                                showHorizontalScrollbar: false,
                                border: false,
                                backgroundColor: .rgba(theme.diff.background.context)
                            ) {
                                TUIDiff(
                                    patch,
                                    view: diffMode,
                                    filetype: TUIUtil.filetype(request.filePath),
                                    syntaxStyle: syntaxStyle,
                                    showLineNumbers: true,
                                    wrapMode: .word
                                )
                                .key("permission-diff-\(request.id)")
                                .id("permission-diff-preview")
                                .width(.percent(100))
                                .height(max(previewHeight, patchLineCount))
                            }
                            .width(.percent(100))
                            .height(previewHeight)
                        }
                    }
                    .padding(top: 1, right: 2, bottom: 1, left: 2)
                    .width(.percent(100))

                    // Bottom action pill bar & keybind hints
                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(footerBg),
                        shouldFill: true
                    ) {
                        if sideBySideFooter {
                            HStack(spacing: 2, alignment: .center) {
                                actionPills
                                TUISpacer()
                                footerHint
                            }
                            .width(.percent(100))
                        } else {
                            VStack(spacing: 1, alignment: .flexStart) {
                                actionPills
                                footerHint
                            }
                            .width(.percent(100))
                        }
                    }
                    .padding(top: 1, right: 2, bottom: 1, left: 2)
                    .width(.percent(100))
                }
                .width(.percent(100))
            }
            .id("opencode-permission-prompt")
            .width(.percent(100))
            .flexShrink(0)
        )
    }

    // MARK: - 2. Interactive Form / Question Prompt (`routes/session/form.tsx`)

    public static func buildFormPrompt(
        form: TUIPendingFormItem,
        state: TUIFormPromptState,
        theme: ResolvedTheme,
        columnWidth: Int,
        onTextInput: @escaping @Sendable (String) -> Void = { _ in },
        onTextSubmit: @escaping @Sendable (String) -> Void = { _ in }
    ) -> AnyTUIView {
        let panelBg = theme.background.raised.base
        let inputBg = theme.decrease(panelBg)
        let accentBorder = theme.background.action.primary.focused
        let singleImmediate = state.isSingleFieldImmediate(form: form)
        let onReview = state.isOnReviewTab(form: form)
        let innerWidth = max(20, columnWidth - 6)

        return AnyTUIView(
            TUIBox(
                border: .sides([.left]),
                borderColor: .rgba(accentBorder),
                backgroundColor: .rgba(panelBg),
                shouldFill: true,
                customBorderChars: TUIScreens.splitBorderChars
            ) {
                VStack(spacing: 1) {
                    // Optional form title & introductory message
                    if let title = form.title, !title.isEmpty {
                        TUIText(
                            title,
                            fg: .rgba(theme.text.muted),
                            bg: .rgba(panelBg),
                            attributes: TextAttributes.bold,
                            wrapMode: .word
                        )
                        .width(.percent(100))
                    }
                    if let message = form.message, !message.isEmpty {
                        TUIText(
                            message,
                            fg: .rgba(theme.text.base),
                            bg: .rgba(panelBg),
                            wrapMode: .word
                        )
                        .width(.percent(100))
                    }

                    // Question tab strip + Submit review tab (when >1 field or multi-step)
                    if !singleImmediate && !form.fields.isEmpty {
                        buildFormTabStrip(form: form, state: state, theme: theme, panelBg: panelBg)
                    }

                    // Active body: Review tab OR current field
                    if onReview {
                        buildFormReviewBody(form: form, state: state, theme: theme, panelBg: panelBg)
                    } else if let field = state.activeField(in: form) {
                        buildFormFieldBody(
                            field: field,
                            state: state,
                            theme: theme,
                            panelBg: panelBg,
                            inputBg: inputBg,
                            innerWidth: innerWidth,
                            onTextInput: onTextInput,
                            onTextSubmit: onTextSubmit
                        )
                    }

                    // Validation error line
                    if let error = state.errorMessage, !error.isEmpty {
                        TUIText(
                            error,
                            fg: .rgba(theme.text.feedback.error.base),
                            bg: .rgba(panelBg),
                            wrapMode: .word
                        )
                        .id("form-error-message")
                        .width(.percent(100))
                    }

                    // Footer hints
                    TUIText(
                        StyledText(chunks: [
                            TextChunk(text: "↑↓ ", fg: theme.text.base, bg: panelBg),
                            TextChunk(text: "select", fg: theme.text.muted, bg: panelBg),
                            TextChunk(text: "  enter ", fg: theme.text.base, bg: panelBg),
                            TextChunk(text: onReview ? "submit" : "confirm", fg: theme.text.muted, bg: panelBg),
                            TextChunk(text: "  tab ", fg: theme.text.base, bg: panelBg),
                            TextChunk(text: "next", fg: theme.text.muted, bg: panelBg),
                            TextChunk(text: "  esc ", fg: theme.text.base, bg: panelBg),
                            TextChunk(text: "dismiss", fg: theme.text.muted, bg: panelBg),
                        ]),
                        bg: .rgba(panelBg),
                        wrapMode: TextWrapMode.none,
                        truncate: true
                    )
                    .width(.percent(100))
                }
                .padding(top: 1, right: 2, bottom: 1, left: 2)
                .width(.percent(100))
            }
            .id("opencode-form-prompt")
            .width(.percent(100))
            .flexShrink(0)
        )
    }

    private static func buildFormTabStrip(
        form: TUIPendingFormItem,
        state: TUIFormPromptState,
        theme: ResolvedTheme,
        panelBg: RGBA
    ) -> AnyTUIView {
        let onReview = state.isOnReviewTab(form: form)
        var chunks: [TextChunk] = []
        for (idx, field) in form.fields.enumerated() {
            if idx > 0 {
                chunks.append(TextChunk(text: "  ", fg: theme.text.muted, bg: panelBg))
            }
            let isActive = (!onReview && idx == state.activeFieldIndex)
            let answered = (state.encodedAnswer(for: field) != nil)
            let label = TUIUtil.truncateWidth(field.label, 22)
            let marker = answered ? "✓ " : ""
            chunks.append(TextChunk(
                text: "\(marker)\(label)",
                fg: isActive ? theme.text.base : (answered ? theme.text.formfield.selected : theme.text.muted),
                bg: panelBg,
                attributes: isActive ? TextAttributes.bold : TextAttributes.none
            ))
        }
        chunks.append(TextChunk(text: "  ", fg: theme.text.muted, bg: panelBg))
        chunks.append(TextChunk(
            text: "Submit",
            fg: onReview ? theme.text.base : theme.text.muted,
            bg: panelBg,
            attributes: onReview ? TextAttributes.bold : TextAttributes.none
        ))

        return AnyTUIView(
            TUIText(StyledText(chunks: chunks), bg: .rgba(panelBg), wrapMode: TextWrapMode.none, truncate: true)
                .id("form-tab-strip")
                .width(.percent(100))
        )
    }

    private static func buildFormReviewBody(
        form: TUIPendingFormItem,
        state: TUIFormPromptState,
        theme: ResolvedTheme,
        panelBg: RGBA
    ) -> AnyTUIView {
        return AnyTUIView(
            VStack(spacing: 0) {
                for field in form.fields {
                    let display = state.displayAnswer(for: field)
                    let missingRequired = (display == nil && field.required)
                    let valueText = display ?? (missingRequired ? "(required)" : "(not answered)")
                    let valueColor: RGBA = missingRequired
                        ? theme.text.feedback.error.base
                        : (display != nil ? theme.text.base : theme.text.muted)

                    TUIText(
                        StyledText(chunks: [
                            TextChunk(text: "\(field.label): ", fg: theme.text.muted, bg: panelBg),
                            TextChunk(text: valueText, fg: valueColor, bg: panelBg),
                        ]),
                        bg: .rgba(panelBg),
                        wrapMode: .word
                    )
                    .key("form-review-\(field.key)")
                    .width(.percent(100))
                }
            }
            .id("form-review-body")
            .width(.percent(100))
        )
    }

    private static func buildFormFieldBody(
        field: TUIFormFieldItem,
        state: TUIFormPromptState,
        theme: ResolvedTheme,
        panelBg: RGBA,
        inputBg: RGBA,
        innerWidth: Int,
        onTextInput: @escaping @Sendable (String) -> Void,
        onTextSubmit: @escaping @Sendable (String) -> Void
    ) -> AnyTUIView {
        let promptHeading = field.description ?? field.label

        switch field.kind {
        case .text(let placeholder):
            return AnyTUIView(
                VStack(spacing: 1) {
                    TUIText(
                        promptHeading,
                        fg: .rgba(theme.text.base),
                        bg: .rgba(panelBg),
                        wrapMode: .word
                    )
                    .width(.percent(100))

                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(inputBg),
                        shouldFill: true
                    ) {
                        TUIInput(
                            value: state.customText,
                            placeholder: placeholder ?? "Type your answer…",
                            placeholderColor: .rgba(theme.text.muted),
                            maxLength: 2000,
                            textColor: .rgba(theme.text.base),
                            backgroundColor: .rgba(inputBg),
                            focusedTextColor: .rgba(theme.text.formfield.focused),
                            focusedBackgroundColor: .rgba(inputBg),
                            showCursor: true,
                            cursorColor: .rgba(theme.text.formfield.focused),
                            onInput: onTextInput,
                            onSubmit: onTextSubmit
                        )
                        .key("form-text-input-\(field.key)")
                        .id("form-text-input")
                        .width(.percent(100))
                        .focused(true)
                    }
                    .padding(right: 1, left: 1)
                    .width(.percent(100))
                }
                .width(.percent(100))
            )

        case .singleSelect, .multiSelect, .boolean:
            let isMulti: Bool
            if case .multiSelect = field.kind { isMulti = true } else { isMulti = false }
            let options = TUIFormPromptState.optionRows(for: field)
            let isCustomActive = field.allowCustom && state.selectedRowIndex == options.count

            return AnyTUIView(
                VStack(spacing: 1) {
                    TUIText(
                        promptHeading,
                        fg: .rgba(theme.text.base),
                        bg: .rgba(panelBg),
                        wrapMode: .word
                    )
                    .width(.percent(100))

                    VStack(spacing: 0) {
                        for (idx, option) in options.enumerated() {
                            let isFocusedRow = (idx == state.selectedRowIndex)
                            let isPicked = state.isOptionSelected(option.value, for: field)
                            let marker: String = isMulti
                                ? (isPicked ? "☑" : "☐")
                                : (isPicked ? "●" : "○")
                            let markerColor: RGBA = isFocusedRow
                                ? theme.text.formfield.focused
                                : (isPicked ? theme.text.formfield.selected : theme.text.muted)
                            let labelColor: RGBA = isFocusedRow
                                ? theme.text.formfield.focused
                                : theme.text.formfield.base

                            VStack(spacing: 0) {
                                TUIText(
                                    StyledText(chunks: [
                                        TextChunk(text: "\(marker) ", fg: markerColor, bg: panelBg),
                                        TextChunk(
                                            text: TUIUtil.truncateWidth(option.label, max(10, innerWidth - 4)),
                                            fg: labelColor,
                                            bg: panelBg,
                                            attributes: isFocusedRow ? TextAttributes.bold : TextAttributes.none
                                        ),
                                    ]),
                                    bg: .rgba(panelBg),
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                                .width(.percent(100))

                                if let desc = option.description, !desc.isEmpty {
                                    TUIText(
                                        desc,
                                        fg: .rgba(theme.text.muted),
                                        bg: .rgba(panelBg),
                                        wrapMode: .word
                                    )
                                    .padding(left: 2)
                                    .width(.percent(100))
                                }
                            }
                            .key("form-opt-\(field.key)-\(idx)")
                            .width(.percent(100))
                        }

                        if field.allowCustom {
                            let trimmedCustom = trimWhitespace(state.customText)
                            let customHasValue = !trimmedCustom.isEmpty
                            let customPicked = customHasValue && state.isOptionSelected(trimmedCustom, for: field)
                            let customMarker: String = isMulti
                                ? (customPicked ? "☑" : "☐")
                                : (customPicked ? "●" : "○")
                            let markerColor: RGBA = isCustomActive
                                ? theme.text.formfield.focused
                                : (customPicked ? theme.text.formfield.selected : theme.text.muted)

                            if state.editingCustom {
                                HStack(spacing: 1, alignment: .center) {
                                    TUIText(customMarker, fg: .rgba(markerColor), bg: .rgba(panelBg), wrapMode: TextWrapMode.none)
                                        .flexShrink(0)
                                    TUIBox(
                                        border: false,
                                        backgroundColor: .rgba(inputBg),
                                        shouldFill: true
                                    ) {
                                        TUIInput(
                                            value: state.customText,
                                            placeholder: "Type your own answer…",
                                            placeholderColor: .rgba(theme.text.muted),
                                            maxLength: 1000,
                                            textColor: .rgba(theme.text.formfield.focused),
                                            backgroundColor: .rgba(inputBg),
                                            focusedTextColor: .rgba(theme.text.formfield.focused),
                                            focusedBackgroundColor: .rgba(inputBg),
                                            showCursor: true,
                                            cursorColor: .rgba(theme.text.formfield.focused),
                                            onInput: onTextInput,
                                            onSubmit: onTextSubmit
                                        )
                                        .key("form-custom-input-\(field.key)")
                                        .id("form-custom-input")
                                        .width(.percent(100))
                                        .focused(true)
                                    }
                                    .padding(right: 1, left: 1)
                                    .flexGrow(1)
                                }
                                .width(.percent(100))
                            } else {
                                let labelText = customHasValue ? state.customText : "Type your own answer"
                                TUIText(
                                    StyledText(chunks: [
                                        TextChunk(text: "\(customMarker) ", fg: markerColor, bg: panelBg),
                                        TextChunk(
                                            text: labelText,
                                            fg: isCustomActive ? theme.text.formfield.focused : theme.text.muted,
                                            bg: panelBg,
                                            attributes: isCustomActive ? TextAttributes.bold : TextAttributes.none
                                        ),
                                    ]),
                                    bg: .rgba(panelBg),
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                                .key("form-custom-row-\(field.key)")
                                .width(.percent(100))
                            }
                        }
                    }
                    .width(.percent(100))
                }
                .width(.percent(100))
            )
        }
    }

    // MARK: - 3. Full Diff Viewer Overlay (`feature-plugins/system/diff-viewer.tsx`)

    public static func buildDiffViewerOverlay(
        state: TUIDiffViewerState,
        cols: Int,
        rows: Int,
        theme: ResolvedTheme,
        syntaxStyle: SyntaxStyle,
        onClose: @escaping @Sendable () -> Void = {}
    ) -> AnyTUIView {
        let dialogTheme = state.fullscreen ? theme : theme.surface(.dialog)
        let cardBg = state.fullscreen ? theme.background.base : dialogTheme.background.base
        let sidebarBg = state.fullscreen ? theme.background.raised.base : dialogTheme.decrease(cardBg)
        let modalWidth = state.fullscreen ? max(40, cols) : min(max(44, cols - 6), max(40, cols))
        let modalHeight = state.fullscreen ? max(12, rows) : min(max(14, rows - 4), max(12, rows))
        let topPad = state.fullscreen ? 0 : max(1, (rows - modalHeight) / 2)

        let showTree = state.showFileTree && !state.files.isEmpty && modalWidth >= 60
        let treeWidth = showTree ? min(32, max(20, modalWidth / 4)) : 0
        let modeBadge = state.splitView ? "split" : "unified"
        let fileCountText = "\(state.files.count) \(state.files.count == 1 ? "file" : "files")"
        let totalAdd = state.totalAdditions
        let totalDel = state.totalDeletions
        let bodyHeight = max(4, modalHeight - (state.fullscreen ? 4 : 6))
        let patchViewportHeight = max(3, bodyHeight - 2)

        let cardContent = TUIBox(
            border: false,
            backgroundColor: .rgba(cardBg),
            shouldFill: true
        ) {
            VStack(spacing: 1) {
                // Header row
                HStack(spacing: 2, alignment: .center) {
                    TUIText(
                        StyledText(chunks: [
                            TextChunk(text: state.title, fg: dialogTheme.text.base, bg: cardBg, attributes: TextAttributes.bold),
                            TextChunk(text: "  \(fileCountText)", fg: dialogTheme.text.muted, bg: cardBg),
                            TextChunk(text: "  +\(totalAdd)", fg: dialogTheme.diff.text.added, bg: cardBg),
                            TextChunk(text: " -\(totalDel)", fg: dialogTheme.diff.text.removed, bg: cardBg),
                        ]),
                        bg: .rgba(cardBg),
                        wrapMode: TextWrapMode.none,
                        truncate: true
                    )
                    .flexShrink(1)

                    TUISpacer()

                    TUIBox(
                        border: false,
                        backgroundColor: .rgba(dialogTheme.background.action.primary.base),
                        shouldFill: true
                    ) {
                        TUIText(
                            modeBadge,
                            fg: .rgba(dialogTheme.text.action.primary.base),
                            bg: .rgba(dialogTheme.background.action.primary.base),
                            wrapMode: TextWrapMode.none
                        )
                    }
                    .id("diff-viewer-mode-badge")
                    .padding(right: 1, left: 1)
                    .flexShrink(0)

                    TUIText("esc", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg), wrapMode: TextWrapMode.none)
                        .flexShrink(0)
                        .onMouseUp { _ in onClose() }
                }
                .id("diff-viewer-header")
                .width(.percent(100))
                .height(1)
                .flexShrink(0)

                // Body: optional file tree sidebar + scrollable TUIDiff pane
                HStack(spacing: 1) {
                    if showTree {
                        buildDiffFileTreeSidebar(
                            state: state,
                            width: treeWidth,
                            height: bodyHeight,
                            theme: dialogTheme,
                            sidebarBg: sidebarBg
                        )
                    }

                    VStack(spacing: 0) {
                        if let file = state.selectedFile {
                            let filePathBudget = max(12, modalWidth - treeWidth - 22)
                            HStack(spacing: 1, alignment: .center) {
                                TUIText(
                                    StyledText(chunks: [
                                        TextChunk(
                                            text: diffStatusGlyph(file.status) + " ",
                                            fg: diffStatusColor(file.status, theme: dialogTheme),
                                            bg: sidebarBg,
                                            attributes: TextAttributes.bold
                                        ),
                                        TextChunk(
                                            text: TUIUtil.truncateLeft(file.path, filePathBudget),
                                            fg: dialogTheme.text.base,
                                            bg: sidebarBg,
                                            attributes: TextAttributes.bold
                                        ),
                                    ]),
                                    bg: .rgba(sidebarBg),
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                                .flexGrow(1)

                                TUIText(
                                    StyledText(chunks: [
                                        TextChunk(text: "+\(file.additions)", fg: dialogTheme.diff.text.added, bg: sidebarBg),
                                        TextChunk(text: " -\(file.deletions)", fg: dialogTheme.diff.text.removed, bg: sidebarBg),
                                    ]),
                                    bg: .rgba(sidebarBg),
                                    wrapMode: TextWrapMode.none
                                )
                                .flexShrink(0)
                            }
                            .background(.rgba(sidebarBg))
                            .padding(right: 1, left: 1)
                            .width(.percent(100))
                            .height(1)
                            .flexShrink(0)

                            if file.patch.isEmpty {
                                TUIBox(
                                    border: false,
                                    backgroundColor: .rgba(dialogTheme.diff.background.context),
                                    shouldFill: true
                                ) {
                                    TUIText(
                                        "No patch content for this file.",
                                        fg: .rgba(dialogTheme.text.muted),
                                        bg: .rgba(dialogTheme.diff.background.context),
                                        attributes: TextAttributes.italic
                                    )
                                }
                                .alignItems(.center)
                                .justifyContent(.center)
                                .width(.percent(100))
                                .height(patchViewportHeight)
                                .flexGrow(1)
                            } else {
                                let patchLineCount = max(
                                    3,
                                    file.patch.split(separator: "\n", omittingEmptySubsequences: false).count
                                )
                                TUIScrollBox(
                                    scrollX: false,
                                    scrollY: true,
                                    viewportCulling: false,
                                    showVerticalScrollbar: true,
                                    showHorizontalScrollbar: false,
                                    border: false,
                                    backgroundColor: .rgba(dialogTheme.diff.background.context),
                                    verticalScrollbarOptions: ScrollBarOptions(
                                        trackOptions: ScrollBarTrackStyleOptions(
                                            foregroundColor: .rgba(dialogTheme.scrollbar.base),
                                            backgroundColor: .rgba(cardBg)
                                        )
                                    )
                                ) {
                                    TUIDiff(
                                        file.patch,
                                        view: state.splitView ? .split : .unified,
                                        filetype: TUIUtil.filetype(file.path),
                                        syntaxStyle: syntaxStyle,
                                        showLineNumbers: true,
                                        wrapMode: state.wrapLines ? .word : TextWrapMode.none
                                    )
                                    .key("diff-viewer-patch-\(state.selectedFileIndex)-\(modeBadge)")
                                    .id("diff-viewer-patch")
                                    .width(.percent(100))
                                    .height(max(patchViewportHeight, patchLineCount))
                                }
                                .id("diff-viewer-scrollbox")
                                .width(.percent(100))
                                .height(patchViewportHeight)
                                .flexGrow(1)
                            }
                        } else {
                            TUIBox(border: false, backgroundColor: .rgba(cardBg), shouldFill: true) {
                                TUIText(
                                    "No changes to display.",
                                    fg: .rgba(dialogTheme.text.muted),
                                    bg: .rgba(cardBg),
                                    attributes: TextAttributes.italic
                                )
                            }
                            .alignItems(.center)
                            .justifyContent(.center)
                            .width(.percent(100))
                            .height(bodyHeight)
                        }
                    }
                    .flexGrow(1)
                    .minWidth(0)
                    .height(bodyHeight)
                }
                .width(.percent(100))
                .height(bodyHeight)
                .flexGrow(1)

                // Footer keybind bar
                TUIText(
                    StyledText(chunks: [
                        TextChunk(text: "n/p ", fg: dialogTheme.text.base, bg: cardBg),
                        TextChunk(text: "file", fg: dialogTheme.text.muted, bg: cardBg),
                        TextChunk(text: "  j/k ", fg: dialogTheme.text.base, bg: cardBg),
                        TextChunk(text: "scroll", fg: dialogTheme.text.muted, bg: cardBg),
                        TextChunk(text: "  v ", fg: dialogTheme.text.base, bg: cardBg),
                        TextChunk(text: "split/unified", fg: dialogTheme.text.muted, bg: cardBg),
                        TextChunk(text: "  b ", fg: dialogTheme.text.base, bg: cardBg),
                        TextChunk(text: "files", fg: dialogTheme.text.muted, bg: cardBg),
                        TextChunk(text: "  f ", fg: dialogTheme.text.base, bg: cardBg),
                        TextChunk(text: "fullscreen", fg: dialogTheme.text.muted, bg: cardBg),
                        TextChunk(text: "  q/esc ", fg: dialogTheme.text.base, bg: cardBg),
                        TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
                    ]),
                    bg: .rgba(cardBg),
                    wrapMode: TextWrapMode.none,
                    truncate: true
                )
                .id("diff-viewer-footer")
                .width(.percent(100))
                .height(1)
                .flexShrink(0)
            }
            .width(.percent(100))
            .height(.percent(100))
        }
        .id("opencode-diff-viewer-card")
        .padding(top: 1, right: 2, bottom: 1, left: 2)
        .width(modalWidth)
        .height(modalHeight)

        if state.fullscreen {
            return AnyTUIView(
                cardContent
                    .position(.absolute, top: 0, right: 0, bottom: 0, left: 0)
                    .zIndex(3200)
            )
        }

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(backdropColor),
                shouldFill: true
            ) {
                cardContent
            }
            .id("opencode-diff-viewer-backdrop")
            .position(.absolute, top: 0, right: 0, bottom: 0, left: 0)
            .alignItems(.center)
            .justifyContent(.flexStart)
            .padding(top: .point(Float(topPad)))
            .zIndex(3200)
        )
    }

    private static func buildDiffFileTreeSidebar(
        state: TUIDiffViewerState,
        width: Int,
        height: Int,
        theme: ResolvedTheme,
        sidebarBg: RGBA
    ) -> AnyTUIView {
        let selBg = theme.background.action.primary.focused
        let selFg = theme.text.action.primary.focused
        let nameBudget = max(8, width - 10)
        let clampedSelected = state.files.isEmpty ? 0 : min(max(0, state.selectedFileIndex), state.files.count - 1)

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(sidebarBg),
                shouldFill: true
            ) {
                VStack(spacing: 0) {
                    TUIText(
                        "Files (\(state.files.count))",
                        fg: .rgba(theme.text.muted),
                        bg: .rgba(sidebarBg),
                        attributes: TextAttributes.bold,
                        wrapMode: TextWrapMode.none
                    )
                    .padding(right: 1, bottom: 1, left: 1)

                    for (idx, file) in state.files.prefix(max(1, height - 2)).enumerated() {
                        let isSel = (idx == clampedSelected)
                        let rowBg = isSel ? selBg : sidebarBg
                        let nameFg = isSel ? selFg : theme.text.base
                        let statusFg = isSel ? selFg : diffStatusColor(file.status, theme: theme)
                        let addFg = isSel ? selFg : theme.diff.text.added
                        let delFg = isSel ? selFg : theme.diff.text.removed

                        TUIBox(
                            border: false,
                            backgroundColor: .rgba(rowBg),
                            shouldFill: true
                        ) {
                            HStack(spacing: 1) {
                                TUIText(
                                    StyledText(chunks: [
                                        TextChunk(text: diffStatusGlyph(file.status) + " ", fg: statusFg, bg: rowBg),
                                        TextChunk(
                                            text: TUIUtil.truncateLeft(file.path, nameBudget),
                                            fg: nameFg,
                                            bg: rowBg,
                                            attributes: isSel ? TextAttributes.bold : TextAttributes.none
                                        ),
                                    ]),
                                    bg: .rgba(rowBg),
                                    wrapMode: TextWrapMode.none,
                                    truncate: true
                                )
                                .flexGrow(1)

                                TUIText(
                                    StyledText(chunks: [
                                        TextChunk(text: "+\(file.additions)", fg: addFg, bg: rowBg),
                                        TextChunk(text: " -\(file.deletions)", fg: delFg, bg: rowBg),
                                    ]),
                                    bg: .rgba(rowBg),
                                    wrapMode: TextWrapMode.none
                                )
                                .flexShrink(0)
                            }
                            .padding(right: 1, left: 1)
                            .width(.percent(100))
                        }
                        .key("diff-file-row-\(idx)-\(file.path)")
                        .width(.percent(100))
                        .height(1)
                    }
                }
                .width(.percent(100))
                .height(.percent(100))
            }
            .id("diff-viewer-file-tree")
            .width(width)
            .height(height)
            .flexShrink(0)
        )
    }

    // MARK: - 4a. Pair Dialog Overlay with Real QR Code (`component/dialog-pair.tsx`)

    public static func buildPairDialogOverlay(
        info: TUIPairingInfo?,
        cols: Int,
        rows: Int,
        theme: ResolvedTheme,
        onClose: @escaping @Sendable () -> Void = {}
    ) -> AnyTUIView {
        let dialogTheme = theme.surface(.dialog)
        let cardBg = dialogTheme.background.base
        let horizontal = cols >= 96
        let cardWidth = horizontal
            ? min(86, max(66, cols - 6))
            : min(64, max(38, cols - 4))
        let topPad = max(1, min(rows / 6, 4))

        let bodyContent: AnyTUIView
        if let info {
            if let err = info.errorMessage, !err.isEmpty {
                bodyContent = AnyTUIView(
                    VStack(spacing: 1) {
                        TUIText(
                            "Could not load server information",
                            fg: .rgba(dialogTheme.text.feedback.error.base),
                            bg: .rgba(cardBg),
                            attributes: TextAttributes.bold,
                            wrapMode: .word
                        )
                        TUIText(err, fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg), wrapMode: .word)
                        TUIText(
                            "Close and reopen Pair to try again.",
                            fg: .rgba(dialogTheme.text.muted),
                            bg: .rgba(cardBg),
                            wrapMode: .word
                        )
                    }
                    .width(.percent(100))
                )
            } else {
                let qrTarget = info.links.first ?? info.localhostURL ?? ""
                let qrRendered = qrTarget.isEmpty ? nil : (try? QR.renderUnicodeCompact(qrTarget, border: 1))
                let qrLines = qrRendered?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []

                let linksColumn = VStack(spacing: 1) {
                    TUIText(
                        "Open a link to connect. Links work once and expire in \(info.expiresInMinutes) minutes.",
                        fg: .rgba(dialogTheme.text.muted),
                        bg: .rgba(cardBg),
                        wrapMode: .word
                    )
                    .width(.percent(100))

                    if let local = info.localhostURL, !local.isEmpty {
                        VStack(spacing: 0) {
                            TUIText("This device", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg))
                            TUIText(local, fg: .rgba(dialogTheme.text.base), bg: .rgba(cardBg), wrapMode: .word)
                                .width(.percent(100))
                        }
                        .width(.percent(100))
                    }

                    if !info.links.isEmpty {
                        VStack(spacing: 0) {
                            TUIText("Links", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg))
                            for (idx, link) in info.links.enumerated() {
                                TUIText(link, fg: .rgba(dialogTheme.text.base), bg: .rgba(cardBg), wrapMode: .word)
                                    .key("pair-link-\(idx)")
                                    .width(.percent(100))
                            }
                        }
                        .width(.percent(100))
                    }

                    if info.isLoopbackOnly {
                        TUIText(
                            "Run `opencode service set hostname 0.0.0.0` to access the service remotely.",
                            fg: .rgba(dialogTheme.text.muted),
                            bg: .rgba(cardBg),
                            wrapMode: .word
                        )
                        .width(.percent(100))
                    }
                }

                let qrColumn = VStack(spacing: 0, alignment: horizontal ? .flexEnd : .center) {
                    for (idx, line) in qrLines.enumerated() {
                        TUIText(
                            line,
                            fg: .rgba(dialogTheme.text.base),
                            bg: .rgba(cardBg),
                            wrapMode: TextWrapMode.none,
                            selectable: false
                        )
                        .key("pair-qr-line-\(idx)")
                    }
                }
                .id("pair-qr-code")
                .flexShrink(0)

                if horizontal {
                    bodyContent = AnyTUIView(
                        HStack(spacing: 2, alignment: .flexStart) {
                            linksColumn
                                .width(34)
                                .flexShrink(0)
                            TUISpacer()
                            if !qrLines.isEmpty {
                                qrColumn
                            }
                        }
                        .width(.percent(100))
                    )
                } else {
                    bodyContent = AnyTUIView(
                        VStack(spacing: 1, alignment: .center) {
                            linksColumn
                                .width(.percent(100))
                            if !qrLines.isEmpty {
                                qrColumn
                            }
                        }
                        .width(.percent(100))
                    )
                }
            }
        } else {
            bodyContent = AnyTUIView(
                TUIText(
                    "Loading server information…",
                    fg: .rgba(dialogTheme.text.muted),
                    bg: .rgba(cardBg)
                )
                .width(.percent(100))
            )
        }

        return buildModalDialogShell(
            id: "opencode-pair-dialog",
            title: "Pair",
            description: nil,
            closeLabel: "esc",
            cardWidth: cardWidth,
            topPad: topPad,
            dialogTheme: dialogTheme,
            footerChunks: [
                TextChunk(text: "esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ],
            onClose: onClose
        ) {
            bodyContent
        }
    }

    // MARK: - 4b. Status Dialog Overlay (`component/dialog-status.tsx`)

    public static func buildStatusDialogOverlay(
        snapshot: TUIStatusSnapshot,
        cols: Int,
        rows: Int,
        theme: ResolvedTheme,
        onClose: @escaping @Sendable () -> Void = {}
    ) -> AnyTUIView {
        let dialogTheme = theme.surface(.dialog)
        let cardBg = dialogTheme.background.base
        let cardWidth = min(68, max(40, cols - 4))
        let topPad = max(2, rows / 6)
        let versionDisplay = snapshot.serverVersion.hasPrefix("v")
            ? snapshot.serverVersion
            : "v\(snapshot.serverVersion)"
        let dirLine = snapshot.gitBranch.map { $0.isEmpty ? snapshot.directory : "\(snapshot.directory) (\($0))" }
            ?? snapshot.directory
        let providerSummary = snapshot.totalModelsCount > 0
            ? "\(snapshot.connectedProvidersCount) connected · \(snapshot.totalModelsCount) models"
            : "\(snapshot.connectedProvidersCount) connected"

        return buildModalDialogShell(
            id: "opencode-status-dialog",
            title: "Status",
            description: nil,
            closeLabel: "esc",
            cardWidth: cardWidth,
            topPad: topPad,
            dialogTheme: dialogTheme,
            footerChunks: [
                TextChunk(text: "esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ],
            onClose: onClose
        ) {
            VStack(spacing: 1) {
                VStack(spacing: 0) {
                    buildKeyValueRow(label: "Server", value: "\(snapshot.serverURL) (\(versionDisplay))", labelWidth: 12, theme: dialogTheme, bg: cardBg)
                    buildKeyValueRow(label: "Directory", value: dirLine, labelWidth: 12, theme: dialogTheme, bg: cardBg)
                    buildKeyValueRow(label: "Providers", value: providerSummary, labelWidth: 12, theme: dialogTheme, bg: cardBg)
                    buildKeyValueRow(
                        label: "Loaded",
                        value: "\(snapshot.skillsCount) skills · \(snapshot.commandsCount) commands",
                        labelWidth: 12,
                        theme: dialogTheme,
                        bg: cardBg
                    )
                }
                .width(.percent(100))

                VStack(spacing: 0) {
                    if snapshot.mcpServers.isEmpty {
                        TUIText("No MCP servers", fg: .rgba(dialogTheme.text.muted), bg: .rgba(cardBg))
                    } else {
                        let count = snapshot.mcpServers.count
                        TUIText(
                            "\(count) MCP server\(count == 1 ? "" : "s")",
                            fg: .rgba(dialogTheme.text.base),
                            bg: .rgba(cardBg),
                            attributes: TextAttributes.bold
                        )
                        for server in snapshot.mcpServers {
                            buildStatusMCPRow(server: server, theme: dialogTheme, bg: cardBg)
                        }
                    }
                }
                .width(.percent(100))
            }
            .width(.percent(100))
        }
    }

    // MARK: - 4c. Usage Dialog Overlay (`component/usage.tsx`)

    public static func buildUsageDialogOverlay(
        workspaceName: String? = nil,
        isSignedIn: Bool = true,
        limits: [TUIUsageLimitRow],
        selectedIndex: Int = 0,
        cols: Int,
        rows: Int,
        theme: ResolvedTheme,
        onClose: @escaping @Sendable () -> Void = {}
    ) -> AnyTUIView {
        let dialogTheme = theme.surface(.dialog)
        let cardBg = dialogTheme.background.base
        let cardWidth = min(70, max(42, cols - 4))
        let topPad = max(2, rows / 6)
        let description: String? = (isSignedIn && !(workspaceName ?? "").isEmpty)
            ? "Workspace: \(workspaceName!)"
            : nil
        let selBg = dialogTheme.background.action.primary.focused
        let selFg = dialogTheme.text.action.primary.focused
        let clampedSel = limits.isEmpty ? 0 : min(max(0, selectedIndex), limits.count - 1)

        var footerChunks: [TextChunk] = []
        if isSignedIn && !limits.isEmpty {
            footerChunks.append(TextChunk(text: "↑↓ ", fg: dialogTheme.text.base, bg: cardBg))
            footerChunks.append(TextChunk(text: "select   ", fg: dialogTheme.text.muted, bg: cardBg))
        }
        footerChunks.append(TextChunk(text: "esc ", fg: dialogTheme.text.base, bg: cardBg))
        footerChunks.append(TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg))

        return buildModalDialogShell(
            id: "opencode-usage-dialog",
            title: "Usage",
            description: description,
            closeLabel: "esc",
            cardWidth: cardWidth,
            topPad: topPad,
            dialogTheme: dialogTheme,
            footerChunks: footerChunks,
            onClose: onClose
        ) {
            if !isSignedIn {
                TUIText(
                    "Sign in to OpenCode Console with /connect to see your workspace's usage limits.",
                    fg: .rgba(dialogTheme.text.muted),
                    bg: .rgba(cardBg),
                    wrapMode: .word
                )
                .width(.percent(100))
            } else if limits.isEmpty {
                TUIText(
                    "No limits apply to your models. Paid models stop only if the workspace runs out of credits.",
                    fg: .rgba(dialogTheme.text.muted),
                    bg: .rgba(cardBg),
                    wrapMode: .word
                )
                .width(.percent(100))
            } else {
                VStack(spacing: 1) {
                    for (idx, row) in limits.enumerated() {
                        buildUsageLimitRowView(
                            row: row,
                            isSelected: idx == clampedSel,
                            dialogTheme: dialogTheme,
                            cardBg: cardBg,
                            selBg: selBg,
                            selFg: selFg
                        )
                    }
                }
                .width(.percent(100))
            }
        }
    }

    // MARK: - 4d. Debug Diagnostics Dialog Overlay (`component/dialog-debug.tsx`)

    public static func buildDebugDialogOverlay(
        snapshot: TUIDebugSnapshot,
        cols: Int,
        rows: Int,
        theme: ResolvedTheme,
        onClose: @escaping @Sendable () -> Void = {}
    ) -> AnyTUIView {
        let dialogTheme = theme.surface(.dialog)
        let cardBg = dialogTheme.background.base
        let cardWidth = min(72, max(44, cols - 4))
        let topPad = max(2, rows / 6)

        let sseLabel: String
        let sseColor: RGBA
        if snapshot.sseConnected {
            sseLabel = "Connected"
            sseColor = dialogTheme.text.feedback.success.base
        } else if snapshot.sseReconnecting {
            sseLabel = "Reconnecting…"
            sseColor = dialogTheme.text.feedback.warning.base
        } else {
            sseLabel = "Disconnected"
            sseColor = dialogTheme.text.feedback.error.base
        }

        let kittyLabel = snapshot.kittyKeyboardFlags > 0
            ? "enabled (flags=\(snapshot.kittyKeyboardFlags))"
            : "disabled (0)"

        return buildModalDialogShell(
            id: "opencode-debug-dialog",
            title: "Debug",
            description: "Share this when reporting an issue",
            closeLabel: "esc",
            cardWidth: cardWidth,
            topPad: topPad,
            dialogTheme: dialogTheme,
            footerChunks: [
                TextChunk(text: "c ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "copy   ", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ],
            onClose: onClose
        ) {
            VStack(spacing: 0) {
                buildKeyValueRow(label: "Server", value: snapshot.serverURL, labelWidth: 12, theme: dialogTheme, bg: cardBg)
                buildKeyValueRow(label: "Version", value: snapshot.serverVersion, labelWidth: 12, theme: dialogTheme, bg: cardBg)
                buildKeyValueRow(label: "Session ID", value: snapshot.sessionID ?? "n/a", labelWidth: 12, theme: dialogTheme, bg: cardBg)
                buildKeyValueRow(label: "SSE Stream", value: sseLabel, valueColor: sseColor, labelWidth: 12, theme: dialogTheme, bg: cardBg)
                buildKeyValueRow(label: "Terminal", value: "\(snapshot.terminalCols)×\(snapshot.terminalRows)", labelWidth: 12, theme: dialogTheme, bg: cardBg)
                buildKeyValueRow(label: "Theme", value: "\(snapshot.themeName) (\(snapshot.themeMode.rawValue))", labelWidth: 12, theme: dialogTheme, bg: cardBg)
                buildKeyValueRow(label: "Kitty Kbd", value: kittyLabel, labelWidth: 12, theme: dialogTheme, bg: cardBg)
                buildKeyValueRow(
                    label: "Catalog",
                    value: "\(snapshot.providersCount) providers · \(snapshot.modelsCount) models · \(snapshot.agentsCount) agents",
                    labelWidth: 12,
                    theme: dialogTheme,
                    bg: cardBg
                )
                buildKeyValueRow(
                    label: "Extensions",
                    value: "\(snapshot.commandsCount) commands · \(snapshot.skillsCount) skills · \(snapshot.toolsCount) tools",
                    labelWidth: 12,
                    theme: dialogTheme,
                    bg: cardBg
                )
            }
            .width(.percent(100))
        }
    }

    // MARK: - 4e. Help Reference Dialog Overlay (`ui/dialog-help.tsx`)

    public static func buildHelpDialogOverlay(
        cols: Int,
        rows: Int,
        theme: ResolvedTheme,
        onClose: @escaping @Sendable () -> Void = {}
    ) -> AnyTUIView {
        let dialogTheme = theme.surface(.dialog)
        let cardBg = dialogTheme.background.base
        let cardWidth = min(78, max(44, cols - 4))
        let topPad = max(1, min(rows / 8, 3))

        let shortcuts: [(String, String)] = [
            ("Ctrl+P / Cmd+P", "Open command palette"),
            ("Ctrl+A / Cmd+A", "Connect provider / select agent"),
            ("Ctrl+X <key>", "Leader chords (m models, a agents, l sessions, b sidebar)"),
            ("Shift+Tab", "Cycle active agent"),
            ("F2", "Cycle recent model"),
            ("Ctrl+T / Ctrl+B", "Toggle Light/Dark mode · Toggle sidebar"),
        ]

        let prefixes: [(String, String)] = [
            ("! <command>", "Run shell command directly"),
            ("@ <path>", "Mention files, symbols, or subagents"),
            ("/ <command>", "Run slash command with live autocomplete"),
        ]

        let slashCommands: [(String, String)] = [
            ("/connect · /models · /agents", "Providers, models, and agents"),
            ("/diff · /timeline", "Full diff viewer and message timeline"),
            ("/undo · /redo · /fork", "Revert, restore, or fork session"),
            ("/pair · /settings", "QR remote pairing and TUI settings"),
            ("/status · /usage · /debug", "Server status, console usage, diagnostics"),
        ]

        return buildModalDialogShell(
            id: "opencode-help-dialog",
            title: "Help",
            description: "Keyboard shortcuts & slash commands",
            closeLabel: "esc/enter",
            cardWidth: cardWidth,
            topPad: topPad,
            dialogTheme: dialogTheme,
            footerChunks: [
                TextChunk(text: "enter/esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "close", fg: dialogTheme.text.muted, bg: cardBg),
            ],
            onClose: onClose
        ) {
            VStack(spacing: 1) {
                buildHelpSection(title: "Keyboard Shortcuts", rows: shortcuts, keyWidth: 18, theme: dialogTheme, bg: cardBg)
                buildHelpSection(title: "Prompt Prefixes", rows: prefixes, keyWidth: 18, theme: dialogTheme, bg: cardBg)
                buildHelpSection(title: "Slash Commands", rows: slashCommands, keyWidth: 30, theme: dialogTheme, bg: cardBg)
            }
            .width(.percent(100))
        }
    }

    // MARK: - 4f. Rename Session Dialog Overlay (`component/dialog-session-rename.tsx`)

    public static func buildRenameSessionDialogOverlay(
        currentTitle: String,
        draftTitle: String? = nil,
        cols: Int,
        rows: Int,
        theme: ResolvedTheme,
        onInput: @escaping @Sendable (String) -> Void = { _ in },
        onSubmit: @escaping @Sendable (String) -> Void = { _ in },
        onClose: @escaping @Sendable () -> Void = {}
    ) -> AnyTUIView {
        let dialogTheme = theme.surface(.dialog)
        let cardBg = dialogTheme.background.base
        let inputBg = dialogTheme.decrease(cardBg)
        let cardWidth = min(62, max(38, cols - 4))
        let topPad = max(2, rows / 5)
        let effectiveValue = draftTitle ?? currentTitle

        return buildModalDialogShell(
            id: "opencode-rename-session-dialog",
            title: "Rename session",
            description: nil,
            closeLabel: "esc",
            cardWidth: cardWidth,
            topPad: topPad,
            dialogTheme: dialogTheme,
            footerChunks: [
                TextChunk(text: "enter ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "save   ", fg: dialogTheme.text.muted, bg: cardBg),
                TextChunk(text: "esc ", fg: dialogTheme.text.base, bg: cardBg),
                TextChunk(text: "cancel", fg: dialogTheme.text.muted, bg: cardBg),
            ],
            onClose: onClose
        ) {
            TUIBox(
                border: false,
                backgroundColor: .rgba(inputBg),
                shouldFill: true
            ) {
                TUIInput(
                    value: effectiveValue,
                    placeholder: "Session title",
                    placeholderColor: .rgba(dialogTheme.text.muted),
                    maxLength: 200,
                    textColor: .rgba(dialogTheme.text.base),
                    backgroundColor: .rgba(inputBg),
                    focusedTextColor: .rgba(dialogTheme.text.formfield.focused),
                    focusedBackgroundColor: .rgba(inputBg),
                    showCursor: true,
                    cursorColor: .rgba(dialogTheme.text.formfield.focused),
                    onInput: onInput,
                    onSubmit: onSubmit
                )
                .key("rename-session-input")
                .id("rename-session-input")
                .width(.percent(100))
                .focused(true)
            }
            .padding(right: 1, left: 1)
            .width(.percent(100))
        }
    }

    // MARK: - 4g. Reconnecting Pill Overlay (`component/reconnecting.tsx`)

    public static func buildReconnectingOverlay(
        managed: Bool = false,
        spinnerTick: Int = 0,
        theme: ResolvedTheme
    ) -> AnyTUIView {
        let pillBg = theme.background.raised.base
        let glyph = spinnerFrames[abs(spinnerTick) % spinnerFrames.count]
        let titleText = managed ? "Restarting service…" : "Reconnecting to server…"
        let detailText = managed
            ? "Your session will resume automatically."
            : "Reconnecting to the server automatically."

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(reconnectingBackdropColor),
                shouldFill: true
            ) {
                TUIBox(
                    border: .sides([.left]),
                    borderColor: .rgba(theme.text.feedback.warning.base),
                    backgroundColor: .rgba(pillBg),
                    shouldFill: true,
                    customBorderChars: TUIScreens.splitBorderChars
                ) {
                    VStack(spacing: 1) {
                        TUIText(
                            StyledText(chunks: [
                                TextChunk(text: "\(glyph) ", fg: theme.text.feedback.warning.base, bg: pillBg),
                                TextChunk(text: titleText, fg: theme.text.base, bg: pillBg, attributes: TextAttributes.bold),
                            ]),
                            bg: .rgba(pillBg),
                            wrapMode: TextWrapMode.none
                        )
                        TUIText(
                            detailText,
                            fg: .rgba(theme.text.muted),
                            bg: .rgba(pillBg),
                            wrapMode: .word
                        )
                    }
                    .padding(top: 1, right: 2, bottom: 1, left: 2)
                    .width(.percent(100))
                }
                .id("opencode-reconnecting-pill")
                .width(50)
            }
            .id("opencode-reconnecting-overlay")
            .position(.absolute, top: 0, right: 0, bottom: 0, left: 0)
            .alignItems(.center)
            .justifyContent(.center)
            .zIndex(10_000)
        )
    }

    // MARK: - 4h. Session Sidebar Todo Section (`feature-plugins/sidebar/todo.tsx`)

    public static func buildSidebarTodoSection(
        items: [TUITodoItem],
        expanded: Bool = true,
        theme: ResolvedTheme,
        background: RGBA? = nil,
        innerWidth: Int = 32
    ) -> AnyTUIView {
        guard !items.isEmpty else {
            return AnyTUIView(EmptyTUIView())
        }

        let bg = background ?? theme.background.raised.base
        let collapsible = items.count > 2
        let remaining = items.filter { $0.status == .pending || $0.status == .inProgress }.count

        var headerChunks: [TextChunk] = []
        if collapsible {
            headerChunks.append(TextChunk(text: expanded ? "▼ " : "▶ ", fg: theme.text.base, bg: bg))
        }
        headerChunks.append(TextChunk(text: "Todo", fg: theme.text.base, bg: bg, attributes: TextAttributes.bold))
        if collapsible && !expanded {
            headerChunks.append(TextChunk(text: " (\(remaining) remaining)", fg: theme.text.muted, bg: bg))
        }

        return AnyTUIView(
            VStack(spacing: 0) {
                TUIText(StyledText(chunks: headerChunks), bg: .rgba(bg), wrapMode: TextWrapMode.none)
                    .width(.percent(100))

                if !collapsible || expanded {
                    for (idx, item) in items.enumerated() {
                        buildSidebarTodoRow(
                            item: item,
                            index: idx,
                            theme: theme,
                            bg: bg,
                            innerWidth: innerWidth
                        )
                    }
                }
            }
            .id("opencode-sidebar-todo")
            .width(.percent(100))
        )
    }

    // MARK: - Shared Private Layout & Formatting Helpers

    private static func buildStatusMCPRow(
        server: TUIMCPServerItem,
        theme: ResolvedTheme,
        bg: RGBA
    ) -> AnyTUIView {
        let dotColor = mcpStatusColor(server.status, theme: theme)
        let detailText: String
        switch server.status {
        case .connected:
            detailText = "Connected"
        case .pending:
            detailText = "Connecting"
        case .disabled:
            detailText = "Disabled in configuration"
        case .failed(let err):
            detailText = err.isEmpty ? "Error" : err
        case .needsAuth(let err):
            detailText = err.isEmpty ? "Needs authentication" : "Needs authentication: \(err)"
        }
        let detailColor: RGBA = server.status.isFailed
            ? theme.text.feedback.error.base
            : theme.text.muted

        return AnyTUIView(
            TUIText(
                StyledText(chunks: [
                    TextChunk(text: "• ", fg: dotColor, bg: bg),
                    TextChunk(text: server.name, fg: theme.text.base, bg: bg, attributes: TextAttributes.bold),
                    TextChunk(text: " \(detailText)", fg: detailColor, bg: bg),
                ]),
                bg: .rgba(bg),
                wrapMode: .word
            )
            .key("status-mcp-\(server.name)")
            .width(.percent(100))
        )
    }

    private static func buildUsageLimitRowView(
        row: TUIUsageLimitRow,
        isSelected: Bool,
        dialogTheme: ResolvedTheme,
        cardBg: RGBA,
        selBg: RGBA,
        selFg: RGBA
    ) -> AnyTUIView {
        let rowBg = isSelected ? selBg : cardBg
        let primaryFg = isSelected ? selFg : dialogTheme.text.base
        let mutedFg = isSelected ? selFg : dialogTheme.text.muted
        let statusFg: RGBA
        if isSelected {
            statusFg = selFg
        } else if row.isReached {
            statusFg = dialogTheme.text.feedback.error.base
        } else if row.isLow {
            statusFg = dialogTheme.text.feedback.warning.base
        } else {
            statusFg = dialogTheme.text.feedback.success.base
        }

        let remainingText: String
        if row.isReached {
            remainingText = "Limit reached"
        } else if let pct = row.remainingPercent {
            remainingText = "\(formatDollarsSimple(row.remainingDollars)) left (\(pct)%)"
        } else {
            remainingText = "\(formatDollarsSimple(row.remainingDollars)) left"
        }

        var metaParts: [String] = [
            "\(formatDollarsSimple(row.spentDollars)) used of \(formatDollarsSimple(row.limitDollars))",
        ]
        if let scope = row.scopeLabel, !scope.isEmpty {
            metaParts.append(scope)
        }
        if let resets = row.resetsLabel, !resets.isEmpty {
            metaParts.append("Resets \(resets)")
        }

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(rowBg),
                shouldFill: true
            ) {
                VStack(spacing: 0) {
                    HStack(spacing: 1) {
                        TUIText(
                            StyledText(chunks: [
                                TextChunk(text: "• ", fg: statusFg, bg: rowBg),
                                TextChunk(
                                    text: row.modelName,
                                    fg: primaryFg,
                                    bg: rowBg,
                                    attributes: isSelected ? TextAttributes.bold : TextAttributes.none
                                ),
                                TextChunk(
                                    text: row.providerName.map { " \($0)" } ?? "",
                                    fg: mutedFg,
                                    bg: rowBg
                                ),
                            ]),
                            bg: .rgba(rowBg),
                            wrapMode: TextWrapMode.none,
                            truncate: true
                        )
                        .flexGrow(1)

                        TUIText(
                            remainingText,
                            fg: .rgba(row.isReached || row.isLow ? statusFg : primaryFg),
                            bg: .rgba(rowBg),
                            attributes: TextAttributes.bold,
                            wrapMode: TextWrapMode.none
                        )
                        .flexShrink(0)
                    }
                    .width(.percent(100))

                    TUIText(
                        metaParts.joined(separator: " · "),
                        fg: .rgba(mutedFg),
                        bg: .rgba(rowBg),
                        wrapMode: .word
                    )
                    .padding(left: 2)
                    .width(.percent(100))
                }
                .padding(right: 1, left: 1)
                .width(.percent(100))
            }
            .key("usage-row-\(row.modelID)")
            .width(.percent(100))
        )
    }

    private static func buildSidebarTodoRow(
        item: TUITodoItem,
        index: Int,
        theme: ResolvedTheme,
        bg: RGBA,
        innerWidth: Int
    ) -> AnyTUIView {
        let markerColor: RGBA
        let textColor: RGBA
        let attrs: UInt32
        switch item.status {
        case .completed:
            markerColor = theme.text.feedback.success.base
            textColor = theme.text.muted
            attrs = TextAttributes.none
        case .inProgress:
            markerColor = theme.text.feedback.warning.base
            textColor = theme.text.feedback.warning.base
            attrs = TextAttributes.none
        case .pending:
            markerColor = theme.text.muted
            textColor = theme.text.base
            attrs = TextAttributes.none
        case .cancelled:
            markerColor = theme.text.faint
            textColor = theme.text.faint
            attrs = TextAttributes.strikethrough
        }

        let contentBudget = max(8, innerWidth - 4)
        return AnyTUIView(
            TUIText(
                StyledText(chunks: [
                    TextChunk(text: "\(item.status.marker) ", fg: markerColor, bg: bg),
                    TextChunk(
                        text: TUIUtil.truncateWidth(item.content, contentBudget),
                        fg: textColor,
                        bg: bg,
                        attributes: attrs
                    ),
                ]),
                bg: .rgba(bg),
                wrapMode: .word
            )
            .key("sidebar-todo-\(index)-\(item.id)")
            .width(.percent(100))
        )
    }

    private static func buildModalDialogShell(
        id: String,
        title: String,
        description: String?,
        closeLabel: String,
        cardWidth: Int,
        topPad: Int,
        dialogTheme: ResolvedTheme,
        footerChunks: [TextChunk],
        onClose: @escaping @Sendable () -> Void,
        @TUIViewBuilder content: () -> AnyTUIView
    ) -> AnyTUIView {
        let cardBg = dialogTheme.background.base
        let innerContent = content()

        return AnyTUIView(
            TUIBox(
                border: false,
                backgroundColor: .rgba(backdropColor),
                shouldFill: true
            ) {
                TUIBox(
                    border: false,
                    backgroundColor: .rgba(cardBg),
                    shouldFill: true
                ) {
                    VStack(spacing: 1) {
                        VStack(spacing: 0) {
                            HStack(spacing: 2) {
                                TUIText(
                                    title,
                                    fg: .rgba(dialogTheme.text.base),
                                    bg: .rgba(cardBg),
                                    attributes: TextAttributes.bold,
                                    wrapMode: TextWrapMode.none
                                )
                                TUISpacer()
                                TUIText(
                                    closeLabel,
                                    fg: .rgba(dialogTheme.text.muted),
                                    bg: .rgba(cardBg),
                                    wrapMode: TextWrapMode.none
                                )
                                .onMouseUp { _ in onClose() }
                            }
                            .width(.percent(100))

                            if let description, !description.isEmpty {
                                TUIText(
                                    description,
                                    fg: .rgba(dialogTheme.text.muted),
                                    bg: .rgba(cardBg),
                                    wrapMode: .word
                                )
                                .width(.percent(100))
                            }
                        }
                        .width(.percent(100))

                        innerContent

                        if !footerChunks.isEmpty {
                            TUIText(
                                StyledText(chunks: footerChunks),
                                bg: .rgba(cardBg),
                                wrapMode: TextWrapMode.none,
                                truncate: true
                            )
                            .width(.percent(100))
                        }
                    }
                    .width(.percent(100))
                }
                .id(id)
                .padding(top: 1, right: 3, bottom: 1, left: 3)
                .width(cardWidth)
            }
            .id("\(id)-backdrop")
            .position(.absolute, top: 0, right: 0, bottom: 0, left: 0)
            .alignItems(.center)
            .justifyContent(.flexStart)
            .padding(top: .point(Float(topPad)))
            .zIndex(3100)
        )
    }

    private static func buildKeyValueRow(
        label: String,
        value: String,
        valueColor: RGBA? = nil,
        labelWidth: Int,
        theme: ResolvedTheme,
        bg: RGBA
    ) -> AnyTUIView {
        let paddedLabel = padRight(label, to: labelWidth)
        return AnyTUIView(
            TUIText(
                StyledText(chunks: [
                    TextChunk(text: paddedLabel, fg: theme.text.muted, bg: bg),
                    TextChunk(text: value, fg: valueColor ?? theme.text.base, bg: bg),
                ]),
                bg: .rgba(bg),
                wrapMode: .word
            )
            .width(.percent(100))
        )
    }

    private static func buildHelpSection(
        title: String,
        rows: [(String, String)],
        keyWidth: Int,
        theme: ResolvedTheme,
        bg: RGBA
    ) -> AnyTUIView {
        return AnyTUIView(
            VStack(spacing: 0) {
                TUIText(
                    title,
                    fg: .rgba(theme.text.base),
                    bg: .rgba(bg),
                    attributes: TextAttributes.bold,
                    wrapMode: TextWrapMode.none
                )
                for (idx, row) in rows.enumerated() {
                    TUIText(
                        StyledText(chunks: [
                            TextChunk(text: padRight(row.0, to: keyWidth), fg: theme.text.action.primary.selected, bg: bg),
                            TextChunk(text: row.1, fg: theme.text.muted, bg: bg),
                        ]),
                        bg: .rgba(bg),
                        wrapMode: .word
                    )
                    .key("help-\(title)-\(idx)")
                    .width(.percent(100))
                }
            }
            .width(.percent(100))
        )
    }

    private static func permissionSubtitle(for request: TUIPendingPermissionItem) -> String? {
        switch (request.toolName, request.filePath) {
        case (let tool?, let path?) where !tool.isEmpty && !path.isEmpty:
            return "\(tool) · \(path)"
        case (let tool?, _) where !tool.isEmpty:
            return tool
        case (_, let path?) where !path.isEmpty:
            return path
        default:
            return nil
        }
    }

    private static func mcpStatusColor(_ status: TUIMCPServerStatus, theme: ResolvedTheme) -> RGBA {
        switch status {
        case .connected: return theme.text.feedback.success.base
        case .failed: return theme.text.feedback.error.base
        case .needsAuth: return theme.text.feedback.warning.base
        case .pending, .disabled: return theme.text.muted
        }
    }

    private static func diffStatusGlyph(_ status: String) -> String {
        switch status.lowercased() {
        case "added", "a": return "A"
        case "deleted", "removed", "d": return "D"
        case "renamed", "r": return "R"
        default: return "M"
        }
    }

    private static func diffStatusColor(_ status: String, theme: ResolvedTheme) -> RGBA {
        switch status.lowercased() {
        case "added", "a": return theme.diff.text.added
        case "deleted", "removed", "d": return theme.diff.text.removed
        default: return theme.text.feedback.warning.base
        }
    }

    private static func padRight(_ text: String, to width: Int) -> String {
        let len = TUIUtil.stringWidth(text)
        if len >= width { return text + " " }
        return text + String(repeating: " ", count: width - len)
    }

    private static func formatDollarsSimple(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<$0.01" }
        let clamped = max(0.0, value)
        let cents = Int((clamped * 100.0).rounded())
        let dollars = cents / 100
        let rem = cents % 100
        if rem == 0 {
            return "$\(dollars)"
        }
        return rem < 10 ? "$\(dollars).0\(rem)" : "$\(dollars).\(rem)"
    }
}

private func trimWhitespace(_ value: String) -> String {
    var start = value.startIndex
    var end = value.endIndex
    while start < end, isASCIIOrUnicodeSpace(value[start]) {
        start = value.index(after: start)
    }
    while end > start {
        let prev = value.index(before: end)
        if isASCIIOrUnicodeSpace(value[prev]) {
            end = prev
        } else {
            break
        }
    }
    return String(value[start..<end])
}

private func isASCIIOrUnicodeSpace(_ ch: Character) -> Bool {
    ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
}
