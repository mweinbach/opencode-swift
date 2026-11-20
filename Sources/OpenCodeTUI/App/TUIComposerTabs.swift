#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIRenderables

// MARK: - Composer Tabs (`packages/tui/src/routes/session/composer/tabs.ts`)

extension TUIRoutes {
    /// The picker's fixed tab order. Unknown tabs sort after these.
    private static let composerTabOrder = ["subagents", "shell", "scripts", "terminals"]

    private static func composerTabRank(_ id: String) -> Int {
        composerTabOrder.firstIndex(of: id) ?? composerTabOrder.count
    }

    /// What a session has running, for the picker tabs and the prompt footer.
    public struct BusyCounts: Equatable, Hashable, Sendable {
        public var scripts: Int
        public var subagents: Int
        public var shells: Int

        public init(scripts: Int = 0, subagents: Int = 0, shells: Int = 0) {
            self.scripts = scripts
            self.subagents = subagents
            self.shells = shells
        }
    }

    /// Counts the running scripts, busy subagents and shells of `sessionID`.
    ///
    /// - Parameters:
    ///   - jobs: `data.job.list(sessionID)`, the running jobs of the session's tree.
    ///   - family: `data.session.family(sessionID)`, every session id in the tree.
    ///   - status: `data.session.status(id)`.
    ///   - parentID: `data.session.get(id)?.parentID`.
    ///   - shellSessionIDs: `metadata.sessionID` of every shell in `data.shell.list(location)`.
    // parity: tui/src/routes/session/composer/tabs.ts#busyCounts [status=adapted hash=1493376a2e8b]
    public static func busyCounts(
        sessionID: String,
        jobs: [JobSchema.Info],
        family: [String],
        status: (String) -> String?,
        parentID: (String) -> String?,
        shellSessionIDs: [String?]
    ) -> BusyCounts {
        BusyCounts(
            scripts: jobs.filter {
                let fields = TUIUtil.JobFields($0)
                return fields.kind == .codemode && fields.sessionID == sessionID
            }.count,
            subagents: family.filter { id in
                id != sessionID
                    && (status(id) == "running" || !TUIUtil.ownedJobs(jobs, sessionID: id, parentID: parentID).isEmpty)
            }.count,
            shells: shellSessionIDs.filter { $0 == sessionID }.count
        )
    }

    /// The tab the picker opens on when nothing asks for one: the first that has something running, else Subagents.
    // parity: tui/src/routes/session/composer/tabs.ts#busyTab [status=implemented hash=408d5197e2de]
    public static func busyTab(_ input: BusyCounts) -> String {
        if input.scripts > 0 { return "scripts" }
        if input.subagents > 0 { return "subagents" }
        if input.shells > 0 { return "shell" }
        return "subagents"
    }

    /// The picker's tabs in a fixed order, and which one is active. Tabs that come and go while it is open, like
    /// Scripts, leave the active tab alone unless they remove it.
    ///
    /// Solid's two effects become explicit reconciliation: ``setInputs(open:defaultTab:)`` replays the effect keyed on
    /// `[open, defaultTab]`, and every change to the tabs, the active tab or the inputs replays the effect that keeps
    /// the active tab valid.
    public final class ComposerTabs: Sendable {
        private struct State: Sendable {
            var tabs: [ComposerTab] = []
            var active: String = ""
            /// Set once the user picks a tab, so a requested tab that registers late no longer takes over.
            var chosen = false
            var open = false
            var defaultTab: String?
        }

        private let state: Mutex<State>

        public init(open: Bool = false, defaultTab: String? = nil) {
            state = Mutex(State(open: open, defaultTab: defaultTab))
        }

        /// Tabs sorted by the fixed picker order; equal ranks keep registration order.
        public var list: [ComposerTab] { state.withLock { Self.sorted($0.tabs) } }

        public var active: String { state.withLock { $0.active } }

        public var open: Bool { state.withLock { $0.open } }

        public func setActive(_ id: String) {
            state.withLock { s in
                s.active = id
                s.chosen = true
                Self.reconcile(&s)
            }
        }

