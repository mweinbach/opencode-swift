#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore

// MARK: - Full-Parity Interactive Client Actions (Permissions, Forms, Shell, Diff, Timeline, Undo/Redo, Fork, Rename, Copy/Export, Pair, Usage, Settings, Stash, Mentions, Workspaces, Session Tabs)

extension TUIInteractiveClient {

    // MARK: - 1. Interactive Permission Prompt Actions

    public func replyActivePermission(decision: PermissionSchema.Reply, message: String? = nil) {
        let target = store.withLock { state -> TUIPendingPermissionItem? in
            guard let req = state.activePermission else { return nil }
            state.pendingPermissions.removeAll { $0.id == req.id }
            state.permissionPromptState = TUIPermissionPromptState()
            return req
        }
        markDirty()
        guard let req = target else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.permission.reply(PermissionReplyInput(
                    sessionID: req.sessionID,
                    requestID: req.id,
                    decision: decision,
                    message: message
                ))
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Permission reply failed: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
            await self.refreshPermissions()
        }
    }

    public func confirmSelectedPermissionOption() {
        let current = store.withLock { state -> (TUIPendingPermissionItem?, TUIPermissionPromptState) in
            (state.activePermission, state.permissionPromptState)
        }
        guard current.0 != nil else { return }
        if current.1.isRejectingWithFeedback {
            let trimmed = current.1.rejectFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
            replyActivePermission(decision: .reject, message: trimmed.isEmpty ? nil : trimmed)
            return
        }
        switch current.1.selectedOption {
        case .once:
            replyActivePermission(decision: .once)
        case .always:
            replyActivePermission(decision: .always)
        case .reject:
            store.withLock { state in
                state.permissionPromptState.isRejectingWithFeedback = true
                state.permissionPromptState.rejectFeedback = ""
            }
            markDirty()
        }
    }

    // MARK: - 2. Interactive Form / Question Prompt Actions

    public func submitActiveForm() {
        let payload = store.withLock { state -> (form: TUIPendingFormItem, answer: FormSchema.Answer)? in
            guard let form = state.activeForm else { return nil }
            let encoded = state.formPromptState.encodedAnswer(for: form)
            var answer: FormSchema.Answer = [:]
            for (k, val) in encoded {
                switch val {
                case .string(let s):
                    answer[k] = .string(s)
                case .bool(let b):
                    answer[k] = .bool(b)
                case .int(let i):
                    answer[k] = .number(Double(i))
                case .double(let d):
                    answer[k] = .number(d)
                case .array(let arr):
                    let strs = arr.compactMap { item -> String? in
                        if case .string(let s) = item { return s }
                        return nil
                    }
                    answer[k] = .strings(strs)
                case .null, .object:
                    break
                }
            }
            state.pendingForms.removeAll { $0.id == form.id }
            state.formPromptState = TUIFormPromptState()
            return (form, answer)
        }
        markDirty()
        guard let payload, let sid = payload.form.sessionID ?? store.withLock({ $0.activeSessionID }) else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.session.form.reply(SessionFormReplyInput(
                    sessionID: sid,
                    formID: payload.form.id,
                    answer: payload.answer
                ))
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Form reply failed: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
            await self.refreshForms()
        }
    }

    public func cancelActiveForm() {
        let target = store.withLock { state -> TUIPendingFormItem? in
            guard let form = state.activeForm else { return nil }
            state.pendingForms.removeAll { $0.id == form.id }
            state.formPromptState = TUIFormPromptState()
            return form
        }
        markDirty()
        guard let form = target, let sid = form.sessionID ?? store.withLock({ $0.activeSessionID }) else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.client.session.form.cancel(SessionFormCancelInput(
                sessionID: sid,
                formID: form.id
            ))
            await self.refreshForms()
        }
    }

    // MARK: - 3. Interactive `!` Shell Mode & Custom Server Slash Commands & Skills

    public func submitShellCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let historyEntry = TUIPromptHistoryEntry(input: trimmed, mode: "shell")
        let submission = store.withLock { state -> (sessionID: String?, agentID: String, modelRef: ModelSchema.Ref?, dir: String) in
            state.historyNavigator.append(historyEntry)
            state.promptText = ""
            state.shellMode = false
            state.slashAutocompleteDismissed = false
            state.mentionAutocompleteDismissed = false
            state.sessionStatus = .running
            state.toastMessage = nil
            return (
                state.activeSessionID,
                state.activeAgent.id,
                state.selectedModel?.ref(variant: state.selectedVariant),
                state.directory
            )
        }
        if let persistence {
            Task { await persistence.appendHistory(historyEntry) }
        }
        markDirty()

        Task { [weak self] in
            guard let self else { return }
            do {
                let targetSID: String
                if let existing = submission.sessionID {
                    targetSID = existing
                } else {
                    let loc = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: submission.dir))
                    let created = try await self.client.session.create(SessionCreateInput(
                        title: "$ \(String(trimmed.prefix(44)))",
                        agent: submission.agentID,
                        model: submission.modelRef,
                        location: loc
                    ))
                    targetSID = created.id.rawValue
                    self.store.withLock { state in
                        state.activeSessionID = targetSID
                        state.activeSessionTitle = created.title ?? "Session"
                        state.route = .session(TUIContext.SessionRoute(sessionID: targetSID))
                        if !state.openSessionTabs.contains(targetSID) {
                            state.openSessionTabs.append(targetSID)
                        }
                    }
                    self.markDirty()
                }
                try await self.client.session.shell(SessionShellInput(
                    sessionID: targetSID,
                    command: trimmed
                ))
                self.store.withLock { state in
                    state.sessionStatus = .idle
                    state.route = .session(TUIContext.SessionRoute(sessionID: targetSID))
                }
                await self.loadMessages(sessionID: targetSID)
                await self.refreshSessions()
            } catch {
                self.store.withLock { state in
                    state.sessionStatus = .idle
                    state.toastMessage = "Shell command failed: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    public func submitServerCommand(name: String, arguments: String) {
        let submission = store.withLock { state -> (sessionID: String?, agentID: String, modelRef: ModelSchema.Ref?, dir: String) in
            state.promptText = ""
            state.slashAutocompleteDismissed = false
            state.sessionStatus = .running
            state.toastMessage = nil
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
                let targetSID: String
                if let existing = submission.sessionID {
                    targetSID = existing
                } else {
                    let loc = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: submission.dir))
                    let created = try await self.client.session.create(SessionCreateInput(
                        title: "/\(name)",
                        agent: submission.agentID,
                        model: submission.modelRef,
                        location: loc
                    ))
                    targetSID = created.id.rawValue
                    self.store.withLock { state in
                        state.activeSessionID = targetSID
                        state.activeSessionTitle = created.title ?? "Session"
                        state.route = .session(TUIContext.SessionRoute(sessionID: targetSID))
                        if !state.openSessionTabs.contains(targetSID) {
                            state.openSessionTabs.append(targetSID)
                        }
                    }
                    self.markDirty()
                }
                try await self.client.session.command(SessionCommandInput(
                    sessionID: targetSID,
                    name: name,
                    text: arguments
                ))
                await self.loadMessages(sessionID: targetSID)
                await self.refreshSessions()
            } catch {
                self.store.withLock { state in
                    state.sessionStatus = .idle
                    state.toastMessage = "Command /\(name) failed: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    public func activateSkill(id: String) {
        let submission = store.withLock { state -> (sessionID: String?, agentID: String, modelRef: ModelSchema.Ref?, dir: String) in
            state.toastMessage = "Activating skill \(id)…"
            state.toastIsError = false
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
                let targetSID: String
                if let existing = submission.sessionID {
                    targetSID = existing
                } else {
                    let loc = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: submission.dir))
                    let created = try await self.client.session.create(SessionCreateInput(
                        title: "Skill: \(id)",
                        agent: submission.agentID,
                        model: submission.modelRef,
                        location: loc
                    ))
                    targetSID = created.id.rawValue
                    self.store.withLock { state in
                        state.activeSessionID = targetSID
                        state.activeSessionTitle = created.title ?? "Session"
                        state.route = .session(TUIContext.SessionRoute(sessionID: targetSID))
                        if !state.openSessionTabs.contains(targetSID) {
                            state.openSessionTabs.append(targetSID)
                        }
                    }
                }
                try await self.client.session.skill(SessionSkillInput(
                    sessionID: targetSID,
                    id: id,
                    resume: false
                ))
                self.store.withLock { state in
                    state.toastMessage = "Activated skill: \(id)"
                    state.toastIsError = false
                }
                self.markDirty()
                await self.loadMessages(sessionID: targetSID)
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Failed to activate skill \(id): \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    // MARK: - 4. `@` File & Agent Mention Autocomplete

    public func queryFilesForMention(_ query: String) {
        let gen = mentionQueryGeneration.withLock { g -> Int in
            g &+= 1
            return g
        }
        Task { [weak self] in
            guard let self else { return }
            let loc = self.locationQuery
            guard let resp = try? await self.client.file.find(FileFindInput(
                location: loc,
                query: query,
                limit: 30
            )) else {
                return
            }
            let currentGen = self.mentionQueryGeneration.withLock { $0 }
            guard currentGen == gen else { return }
            let paths = resp.data.map(\.path.rawValue)
            self.store.withLock { state in
                state.mentionFiles = paths
                let count = state.mentionSuggestions.count
                if count > 0 {
                    state.mentionAutocompleteIndex = min(state.mentionAutocompleteIndex, count - 1)
                } else {
                    state.mentionAutocompleteIndex = 0
                }
            }
            self.markDirty()
        }
    }

    // MARK: - 5. Dialog Openers (Diff, Settings, Status, Usage, Skills, Timeline, Pair, Help, Debug, Rename, Stash, Workspaces)

    public func openDiffViewer() {
        let (splitPref, wrapPref, activeSID) = store.withLock { state -> (Bool, Bool, String?) in
            let split: Bool
            if state.preferences.diffView == "split" {
                split = true
            } else if state.preferences.diffView == "unified" {
                split = false
            } else {
                split = state.cols > 120
            }
            let wrap = state.preferences.diffWrap != "none"
            state.diffViewerState = TUIDiffViewerState(
                title: "Diff Viewer",
                files: [],
                selectedFileIndex: 0,
                splitView: split,
                fullscreen: false,
                showFileTree: true,
                wrapLines: wrap
            )
            state.activeDialog = .diffViewer
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            return (split, wrap, state.activeSessionID)
        }
        markDirty()

        Task { [weak self] in
            guard let self else { return }
            var entries: [TUIDiffFileEntry] = []
            if let vcsDiff = try? await self.client.vcs.diff(VcsDiffInput(location: self.locationQuery, mode: .working)),
               !vcsDiff.data.isEmpty {
                entries = vcsDiff.data.map { d in
                    TUIDiffFileEntry(
                        path: d.file,
                        additions: d.additions.rawValue,
                        deletions: d.deletions.rawValue,
                        status: d.status.rawValue,
                        patch: d.patch
                    )
                }
            } else if let sid = activeSID,
                      let sessionDiff = try? await self.client.session.diff(SessionDiffInput(sessionID: sid)),
                      !sessionDiff.isEmpty {
                entries = sessionDiff.map { d in
                    TUIDiffFileEntry(
                        path: d.file,
                        additions: d.additions.rawValue,
                        deletions: d.deletions.rawValue,
                        status: d.status.rawValue,
                        patch: d.patch
                    )
                }
            }
            self.store.withLock { state in
                guard state.activeDialog == .diffViewer else { return }
                state.diffViewerState = TUIDiffViewerState(
                    title: "Diff Viewer",
                    files: entries,
                    selectedFileIndex: 0,
                    splitView: splitPref,
                    fullscreen: state.diffViewerState.fullscreen,
                    showFileTree: state.diffViewerState.showFileTree,
                    wrapLines: wrapPref
                )
            }
            self.markDirty()
        }
    }

    public func openSettingsDialog() {
        openDialog(.settings)
    }

    public func openStatusDialog() {
        openDialog(.status)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshServerInfo()
            await self.refreshMCP()
            await self.refreshVCS()
            await self.refreshSkills()
            await self.refreshCommands()
        }
    }

    public func openUsageDialog() {
        openDialog(.usage)
        Task { [weak self] in
            guard let self else { return }
            guard let resp = try? await self.client.experimental.usage.limits(
                ExperimentalUsageLimitsInput(location: self.locationQuery)
            ) else {
                self.store.withLock { state in
                    state.usageSignedIn = false
                    state.usageLimits = []
                }
                self.markDirty()
                return
            }
            guard let limitsData = resp.data else {
                self.store.withLock { state in
                    state.usageSignedIn = false
                    state.usageLimits = []
                }
                self.markDirty()
                return
            }
            let nowMs = Double(Flock.currentEpochMs())
            let providers = self.store.withLock { $0.providers }
            var rows: [TUIUsageLimitRow] = []
            for budget in limitsData.budgets {
                let limitVal = budget.limit.rawValue
                let spentVal = budget.spent.rawValue
                let remaining = max(0.0, limitVal - spentVal)
                let resetSec = max(0, Int((budget.resetsAt - nowMs) / 1000.0))
                let resetText: String
                if resetSec >= 3600 {
                    resetText = "Resets in \(resetSec / 3600)h"
                } else if resetSec >= 60 {
                    resetText = "Resets in \(resetSec / 60)m"
                } else {
                    resetText = "Resets soon"
                }
                let remPct = limitVal > 0 ? max(0, min(100, Int(((remaining / limitVal) * 100.0).rounded()))) : 0
                let matchedName = budget.models.first?.name ?? (budget.coverage == .all ? "All models" : "Workspace budget")
                let provName = budget.models.first.map { providers[$0.providerID.rawValue] ?? TUIUtil.titlecase($0.providerID.rawValue) } ?? "OpenCode"
                rows.append(TUIUsageLimitRow(
                    modelID: budget.models.first?.modelID.rawValue ?? budget.id,
                    modelName: matchedName,
                    providerName: provName,
                    scopeLabel: budget.scope.rawValue,
                    spentDollars: spentVal,
                    limitDollars: limitVal,
                    remainingDollars: remaining,
                    remainingPercent: remPct,
                    resetsLabel: resetText,
                    isReached: remaining <= 0.0001,
                    isLow: remPct <= 15
                ))
            }
            self.store.withLock { state in
                state.usageSignedIn = true
                state.usageWorkspaceName = limitsData.workspace.name
                state.usageLimits = rows
            }
            self.markDirty()
        }
    }

    public func openSkillsDialog() {
        openDialog(.skills)
        Task { [weak self] in
            await self?.refreshSkills()
        }
    }

    public func openTimelineDialog() {
        let hasSession = store.withLock { $0.activeSessionID != nil }
        if !hasSession {
            store.withLock { state in
                state.toastMessage = "Open a session first to view its timeline"
                state.toastIsError = false
            }
            markDirty()
            return
        }
        openDialog(.timeline)
    }

    public func openPairDialog() {
        store.withLock { state in
            state.pairingInfo = nil
            state.activeDialog = .pair
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            if state.promptText.hasPrefix("/") {
                state.promptText = ""
            }
        }
        markDirty()

        Task { [weak self] in
            guard let self else { return }
            do {
                async let infoTask = self.client.server.info()
                async let pairTask = self.client.server.pair()
                let serverInfo = try await infoTask
                let pair = try await pairTask
                let baseURLs = serverInfo.urls.isEmpty ? [self.store.withLock { $0.serverURL }] : serverInfo.urls
                let links = baseURLs.map { url -> String in
                    let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
                    return "\(trimmed)/auth/connect/\(pair.code)"
                }
                let localLink: String? = links.first.map { link in
                    link.replacingOccurrences(of: "127.0.0.1", with: "localhost")
                }
                let isLoopback = baseURLs.allSatisfy {
                    $0.contains("127.0.0.1") || $0.contains("localhost") || $0.contains("[::1]")
                }
                let minutes = max(1, Int((Double(pair.expiresIn) / 60.0).rounded()))
                self.store.withLock { state in
                    guard state.activeDialog == .pair else { return }
                    state.pairingInfo = TUIPairingInfo(
                        links: links,
                        localhostURL: localLink,
                        expiresInMinutes: minutes,
                        isLoopbackOnly: isLoopback,
                        errorMessage: nil
                    )
                }
            } catch {
                self.store.withLock { state in
                    guard state.activeDialog == .pair else { return }
                    state.pairingInfo = TUIPairingInfo(
                        links: [],
                        errorMessage: "\(error)"
                    )
                }
            }
            self.markDirty()
        }
    }

    public func openHelpDialog() {
        openDialog(.help)
    }

    public func openDebugDialog() {
        openDialog(.debug)
    }

    public func openWorkspacesDialog() {
        openDialog(.workspaces)
        Task { [weak self] in
            await self?.refreshWorktrees()
        }
    }

    public func openStashListDialog() {
        openDialog(.stashList)
    }

    public func openRenameSessionDialog(sessionID: String? = nil, currentTitle: String? = nil) {
        let resolved = store.withLock { state -> (String, String)? in
            let sid = sessionID ?? state.activeSessionID
            guard let sid, !sid.isEmpty else { return nil }
            let title = currentTitle
                ?? state.sessions.first(where: { $0.id == sid })?.title
                ?? state.activeSessionTitle
            state.renameTargetSessionID = sid
            state.renameDraft = title
            state.activeDialog = .renameSession
            state.dialogFilter = title
            state.dialogSelectedIndex = 0
            return (sid, title)
        }
        if resolved == nil {
            store.withLock { state in
                state.toastMessage = "No active session to rename"
                state.toastIsError = false
            }
        }
        markDirty()
    }

    // MARK: - 6. Settings Cycling (`DialogConfig`)

    public func cycleSelectedSetting(direction: Int = 1) {
        let openThemePicker: Bool = store.withLock { state in
            guard state.activeDialog == .settings else { return false }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return false }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            guard let settingID = TUISettingID(rawValue: rows[idx].id) else { return false }
            if settingID == .theme && direction == 1 {
                return true
            }
            TUISettingsCatalog.cycle(settingID, direction: direction, preferences: &state.preferences)
            state.themeName = state.preferences.themeName
            state.themePreference = state.preferences.themePreference
            if state.preferences.sidebarMode == "hide" {
                state.sidebarExplicitOverride = false
            } else {
                state.sidebarExplicitOverride = nil
            }
            return false
        }
        if openThemePicker {
            openDialog(.themePicker)
            return
        }
        persistPreferencesAsync()
        markDirty()
    }

    // MARK: - 7. Session Lifecycle Actions (Undo, Redo, Fork, Rename, Delete, Pin, Copy, Export, Workspaces, Tabs)

    public func undoLastUserMessage() {
        let info = store.withLock { state -> (sid: String, messageID: String)? in
            guard let sid = state.activeSessionID else { return nil }
            for item in state.messages.reversed() {
                if case .user(let id, _, _, let isOpt) = item, !isOpt {
                    return (sid, id)
                }
            }
            return nil
        }
        guard let info else {
            store.withLock { state in
                state.toastMessage = "No user message to undo"
                state.toastIsError = false
            }
            markDirty()
            return
        }
        revertToMessage(id: info.messageID)
    }

    public func revertToMessage(id messageID: String) {
        guard let sid = store.withLock({ $0.activeSessionID }) else { return }
        store.withLock { state in
            state.toastMessage = "Reverting message…"
            state.toastIsError = false
        }
        markDirty()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.client.session.revert.stage(SessionRevertStageInput(
                    sessionID: sid,
                    messageID: messageID
                ))
                self.store.withLock { state in
                    state.hasRevertedMessage = true
                    state.revertedMessageID = messageID
                    state.toastMessage = "Reverted message (use /redo to restore)"
                    state.toastIsError = false
                }
                await self.loadMessages(sessionID: sid)
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Revert failed: \(error)"
                    state.toastIsError = true
                }
            }
            self.markDirty()
        }
    }

    public func redoRevertedMessage() {
        guard let sid = store.withLock({ $0.activeSessionID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.session.revert.clear(SessionRevertClearInput(sessionID: sid))
                self.store.withLock { state in
                    state.hasRevertedMessage = false
                    state.revertedMessageID = nil
                    state.toastMessage = "Restored reverted message"
                    state.toastIsError = false
                }
                await self.loadMessages(sessionID: sid)
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Redo failed: \(error)"
                    state.toastIsError = true
                }
            }
            self.markDirty()
        }
    }

    public func forkActiveSession(beforeMessageID: String? = nil) {
        guard let sid = store.withLock({ $0.activeSessionID }) else {
            store.withLock { state in
                state.toastMessage = "No active session to fork"
                state.toastIsError = false
            }
            markDirty()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let forked = try await self.client.session.fork(SessionForkInput(
                    sessionID: sid,
                    before: beforeMessageID
                ))
                let title = SessionTitleFallback.displayLabel(title: forked.title, parentID: forked.parentID?.rawValue)
                self.openSession(id: forked.id.rawValue, title: title)
                self.store.withLock { state in
                    state.toastMessage = "Forked session: \(title)"
                    state.toastIsError = false
                }
                self.markDirty()
                await self.refreshSessions()
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Fork failed: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    public func submitRenameSession(_ rawTitle: String? = nil) {
        let info = store.withLock { state -> (id: String, title: String)? in
            guard let sid = state.renameTargetSessionID ?? state.activeSessionID else { return nil }
            let trimmed = (rawTitle ?? state.renameDraft).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            state.activeDialog = nil
            state.dialogFilter = ""
            state.renameTargetSessionID = nil
            return (sid, trimmed)
        }
        markDirty()
        guard let info else {
            closeDialog(commitTheme: false)
            return
        }
        renameSession(id: info.id, newTitle: info.title)
    }

    public func renameSession(id: String, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.withLock { state in
            if state.activeSessionID == id {
                state.activeSessionTitle = trimmed
            }
            if let idx = state.sessions.firstIndex(where: { $0.id == id }) {
                let prev = state.sessions[idx]
                state.sessions[idx] = TUISessionItem(
                    id: prev.id,
                    title: trimmed,
                    directory: prev.directory,
                    updatedMs: prev.updatedMs,
                    parentID: prev.parentID
                )
            }
        }
        markDirty()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.session.update(SessionUpdateInput(sessionID: id, title: trimmed))
                self.store.withLock { state in
                    state.toastMessage = "Renamed session to \"\(trimmed)\""
                    state.toastIsError = false
                }
                self.markDirty()
                await self.refreshSessions()
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Rename failed: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    public func requestDeleteSelectedSession() {
        let targetID = store.withLock { state -> String? in
            guard state.activeDialog == .sessionList else { return nil }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return nil }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            let sid = rows[idx].id
            if state.pendingDeleteSessionID == sid {
                state.pendingDeleteSessionID = nil
                return sid
            } else {
                state.pendingDeleteSessionID = sid
                return nil
            }
        }
        markDirty()
        guard let sid = targetID else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.session.remove(SessionRemoveInput(sessionID: sid))
                self.store.withLock { state in
                    state.sessions.removeAll { $0.id == sid }
                    state.openSessionTabs.removeAll { $0 == sid }
                    state.preferences.pinnedSessionIDs.removeAll { $0 == sid }
                    if state.activeSessionID == sid {
                        state.activeSessionID = nil
                        state.activeSessionTitle = "New Session"
                        state.messages = []
                        state.route = .home(TUIContext.HomeRoute())
                    }
                    state.toastMessage = "Session deleted"
                    state.toastIsError = false
                }
                self.persistPreferencesAsync()
                self.markDirty()
                await self.refreshSessions()
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Delete session failed: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    public func togglePinSelectedSession() {
        store.withLock { state in
            guard state.activeDialog == .sessionList else { return }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            let sid = rows[idx].id
            if let existing = state.preferences.pinnedSessionIDs.firstIndex(of: sid) {
                state.preferences.pinnedSessionIDs.remove(at: existing)
            } else {
                state.preferences.pinnedSessionIDs.insert(sid, at: 0)
            }
        }
        persistPreferencesAsync()
        markDirty()
    }

    public func copySessionTranscript() {
        let (title, msgs) = store.withLock { ($0.activeSessionTitle, $0.messages) }
        guard !msgs.isEmpty else {
            store.withLock { state in
                state.toastMessage = "No messages to copy"
                state.toastIsError = false
            }
            markDirty()
            return
        }
        let markdown = TUITranscriptFormatter.formatMarkdownTranscript(title: title, messages: msgs)
        Task { [weak self] in
            var copied = false
            if let host = try? createHostClipboard() {
                if (try? await host.writeText(markdown)) != nil {
                    copied = true
                }
                try? await host.dispose()
            }
            self?.store.withLock { state in
                state.toastMessage = copied ? "Copied session transcript to clipboard" : "Transcript ready (\(markdown.count) chars)"
                state.toastIsError = false
            }
            self?.markDirty()
        }
    }

    public func copyDebugSnapshot() {
        let snap = store.withLock { $0.debugSnapshot }
        let summary = """
        OpenCode Debug Info
        Server: \(snap.serverURL) (\(snap.serverVersion))
        Session: \(snap.sessionID ?? "n/a")
        SSE: \(snap.sseConnected ? "connected" : (snap.sseReconnecting ? "reconnecting" : "disconnected"))
        Terminal: \(snap.terminalCols)x\(snap.terminalRows) (Kitty flags=\(snap.kittyKeyboardFlags))
        Theme: \(snap.themeName) (\(snap.themeMode.rawValue))
        Catalog: \(snap.providersCount) providers, \(snap.modelsCount) models, \(snap.agentsCount) agents, \(snap.commandsCount) commands, \(snap.skillsCount) skills
        """
        Task { [weak self] in
            if let host = try? createHostClipboard() {
                _ = try? await host.writeText(summary)
                try? await host.dispose()
            }
            self?.store.withLock { state in
                state.toastMessage = "Copied debug info to clipboard"
                state.toastIsError = false
            }
            self?.markDirty()
        }
    }

    public func exportSessionTranscript() {
        let (title, msgs, dir) = store.withLock { ($0.activeSessionTitle, $0.messages, $0.directory) }
        guard !msgs.isEmpty else {
            store.withLock { state in
                state.toastMessage = "No messages to export"
                state.toastIsError = false
            }
            markDirty()
            return
        }
        let markdown = TUITranscriptFormatter.formatMarkdownTranscript(title: title, messages: msgs)
        let slug = title.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        let cleanSlug = String(slug.drop(while: { $0 == "-" }).reversed().drop(while: { $0 == "-" }).reversed())
        let filename = "opencode-\(cleanSlug.isEmpty ? "session" : String(cleanSlug.prefix(32))).md"
        let targetPath = "\(dir)/\(filename)"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await LocalFileSystem.shared.writeFile(Array(markdown.utf8), to: targetPath, createDirectories: true)
                self.store.withLock { state in
                    state.toastMessage = "Exported transcript to \(filename)"
                    state.toastIsError = false
                }
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Export failed: \(error)"
                    state.toastIsError = true
                }
            }
            self.markDirty()
        }
    }

    public func switchWorkspace(directory targetDirectory: String) {
        let activeSID = store.withLock { state -> String? in
            state.directory = targetDirectory
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.toastMessage = "Switched workspace to \(TUIUtil.abbreviateHome(targetDirectory, home: state.homeDirectory))"
            state.toastIsError = false
            return state.activeSessionID
        }
        markDirty()
        Task { [weak self] in
            guard let self else { return }
            if let sid = activeSID {
                _ = try? await self.client.session.move(SessionMoveInput(sessionID: sid, directory: targetDirectory))
            }
            await self.refreshVCS()
            await self.refreshMCP()
            await self.refreshCommands()
            await self.refreshSkills()
        }
    }

    public func reloadLocationConfig() {
        store.withLock { state in
            state.toastMessage = "Reloading configuration…"
            state.toastIsError = false
        }
        markDirty()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.location.reload()
                await self.refreshAgents()
                await self.refreshIntegrations()
                await self.refreshProvidersAndModels()
                await self.refreshMCP()
                await self.refreshVCS()
                await self.refreshCommands()
                await self.refreshSkills()
                self.store.withLock { state in
                    state.toastMessage = "Configuration reloaded"
                    state.toastIsError = false
                }
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Reload failed: \(error)"
                    state.toastIsError = true
                }
            }
            self.markDirty()
        }
    }

    // MARK: - 8. Prompt Stash & External `$EDITOR`

    public func stashCurrentPrompt() {
        let text = store.withLock { state in
            TUIPasteManager.expand(state.promptText, blocks: state.pastedBlocks)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else {
            store.withLock { state in
                state.toastMessage = "Prompt is empty — nothing to stash"
                state.toastIsError = false
            }
            markDirty()
            return
        }
        stashPromptText(text)
    }

    public func stashPromptText(_ text: String) {
        let entry = TUIPromptStashEntry(input: text)
        let updated = store.withLock { state -> [TUIPromptStashEntry] in
            state.stashEntries.insert(entry, at: 0)
            if state.stashEntries.count > TUIPersistenceStore.maxStashEntries {
                state.stashEntries = Array(state.stashEntries.prefix(TUIPersistenceStore.maxStashEntries))
            }
            state.promptText = ""
            state.pastedBlocks = []
            state.toastMessage = "Stashed prompt"
            state.toastIsError = false
            return state.stashEntries
        }
        if let persistence {
            Task { await persistence.saveStash(updated) }
        }
        markDirty()
    }

    public func popMostRecentStash() {
        let popped = store.withLock { state -> (TUIPromptStashEntry?, [TUIPromptStashEntry]) in
            guard !state.stashEntries.isEmpty else { return (nil, state.stashEntries) }
            let first = state.stashEntries.removeFirst()
            state.promptText = first.input
            state.toastMessage = "Restored stashed prompt"
            state.toastIsError = false
            return (first, state.stashEntries)
        }
        if popped.0 != nil, let persistence {
            Task { await persistence.saveStash(popped.1) }
        } else if popped.0 == nil {
            store.withLock { state in
                state.toastMessage = "No stashed prompts"
                state.toastIsError = false
            }
        }
        markDirty()
    }

    public func popStashEntry(id: String) {
        let updated = store.withLock { state -> [TUIPromptStashEntry]? in
            guard let idx = state.stashEntries.firstIndex(where: { $0.id == id }) else { return nil }
            let entry = state.stashEntries.remove(at: idx)
            state.promptText = entry.input
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.toastMessage = "Restored stashed prompt"
            state.toastIsError = false
            return state.stashEntries
        }
        if let updated, let persistence {
            Task { await persistence.saveStash(updated) }
        }
        markDirty()
    }

    public func deleteSelectedStashEntry() {
        let updated = store.withLock { state -> [TUIPromptStashEntry]? in
            guard state.activeDialog == .stashList else { return nil }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return nil }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            let id = rows[idx].id
            state.stashEntries.removeAll { $0.id == id }
            if state.dialogSelectedIndex >= state.stashEntries.count {
                state.dialogSelectedIndex = max(0, state.stashEntries.count - 1)
            }
            return state.stashEntries
        }
        if let updated, let persistence {
            Task { await persistence.saveStash(updated) }
        }
        markDirty()
    }

    public func requestExternalEditor() {
        if let hook = onRequestExternalEditor {
            hook()
        } else {
            store.withLock { state in
                state.toastMessage = "External $EDITOR is available in interactive TTY mode"
                state.toastIsError = false
            }
            markDirty()
        }
    }

    // MARK: - 9. Session Tab Navigation (`<leader>1..9`, `Ctrl+Tab`, `<leader>w`, `Ctrl+Shift+T`)

    public func selectSessionTab(index: Int) {
        let target = store.withLock { state -> (String, String)? in
            guard index >= 0 && index < state.openSessionTabs.count else { return nil }
            let sid = state.openSessionTabs[index]
            let title = state.sessions.first(where: { $0.id == sid })?.title ?? "Session"
            return (sid, title)
        }
        if let (sid, title) = target {
            openSession(id: sid, title: title)
        }
    }

    public func cycleSessionTab(direction: Int) {
        let target = store.withLock { state -> (String, String)? in
            guard state.openSessionTabs.count >= 2 else { return nil }
            let curIdx = state.activeSessionID.flatMap { state.openSessionTabs.firstIndex(of: $0) } ?? 0
            let nextIdx = ((curIdx + direction) % state.openSessionTabs.count + state.openSessionTabs.count) % state.openSessionTabs.count
            let sid = state.openSessionTabs[nextIdx]
            let title = state.sessions.first(where: { $0.id == sid })?.title ?? "Session"
            return (sid, title)
        }
        if let (sid, title) = target {
            openSession(id: sid, title: title)
        }
    }

    public func closeCurrentSessionTab() {
        let nextTarget = store.withLock { state -> (String, String)? in
            guard let cur = state.activeSessionID else { return nil }
            state.openSessionTabs.removeAll { $0 == cur }
            state.closedSessionTabs.insert(cur, at: 0)
            if state.closedSessionTabs.count > 20 {
                state.closedSessionTabs = Array(state.closedSessionTabs.prefix(20))
            }
            if let fallbackID = state.openSessionTabs.last {
                let title = state.sessions.first(where: { $0.id == fallbackID })?.title ?? "Session"
                return (fallbackID, title)
            }
            state.activeSessionID = nil
            state.activeSessionTitle = "New Session"
            state.messages = []
            state.route = .home(TUIContext.HomeRoute())
            return nil
        }
        if let (sid, title) = nextTarget {
            openSession(id: sid, title: title)
        } else {
            markDirty()
        }
    }

    public func reopenClosedSessionTab() {
        let target = store.withLock { state -> (String, String)? in
            guard !state.closedSessionTabs.isEmpty else { return nil }
            let sid = state.closedSessionTabs.removeFirst()
            let title = state.sessions.first(where: { $0.id == sid })?.title ?? "Session"
            return (sid, title)
        }
        if let (sid, title) = target {
            openSession(id: sid, title: title)
        }
    }

    // MARK: - 10. Queued Prompts Management (`<leader>return`, `<leader>q`, `/queue`)

    public func submitQueuedPrompt(rawText: String) {
        let (isShell, pastedBlocks) = store.withLock { ($0.shellMode, $0.pastedBlocks) }
        let expanded = TUIPasteManager.expand(rawText, blocks: pastedBlocks)
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isShell || trimmed.hasPrefix("/") {
            store.withLock { state in
                state.toastMessage = "This prompt cannot be queued"
                state.toastIsError = false
            }
            markDirty()
            return
        }

        let optimisticID = nextOptimisticID()
        let historyEntry = TUIPromptHistoryEntry(input: trimmed, mode: "normal")
        let submission = store.withLock { state -> (sessionID: String?, agentID: String, modelRef: ModelSchema.Ref?, dir: String) in
            state.historyNavigator.append(historyEntry)
            state.promptText = ""
            state.pastedBlocks = []
            state.slashAutocompleteDismissed = false
            state.slashAutocompleteIndex = 0
            state.mentionAutocompleteDismissed = false
            state.mentionAutocompleteIndex = 0
            state.queuedPrompts.append(TUIQueuedPromptItem(id: optimisticID, text: trimmed, delivery: "queue"))
            state.toastMessage = "Prompt queued"
            state.toastIsError = false
            return (
                state.activeSessionID,
                state.activeAgent.id,
                state.selectedModel?.ref(variant: state.selectedVariant),
                state.directory
            )
        }
        if let persistence {
            Task { await persistence.appendHistory(historyEntry) }
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
                let enqueued = try await self.client.session.prompt(SessionPromptInput(
                    sessionID: targetSessionID,
                    text: trimmed,
                    delivery: .queue
                ))
                let serverID = enqueued.id.rawValue
                let serverDelivery = enqueued.delivery.rawValue
                self.store.withLock { state in
                    if let idx = state.queuedPrompts.firstIndex(where: { $0.id == optimisticID }) {
                        state.queuedPrompts[idx] = TUIQueuedPromptItem(
                            id: serverID,
                            text: trimmed,
                            delivery: serverDelivery
                        )
                    }
                }
                self.markDirty()
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Failed to queue prompt: \(error)"
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    public func openQueuedPromptsDialog() {
        openDialog(.queuedPrompts)
        Task { [weak self] in
            await self?.refreshQueuedPrompts()
        }
    }

    public func refreshQueuedPrompts() async {
        guard let sid = store.withLock({ $0.activeSessionID }) else { return }
        guard let inbox = try? await client.session.inbox.list(SessionInboxListInput(sessionID: sid)) else {
            return
        }
        let items: [TUIQueuedPromptItem] = inbox.compactMap { record in
            switch record {
            case .user(let u):
                return TUIQueuedPromptItem(
                    id: u.id.rawValue,
                    text: u.payload.text,
                    delivery: u.delivery.rawValue
                )
            case .synthetic, .compaction, .move:
                return nil
            }
        }
        store.withLock { state in
            guard state.activeSessionID == sid else { return }
            state.queuedPrompts = items
            if state.activeDialog == .queuedPrompts {
                let count = state.dialogRows().count
                if state.dialogSelectedIndex >= count {
                    state.dialogSelectedIndex = max(0, count - 1)
                }
            }
        }
        markDirty()
    }

    public func undoSelectedQueuedPrompt() {
        let target = store.withLock { state -> (sessionID: String?, item: TUIQueuedPromptItem)? in
            guard state.activeDialog == .queuedPrompts else { return nil }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return nil }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            let rowID = rows[idx].id
            guard let itemIdx = state.queuedPrompts.firstIndex(where: { $0.id == rowID }) else { return nil }
            let removed = state.queuedPrompts.remove(at: itemIdx)
            if state.promptText.isEmpty {
                state.promptText = removed.text
            } else {
                state.promptText += "\n" + removed.text
            }
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.slashAutocompleteDismissed = false
            state.mentionAutocompleteDismissed = false
            state.toastMessage = "Restored queued prompt to composer"
            state.toastIsError = false
            return (state.activeSessionID, removed)
        }
        markDirty()
        guard let target, let sid = target.sessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.client.session.inbox.cancel(SessionInboxCancelInput(
                sessionID: sid,
                inboxID: target.item.id
            ))
        }
    }

    public func deleteSelectedQueuedPrompt() {
        let target = store.withLock { state -> (sessionID: String?, item: TUIQueuedPromptItem)? in
            guard state.activeDialog == .queuedPrompts else { return nil }
            let rows = state.dialogRows()
            guard !rows.isEmpty else { return nil }
            let idx = min(max(0, state.dialogSelectedIndex), rows.count - 1)
            let rowID = rows[idx].id
            guard let itemIdx = state.queuedPrompts.firstIndex(where: { $0.id == rowID }) else { return nil }
            let removed = state.queuedPrompts.remove(at: itemIdx)
            let remainingRows = state.dialogRows().count
            if state.dialogSelectedIndex >= remainingRows {
                state.dialogSelectedIndex = max(0, remainingRows - 1)
            }
            state.toastMessage = "Deleted queued prompt"
            state.toastIsError = false
            return (state.activeSessionID, removed)
        }
        markDirty()
        guard let target, let sid = target.sessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.client.session.inbox.cancel(SessionInboxCancelInput(
                sessionID: sid,
                inboxID: target.item.id
            ))
        }
    }

    public func steerQueuedPrompt(id: String) {
        let sid = store.withLock { state -> String? in
            if let idx = state.queuedPrompts.firstIndex(where: { $0.id == id }) {
                let prev = state.queuedPrompts[idx]
                state.queuedPrompts[idx] = TUIQueuedPromptItem(id: prev.id, text: prev.text, delivery: "steer")
            }
            state.activeDialog = nil
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.toastMessage = "Promoted queued prompt to steer"
            state.toastIsError = false
            return state.activeSessionID
        }
        markDirty()
        guard let sid else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.client.session.inbox.update(SessionInboxUpdateInput(
                sessionID: sid,
                inboxID: id,
                delivery: .steer
            ))
            await self.refreshQueuedPrompts()
        }
    }

    // MARK: - 11. Embedded Live Terminal Pane (`<leader>t`, `<leader>up`, `<leader>left/right`, `/terminal`)

    public func toggleTerminalPane() {
        let shouldOpen = store.withLock { !$0.terminalPane.isOpen }
        if !shouldOpen {
            closeTerminalPane()
            return
        }
        let cwd = store.withLock { state -> String in
            state.terminalPane.isOpen = true
            state.terminalPane.isFocused = true
            state.terminalPane.exitCode = nil
            if state.terminalPane.outputLines.isEmpty {
                let displayDir = TUIUtil.abbreviateHome(state.directory, home: state.homeDirectory)
                state.terminalPane.outputLines.append("Connected workspace: \(displayDir)")
            }
            return state.directory
        }
        markDirty()

        Task { [weak self] in
            guard let self else { return }
            if let created = try? await self.client.pty.create(PtyCreateInput(
                location: self.locationQuery,
                cwd: cwd,
                title: "Terminal"
            )) {
                let ptyInfo = created.data
                self.store.withLock { state in
                    guard state.terminalPane.isOpen else { return }
                    state.terminalPane.ptyID = ptyInfo.id.rawValue
                    if !ptyInfo.title.isEmpty {
                        state.terminalPane.title = ptyInfo.title
                    }
                    state.terminalPane.exitCode = ptyInfo.exitCode?.rawValue
                }
                self.markDirty()
            }
        }
    }

    public func closeTerminalPane() {
        let ptyID = store.withLock { state -> String? in
            let existing = state.terminalPane.ptyID
            state.terminalPane.isOpen = false
            state.terminalPane.isFocused = false
            state.terminalPane.ptyID = nil
            state.terminalPane.inputBuffer = ""
            return existing
        }
        markDirty()
        if let ptyID {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.client.pty.remove(PtyRemoveInput(ptyID: ptyID, location: self.locationQuery))
            }
        }
    }

    public func focusTerminalPane(_ focused: Bool) {
        store.withLock { state in
            state.terminalPane.isFocused = focused && state.terminalPane.isOpen
        }
        markDirty()
    }

    public func appendTerminalOutput(_ text: String, exitCode: Int? = nil) {
        let normalized = TUIPasteManager.normalize(text)
        let lines = normalized.isEmpty
            ? []
            : normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        store.withLock { state in
            if !lines.isEmpty {
                state.terminalPane.outputLines.append(contentsOf: lines)
                if state.terminalPane.outputLines.count > TUIEmbeddedTerminalPane.maxStoredOutputLines {
                    state.terminalPane.outputLines = Array(
                        state.terminalPane.outputLines.suffix(TUIEmbeddedTerminalPane.maxStoredOutputLines)
                    )
                }
            }
            if let exitCode {
                state.terminalPane.exitCode = exitCode
            }
        }
        markDirty()
    }

    public func submitTerminalCommand(_ rawCommand: String) {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = store.withLock { state -> String in
            state.terminalPane.inputBuffer = ""
            return state.directory
        }
        guard !trimmed.isEmpty else {
            markDirty()
            return
        }
        if trimmed == "clear" {
            store.withLock { state in
                state.terminalPane.outputLines = []
                state.terminalPane.exitCode = nil
            }
            markDirty()
            return
        }
        if trimmed == "exit" {
            closeTerminalPane()
            return
        }

        store.withLock { state in
            state.terminalPane.exitCode = nil
            state.terminalPane.outputLines.append("$ \(trimmed)")
            if state.terminalPane.outputLines.count > TUIEmbeddedTerminalPane.maxStoredOutputLines {
                state.terminalPane.outputLines = Array(
                    state.terminalPane.outputLines.suffix(TUIEmbeddedTerminalPane.maxStoredOutputLines)
                )
            }
        }
        markDirty()

        Task { [weak self] in
            guard let self else { return }
            do {
                let created = try await self.client.shell.create(ShellCreateInput(
                    location: self.locationQuery,
                    command: trimmed,
                    cwd: cwd
                ))
                let shellID = created.data.id.rawValue
                var latestInfo = created.data
                for _ in 0..<40 {
                    if latestInfo.status != .running { break }
                    try? await Task.sleep(for: .milliseconds(50))
                    if let polled = try? await self.client.shell.get(ShellGetInput(id: shellID, location: self.locationQuery)) {
                        latestInfo = polled.data
                    } else {
                        break
                    }
                }
                if let out = try? await self.client.shell.output(ShellOutputInput(id: shellID, location: self.locationQuery)) {
                    let body = out.data.output.trimmingCharacters(in: .newlines)
                    let code = latestInfo.exit.map(Int.init)
                    self.appendTerminalOutput(body, exitCode: code)
                } else if let code = latestInfo.exit.map(Int.init) {
                    self.appendTerminalOutput("", exitCode: code)
                }
            } catch {
                // Keep pane responsive when server shell API is unavailable (e.g. offline/mock transport).
            }
        }
    }

    // MARK: - 12. Interactive OAuth, Connect Method Forms & System Browser Launch

    /// Extracts a device-flow verification code (such as `ABCD-1234` or `R283-GOUEO`) from OAuth instructions.
    public static func extractOAuthDeviceCode(from text: String) -> String? {
        let bytes = Array(text.utf8)
        let isCodeChar: (UInt8) -> Bool = { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A)
        }
        var i = 0
        while i + 9 <= bytes.count {
            let prevBoundary = (i == 0) || !isCodeChar(bytes[i - 1])
            if prevBoundary
                && isCodeChar(bytes[i])
                && isCodeChar(bytes[i + 1])
                && isCodeChar(bytes[i + 2])
                && isCodeChar(bytes[i + 3])
                && bytes[i + 4] == 0x2D
                && isCodeChar(bytes[i + 5])
                && isCodeChar(bytes[i + 6])
                && isCodeChar(bytes[i + 7])
                && isCodeChar(bytes[i + 8])
            {
                var end = i + 9
                if end < bytes.count && isCodeChar(bytes[end]) {
                    end += 1
                }
                if end == bytes.count || !isCodeChar(bytes[end]) {
                    return String(decoding: bytes[i..<end], as: UTF8.self)
                }
            }
            i += 1
        }
        return nil
    }

    internal static func connectFormFieldKey(_ field: FormSchema.Field) -> String {
        switch field {
        case .string(let f): return f.key
        case .number(let f): return f.key
        case .integer(let f): return f.key
        case .boolean(let f): return f.key
        case .multiselect(let f): return f.key
        case .external(let f): return f.key
        }
    }

    internal static func connectFormFieldTitle(_ field: FormSchema.Field) -> String {
        switch field {
        case .string(let f): return f.title ?? f.key
        case .number(let f): return f.title ?? f.key
        case .integer(let f): return f.title ?? f.key
        case .boolean(let f): return f.title ?? f.key
        case .multiselect(let f): return f.title ?? f.key
        case .external(let f): return f.title ?? f.key
        }
    }

    internal static func connectFormFieldIsHidden(_ field: FormSchema.Field) -> Bool {
        switch field {
        case .string(let f): return f.hidden == true
        case .number(let f): return f.hidden == true
        case .integer(let f): return f.hidden == true
        case .boolean(let f): return f.hidden == true
        case .multiselect(let f): return f.hidden == true
        case .external: return false
        }
    }

    internal static func connectFormDefaultValue(_ field: FormSchema.Field) -> FormSchema.Value? {
        switch field {
        case .string(let f): return f.defaultValue.map(FormSchema.Value.string)
        case .number(let f): return f.defaultValue.map(FormSchema.Value.number)
        case .integer(let f): return f.defaultValue.map { .number(Double($0)) }
        case .boolean(let f): return f.defaultValue.map(FormSchema.Value.bool)
        case .multiselect(let f): return f.defaultValue.map(FormSchema.Value.strings)
        case .external: return nil
        }
    }

    internal static func isConnectFormFieldActive(_ field: FormSchema.Field, answer: FormSchema.Answer) -> Bool {
        let conditions: [FormSchema.When]?
        switch field {
        case .string(let f): conditions = f.when
        case .number(let f): conditions = f.when
        case .integer(let f): conditions = f.when
        case .boolean(let f): conditions = f.when
        case .multiselect(let f): conditions = f.when
        case .external: return true
        }
        guard let conditions else { return true }
        return conditions.allSatisfy { cond in
            guard let current = answer[cond.key] else { return false }
            let matches: Bool
            switch (current, cond.value) {
            case (.string(let a), .string(let b)): matches = a == b
            case (.number(let a), .number(let b)): matches = a == b
            case (.bool(let a), .bool(let b)): matches = a == b
            case (.strings(let arr), .string(let b)): matches = arr.contains(b)
            case (.strings(let arr), .number(let b)): matches = arr.contains(String(b))
            case (.strings(let arr), .bool(let b)): matches = arr.contains(String(b))
            default: matches = false
            }
            return cond.op == .eq ? matches : !matches
        }
    }

    internal static func validateConnectFormValue(field: FormSchema.Field, value: FormSchema.Value?) -> String? {
        switch field {
        case .external:
            return nil
        case .string(let f):
            guard let value else { return f.required == true ? "Required" : nil }
            guard case .string(let s) = value else { return "Expected a string" }
            if s.isEmpty && f.required == true { return "Required" }
            if let minLen = f.minLength, s.count < minLen.rawValue {
                return "Must be at least \(minLen.rawValue) characters"
            }
            if let maxLen = f.maxLength, s.count > maxLen.rawValue {
                return "Must be at most \(maxLen.rawValue) characters"
            }
            if let pattern = f.pattern, let rx = try? Regex(pattern), !s.contains(rx) {
                return "Invalid format"
            }
            if let fmt = f.format {
                switch fmt {
                case .uri:
                    if URL(string: s)?.scheme == nil { return "Expected a URL" }
                case .email:
                    let parts = s.split(separator: "@")
                    if parts.count != 2 || !parts[1].contains(".") || s.contains(" ") {
                        return "Expected an email address"
                    }
                case .date:
                    if s.count != 10 || s.split(separator: "-").count != 3 { return "Expected a date" }
                case .dateTime:
                    if !s.contains("T") || s.count < 19 { return "Expected a date and time" }
                }
            }
            if let opts = f.options, !opts.isEmpty, f.custom != true, !opts.contains(where: { $0.value == s }) {
                return "Invalid selection"
            }
            return nil
        case .number(let f):
            guard let value else { return f.required == true ? "Required" : nil }
            guard case .number(let n) = value, n.isFinite else { return "Expected a number" }
            if let minV = f.minimum, n < minV { return "Must be at least \(minV)" }
            if let maxV = f.maximum, n > maxV { return "Must be at most \(maxV)" }
            return nil
        case .integer(let f):
            guard let value else { return f.required == true ? "Required" : nil }
            guard case .number(let n) = value, n.isFinite, n.rounded(.towardZero) == n else {
                return "Expected an integer"
            }
            if let minV = f.minimum, n < minV { return "Must be at least \(minV)" }
            if let maxV = f.maximum, n > maxV { return "Must be at most \(maxV)" }
            return nil
        case .boolean(let f):
            guard let value else { return f.required == true ? "Required" : nil }
            guard case .bool = value else { return "Expected a boolean" }
            return nil
        case .multiselect(let f):
            guard let value else { return f.required == true ? "Required" : nil }
            guard case .strings(let arr) = value else { return "Expected an array of strings" }
            if let minI = f.minItems, arr.count < minI.rawValue { return "Select at least \(minI.rawValue)" }
            if let maxI = f.maxItems, arr.count > maxI.rawValue { return "Select at most \(maxI.rawValue)" }
            return nil
        }
    }

    internal static func connectFormDialogRows(
        form: TUIConnectFormState,
        filter: String,
        errorMessage: String?
    ) -> [TUIDialogRow] {
        guard let field = form.currentField else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func matches(_ text: String, _ secondary: String? = nil) -> Bool {
            guard !needle.isEmpty else { return true }
            if text.lowercased().contains(needle) { return true }
            if let secondary, secondary.lowercased().contains(needle) { return true }
            return false
        }

        switch field {
        case .string(let sf):
            if let opts = sf.options, !opts.isEmpty {
                var rows: [TUIDialogRow] = opts.compactMap { opt in
                    guard matches(opt.label, "\(opt.value) \(opt.description ?? "")") else { return nil }
                    let isDefault = sf.defaultValue == opt.value
                    return TUIDialogRow(
                        id: "form-opt:\(opt.value)",
                        title: opt.label,
                        subtitle: opt.description,
                        trailing: isDefault ? "default" : nil,
                        isActive: isDefault
                    )
                }
                let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
                if sf.custom == true, !trimmed.isEmpty, !opts.contains(where: { $0.value == trimmed }) {
                    rows.append(TUIDialogRow(
                        id: "form-custom:\(trimmed)",
                        title: "Use \"\(trimmed)\"",
                        subtitle: "Custom value",
                        trailing: "enter",
                        badgeColorKind: .success
                    ))
                }
                if sf.required != true, matches("Skip", "optional") {
                    rows.append(TUIDialogRow(
                        id: "form-skip",
                        title: "Skip",
                        subtitle: "Optional"
                    ))
                }
                return rows
            }
            let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            if let err = errorMessage, !err.isEmpty {
                return [
                    TUIDialogRow(
                        id: "form-text-submit",
                        title: trimmed.isEmpty ? (sf.placeholder ?? sf.title ?? sf.key) : trimmed,
                        subtitle: err,
                        trailing: "enter",
                        badgeColorKind: .error
                    ),
                ]
            }
            if !trimmed.isEmpty {
                return [
                    TUIDialogRow(
                        id: "form-text-submit",
                        title: trimmed,
                        subtitle: sf.title ?? sf.key,
                        trailing: "enter confirm",
                        badgeColorKind: .success
                    ),
                ]
            }
            return [
                TUIDialogRow(
                    id: "form-text-submit",
                    title: sf.placeholder ?? sf.title ?? sf.key,
                    subtitle: sf.description ?? (sf.required == true ? "Type value and press Enter" : "Optional — press Enter to skip"),
                    trailing: "enter"
                ),
            ]

        case .boolean(let bf):
            let ordered: [(String, String, Bool)] = bf.defaultValue == false
                ? [("form-bool:false", "No", true), ("form-bool:true", "Yes", false)]
                : [("form-bool:true", "Yes", bf.defaultValue != false), ("form-bool:false", "No", false)]
            var rows: [TUIDialogRow] = ordered.compactMap { id, label, isDefault in
                guard matches(label) else { return nil }
                return TUIDialogRow(
                    id: id,
                    title: label,
                    trailing: isDefault ? "default" : nil,
                    isActive: isDefault
                )
            }
            if bf.required != true, matches("Skip", "optional") {
                rows.append(TUIDialogRow(id: "form-skip", title: "Skip", subtitle: "Optional"))
            }
            return rows

        case .multiselect(let mf):
            let selectedSet = Set(form.multiselectDraft)
            var rows: [TUIDialogRow] = mf.options.compactMap { opt in
                guard matches(opt.label, "\(opt.value) \(opt.description ?? "")") else { return nil }
                let checked = selectedSet.contains(opt.value)
                return TUIDialogRow(
                    id: "form-multi:\(opt.value)",
                    title: "\(checked ? "[✓]" : "[ ]") \(opt.label)",
                    subtitle: opt.description,
                    isActive: checked,
                    badgeColorKind: checked ? .success : nil
                )
            }
            let errSub = (errorMessage?.isEmpty == false) ? errorMessage : "\(form.multiselectDraft.count) selected"
            rows.append(TUIDialogRow(
                id: "form-multi-submit",
                title: "Continue",
                subtitle: errSub,
                trailing: "enter",
                badgeColorKind: (errorMessage?.isEmpty == false) ? .error : .success
            ))
            return rows

        case .number(let nf):
            let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                TUIDialogRow(
                    id: "form-text-submit",
                    title: trimmed.isEmpty ? (nf.defaultValue.map { String($0) } ?? "Enter a number") : trimmed,
                    subtitle: (errorMessage?.isEmpty == false) ? errorMessage : (nf.title ?? nf.key),
                    trailing: "enter",
                    badgeColorKind: (errorMessage?.isEmpty == false) ? .error : (!trimmed.isEmpty ? .success : nil)
                ),
            ]

        case .integer(let inf):
            let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                TUIDialogRow(
                    id: "form-text-submit",
                    title: trimmed.isEmpty ? (inf.defaultValue.map { String($0) } ?? "Enter an integer") : trimmed,
                    subtitle: (errorMessage?.isEmpty == false) ? errorMessage : (inf.title ?? inf.key),
                    trailing: "enter",
                    badgeColorKind: (errorMessage?.isEmpty == false) ? .error : (!trimmed.isEmpty ? .success : nil)
                ),
            ]

        case .external(let ext):
            return [
                TUIDialogRow(
                    id: "form-ext-continue",
                    title: ext.title ?? "Continue after completing browser step",
                    subtitle: ext.url,
                    trailing: "enter",
                    badgeColorKind: .success
                ),
            ]
        }
    }

    private static func initialDraftForConnectField(_ field: FormSchema.Field) -> (filter: String, selectedIndex: Int, multiDraft: [String]) {
        switch field {
        case .string(let sf):
            if let opts = sf.options, !opts.isEmpty {
                let defaultIdx = sf.defaultValue.flatMap { def in opts.firstIndex(where: { $0.value == def }) } ?? 0
                return ("", defaultIdx, [])
            }
            return (sf.defaultValue ?? "", 0, [])
        case .number(let nf):
            return (nf.defaultValue.map { String($0) } ?? "", 0, [])
        case .integer(let inf):
            return (inf.defaultValue.map { String($0) } ?? "", 0, [])
        case .boolean:
            return ("", 0, [])
        case .multiselect(let mf):
            return ("", 0, mf.defaultValue ?? [])
        case .external:
            return ("", 0, [])
        }
    }

    /// Finds the next active visible field starting at `startIndex`, populating any active hidden fields along the way.
    private static func nextVisibleConnectFieldIndex(
        in fields: [FormSchema.Field],
        from startIndex: Int,
        answers: inout FormSchema.Answer
    ) -> Int? {
        var idx = startIndex
        while idx < fields.count {
            let field = fields[idx]
            if !isConnectFormFieldActive(field, answer: answers) {
                idx += 1
                continue
            }
            if connectFormFieldIsHidden(field) {
                if let def = connectFormDefaultValue(field) {
                    answers[connectFormFieldKey(field)] = def
                }
                idx += 1
                continue
            }
            return idx
        }
        return nil
    }

    internal static func connectFormDialogTitle(integrationName: String, fieldTitle: String) -> String {
        let combined = "\(integrationName) — \(fieldTitle)"
        return combined.count <= 44 ? combined : fieldTitle
    }

    internal func beginConnectMethodWithFormCheck(_ item: TUIIntegrationItem, method: TUIIntegrationMethod) {
        guard let formFields = method.form, !formFields.elements.isEmpty else {
            executeConnectMethod(item, method: method, answer: nil)
            return
        }
        var answers: FormSchema.Answer = [:]
        guard let firstVisible = Self.nextVisibleConnectFieldIndex(
            in: formFields.elements,
            from: 0,
            answers: &answers
        ) else {
            executeConnectMethod(item, method: method, answer: answers.isEmpty ? nil : answers)
            return
        }

        let field = formFields.elements[firstVisible]
        let draft = Self.initialDraftForConnectField(field)
        let title = Self.connectFormFieldTitle(field)
        let formState = TUIConnectFormState(
            integrationID: item.id,
            integrationName: item.name,
            method: method,
            fields: formFields.elements,
            fieldIndex: firstVisible,
            visitedIndices: [],
            answers: answers,
            multiselectDraft: draft.multiDraft
        )

        store.withLock { state in
            state.connectFormState = formState
            state.connectFormAnswer = nil
            state.connectTargetIntegrationID = item.id
            state.connectTargetIntegrationName = Self.connectFormDialogTitle(integrationName: item.name, fieldTitle: title)
            state.activeDialog = .connectMethod
            state.dialogFilter = draft.filter
            state.dialogSelectedIndex = draft.selectedIndex
            state.connectErrorMessage = nil
            state.connectSubmitting = false
        }
        markDirty()

        if case .external(let ext) = field, !ext.url.isEmpty {
            launchBrowserURLNonFatal(ext.url)
        }
    }

    internal func confirmConnectFormRow(rowID: String) {
        enum StepOutcome {
            case stay
            case advance(externalURL: String?)
            case complete(item: TUIIntegrationItem, method: TUIIntegrationMethod, answer: FormSchema.Answer)
        }

        let outcome: StepOutcome = store.withLock { state in
            guard var form = state.connectFormState, let field = form.currentField else {
                return .stay
            }
            let key = Self.connectFormFieldKey(field)

            // Toggle multiselect option in place without advancing yet
            if rowID.hasPrefix("form-multi:") {
                let optVal = String(rowID.dropFirst("form-multi:".count))
                if let existing = form.multiselectDraft.firstIndex(of: optVal) {
                    form.multiselectDraft.remove(at: existing)
                } else {
                    form.multiselectDraft.append(optVal)
                }
                state.connectFormState = form
                state.connectErrorMessage = nil
                return .stay
            }

            let parsedValue: FormSchema.Value?
            if rowID == "form-skip" {
                parsedValue = nil
            } else if rowID.hasPrefix("form-opt:") {
                parsedValue = .string(String(rowID.dropFirst("form-opt:".count)))
            } else if rowID.hasPrefix("form-custom:") {
                parsedValue = .string(String(rowID.dropFirst("form-custom:".count)))
            } else if rowID == "form-bool:true" {
                parsedValue = .bool(true)
            } else if rowID == "form-bool:false" {
                parsedValue = .bool(false)
            } else if rowID == "form-multi-submit" {
                parsedValue = form.multiselectDraft.isEmpty ? nil : .strings(form.multiselectDraft)
            } else if rowID == "form-ext-continue" {
                parsedValue = .bool(true)
            } else if rowID == "form-text-submit" {
                let trimmed = state.dialogFilter.trimmingCharacters(in: .whitespacesAndNewlines)
                switch field {
                case .string(let sf):
                    parsedValue = (trimmed.isEmpty && sf.required != true) ? nil : .string(trimmed)
                case .number(let nf):
                    if trimmed.isEmpty && nf.required != true {
                        parsedValue = nil
                    } else if let n = Double(trimmed), n.isFinite {
                        parsedValue = .number(n)
                    } else {
                        state.connectErrorMessage = "Expected a number"
                        return .stay
                    }
                case .integer(let inf):
                    if trimmed.isEmpty && inf.required != true {
                        parsedValue = nil
                    } else if let n = Int(trimmed) {
                        parsedValue = .number(Double(n))
                    } else {
                        state.connectErrorMessage = "Expected an integer"
                        return .stay
                    }
                default:
                    parsedValue = nil
                }
            } else {
                return .stay
            }

            if let err = Self.validateConnectFormValue(field: field, value: parsedValue) {
                state.connectErrorMessage = err
                return .stay
            }

            if let parsedValue {
                form.answers[key] = parsedValue
            } else {
                form.answers.removeValue(forKey: key)
            }
            form.visitedIndices.append(form.fieldIndex)

            if let nextIdx = Self.nextVisibleConnectFieldIndex(
                in: form.fields,
                from: form.fieldIndex + 1,
                answers: &form.answers
            ) {
                let nextField = form.fields[nextIdx]
                let draft = Self.initialDraftForConnectField(nextField)
                let nextTitle = Self.connectFormFieldTitle(nextField)
                form.fieldIndex = nextIdx
                form.multiselectDraft = draft.multiDraft
                state.connectFormState = form
                state.connectTargetIntegrationName = Self.connectFormDialogTitle(integrationName: form.integrationName, fieldTitle: nextTitle)
                state.dialogFilter = draft.filter
                state.dialogSelectedIndex = draft.selectedIndex
                state.connectErrorMessage = nil
                if case .external(let ext) = nextField, !ext.url.isEmpty {
                    return .advance(externalURL: ext.url)
                }
                return .advance(externalURL: nil)
            }

            // Form complete: restore integration name and launch connection method
            let integrationItem = state.integrations.first(where: { $0.id == form.integrationID })
                ?? TUIIntegrationItem(id: form.integrationID, name: form.integrationName, methods: [form.method])
            state.connectFormState = nil
            state.connectTargetIntegrationName = form.integrationName
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.connectErrorMessage = nil
            return .complete(item: integrationItem, method: form.method, answer: form.answers)
        }

        markDirty()
        switch outcome {
        case .stay:
            break
        case .advance(let externalURL):
            if let externalURL {
                launchBrowserURLNonFatal(externalURL)
            }
        case .complete(let item, let method, let answer):
            executeConnectMethod(item, method: method, answer: answer)
        }
    }

    /// Submits a text/number/integer value directly for the currently active connect form field.
    public func submitConnectFormFieldValue(_ rawValue: String) {
        store.withLock { state in
            state.dialogFilter = rawValue
            state.connectErrorMessage = nil
        }
        confirmConnectFormRow(rowID: "form-text-submit")
    }

    internal func navigateBackInConnectForm() {
        let shouldReturnToProviderList: Bool = store.withLock { state in
            guard var form = state.connectFormState else { return true }
            if let prevIdx = form.visitedIndices.popLast(), prevIdx >= 0, prevIdx < form.fields.count {
                let prevField = form.fields[prevIdx]
                let prevKey = Self.connectFormFieldKey(prevField)
                form.answers.removeValue(forKey: prevKey)
                let draft = Self.initialDraftForConnectField(prevField)
                form.fieldIndex = prevIdx
                form.multiselectDraft = draft.multiDraft
                state.connectFormState = form
                state.connectTargetIntegrationName = Self.connectFormDialogTitle(
                    integrationName: form.integrationName,
                    fieldTitle: Self.connectFormFieldTitle(prevField)
                )
                state.dialogFilter = draft.filter
                state.dialogSelectedIndex = draft.selectedIndex
                state.connectErrorMessage = nil
                return false
            }

            // First field: exit form back to method picker (if multiple methods) or provider picker
            let integration = state.integrations.first(where: { $0.id == form.integrationID })
            state.connectFormState = nil
            state.connectFormAnswer = nil
            state.connectTargetIntegrationName = form.integrationName
            state.dialogFilter = ""
            state.dialogSelectedIndex = 0
            state.connectErrorMessage = nil
            if let integration, integration.connectMethods.count > 1 {
                state.activeDialog = .connectMethod
                return false
            }
            return true
        }
        if shouldReturnToProviderList {
            openConnectProvider()
        } else {
            markDirty()
        }
    }

    internal func nextOAuthGeneration() -> Int {
        oauthGeneration.withLock { gen in
            gen &+= 1
            return gen
        }
    }

    internal func currentOAuthGeneration() -> Int {
        oauthGeneration.withLock { $0 }
    }

    internal func cancelActiveOAuthTaskOnly() {
        _ = nextOAuthGeneration()
        let prior = activeOAuthTask.withLock { task -> Task<Void, Never>? in
            let existing = task
            task = nil
            return existing
        }
        prior?.cancel()
    }

    internal func setActiveOAuthTask(_ task: Task<Void, Never>) {
        let prior = activeOAuthTask.withLock { slot -> Task<Void, Never>? in
            let existing = slot
            slot = task
            return existing
        }
        prior?.cancel()
    }

    /// Cancels any active OAuth attempt (stopping polling and notifying `DELETE /api/integration/:id/connect/oauth/:attemptID`).
    public func cancelActiveOAuth() {
        cancelActiveOAuthTaskOnly()
        let activeOAuth = store.withLock { state -> (String, String)? in
            let intID = state.connectTargetIntegrationID
            let attemptID = state.connectOAuthAttemptID
            state.connectSubmitting = false
            state.connectOAuthAttemptID = nil
            state.connectOAuthURL = nil
            state.connectOAuthInstructions = nil
            state.connectOAuthUserCode = nil
            state.connectOAuthMode = nil
            state.connectOAuthNeedsCode = false
            state.connectOAuthAllowsPaste = false
            state.connectErrorMessage = nil
            if let intID, let attemptID {
                return (intID, attemptID)
            }
            return nil
        }
        markDirty()
        if let (intID, attemptID) = activeOAuth {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.client.integration.oauth.cancel(
                    IntegrationOauthCancelInput(
                        integrationID: intID,
                        attemptID: attemptID,
                        location: self.locationQuery
                    )
                )
            }
        }
    }

    /// Re-opens the currently displayed OAuth verification URL in the system browser.
    public func openActiveOAuthURL() {
        guard let url = store.withLock({ $0.connectOAuthURL }), !url.isEmpty else { return }
        launchBrowserURLNonFatal(url)
    }

    private func launchBrowserURLNonFatal(_ url: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.openBrowserURL(url)
            } catch {
                self.store.withLock { state in
                    state.toastMessage = "Could not open the browser. Open the URL manually."
                    state.toastIsError = true
                }
                self.markDirty()
            }
        }
    }

    internal func executeConnectMethod(
        _ item: TUIIntegrationItem,
        method: TUIIntegrationMethod,
        answer: FormSchema.Answer?
    ) {
        switch method {
        case .key(let label, _):
            store.withLock { state in
                state.connectTargetIntegrationID = item.id
                state.connectTargetIntegrationName = item.name
                state.connectMethodLabel = label.isEmpty ? "API key" : label
                state.connectFormState = nil
                state.connectFormAnswer = answer
                state.activeDialog = .connectAPIKey
                state.dialogFilter = ""
                state.dialogSelectedIndex = 0
                state.connectErrorMessage = nil
                state.connectSubmitting = false
            }
            markDirty()

        case .external(let methodID, _, _):
            store.withLock { state in
                state.connectFormState = nil
                state.connectFormAnswer = nil
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
                            methodID: methodID,
                            answer: answer
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

        case .oauth(let methodID, let label, _):
            cancelActiveOAuthTaskOnly()
            let generation = nextOAuthGeneration()
            store.withLock { state in
                state.connectFormState = nil
                state.connectFormAnswer = nil
                state.connectTargetIntegrationID = item.id
                state.connectTargetIntegrationName = item.name
                state.connectMethodLabel = label.isEmpty ? "OAuth" : label
                state.connectOAuthMethodID = methodID
                state.connectOAuthAttemptID = nil
                state.connectOAuthURL = nil
                state.connectOAuthInstructions = "Starting authorization…"
                state.connectOAuthUserCode = nil
                state.connectOAuthMode = nil
                state.connectOAuthNeedsCode = false
                state.connectOAuthAllowsPaste = false
                state.connectSubmitting = true
                state.connectErrorMessage = nil
                state.activeDialog = .connectOAuth
                state.dialogFilter = ""
                state.dialogSelectedIndex = 0
            }
            markDirty()

            let oauthTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let started = try await self.client.integration.oauth.connect(
                        IntegrationOauthConnectInput(
                            integrationID: item.id,
                            location: self.locationQuery,
                            methodID: methodID,
                            answer: answer
                        )
                    )
                    let data = started.data
                    let attemptID = data.attemptID.rawValue
                    let isStillCurrent = !Task.isCancelled
                        && self.currentOAuthGeneration() == generation
                        && self.store.withLock { $0.activeDialog == .connectOAuth && $0.connectTargetIntegrationID == item.id }

                    guard isStillCurrent else {
                        _ = try? await self.client.integration.oauth.cancel(
                            IntegrationOauthCancelInput(
                                integrationID: item.id,
                                attemptID: attemptID,
                                location: self.locationQuery
                            )
                        )
                        return
                    }

                    let userCode = Self.extractOAuthDeviceCode(from: data.instructions)
                    let allowsPaste = (data.paste == true)
                    let showCodeInput = (data.mode == .code) || allowsPaste
                    var displayInstructions = data.instructions
                    if let userCode, !displayInstructions.contains(userCode) {
                        displayInstructions = displayInstructions.isEmpty
                            ? "Enter code: \(userCode)"
                            : "\(displayInstructions) (Code: \(userCode))"
                    }
                    if data.mode == .auto && allowsPaste {
                        let hint = "Waiting for authorization… or paste redirect URL / code and press Enter."
                        displayInstructions = displayInstructions.isEmpty ? hint : "\(displayInstructions)\n\(hint)"
                    }

                    self.store.withLock { state in
                        guard state.activeDialog == .connectOAuth else { return }
                        state.connectOAuthAttemptID = attemptID
                        state.connectOAuthURL = data.url
                        state.connectOAuthInstructions = displayInstructions
                        state.connectOAuthUserCode = userCode
                        state.connectOAuthMode = data.mode
                        state.connectOAuthAllowsPaste = allowsPaste
                        state.connectOAuthNeedsCode = showCodeInput
                        state.connectSubmitting = false
                    }
                    self.markDirty()

                    if !data.url.isEmpty {
                        do {
                            try await self.openBrowserURL(data.url)
                        } catch {
                            self.store.withLock { state in
                                state.toastMessage = "Could not open the browser. Open the URL manually."
                                state.toastIsError = true
                            }
                            self.markDirty()
                        }
                    }

                    if data.mode == .auto {
                        await self.pollOAuthAttempt(
                            integrationID: item.id,
                            integrationName: item.name,
                            attemptID: attemptID,
                            generation: generation
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.currentOAuthGeneration() == generation else { return }
                    self.store.withLock { state in
                        guard state.activeDialog == .connectOAuth else { return }
                        state.connectSubmitting = false
                        state.connectErrorMessage = "\(error)"
                    }
                    self.markDirty()
                }
            }
            setActiveOAuthTask(oauthTask)

        case .command(let methodID, let label):
            store.withLock { state in
                state.connectFormState = nil
                state.connectFormAnswer = nil
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

    internal func submitOAuthManualCodeOrReopenBrowser(_ rawCode: String? = nil) {
        enum Action {
            case none
            case reopenBrowser(String)
            case complete(id: String, name: String, attemptID: String, code: String, mode: IntegrationSchema.Attempt.Mode?)
        }

        let action: Action = store.withLock { state in
            guard state.activeDialog == .connectOAuth,
                  !state.connectSubmitting,
                  let id = state.connectTargetIntegrationID,
                  let attemptID = state.connectOAuthAttemptID
            else {
                return .none
            }
            let code = (rawCode ?? state.dialogFilter).trimmingCharacters(in: .whitespacesAndNewlines)
            if code.isEmpty {
                if state.connectOAuthMode == .auto, let url = state.connectOAuthURL, !url.isEmpty {
                    return .reopenBrowser(url)
                }
                state.connectErrorMessage = "Please paste the authorization code"
                return .none
            }
            state.connectSubmitting = true
            state.connectErrorMessage = nil
            return .complete(
                id: id,
                name: state.connectTargetIntegrationName,
                attemptID: attemptID,
                code: code,
                mode: state.connectOAuthMode
            )
        }
        markDirty()

        switch action {
        case .none:
            return
        case .reopenBrowser(let url):
            launchBrowserURLNonFatal(url)
            return
        case .complete(let id, let name, let attemptID, let code, let mode):
            cancelActiveOAuthTaskOnly()
            let generation = nextOAuthGeneration()
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.integration.oauth.complete(
                        IntegrationOauthCompleteInput(
                            integrationID: id,
                            attemptID: attemptID,
                            location: self.locationQuery,
                            code: code
                        )
                    )
                    guard !Task.isCancelled, self.currentOAuthGeneration() == generation else { return }
                    await self.finishProviderConnected(integrationID: id, integrationName: name)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.currentOAuthGeneration() == generation else { return }
                    self.store.withLock { state in
                        state.connectSubmitting = false
                        state.connectErrorMessage = "\(error)"
                    }
                    self.markDirty()
                    if mode == .auto {
                        await self.pollOAuthAttempt(
                            integrationID: id,
                            integrationName: name,
                            attemptID: attemptID,
                            generation: generation
                        )
                    }
                }
            }
            setActiveOAuthTask(task)
        }
    }

    internal func pollOAuthAttempt(
        integrationID: String,
        integrationName: String,
        attemptID: String,
        generation: Int
    ) async {
        let maxPolls = 900 // Up to 15 minutes at 1s polling cadence
        for pollIdx in 0..<maxPolls {
            if Task.isCancelled || currentOAuthGeneration() != generation { return }
            if pollIdx > 0 {
                do {
                    try await Task.sleep(for: oauthPollInterval)
                } catch {
                    return
                }
            }
            if Task.isCancelled || currentOAuthGeneration() != generation { return }
            let stillActive = store.withLock { state in
                state.activeDialog == .connectOAuth
                    && state.connectOAuthAttemptID == attemptID
                    && !state.connectSubmitting
            }
            guard stillActive else { return }

            do {
                let resp = try await client.integration.oauth.status(
                    IntegrationOauthStatusInput(
                        integrationID: integrationID,
                        attemptID: attemptID,
                        location: locationQuery
                    )
                )
                if Task.isCancelled || currentOAuthGeneration() != generation { return }
                switch resp.data {
                case .pending:
                    continue
                case .complete:
                    await finishProviderConnected(integrationID: integrationID, integrationName: integrationName)
                    return
                case .failed(let msg, _):
                    store.withLock { state in
                        guard state.activeDialog == .connectOAuth && state.connectOAuthAttemptID == attemptID else { return }
                        state.connectSubmitting = false
                        state.connectOAuthAttemptID = nil
                        state.connectErrorMessage = msg
                        state.toastMessage = msg
                        state.toastIsError = true
                    }
                    markDirty()
                    return
                case .expired:
                    store.withLock { state in
                        guard state.activeDialog == .connectOAuth && state.connectOAuthAttemptID == attemptID else { return }
                        state.connectSubmitting = false
                        state.connectOAuthAttemptID = nil
                        state.connectErrorMessage = "Authorization expired"
                        state.toastMessage = "Authorization expired"
                        state.toastIsError = true
                    }
                    markDirty()
                    return
                }
            } catch is CancellationError {
                return
            } catch let err as ClientError where err.statusCode == 404 || err.statusCode == 410 {
                store.withLock { state in
                    guard state.activeDialog == .connectOAuth && state.connectOAuthAttemptID == attemptID else { return }
                    state.connectSubmitting = false
                    state.connectOAuthAttemptID = nil
                    state.connectErrorMessage = "Authorization session expired"
                }
                markDirty()
                return
            } catch {
                continue
            }
        }
    }
}
