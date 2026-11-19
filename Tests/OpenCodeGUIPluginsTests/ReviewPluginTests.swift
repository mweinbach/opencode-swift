import Testing
import OpenCodeGUIPlugins
import OpenCodeSchema
import OpenCodeUtil

@Suite("Review Plugin Domain & State Machines")
struct ReviewPluginTests {
    @Test("path normalization, directory scoping, depth-first sort, and folder expansion match upstream")
    func pathKindsAndSorting() {
        #expect(ReviewPathHelper.reviewDiffDirectory(root: "/repo", file: "src/lib/a.ts") == "/repo/src/lib")
        #expect(ReviewPathHelper.reviewDiffDirectory(root: #"C:\repo"#, file: "src/lib/a.ts") == #"C:\repo\src\lib"#)
        #expect(ReviewPathHelper.reviewDiffDirectory(root: "/repo/", file: "README.md") == "/repo")
        #expect(ReviewPathHelper.reviewDiffDirectory(root: "/", file: "src/a.ts") == "/src")
        #expect(ReviewPathHelper.reviewDiffDirectory(root: #"C:\"#, file: "src/a.ts") == #"C:\src"#)

        let sorted = ReviewPathHelper.sortReviewPaths(["README.md", "src/a.ts", "src/lib/z.ts", "docs/guide.md", "src/lib/b.ts"])
        #expect(sorted == ["docs/guide.md", "src/lib/b.ts", "src/lib/z.ts", "src/a.ts", "README.md"])

        let noHunk = SessionSchema.FileDiffInfo(file: "src/a.ts", patch: "diff --git a/src/a.ts b/src/a.ts", additions: 1, deletions: 0, status: .modified)
        let hasHunk = SessionSchema.FileDiffInfo(file: "src/a.ts", patch: "@@ -0,0 +1 @@\n+hi", additions: 1, deletions: 0, status: .modified)
        let imageDiff = SessionSchema.FileDiffInfo(file: "assets/logo.png", patch: "", additions: 1, deletions: 0, status: .added)
        #expect(ReviewPathHelper.reviewDiffNeedsLoad(noHunk))
        #expect(!ReviewPathHelper.reviewDiffNeedsLoad(hasHunk))
        #expect(!ReviewPathHelper.reviewDiffNeedsLoad(imageDiff))

        let folderRow = SessionSchema.FileDiffInfo(file: "research/", patch: "", additions: 0, deletions: 0, status: .added)
        let childRow = SessionSchema.FileDiffInfo(file: "research/a.md", patch: "", additions: 1, deletions: 0, status: .added)
        let moreRow = SessionSchema.FileDiffInfo(file: "research/", patch: "", additions: 0, deletions: 0, status: .added, more: true)
        let expanded = ReviewPathHelper.expandReviewFolders(rows: [folderRow], loaded: ["research/": [childRow, moreRow]])
        #expect(expanded.map(\.file) == ["research/", "research/a.md"])

        let kinds = ReviewPathHelper.reviewDiffKinds([
            SessionSchema.FileDiffInfo(file: "src/new.swift", patch: "", additions: 1, deletions: 0, status: .added),
            SessionSchema.FileDiffInfo(file: "src/old.swift", patch: "", additions: 0, deletions: 1, status: .deleted),
        ])
        #expect(kinds["src/new.swift"] == .add)
        #expect(kinds["src/old.swift"] == .del)
        #expect(kinds["src"] == .mix)
    }

    @Test("review diff machine handles stale refresh, offline preservation, and retry")
    func diffMachineTransitions() {
        let target = ReviewDiffMachine.Target.vcs(
            serverID: "srv",
            directory: "/repo",
            mode: .git,
            branch: "feat",
            defaultBranch: "main"
        )
        let t1 = ReviewDiffMachine.reduce(
            state: ReviewDiffMachine.initialState,
            event: .contextChanged(.ready(target: target, connected: true, demanded: true))
        )
        #expect(t1.effects == [.fetch(target: target, attempt: 1)])

        // Refresh while loading marks state stale; completing triggers follow-up fetch
        let t2 = ReviewDiffMachine.reduce(state: t1.state, event: .refresh(source: .vcs))
        let rows = ReviewDiffMachine.Rows(
            rows: [SessionSchema.FileDiffInfo(file: "a.swift", patch: "", additions: 2, deletions: 0, status: .modified)],
            version: 100
        )
        let t3 = ReviewDiffMachine.reduce(state: t2.state, event: .fetchSucceeded(attempt: 1, rows: rows))
        #expect(t3.effects == [.fetch(target: target, attempt: 2)])
        #expect(ReviewDiffMachine.isReady(t3.state))

        // Failed refresh keeps loaded rows
        let t4 = ReviewDiffMachine.reduce(state: t3.state, event: .fetchFailed(attempt: 2, message: "boom"))
        #expect(ReviewDiffMachine.view(t4.state) == .ready(rows: rows.rows, version: 100))
    }