        /// Updates `open` and `defaultTab`. A change re-picks the requested tab (or the first) while open.
        public func setInputs(open: Bool, defaultTab: String?) {
            state.withLock { s in
                guard s.open != open || s.defaultTab != defaultTab else { return }
                s.open = open
                s.defaultTab = defaultTab
                s.chosen = false
                let tabs = Self.sorted(s.tabs)
                if open && !tabs.isEmpty { Self.pick(&s, tabs) }
                Self.reconcile(&s)
            }
        }

        public func register(_ tab: ComposerTab) -> @Sendable () -> Void {
            state.withLock { s in
                if let index = s.tabs.firstIndex(where: { $0.id == tab.id }) {
                    s.tabs[index] = tab
                } else {
                    s.tabs.append(tab)
                }
                if s.active.isEmpty { s.active = tab.id }
                Self.reconcile(&s)
            }
            return { [weak self] in
                self?.state.withLock { s in
                    s.tabs.removeAll { $0.id == tab.id }
                    Self.reconcile(&s)
                }
            }
        }

        private static func sorted(_ tabs: [ComposerTab]) -> [ComposerTab] {
            tabs.enumerated()
                .sorted { lhs, rhs in
                    let (l, r) = (composerTabRank(lhs.element.id), composerTabRank(rhs.element.id))
                    return l != r ? l < r : lhs.offset < rhs.offset
                }
                .map(\.element)
        }

        private static func pick(_ s: inout State, _ tabs: [ComposerTab]) {
            let match = s.defaultTab.flatMap { requested in tabs.first { $0.id == requested } }
            s.active = match?.id ?? tabs[0].id
        }

        private static func reconcile(_ s: inout State) {
            let tabs = sorted(s.tabs)
            guard s.open, !tabs.isEmpty else { return }
            let late = !s.chosen
                && s.defaultTab.map { requested in requested != s.active && tabs.contains { $0.id == requested } } == true
            if late || !tabs.contains(where: { $0.id == s.active }) { pick(&s, tabs) }
        }
    }

    // parity: tui/src/routes/session/composer/tabs.ts#createComposerTabs [status=adapted hash=22dd25133a0f]
    public static func createComposerTabs(open: Bool = false, defaultTab: String? = nil) -> ComposerTabs {
        ComposerTabs(open: open, defaultTab: defaultTab)
    }
}

// MARK: - Scripts Tab (`packages/tui/src/routes/session/composer/scripts-tab.tsx`)

extension TUIRoutes {
    public struct ScriptsTabEntry: Equatable, Hashable, Sendable {
        public let id: String
        public let label: String
        public let started: Double

        public init(id: String, label: String, started: Double) {
            self.id = id
            self.label = label
            self.started = started
        }
    }

    /// The running Code Mode scripts of `sessionID`. Scripts show for the main session only, like desktop.
    public static func runningScripts(sessionID: String, parentID: String?, jobs: [JobSchema.Info]) -> [JobSchema.Info] {
        if let parentID, !parentID.isEmpty { return [] }
        return jobs.filter {
            let fields = TUIUtil.JobFields($0)
            return fields.kind == .codemode && fields.sessionID == sessionID
        }
    }

    /// The elapsed label of a running script: whole seconds under a minute, else the locale duration.
    public static func scriptElapsed(started: Double, now: Double) -> String {
        let ms = max(0, now - started)
        return ms < 60_000 ? "\(Int((ms / 1000).rounded(.down)))s" : duration(ms)
    }

    /// Selection and commands of the Scripts tab (`composer.script.up`, `.down`, `.cancel`).
    public final class ScriptsTabModel: Sendable {
        private let selectedState = Mutex(0)

        public init() {}

        public var selected: Int { selectedState.withLock { $0 } }

        /// Keeps the selection on a script when the list shrinks.
        public func clamp(count: Int) {
            selectedState.withLock { if $0 >= count { $0 = max(0, count - 1) } }
        }

        public func select(_ index: Int) {
            selectedState.withLock { $0 = index }
        }

