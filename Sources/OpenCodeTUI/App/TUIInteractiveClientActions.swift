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
        let cleanSlug = String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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
        let text = store.withLock { $0.promptText.trimmingCharacters(in: .whitespacesAndNewlines) }
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
}