    @Test("review folder machine retries with exponential backoff and formats truncated labels")
    func folderMachineLifecycle() {
        let source = ReviewFolderMachine.Source(
            serverID: "srv",
            root: "/repo",
            directory: "/repo",
            mode: .git,
            branch: "main",
            defaultBranch: "main"
        )
        let folder = SessionSchema.FileDiffInfo(file: "untracked/", patch: "", additions: 0, deletions: 0, status: .added)
        let ctx = ReviewFolderMachine.Context(source: source, connected: true, rows: [folder], expanded: ["untracked/"])
        var state = ReviewFolderMachine.initialState
        let t1 = ReviewFolderMachine.reduce(state: state, event: .contextChanged(ctx))
        state = t1.state
        #expect(t1.effects == [.fetch(folder: "untracked/", source: source, attempt: 1, delayMs: 0)])

        // Failure triggers exponential backoff: 1000ms, 2000ms, 4000ms, then error
        let f1 = ReviewFolderMachine.reduce(state: state, event: .fetchFailed(folder: "untracked/", attempt: 1))
        #expect(f1.effects == [.fetch(folder: "untracked/", source: source, attempt: 2, delayMs: 1_000)])
        let f2 = ReviewFolderMachine.reduce(state: f1.state, event: .fetchFailed(folder: "untracked/", attempt: 2))
        #expect(f2.effects == [.fetch(folder: "untracked/", source: source, attempt: 3, delayMs: 2_000)])
        let f3 = ReviewFolderMachine.reduce(state: f2.state, event: .fetchFailed(folder: "untracked/", attempt: 3))
        #expect(f3.effects == [.fetch(folder: "untracked/", source: source, attempt: 4, delayMs: 4_000)])
        let f4 = ReviewFolderMachine.reduce(state: f3.state, event: .fetchFailed(folder: "untracked/", attempt: 4))
        #expect(f4.effects.isEmpty)
        let errLabels = ReviewFolderMachine.labels(state: f4.state, formatMore: { "\($0)+" }, failedLabel: "Failed")
        #expect(errLabels["untracked"] == "Failed")

        // Retry succeeds with `more` marker
        let r1 = ReviewFolderMachine.reduce(state: f4.state, event: .retry)
        #expect(r1.effects == [.fetch(folder: "untracked/", source: source, attempt: 5, delayMs: 0)])
        let entries = [
            SessionSchema.FileDiffInfo(file: "untracked/f1.txt", patch: "", additions: 1, deletions: 0, status: .added),
            SessionSchema.FileDiffInfo(file: "untracked/", patch: "", additions: 0, deletions: 0, status: .added, more: true),
        ]
        let r2 = ReviewFolderMachine.reduce(state: r1.state, event: .fetchSucceeded(folder: "untracked/", attempt: 5, entries: entries))
        let readyLabels = ReviewFolderMachine.labels(state: r2.state, formatMore: { "\($0)+" }, failedLabel: "Failed")
        #expect(readyLabels["untracked"] == "1+")
    }

    @Test("review detail machine falls back from scoped directory to bounded patch with retries")
    func detailMachineFallback() {
        let target = ReviewDetailMachine.Target.vcs(
            serverID: "srv",
            mode: .git,
            branch: "main",
            defaultBranch: "main",
            root: "/repo",
            scoped: "/repo/src",
            file: "src/large.swift",
            additions: 120,
            deletions: 4,
            version: 1
        )
        let t1 = ReviewDetailMachine.reduce(
            state: ReviewDetailMachine.initialState,
            event: .contextChanged(.needed(target: target, connected: true))
        )
        #expect(t1.effects == [.fetch(target: target, stage: .scoped, attempt: 1, delayMs: 0)])

        // Scoped failure immediately falls back to bounded with 0 delay
        let t2 = ReviewDetailMachine.reduce(state: t1.state, event: .fetchFailed(attempt: 1, message: "too large"))
        #expect(t2.effects == [.fetch(target: target, stage: .bounded, attempt: 2, delayMs: 0)])

        let fullDiff = SessionSchema.FileDiffInfo(file: "src/large.swift", patch: "@@ -1 +1 @@\n+ok", additions: 120, deletions: 4, status: .modified)
        let t3 = ReviewDetailMachine.reduce(state: t2.state, event: .fetchSucceeded(attempt: 2, diff: fullDiff))
        #expect(ReviewDetailMachine.view(state: t3.state, target: target) == .ready(diff: fullDiff))
    }