        /// `composer.script.up`: the first row closes the picker.
        public func up(close: () -> Void) {
            let atTop = selectedState.withLock { selected -> Bool in
                if selected == 0 { return true }
                selected -= 1
                return false
            }
            if atTop { close() }
        }

        /// `composer.script.down`: wraps to the first script.
        public func down(count: Int) {
            guard count > 0 else { return }
            selectedState.withLock { $0 = ($0 + 1) % count }
        }

        /// `composer.script.cancel`: the job to cancel through `experimental.job.cancel`, if any.
        public func cancelTarget(_ scripts: [JobSchema.Info]) -> String? {
            let index = selected
            return scripts.indices.contains(index) ? TUIUtil.JobFields(scripts[index]).id : nil
        }

        /// The tab's footer hints: cancel while a script is selected.
        public func hints(_ scripts: [JobSchema.Info], cancelShortcut: String?) -> [ComposerHint] {
            scripts.indices.contains(selected) ? [ComposerHint(label: "cancel", shortcut: cancelShortcut ?? "")] : []
        }

        /// Registers the Scripts tab while any script runs; returns the unregister callback.
        public func register(
            in tabs: ComposerTabs,
            scripts: @escaping @Sendable () -> [JobSchema.Info],
            cancelShortcut: @escaping @Sendable () -> String?
        ) -> (@Sendable () -> Void)? {
            guard !scripts().isEmpty else { return nil }
            return tabs.register(ComposerTab(id: "scripts", label: "Scripts") { [weak self] in
                self?.hints(scripts(), cancelShortcut: cancelShortcut()) ?? []
            })
        }
    }

    /// Builds the Scripts tab rows: each running script's first line of code and its elapsed time. Labels scan the
    /// transcript, so the caller passes `messages` only while the tab shows.
    // parity: tui/src/routes/session/composer/scripts-tab.tsx#ScriptsTab [status=adapted hash=9666db567929]
    public static func ScriptsTab(
        ctx: any RenderContext,
        sessionID: String,
        parentID: String? = nil,
        jobs: [JobSchema.Info],
        messages: [SessionMessageSchema.Info],
        active: Bool,
        selected: Int = 0,
        now: Double,
        theme: ResolvedTheme? = nil
    ) -> BoxRenderable {
        let t = theme ?? (try! resolveThemeDocument(ThemeDefaults.opencode, mode: .dark))
        let box = BoxRenderable(ctx: ctx, options: BoxOptions(
            id: "composer-scripts-\(sessionID)",
            maxHeight: .point(5),
            flexDirection: .column,
            visible: active
        ))
        guard active else { return box }
        let entries = runningScripts(sessionID: sessionID, parentID: parentID, jobs: jobs).map { job in
            let fields = TUIUtil.JobFields(job)
            return ScriptsTabEntry(id: fields.id, label: TUIUtil.scriptLabel(messages, job: job), started: fields.started)
        }
        for (index, entry) in entries.enumerated() {
            let isActive = index == selected
            let row = BoxRenderable(ctx: ctx, options: BoxOptions(
                flexDirection: .row,
                paddingRight: .point(1),
                paddingLeft: .point(1),
                gap: .point(1),
                backgroundColor: .rgba(isActive ? t.background.action.primary.focused : t.background.action.primary.base)
            ))
            let labelBox = BoxRenderable(ctx: ctx, options: BoxOptions(minWidth: .point(0), flexGrow: 1, flexDirection: .row))
            labelBox.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(entry.label),
                fg: .rgba(isActive ? t.text.action.primary.focused : t.text.action.primary.base),
                attributes: isActive ? TextAttributes.bold : TextAttributes.none,
                wrapMode: TextWrapMode.none,
                truncate: true
            )))
            row.add(labelBox)
            row.add(TextRenderable(ctx: ctx, options: TextOptions(
                content: .string(scriptElapsed(started: entry.started, now: now)),
                flexShrink: 0,
                fg: .rgba(isActive ? t.text.action.primary.focused : t.text.muted),
                wrapMode: TextWrapMode.none
            )))
            box.add(row)
        }
        return box
    }
}