    @Test("review git-init, render, scroll, screen machines and comment drafts work cohesively")
    func companionMachinesAndController() async {
        // Git init machine
        var gitInit = ReviewInitGitMachine.createState()
        let g1 = ReviewInitGitMachine.reduce(state: gitInit, event: .initRequested(sessionKey: "s1", ready: true))
        gitInit = g1.state
        #expect(ReviewInitGitMachine.isInitializingGit(gitInit, sessionKey: "s1"))
        let g2 = ReviewInitGitMachine.reduce(state: gitInit, event: .initSucceeded(sessionKey: "s1", attempt: 1))
        #expect(g2.effects == [.attemptAbort(attempt: 1), .cachesSync(sessionKey: "s1", attempt: 2, timeoutMs: 30_000)])

        // Render deferral machine
        var render = ReviewRenderMachine.initialState
        render = ReviewRenderMachine.reduce(state: render, event: .visitSynced(visitID: 1)).state
        #expect(!ReviewRenderMachine.panelReady(render))
        render = ReviewRenderMachine.reduce(state: render, event: .frameSettled(attempt: 1)).state
        #expect(ReviewRenderMachine.panelReady(render))
        render = ReviewRenderMachine.reduce(state: render, event: .visitSynced(visitID: 2)).state
        #expect(ReviewRenderMachine.panelReady(render))
        #expect(!ReviewRenderMachine.mobileReady(render))

        // Screen demand machine
        var screen = ReviewScreenMachine.initialState
        screen = ReviewScreenMachine.reduce(state: screen, event: .watchAdded(screenID: 1, watchID: 10, source: .tree)).state
        let enter = ReviewScreenMachine.reduce(state: screen, event: .routeEntered(screenID: 1))
        #expect(enter.effects == [.modelCreate(screenID: 1, attempt: 1)])
        #expect(ReviewScreenMachine.demand(enter.state, screenID: 1).tree == 1)

        // ReviewController comment drafts & filter
        let controller = ReviewController()
        let c = await controller.addComment(
            file: "src/app.swift",
            selection: LineRangeSelection(start: 20, end: 10),
            comment: "Check edge case"
        )
        #expect(c.selection == LineRangeSelection(start: 10, end: 20))
        _ = await controller.updateComment(id: c.id, comment: "Updated note")
        #expect(await controller.allComments().first?.comment == "Updated note")
        #expect(await controller.removeComment(id: c.id))
        #expect(await controller.allComments().isEmpty)
    }

    @Test("review scroll machine manages narrow restore, focused file scroll retries, and user interaction")
    func scrollMachineLifecycle() {
        let ctx = ReviewScrollMachine.Context(visitID: 1, narrow: true, scroller: true, ready: true, layoutReady: true, commentFocused: false)
        var state = ReviewScrollMachine.initialState
        let t1 = ReviewScrollMachine.reduce(state: state, event: .contextSynced(ctx))
        state = t1.state
        #expect(t1.effects == [.frameRestore(attempt: 1)])
        #expect(ReviewScrollMachine.canRestore(state, attempt: 1))
        #expect(!ReviewScrollMachine.canSave(state))

        let focused = ReviewScrollMachine.reduce(state: state, event: .fileFocused(path: "src/a.swift"))
        state = focused.state
        #expect(focused.effects == [.frameCancel, .frameSchedule(attempt: 2, path: "src/a.swift")])

        let retry = ReviewScrollMachine.reduce(state: state, event: .frameStepped(attempt: 2, outcome: .retry))
        state = retry.state
        #expect(retry.effects == [.frameSchedule(attempt: 2, path: "src/a.swift")])

        let settled = ReviewScrollMachine.reduce(state: state, event: .frameStepped(attempt: 2, outcome: .settled))
        #expect(ReviewScrollMachine.canSave(settled.state))
    }
}
