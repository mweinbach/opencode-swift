import Foundation
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Review Contracts & Comment Drafts (`review/contract.ts`, `review/model.ts`)

public enum ReviewChangeKind: String, Equatable, Hashable, Sendable, Codable {
    case add
    case del
    case mix
}

public enum ReviewChangeMode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case git
    case branch
    case turn
}

public enum ReviewDiffFailure: Equatable, Hashable, Sendable, Codable {
    case rejected(message: String)
    case timeout
}

public typealias ReviewDetailsFailure = ReviewDiffFailure

public enum ReviewDetailsView: Equatable, Sendable {
    case loading
    case offline
    case noVCS
    case error(failure: ReviewDetailsFailure)
    case ready(rows: [SessionSchema.FileDiffInfo], version: Int)
}

public struct ReviewLineComment: Equatable, Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let file: String
    public let selection: LineRangeSelection
    public let comment: String
    public let preview: String?

    public init(
        id: String,
        file: String,
        selection: LineRangeSelection,
        comment: String,
        preview: String? = nil
    ) {
        self.id = id
        self.file = file
        self.selection = LineRangeSelection(
            start: min(selection.start, selection.end),
            end: max(selection.start, selection.end)
        )
        self.comment = comment
        self.preview = preview
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(file)
        hasher.combine(selection.start)
        hasher.combine(selection.end)
        hasher.combine(comment)
        hasher.combine(preview)
    }
}

public struct ReviewCommentFocus: Equatable, Hashable, Sendable, Codable {
    public let file: String
    public let id: String

    public init(file: String, id: String) {
        self.file = file
        self.id = id
    }
}

/// Pure immutable draft store for code review inline line comments and focus tracking.
public struct ReviewCommentStore: Equatable, Sendable {
    public private(set) var comments: [ReviewLineComment]
    public private(set) var focus: ReviewCommentFocus?
    private var nextID: Int

    public init(comments: [ReviewLineComment] = [], focus: ReviewCommentFocus? = nil) {
        self.comments = comments
        self.focus = focus
        self.nextID = comments.count
    }

    @discardableResult
    public mutating func add(
        file: String,
        selection: LineRangeSelection,
        comment: String,
        preview: String? = nil,
        id: String? = nil
    ) -> ReviewLineComment {
        nextID += 1
        let item = ReviewLineComment(
            id: id ?? "review-comment-\(nextID)",
            file: file,
            selection: selection,
            comment: comment,
            preview: preview
        )
        comments.append(item)
        return item
    }

    @discardableResult
    public mutating func update(id: String, comment: String, preview: String? = nil) -> ReviewLineComment? {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return nil }
        let existing = comments[index]
        let updated = ReviewLineComment(
            id: existing.id,
            file: existing.file,
            selection: existing.selection,
            comment: comment,
            preview: preview ?? existing.preview
        )
        comments[index] = updated
        return updated
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = comments.count
        comments.removeAll { $0.id == id }
        if focus?.id == id {
            focus = nil
        }
        return comments.count != before
    }

    public mutating func setFocus(_ focus: ReviewCommentFocus?) {
        self.focus = focus
    }

    public func comments(forFile file: String) -> [ReviewLineComment] {
        let normalized = ReviewPathHelper.normalizePath(file)
        return comments.filter { ReviewPathHelper.normalizePath($0.file) == normalized }
    }
}

// MARK: - Review Path, Diff Kinds & Sorting Helpers (`review/kinds.ts`)

public enum ReviewListKey: String, Equatable, Hashable, Sendable {
    case arrowDown = "ArrowDown"
    case arrowUp = "ArrowUp"
    case enter = "Enter"
}

public enum ReviewListNavigationResult: Equatable, Sendable {
    case none
    case highlight(String)
    case select(String)
}

public enum ReviewPathHelper {
    public static func normalizePath(_ value: String) -> String {
        let slashReplaced = value.replacingOccurrences(of: "\\", with: "/")
        let trimmed = slashReplaced.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var result = ""
        var previousWasSlash = false
        for ch in trimmed {
            if ch == "/" {
                if !previousWasSlash {
                    result.append(ch)
                    previousWasSlash = true
                }
            } else {
                result.append(ch)
                previousWasSlash = false
            }
        }
        return result
    }

    public static func reviewDiffNeedsLoad(_ diff: SessionSchema.FileDiffInfo) -> Bool {
        if diff.additions == 0 && diff.deletions == 0 {
            return false
        }
        let kind = artifactKind(diff.file)
        if kind == .image || kind == .audio {
            return false
        }
        if diff.patch.isEmpty {
            return true
        }
        let hasHunk = diff.patch
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .contains { $0.hasPrefix("@@ ") }
        return !hasHunk
    }

    public static func reviewRootDirectory(_ root: String) -> String {
        if root == "/" { return root }
        let chars = Array(root)
        if chars.count == 2, chars[0].isLetter, chars[1] == ":" {
            return root
        }
        if chars.count == 3, chars[0].isLetter, chars[1] == ":", (chars[2] == "/" || chars[2] == "\\") {
            return root
        }
        var end = root.endIndex
        while end > root.startIndex {
            let prev = root.index(before: end)
            if root[prev] == "/" || root[prev] == "\\" {
                end = prev
            } else {
                break
            }
        }
        return String(root[..<end])
    }

    public static func reviewFolderDirectory(root: String, folder: String) -> String {
        let separator = root.contains("\\") ? "\\" : "/"
        let base = reviewRootDirectory(root)
        let prefix = base.hasSuffix(separator) ? base : base + separator
        let normalized = normalizePath(folder).replacingOccurrences(of: "/", with: separator)
        return prefix + normalized
    }

    public static func reviewDiffDirectory(root: String, file: String) -> String {
        let path = normalizePath(file)
        guard let lastSlash = path.lastIndex(of: "/") else {
            return reviewRootDirectory(root)
        }
        return reviewFolderDirectory(root: root, folder: String(path[..<lastSlash]))
    }

    public static func isReviewFolder(_ file: String) -> Bool {
        file.hasSuffix("/")
    }

    public static func expandReviewFolders(
        rows: [SessionSchema.FileDiffInfo],
        loaded: [String: [SessionSchema.FileDiffInfo]]
    ) -> [SessionSchema.FileDiffInfo] {
        var out: [SessionSchema.FileDiffInfo] = []
        for row in rows {
            out.append(row)
            if let children = loaded[row.file] {
                let visible = children.filter { $0.more != true }
                out.append(contentsOf: expandReviewFolders(rows: visible, loaded: loaded))
            }
        }
        return out
    }

    public static func reviewDiffKinds(_ diffs: [SessionSchema.FileDiffInfo]) -> [String: ReviewChangeKind] {
        func merge(_ existing: ReviewChangeKind?, _ next: ReviewChangeKind) -> ReviewChangeKind {
            guard let existing else { return next }
            return existing == next ? existing : .mix
        }

        var out: [String: ReviewChangeKind] = [:]
        for diff in diffs {
            let file = normalizePath(diff.file)
            let kind: ReviewChangeKind
            switch diff.status {
            case .added: kind = .add
            case .deleted: kind = .del
            case .modified: kind = .mix
            }
            out[file] = kind

            let parts = file.split(separator: "/").map(String.init)
            if parts.count > 1 {
                for idx in 0..<(parts.count - 1) {
                    let dir = parts[0...idx].joined(separator: "/")
                    if !dir.isEmpty {
                        out[dir] = merge(out[dir], kind)
                    }
                }
            }
        }
        return out
    }

    public static func filterReviewFiles(_ files: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return files }
        return files.filter { $0.lowercased().contains(needle) }
    }

    /// Depth-first file order with directories before sibling files, matching `sortReviewPaths`.
    public static func sortReviewPaths(_ paths: [String]) -> [String] {
        struct Node {
            let name: String
            let path: String
            let isFile: Bool
            let original: String
        }

        var nodes: [String: Node] = [:]
        for value in paths {
            let file = normalizePath(value)
            guard !file.isEmpty else { continue }
            let parts = file.split(separator: "/").map(String.init)
            for (index, name) in parts.enumerated() {
                let path = parts[0...index].joined(separator: "/")
                if nodes[path] != nil { continue }
                let leaf = index == parts.count - 1
                nodes[path] = Node(name: name, path: path, isFile: leaf, original: leaf ? value : path)
            }
        }

        var children: [String: [Node]] = [:]
        for node in nodes.values {
            let parent: String
            if let slash = node.path.lastIndex(of: "/") {
                parent = String(node.path[..<slash])
            } else {
                parent = ""
            }
            children[parent, default: []].append(node)
        }

        for (key, list) in children {
            children[key] = list.sorted { a, b in
                if a.isFile != b.isFile {
                    return !a.isFile
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        var out: [String] = []
        var stack: [Node] = (children[""] ?? []).reversed()
        while let node = stack.popLast() {
            if node.isFile {
                out.append(node.original)
                continue
            }
            stack.append(contentsOf: (children[node.path] ?? []).reversed())
        }
        return out
    }

    public static func navigateFileList(
        key: ReviewListKey,
        files: [String],
        highlighted: String?
    ) -> ReviewListNavigationResult {
        guard !files.isEmpty else { return .none }
        switch key {
        case .arrowDown, .arrowUp:
            let currentIndex = highlighted.flatMap { files.firstIndex(of: $0) } ?? -1
            let delta = key == .arrowDown ? 1 : -1
            let start = currentIndex == -1 ? (delta > 0 ? 0 : files.count - 1) : currentIndex + delta
            let clamped = max(0, min(files.count - 1, start))
            return .highlight(files[clamped])
        case .enter:
            guard let target = highlighted ?? files.first else { return .none }
            return .select(target)
        }
    }

    /// Generates the stable diff row DOM/anchor identifier `session-review-diff-<fnv1a>`.
    public static func reviewDiffID(for path: String) -> String? {
        guard let sum = checksum(path) else { return nil }
        return "session-review-diff-\(sum)"
    }
}

// MARK: - Review Diff Machine (`review/machine.ts`)

public enum ReviewDiffMachine: GUIStateMachine {
    public static let timeoutMs = 30_000

    public enum VCSMode: String, Equatable, Hashable, Sendable, Codable {
        case git
        case branch
    }

    public enum SourceKind: String, Equatable, Hashable, Sendable {
        case vcs
        case turn
    }

    public enum Target: Equatable, Hashable, Sendable {
        case vcs(
            serverID: String,
            directory: String,
            mode: VCSMode,
            branch: String,
            defaultBranch: String
        )
        case turn(serverID: String, sessionID: String)

        public var kind: SourceKind {
            switch self {
            case .vcs: return .vcs
            case .turn: return .turn
            }
        }
    }

    public struct Rows: Equatable, Sendable {
        public let rows: [SessionSchema.FileDiffInfo]
        public let version: Int

        public init(rows: [SessionSchema.FileDiffInfo], version: Int) {
            self.rows = rows
            self.version = version
        }
    }

    public enum Context: Equatable, Sendable {
        case waiting
        case noVCS
        case offline
        case ready(target: Target, connected: Bool, demanded: Bool, cached: Rows? = nil)
    }

    public struct Link: Equatable, Sendable {
        public let target: Target
        public let connected: Bool
        public let demanded: Bool
        public let attempt: Int

        public init(target: Target, connected: Bool, demanded: Bool, attempt: Int) {
            self.target = target
            self.connected = connected
            self.demanded = demanded
            self.attempt = attempt
        }
    }

    public enum State: Equatable, Sendable {
        case waiting(attempt: Int)
        case noVCS(attempt: Int)
        case offline(attempt: Int)
        case idle(link: Link)
        case loading(link: Link, stale: Bool)
        case ready(link: Link, rows: Rows)
        case refreshing(link: Link, rows: Rows)
        case error(link: Link, failure: ReviewDiffFailure)
        case disposed(attempt: Int)

        public var attempt: Int {
            switch self {
            case .waiting(let a), .noVCS(let a), .offline(let a), .disposed(let a):
                return a
            case .idle(let link),
                 .loading(let link, _),
                 .ready(let link, _),
                 .refreshing(let link, _),
                 .error(let link, _):
                return link.attempt
            }
        }

        public var isInFlight: Bool {
            switch self {
            case .loading, .refreshing: return true
            default: return false
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case contextChanged(Context)
        case sideOpened
        case windowFocused
        case refresh(source: SourceKind)
        case retry
        case fetchSucceeded(attempt: Int, rows: Rows)
        case fetchFailed(attempt: Int, message: String)
        case fetchTimedOut(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case fetch(target: Target, attempt: Int)
        case abort
    }

    public enum View: Equatable, Sendable {
        case loading
        case offline
        case noVCS
        case error(failure: ReviewDiffFailure)
        case ready(rows: [SessionSchema.FileDiffInfo], version: Int)
    }

    public static let initialState: State = .waiting(attempt: 0)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state {
            return GUIStateTransition(state: state)
        }
        if case .disposed = event {
            return leave(state: state, next: .disposed(attempt: state.attempt))
        }
        if case .contextChanged(let context) = event {
            return handleContextChanged(state: state, context: context)
        }

        guard let link = linkOf(state) else {
            return GUIStateTransition(state: state)
        }
        let enabled = link.connected && link.demanded

        switch event {
        case .sideOpened:
            if link.connected && !state.isInFlight {
                return startFetch(state: state, link: link, rows: rowsOf(state))
            }
            return GUIStateTransition(state: state)

        case .windowFocused:
            let canRefetch: Bool
            switch state {
            case .ready, .error: canRefetch = true
            default: canRefetch = false
            }
            if enabled && link.target.kind == .vcs && canRefetch {
                return startFetch(state: state, link: link, rows: rowsOf(state))
            }
            return GUIStateTransition(state: state)

        case .refresh(let source):
            if !enabled || link.target.kind != source {
                return GUIStateTransition(state: state)
            }
            if case .loading(let loadingLink, let stale) = state {
                return stale
                    ? GUIStateTransition(state: state)
                    : GUIStateTransition(state: .loading(link: loadingLink, stale: true))
            }
            return startFetch(state: state, link: link, rows: rowsOf(state))

        case .retry:
            if case .error = state, link.connected {
                return startFetch(state: state, link: link, rows: nil)
            }
            return GUIStateTransition(state: state)

        case .fetchSucceeded(let attempt, let rows):
            guard state.isInFlight && attempt == link.attempt else {
                return GUIStateTransition(state: state)
            }
            if case .loading(let loadingLink, true) = state {
                let nextAttempt = loadingLink.attempt + 1
                let nextLink = Link(
                    target: loadingLink.target,
                    connected: loadingLink.connected,
                    demanded: loadingLink.demanded,
                    attempt: nextAttempt
                )
                return GUIStateTransition(
                    state: .refreshing(link: nextLink, rows: rows),
                    effects: [.fetch(target: loadingLink.target, attempt: nextAttempt)]
                )
            }
            return GUIStateTransition(state: .ready(link: link, rows: rows))

        case .fetchFailed(let attempt, let message):
            guard state.isInFlight && attempt == link.attempt else {
                return GUIStateTransition(state: state)
            }
            if case .refreshing(_, let rows) = state {
                return GUIStateTransition(state: .ready(link: link, rows: rows))
            }
            return GUIStateTransition(state: .error(link: link, failure: .rejected(message: message)))

        case .fetchTimedOut(let attempt):
            guard state.isInFlight && attempt == link.attempt else {
                return GUIStateTransition(state: state)
            }
            if case .refreshing(_, let rows) = state {
                return GUIStateTransition(state: .ready(link: link, rows: rows))
            }
            return GUIStateTransition(state: .error(link: link, failure: .timeout))

        case .contextChanged, .disposed:
            return GUIStateTransition(state: state)
        }
    }

    public static func view(_ state: State) -> View {
        switch state {
        case .offline:
            return .offline
        case .noVCS:
            return .noVCS
        case .idle(let link):
            return link.connected ? .loading : .offline
        case .error(_, let failure):
            return .error(failure: failure)
        case .ready(_, let rows), .refreshing(_, let rows):
            return .ready(rows: rows.rows, version: rows.version)
        case .waiting, .loading, .disposed:
            return .loading
        }
    }

    public static func isReady(_ state: State) -> Bool {
        switch state {
        case .ready, .refreshing, .noVCS: return true
        default: return false
        }
    }

    private static func handleContextChanged(state: State, context: Context) -> GUIStateTransition<State, Effect> {
        switch context {
        case .waiting:
            if case .waiting = state { return GUIStateTransition(state: state) }
            return leave(state: state, next: .waiting(attempt: state.attempt))
        case .noVCS:
            if case .noVCS = state { return GUIStateTransition(state: state) }
            return leave(state: state, next: .noVCS(attempt: state.attempt))
        case .offline:
            if case .offline = state { return GUIStateTransition(state: state) }
            return leave(state: state, next: .offline(attempt: state.attempt))
        case .ready(let target, let connected, let demanded, let cached):
            let nextLink = Link(target: target, connected: connected, demanded: demanded, attempt: state.attempt)
            let enabled = connected && demanded

            guard let currentLink = linkOf(state), currentLink.target == target else {
                if enabled {
                    return startFetch(state: state, link: nextLink, rows: cached)
                }
                if let cached {
                    return leave(state: state, next: .ready(link: nextLink, rows: cached))
                }
                return leave(state: state, next: .idle(link: nextLink))
            }

            if currentLink.connected == connected && currentLink.demanded == demanded {
                return GUIStateTransition(state: state)
            }

            if !connected {
                if let rows = rowsOf(state) {
                    return leave(state: state, next: .ready(link: nextLink, rows: rows))
                }
                return leave(state: state, next: .idle(link: nextLink))
            }

            if enabled && !(currentLink.connected && currentLink.demanded) && !state.isInFlight {
                return startFetch(state: state, link: nextLink, rows: rowsOf(state))
            }

            return GUIStateTransition(state: updatingLink(state, to: nextLink))
        }
    }

    private static func startFetch(state: State, link: Link, rows: Rows?) -> GUIStateTransition<State, Effect> {
        let attempt = state.attempt + 1
        let nextLink = Link(target: link.target, connected: link.connected, demanded: link.demanded, attempt: attempt)
        let nextState: State = rows.map { .refreshing(link: nextLink, rows: $0) } ?? .loading(link: nextLink, stale: false)
        let effects: [Effect] = state.isInFlight ? [.abort, .fetch(target: link.target, attempt: attempt)] : [.fetch(target: link.target, attempt: attempt)]
        return GUIStateTransition(state: nextState, effects: effects)
    }

    private static func leave(state: State, next: State) -> GUIStateTransition<State, Effect> {
        GUIStateTransition(state: next, effects: state.isInFlight ? [.abort] : [])
    }

    private static func linkOf(_ state: State) -> Link? {
        switch state {
        case .idle(let link),
             .loading(let link, _),
             .ready(let link, _),
             .refreshing(let link, _),
             .error(let link, _):
            return link
        default:
            return nil
        }
    }

    private static func rowsOf(_ state: State) -> Rows? {
        switch state {
        case .ready(_, let rows), .refreshing(_, let rows): return rows
        default: return nil
        }
    }

    private static func updatingLink(_ state: State, to link: Link) -> State {
        switch state {
        case .idle: return .idle(link: link)
        case .loading(_, let stale): return .loading(link: link, stale: stale)
        case .ready(_, let rows): return .ready(link: link, rows: rows)
        case .refreshing(_, let rows): return .refreshing(link: link, rows: rows)
        case .error(_, let failure): return .error(link: link, failure: failure)
        default: return state
        }
    }
}

// MARK: - Review Folder Expansion Machine (`review/folder-machine.ts`)

public enum ReviewFolderMachine: GUIStateMachine {
    public static let retriesLimit = 3

    public struct Source: Equatable, Hashable, Sendable {
        public let serverID: String
        public let root: String
        public let directory: String
        public let mode: ReviewDiffMachine.VCSMode
        public let branch: String
        public let defaultBranch: String

        public init(
            serverID: String,
            root: String,
            directory: String,
            mode: ReviewDiffMachine.VCSMode,
            branch: String,
            defaultBranch: String
        ) {
            self.serverID = serverID
            self.root = root
            self.directory = directory
            self.mode = mode
            self.branch = branch
            self.defaultBranch = defaultBranch
        }
    }

    public struct Context: Equatable, Sendable {
        public let source: Source?
        public let connected: Bool
        public let rows: [SessionSchema.FileDiffInfo]
        public let expanded: Set<String>

        public init(
            source: Source?,
            connected: Bool,
            rows: [SessionSchema.FileDiffInfo],
            expanded: Set<String>
        ) {
            self.source = source
            self.connected = connected
            self.rows = rows
            self.expanded = expanded
        }
    }

    public enum FolderItem: Equatable, Sendable {
        case loading(attempt: Int, stale: Bool, failures: Int)
        case ready(attempt: Int, entries: [SessionSchema.FileDiffInfo])
        case refreshing(attempt: Int, entries: [SessionSchema.FileDiffInfo])
        case error(attempt: Int)

        public var attempt: Int {
            switch self {
            case .loading(let a, _, _), .ready(let a, _), .refreshing(let a, _), .error(let a):
                return a
            }
        }

        public var isInFlight: Bool {
            switch self {
            case .loading, .refreshing: return true
            case .ready, .error: return false
            }
        }
    }

    public enum State: Equatable, Sendable {
        case inactive(issued: Int)
        case active(
            issued: Int,
            source: Source,
            connected: Bool,
            rows: [SessionSchema.FileDiffInfo],
            expanded: Set<String>,
            folders: [String: FolderItem]
        )
        case disposed(issued: Int)

        public var issued: Int {
            switch self {
            case .inactive(let i), .active(let i, _, _, _, _, _), .disposed(let i):
                return i
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case contextChanged(Context)
        case refresh
        case retry
        case fetchSucceeded(folder: String, attempt: Int, entries: [SessionSchema.FileDiffInfo])
        case fetchFailed(folder: String, attempt: Int)
        case fetchTimedOut(folder: String, attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case fetch(folder: String, source: Source, attempt: Int, delayMs: Int)
        case abort(attempt: Int)
    }

    public static let initialState: State = .inactive(issued: 0)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state {
            return GUIStateTransition(state: state)
        }
        if case .disposed = event {
            return GUIStateTransition(state: .disposed(issued: state.issued), effects: allAborts(state))
        }
        if case .contextChanged(let context) = event {
            return handleContextChanged(state: state, context: context)
        }

        guard case .active(var issued, let source, let connected, let rows, let expanded, var folders) = state else {
            return GUIStateTransition(state: state)
        }

        switch event {
        case .refresh:
            let hasFreshLoading = folders.values.contains { item in
                if case .loading(_, false, _) = item { return true }
                return false
            }
            guard connected && hasFreshLoading else {
                return GUIStateTransition(state: state)
            }
            for (folder, item) in folders {
                if case .loading(let attempt, _, let failures) = item {
                    folders[folder] = .loading(attempt: attempt, stale: true, failures: failures)
                }
            }
            return GUIStateTransition(
                state: .active(issued: issued, source: source, connected: connected, rows: rows, expanded: expanded, folders: folders)
            )

        case .retry:
            let failedFolders = folders.keys.sorted().filter { folder in
                if case .error = folders[folder] {
                    return expanded.contains(folder)
                }
                return false
            }
            guard connected && !failedFolders.isEmpty else {
                return GUIStateTransition(state: state)
            }
            var effects: [Effect] = []
            for folder in failedFolders {
                issued += 1
                folders[folder] = .loading(attempt: issued, stale: false, failures: 0)
                effects.append(.fetch(folder: folder, source: source, attempt: issued, delayMs: 0))
            }
            return GUIStateTransition(
                state: .active(issued: issued, source: source, connected: connected, rows: rows, expanded: expanded, folders: folders),
                effects: effects
            )

        case .fetchSucceeded(let folder, let attempt, let entries):
            guard let item = folders[folder], item.attempt == attempt, item.isInFlight else {
                return GUIStateTransition(state: state)
            }
            if case .loading(_, true, _) = item {
                issued += 1
                return settleFolder(
                    issued: issued,
                    source: source,
                    connected: connected,
                    rows: rows,
                    expanded: expanded,
                    folders: folders,
                    folder: folder,
                    replacement: .refreshing(attempt: issued, entries: entries),
                    trailingEffects: [.fetch(folder: folder, source: source, attempt: issued, delayMs: 0)]
                )
            }
            return settleFolder(
                issued: issued,
                source: source,
                connected: connected,
                rows: rows,
                expanded: expanded,
                folders: folders,
                folder: folder,
                replacement: .ready(attempt: attempt, entries: entries),
                trailingEffects: []
            )

        case .fetchFailed(let folder, let attempt), .fetchTimedOut(let folder, let attempt):
            guard let item = folders[folder], item.attempt == attempt, item.isInFlight else {
                return GUIStateTransition(state: state)
            }
            if case .refreshing(let refreshAttempt, let entries) = item {
                return settleFolder(
                    issued: issued,
                    source: source,
                    connected: connected,
                    rows: rows,
                    expanded: expanded,
                    folders: folders,
                    folder: folder,
                    replacement: .ready(attempt: refreshAttempt, entries: entries),
                    trailingEffects: []
                )
            }
            if !expanded.contains(folder) {
                folders.removeValue(forKey: folder)
                return GUIStateTransition(
                    state: .active(issued: issued, source: source, connected: connected, rows: rows, expanded: expanded, folders: folders)
                )
            }
            if case .fetchFailed = event, case .loading(_, let stale, let failures) = item, failures < retriesLimit {
                issued += 1
                let delay = min(1_000 * (1 << failures), 30_000)
                folders[folder] = .loading(attempt: issued, stale: stale, failures: failures + 1)
                return GUIStateTransition(
                    state: .active(issued: issued, source: source, connected: connected, rows: rows, expanded: expanded, folders: folders),
                    effects: [.fetch(folder: folder, source: source, attempt: issued, delayMs: delay)]
                )
            }
            folders[folder] = .error(attempt: attempt)
            return GUIStateTransition(
                state: .active(issued: issued, source: source, connected: connected, rows: rows, expanded: expanded, folders: folders)
            )

        case .contextChanged, .disposed:
            return GUIStateTransition(state: state)
        }
    }

    public static func candidates(rows: [SessionSchema.FileDiffInfo], state: State) -> [String] {
        Array(reachableFolders(rows: rows, loaded: loadedEntries(state))).sorted()
    }

    public static func expandedDiffs(rows: [SessionSchema.FileDiffInfo], state: State) -> [SessionSchema.FileDiffInfo] {
        ReviewPathHelper.expandReviewFolders(rows: rows, loaded: loadedEntries(state))
    }

    public static func labels(
        state: State,
        formatMore: (Int) -> String,
        failedLabel: String
    ) -> [String: String] {
        guard case .active(_, _, _, _, _, let folders) = state else { return [:] }
        var out: [String: String] = [:]
        for (folder, item) in folders {
            let key = ReviewPathHelper.normalizePath(folder)
            switch item {
            case .error:
                out[key] = failedLabel
            case .loading:
                continue
            case .ready(_, let entries), .refreshing(_, let entries):
                let shown = entries.filter { $0.more != true }.count
                let hasMore = entries.contains { $0.more == true }
                out[key] = hasMore ? formatMore(shown) : "\(shown)"
            }
        }
        return out
    }

    private static func handleContextChanged(state: State, context: Context) -> GUIStateTransition<State, Effect> {
        guard let source = context.source else {
            if case .inactive = state { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .inactive(issued: state.issued), effects: allAborts(state))
        }

        switch state {
        case .inactive(let issued):
            return startNewSource(
                issued: issued,
                priorEffects: [],
                source: source,
                context: context
            )
        case .active(let issued, let currentSource, let connected, let rows, let expanded, let folders):
            if currentSource != source {
                return startNewSource(
                    issued: issued,
                    priorEffects: allAborts(state),
                    source: source,
                    context: context
                )
            }
            if connected == context.connected && rows == context.rows && expanded == context.expanded {
                return GUIStateTransition(state: state)
            }

            let reach = reachableFolders(rows: context.rows, loaded: loadedEntries(state))
            let rowsChanged = rows != context.rows
            let reload = rowsChanged || (context.connected && !connected)
            var nextIssued = issued
            var effects: [Effect] = []
            var nextFolders: [String: FolderItem] = [:]

            func abortItem(_ item: FolderItem) {
                if item.isInFlight {
                    effects.append(.abort(attempt: item.attempt))
                }
            }

            func startFolder(_ folder: String, entries: [SessionSchema.FileDiffInfo]? = nil) {
                nextIssued += 1
                nextFolders[folder] = entries.map { .refreshing(attempt: nextIssued, entries: $0) }
                    ?? .loading(attempt: nextIssued, stale: false, failures: 0)
                effects.append(.fetch(folder: folder, source: source, attempt: nextIssued, delayMs: 0))
            }

            for folder in folders.keys.sorted() {
                guard let item = folders[folder] else { continue }
                if !reach.contains(folder) {
                    abortItem(item)
                    continue
                }
                if !context.connected {
                    abortItem(item)
                    switch item {
                    case .ready(let a, let e), .refreshing(let a, let e):
                        nextFolders[folder] = .ready(attempt: a, entries: e)
                    case .loading, .error:
                        break
                    }
                    continue
                }
                switch item {
                case .error:
                    if !context.expanded.contains(folder) { continue }
                    if reload {
                        startFolder(folder)
                    } else {
                        nextFolders[folder] = item
                    }
                case .loading(let attempt, let stale, let failures):
                    nextFolders[folder] = (rowsChanged && !stale)
                        ? .loading(attempt: attempt, stale: true, failures: failures)
                        : item
                case .ready(_, let entries), .refreshing(_, let entries):
                    if !reload {
                        nextFolders[folder] = item
                    } else {
                        abortItem(item)
                        startFolder(folder, entries: entries)
                    }
                }
            }

            if context.connected {
                for folder in context.expanded.sorted() {
                    if nextFolders[folder] == nil && reach.contains(folder) {
                        startFolder(folder)
                    }
                }
            }

            return GUIStateTransition(
                state: .active(
                    issued: nextIssued,
                    source: source,
                    connected: context.connected,
                    rows: context.rows,
                    expanded: context.expanded,
                    folders: nextFolders
                ),
                effects: effects
            )
        case .disposed:
            return GUIStateTransition(state: state)
        }
    }

    private static func startNewSource(
        issued: Int,
        priorEffects: [Effect],
        source: Source,
        context: Context
    ) -> GUIStateTransition<State, Effect> {
        var nextIssued = issued
        var folders: [String: FolderItem] = [:]
        var effects = priorEffects
        if context.connected {
            for folder in context.expanded.sorted() {
                nextIssued += 1
                folders[folder] = .loading(attempt: nextIssued, stale: false, failures: 0)
                effects.append(.fetch(folder: folder, source: source, attempt: nextIssued, delayMs: 0))
            }
        }
        return GUIStateTransition(
            state: .active(
                issued: nextIssued,
                source: source,
                connected: context.connected,
                rows: context.rows,
                expanded: context.expanded,
                folders: folders
            ),
            effects: effects
        )
    }

    private static func settleFolder(
        issued: Int,
        source: Source,
        connected: Bool,
        rows: [SessionSchema.FileDiffInfo],
        expanded: Set<String>,
        folders: [String: FolderItem],
        folder: String,
        replacement: FolderItem,
        trailingEffects: [Effect]
    ) -> GUIStateTransition<State, Effect> {
        var replaced = folders
        replaced[folder] = replacement
        let candidateState: State = .active(
            issued: issued,
            source: source,
            connected: connected,
            rows: rows,
            expanded: expanded,
            folders: replaced
        )
        let reach = reachableFolders(rows: rows, loaded: loadedEntries(candidateState))
        var prunedAborts: [Effect] = []
        var keptFolders: [String: FolderItem] = [:]
        for key in replaced.keys.sorted() {
            guard let item = replaced[key] else { continue }
            if reach.contains(key) {
                keptFolders[key] = item
            } else if item.isInFlight {
                prunedAborts.append(.abort(attempt: item.attempt))
            }
        }
        let keptExpanded = expanded.filter { reach.contains($0) }
        return GUIStateTransition(
            state: .active(
                issued: issued,
                source: source,
                connected: connected,
                rows: rows,
                expanded: keptExpanded,
                folders: keptFolders
            ),
            effects: prunedAborts + trailingEffects
        )
    }

    private static func loadedEntries(_ state: State) -> [String: [SessionSchema.FileDiffInfo]] {
        guard case .active(_, _, _, _, _, let folders) = state else { return [:] }
        var out: [String: [SessionSchema.FileDiffInfo]] = [:]
        for (folder, item) in folders {
            switch item {
            case .ready(_, let entries), .refreshing(_, let entries):
                out[folder] = entries
            case .loading, .error:
                break
            }
        }
        return out
    }

    private static func reachableFolders(
        rows: [SessionSchema.FileDiffInfo],
        loaded: [String: [SessionSchema.FileDiffInfo]]
    ) -> Set<String> {
        Set(
            ReviewPathHelper.expandReviewFolders(rows: rows, loaded: loaded)
                .map(\.file)
                .filter(ReviewPathHelper.isReviewFolder)
        )
    }

    private static func allAborts(_ state: State) -> [Effect] {
        guard case .active(_, _, _, _, _, let folders) = state else { return [] }
        return folders.keys.sorted().compactMap { key in
            guard let item = folders[key], item.isInFlight else { return nil }
            return .abort(attempt: item.attempt)
        }
    }
}

// MARK: - Review Detail Patch Machine (`review/detail-machine.ts`)

public enum ReviewDetailMachine: GUIStateMachine {
    public static let retriesLimit = 2

    public enum Stage: String, Equatable, Hashable, Sendable {
        case scoped
        case bounded
    }

    public enum Target: Equatable, Hashable, Sendable {
        case turn(
            serverID: String,
            sessionID: String,
            file: String,
            additions: Int,
            deletions: Int,
            version: Int
        )
        case vcs(
            serverID: String,
            mode: ReviewDiffMachine.VCSMode,
            branch: String,
            defaultBranch: String,
            root: String,
            scoped: String,
            file: String,
            additions: Int,
            deletions: Int,
            version: Int
        )

        public var initialStage: Stage {
            if case .vcs(_, _, _, _, let root, let scoped, _, _, _, _) = self, scoped != root {
                return .scoped
            }
            return .bounded
        }
    }

    public enum Context: Equatable, Sendable {
        case none
        case needed(target: Target, connected: Bool, cached: SessionSchema.FileDiffInfo? = nil)
    }

    public enum State: Equatable, Sendable {
        case idle(attempt: Int)
        case offline(target: Target, attempt: Int)
        case loading(target: Target, stage: Stage, failures: Int, attempt: Int)
        case ready(target: Target, attempt: Int, diff: SessionSchema.FileDiffInfo?)
        case error(target: Target, attempt: Int, failure: ReviewDiffFailure)
        case disposed(attempt: Int)

        public var attempt: Int {
            switch self {
            case .idle(let a), .offline(_, let a), .loading(_, _, _, let a), .ready(_, let a, _), .error(_, let a, _), .disposed(let a):
                return a
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case contextChanged(Context)
        case retry
        case fetchSucceeded(attempt: Int, diff: SessionSchema.FileDiffInfo?)
        case fetchFailed(attempt: Int, message: String)
        case fetchTimedOut(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case fetch(target: Target, stage: Stage, attempt: Int, delayMs: Int)
        case abort(attempt: Int)
    }

    public enum View: Equatable, Sendable {
        case loading
        case offline
        case error(failure: ReviewDiffFailure)
        case ready(diff: SessionSchema.FileDiffInfo?)
    }

    public static let initialState: State = .idle(attempt: 0)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            return leave(state: state, next: .disposed(attempt: state.attempt))
        case .contextChanged(let context):
            return handleContextChanged(state: state, context: context)
        case .retry:
            if case .error(let target, _, _) = state {
                return start(state: state, target: target)
            }
            return GUIStateTransition(state: state)
        case .fetchTimedOut(let attempt):
            guard case .loading(let target, _, _, let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .error(target: target, attempt: currentAttempt, failure: .timeout),
                effects: [.abort(attempt: currentAttempt)]
            )
        case .fetchSucceeded(let attempt, let diff):
            guard case .loading(let target, let stage, _, let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if diff != nil || stage == .bounded {
                return GUIStateTransition(state: .ready(target: target, attempt: currentAttempt, diff: diff))
            }
            return request(target: target, currentAttempt: currentAttempt, stage: .bounded, failures: 0, delayMs: 0)
        case .fetchFailed(let attempt, let message):
            guard case .loading(let target, let stage, let failures, let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if stage == .scoped {
                return request(target: target, currentAttempt: currentAttempt, stage: .bounded, failures: 0, delayMs: 0)
            }
            if failures < retriesLimit {
                let delay = min(1_000 * (1 << failures), 30_000)
                return request(target: target, currentAttempt: currentAttempt, stage: .bounded, failures: failures + 1, delayMs: delay)
            }
            return GUIStateTransition(state: .error(target: target, attempt: currentAttempt, failure: .rejected(message: message)))
        }
    }

    public static func view(state: State, target: Target) -> View {
        guard targetOf(state) == target else { return .loading }
        switch state {
        case .offline:
            return .offline
        case .error(_, _, let failure):
            return .error(failure: failure)
        case .ready(_, _, let diff):
            return .ready(diff: diff)
        case .idle, .loading, .disposed:
            return .loading
        }
    }

    private static func handleContextChanged(state: State, context: Context) -> GUIStateTransition<State, Effect> {
        switch context {
        case .none:
            if case .idle = state { return GUIStateTransition(state: state) }
            return leave(state: state, next: .idle(attempt: state.attempt))
        case .needed(let target, let connected, let cached):
            let same = targetOf(state) == target
            if same, case .ready = state {
                return GUIStateTransition(state: state)
            }
            if let cached {
                return leave(state: state, next: .ready(target: target, attempt: state.attempt, diff: cached))
            }
            if !connected {
                if same, case .offline = state {
                    return GUIStateTransition(state: state)
                }
                return leave(state: state, next: .offline(target: target, attempt: state.attempt))
            }
            if same {
                switch state {
                case .loading, .error:
                    return GUIStateTransition(state: state)
                default:
                    break
                }
            }
            return start(state: state, target: target)
        }
    }

    private static func start(state: State, target: Target) -> GUIStateTransition<State, Effect> {
        let nextAttempt = state.attempt + 1
        let stage = target.initialStage
        let fetchEffect: Effect = .fetch(target: target, stage: stage, attempt: nextAttempt, delayMs: 0)
        let effects: [Effect]
        if case .loading(_, _, _, let prevAttempt) = state {
            effects = [.abort(attempt: prevAttempt), fetchEffect]
        } else {
            effects = [fetchEffect]
        }
        return GUIStateTransition(
            state: .loading(target: target, stage: stage, failures: 0, attempt: nextAttempt),
            effects: effects
        )
    }

    private static func request(
        target: Target,
        currentAttempt: Int,
        stage: Stage,
        failures: Int,
        delayMs: Int
    ) -> GUIStateTransition<State, Effect> {
        let nextAttempt = currentAttempt + 1
        return GUIStateTransition(
            state: .loading(target: target, stage: stage, failures: failures, attempt: nextAttempt),
            effects: [.fetch(target: target, stage: stage, attempt: nextAttempt, delayMs: delayMs)]
        )
    }

    private static func leave(state: State, next: State) -> GUIStateTransition<State, Effect> {
        if case .loading(_, _, _, let attempt) = state {
            return GUIStateTransition(state: next, effects: [.abort(attempt: attempt)])
        }
        return GUIStateTransition(state: next)
    }

    private static func targetOf(_ state: State) -> Target? {
        switch state {
        case .offline(let t, _), .loading(let t, _, _, _), .ready(let t, _, _), .error(let t, _, _):
            return t
        case .idle, .disposed:
            return nil
        }
    }
}

// MARK: - Review Git Init, Render, Scroll & Screen Machines

public enum ReviewInitGitMachine: GUIStateMachine {
    public static let timeoutMs = 30_000

    public enum Entry: Equatable, Sendable {
        case initializing(attempt: Int)
        case syncing(attempt: Int)

        public var attempt: Int {
            switch self {
            case .initializing(let a), .syncing(let a): return a
            }
        }
    }

    public enum State: Equatable, Sendable {
        case active(issued: Int, sessions: [String: Entry])
        case disposed
    }

    public enum FailureReason: String, Equatable, Hashable, Sendable {
        case unavailable
        case rejected
        case timeout
    }

    public enum Event: Equatable, Sendable {
        case initRequested(sessionKey: String, ready: Bool)
        case initSucceeded(sessionKey: String, attempt: Int)
        case initFailed(sessionKey: String, attempt: Int, routedSessionKey: String, message: String?)
        case initTimedOut(sessionKey: String, attempt: Int, routedSessionKey: String)
        case syncSettled(sessionKey: String, attempt: Int)
        case syncTimedOut(sessionKey: String, attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case vcsInit(sessionKey: String, attempt: Int, timeoutMs: Int)
        case cachesSync(sessionKey: String, attempt: Int, timeoutMs: Int)
        case attemptAbort(attempt: Int)
        case toastFailed(reason: FailureReason, message: String?)
    }

    public static func createState() -> State {
        .active(issued: 0, sessions: [:])
    }

    public static func isInitializingGit(_ state: State, sessionKey: String) -> Bool {
        if case .active(_, let sessions) = state {
            return sessions[sessionKey] != nil
        }
        return false
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .active(var issued, var sessions) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            let aborts = sessions.keys.sorted().compactMap { sessions[$0]?.attempt }.map { Effect.attemptAbort(attempt: $0) }
            return GUIStateTransition(state: .disposed, effects: aborts)

        case .initRequested(let sessionKey, let ready):
            if sessions[sessionKey] != nil { return GUIStateTransition(state: state) }
            if !ready {
                return GUIStateTransition(state: state, effects: [.toastFailed(reason: .unavailable, message: nil)])
            }
            issued += 1
            sessions[sessionKey] = .initializing(attempt: issued)
            return GUIStateTransition(
                state: .active(issued: issued, sessions: sessions),
                effects: [.vcsInit(sessionKey: sessionKey, attempt: issued, timeoutMs: timeoutMs)]
            )

        case .initSucceeded(let sessionKey, let attempt):
            guard case .initializing(let currentAttempt) = sessions[sessionKey], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            issued += 1
            sessions[sessionKey] = .syncing(attempt: issued)
            return GUIStateTransition(
                state: .active(issued: issued, sessions: sessions),
                effects: [
                    .attemptAbort(attempt: currentAttempt),
                    .cachesSync(sessionKey: sessionKey, attempt: issued, timeoutMs: timeoutMs),
                ]
            )

        case .initFailed(let sessionKey, let attempt, let routedSessionKey, let message):
            guard case .initializing(let currentAttempt) = sessions[sessionKey], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            sessions.removeValue(forKey: sessionKey)
            var effects: [Effect] = [.attemptAbort(attempt: currentAttempt)]
            if routedSessionKey == sessionKey {
                effects.append(.toastFailed(reason: .rejected, message: message))
            }
            return GUIStateTransition(state: .active(issued: issued, sessions: sessions), effects: effects)

        case .initTimedOut(let sessionKey, let attempt, let routedSessionKey):
            guard case .initializing(let currentAttempt) = sessions[sessionKey], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            sessions.removeValue(forKey: sessionKey)
            var effects: [Effect] = [.attemptAbort(attempt: currentAttempt)]
            if routedSessionKey == sessionKey {
                effects.append(.toastFailed(reason: .timeout, message: nil))
            }
            return GUIStateTransition(state: .active(issued: issued, sessions: sessions), effects: effects)

        case .syncSettled(let sessionKey, let attempt), .syncTimedOut(let sessionKey, let attempt):
            guard case .syncing(let currentAttempt) = sessions[sessionKey], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            sessions.removeValue(forKey: sessionKey)
            return GUIStateTransition(
                state: .active(issued: issued, sessions: sessions),
                effects: [.attemptAbort(attempt: currentAttempt)]
            )
        }
    }
}

public enum ReviewRenderMachine: GUIStateMachine {
    public enum State: Equatable, Sendable {
        case initialDeferring(visitID: Int, attempt: Int)
        case visitDeferring(visitID: Int, attempt: Int)
        case ready(visitID: Int, attempt: Int)
        case disposed(attempt: Int)
    }

    public enum Event: Equatable, Sendable {
        case visitSynced(visitID: Int)
        case frameSettled(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case frameSchedule(attempt: Int)
        case frameCancel
    }

    public static let initialState: State = .initialDeferring(visitID: 0, attempt: 0)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        let scheduled: Bool
        let currentVisitID: Int
        let currentAttempt: Int
        let isInitial: Bool

        switch state {
        case .initialDeferring(let v, let a):
            scheduled = a > 0
            currentVisitID = v
            currentAttempt = a
            isInitial = true
        case .visitDeferring(let v, let a):
            scheduled = a > 0
            currentVisitID = v
            currentAttempt = a
            isInitial = false
        case .ready(let v, let a):
            scheduled = false
            currentVisitID = v
            currentAttempt = a
            isInitial = false
        case .disposed:
            return GUIStateTransition(state: state)
        }

        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed(attempt: currentAttempt + 1), effects: scheduled ? [.frameCancel] : [])
        case .visitSynced(let visitID):
            if visitID == currentVisitID { return GUIStateTransition(state: state) }
            let nextAttempt = currentAttempt + 1
            let nextState: State = isInitial
                ? .initialDeferring(visitID: visitID, attempt: nextAttempt)
                : .visitDeferring(visitID: visitID, attempt: nextAttempt)
            return GUIStateTransition(
                state: nextState,
                effects: scheduled ? [.frameCancel, .frameSchedule(attempt: nextAttempt)] : [.frameSchedule(attempt: nextAttempt)]
            )
        case .frameSettled(let attempt):
            if case .ready = state { return GUIStateTransition(state: state) }
            guard attempt == currentAttempt else { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .ready(visitID: currentVisitID, attempt: currentAttempt))
        }
    }

    public static func panelReady(_ state: State) -> Bool {
        switch state {
        case .ready, .visitDeferring: return true
        default: return false
        }
    }

    public static func mobileReady(_ state: State) -> Bool {
        if case .ready = state { return true }
        return false
    }
}

public enum ReviewScrollMachine: GUIStateMachine {
    public static let maxFrames = 60

    public struct Context: Equatable, Sendable {
        public let visitID: Int
        public let narrow: Bool
        public let scroller: Bool
        public let ready: Bool
        public let layoutReady: Bool
        public let commentFocused: Bool

        public init(
            visitID: Int = 0,
            narrow: Bool = false,
            scroller: Bool = false,
            ready: Bool = false,
            layoutReady: Bool = false,
            commentFocused: Bool = false
        ) {
            self.visitID = visitID
            self.narrow = narrow
            self.scroller = scroller
            self.ready = ready
            self.layoutReady = layoutReady
            self.commentFocused = commentFocused
        }

        var isScrollable: Bool { narrow && scroller && ready }
        var isRestorable: Bool { narrow && scroller && layoutReady }
    }

    public enum FrameOutcome: String, Equatable, Sendable {
        case settled
        case retry
    }

    public enum State: Equatable, Sendable {
        case restoring(context: Context, restoreQueued: Bool, attempt: Int)
        case waiting(context: Context, path: String, attempt: Int)
        case scrolling(context: Context, path: String, retries: Int, attempt: Int)
        case settled(context: Context, attempt: Int)
        case disposed(attempt: Int)
    }

    public enum Event: Equatable, Sendable {
        case contextSynced(Context)
        case restoreRequested
        case restoreStepped(attempt: Int)
        case fileFocused(path: String)
        case frameStepped(attempt: Int, outcome: FrameOutcome)
        case interacted
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case frameRestore(attempt: Int)
        case frameSchedule(attempt: Int, path: String)
        case frameCancel
    }

    public static let initialState: State = .restoring(context: Context(), restoreQueued: false, attempt: 0)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        switch event {
        case .disposed:
            return stop(state: state, next: .disposed(attempt: attemptOf(state) + 1))

        case .contextSynced(let context):
            return handleContextSynced(state: state, context: context)

        case .restoreRequested:
            guard case .restoring(let context, false, let attempt) = state, context.isRestorable else {
                return GUIStateTransition(state: state)
            }
            let nextAttempt = attempt + 1
            return GUIStateTransition(
                state: .restoring(context: context, restoreQueued: true, attempt: nextAttempt),
                effects: [.frameRestore(attempt: nextAttempt)]
            )

        case .restoreStepped(let attempt):
            guard case .restoring(let context, true, let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .restoring(context: context, restoreQueued: false, attempt: currentAttempt))

        case .fileFocused(let path):
            guard let context = contextOf(state), context.narrow else {
                return GUIStateTransition(state: state)
            }
            let nextAttempt = attemptOf(state) + 1
            let cancel: [Effect] = isFramed(state) ? [.frameCancel] : []
            if !context.isScrollable {
                return GUIStateTransition(state: .waiting(context: context, path: path, attempt: nextAttempt), effects: cancel)
            }
            return GUIStateTransition(
                state: .scrolling(context: context, path: path, retries: 0, attempt: nextAttempt),
                effects: cancel + [.frameSchedule(attempt: nextAttempt, path: path)]
            )

        case .interacted:
            guard let context = contextOf(state), context.narrow else {
                return GUIStateTransition(state: state)
            }
            if case .settled = state { return GUIStateTransition(state: state) }
            return stop(state: state, next: .settled(context: context, attempt: attemptOf(state) + 1))

        case .frameStepped(let attempt, let outcome):
            guard case .scrolling(let context, let path, let retries, let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if outcome == .settled || retries >= maxFrames {
                return GUIStateTransition(state: .settled(context: context, attempt: currentAttempt))
            }
            return GUIStateTransition(
                state: .scrolling(context: context, path: path, retries: retries + 1, attempt: currentAttempt),
                effects: [.frameSchedule(attempt: currentAttempt, path: path)]
            )
        }
    }

    public static func canRestore(_ state: State, attempt: Int) -> Bool {
        guard case .restoring(let context, true, let currentAttempt) = state else { return false }
        return currentAttempt == attempt && context.isRestorable
    }

    public static func canSave(_ state: State) -> Bool {
        guard case .settled(let context, _) = state else { return false }
        return context.isRestorable
    }

    private static func handleContextSynced(state: State, context: Context) -> GUIStateTransition<State, Effect> {
        guard let current = contextOf(state), current != context else {
            return GUIStateTransition(state: state)
        }
        let cancel: [Effect] = isFramed(state) ? [.frameCancel] : []
        let nextAttempt = attemptOf(state) + 1

        if context.visitID != current.visitID {
            if context.commentFocused {
                return stop(state: state, next: .settled(context: context, attempt: nextAttempt))
            }
            if context.isRestorable {
                return GUIStateTransition(
                    state: .restoring(context: context, restoreQueued: true, attempt: nextAttempt),
                    effects: cancel + [.frameRestore(attempt: nextAttempt)]
                )
            }
            return GUIStateTransition(
                state: .restoring(context: context, restoreQueued: false, attempt: nextAttempt),
                effects: cancel
            )
        }

        if !context.narrow {
            if case .restoring(_, false, let attempt) = state {
                return GUIStateTransition(state: .restoring(context: context, restoreQueued: false, attempt: attempt))
            }
            return GUIStateTransition(
                state: .restoring(context: context, restoreQueued: false, attempt: nextAttempt),
                effects: cancel
            )
        }

        switch state {
        case .waiting(_, let path, let attempt):
            if context.isScrollable {
                return GUIStateTransition(
                    state: .scrolling(context: context, path: path, retries: 0, attempt: nextAttempt),
                    effects: [.frameSchedule(attempt: nextAttempt, path: path)]
                )
            }
            return GUIStateTransition(state: .waiting(context: context, path: path, attempt: attempt))

        case .scrolling(_, let path, let retries, let attempt):
            if context.isScrollable {
                return GUIStateTransition(state: .scrolling(context: context, path: path, retries: retries, attempt: attempt))
            }
            let nextState: State = context.scroller
                ? .settled(context: context, attempt: nextAttempt)
                : .restoring(context: context, restoreQueued: false, attempt: nextAttempt)
            return GUIStateTransition(state: nextState, effects: [.frameCancel])

        case .settled(_, let attempt):
            let nextState: State = context.scroller
                ? .settled(context: context, attempt: attempt)
                : .restoring(context: context, restoreQueued: false, attempt: attempt)
            return GUIStateTransition(state: nextState)

        case .restoring(_, let restoreQueued, let attempt):
            if context.commentFocused {
                return stop(state: state, next: .settled(context: context, attempt: nextAttempt))
            }
            if !context.isRestorable {
                return GUIStateTransition(
                    state: .restoring(context: context, restoreQueued: false, attempt: attempt),
                    effects: restoreQueued ? [.frameCancel] : []
                )
            }
            if !restoreQueued && !current.isRestorable {
                return GUIStateTransition(
                    state: .restoring(context: context, restoreQueued: true, attempt: nextAttempt),
                    effects: [.frameRestore(attempt: nextAttempt)]
                )
            }
            return GUIStateTransition(state: .restoring(context: context, restoreQueued: restoreQueued, attempt: attempt))

        case .disposed:
            return GUIStateTransition(state: state)
        }
    }

    private static func stop(state: State, next: State) -> GUIStateTransition<State, Effect> {
        GUIStateTransition(state: next, effects: isFramed(state) ? [.frameCancel] : [])
    }

    private static func isFramed(_ state: State) -> Bool {
        switch state {
        case .restoring(_, true, _), .scrolling: return true
        default: return false
        }
    }

    private static func contextOf(_ state: State) -> Context? {
        switch state {
        case .restoring(let c, _, _), .waiting(let c, _, _), .scrolling(let c, _, _, _), .settled(let c, _):
            return c
        case .disposed:
            return nil
        }
    }

    private static func attemptOf(_ state: State) -> Int {
        switch state {
        case .restoring(_, _, let a), .waiting(_, _, let a), .scrolling(_, _, _, let a), .settled(_, let a), .disposed(let a):
            return a
        }
    }
}

public enum ReviewScreenMachine: GUIStateMachine {
    public enum DemandSource: String, Equatable, Hashable, Sendable {
        case tree
        case files
        case panel
        case details
    }

    public struct Demand: Equatable, Hashable, Sendable {
        public let tree: Int
        public let files: Int
        public let panel: Int
        public let details: Int

        public init(tree: Int = 0, files: Int = 0, panel: Int = 0, details: Int = 0) {
            self.tree = tree
            self.files = files
            self.panel = panel
            self.details = details
        }
    }

    public struct Watch: Equatable, Hashable, Sendable {
        public let id: Int
        public let source: DemandSource

        public init(id: Int, source: DemandSource) {
            self.id = id
            self.source = source
        }
    }

    public enum Entry: Equatable, Sendable {
        case watching(watches: [Watch])
        case ready(attempt: Int, panels: [Int], watches: [Watch])

        public var watches: [Watch] {
            switch self {
            case .watching(let w), .ready(_, _, let w): return w
            }
        }
    }

    public enum State: Equatable, Sendable {
        case active(issued: Int, routed: Int?, entries: [Int: Entry])
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case routeEntered(screenID: Int)
        case routeLeft
        case panelMounted(screenID: Int, panelID: Int)
        case panelUnmounted(screenID: Int, panelID: Int)
        case watchAdded(screenID: Int, watchID: Int, source: DemandSource)
        case watchRemoved(screenID: Int, watchID: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case modelCreate(screenID: Int, attempt: Int)
        case modelDispose(screenID: Int, attempt: Int)
    }

    public static let initialState: State = .active(issued: 0, routed: nil, entries: [:])

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .active(let issued, let routed, var entries) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            let effects: [Effect] = entries.keys.sorted().compactMap { screenID in
                if case .ready(let attempt, _, _) = entries[screenID] {
                    return .modelDispose(screenID: screenID, attempt: attempt)
                }
                return nil
            }
            return GUIStateTransition(state: .disposed, effects: effects)

        case .routeEntered(let screenID):
            if routed == screenID { return GUIStateTransition(state: state) }
            let nextTransition: GUIStateTransition<State, Effect>
            if case .ready = entries[screenID] {
                nextTransition = GUIStateTransition(state: .active(issued: issued, routed: screenID, entries: entries))
            } else {
                nextTransition = createModel(issued: issued, routed: screenID, entries: entries, screenID: screenID, panels: [])
            }
            guard let previousRouted = routed else { return nextTransition }
            return settleScreen(transition: nextTransition, screenID: previousRouted)

        case .routeLeft:
            guard let previousRouted = routed else { return GUIStateTransition(state: state) }
            let updated = GUIStateTransition<State, Effect>(state: .active(issued: issued, routed: nil, entries: entries))
            return settleScreen(transition: updated, screenID: previousRouted)

        case .panelMounted(let screenID, let panelID):
            guard case .ready(let attempt, let panels, let watches) = entries[screenID] else {
                return createModel(issued: issued, routed: routed, entries: entries, screenID: screenID, panels: [panelID])
            }
            if panels.contains(panelID) { return GUIStateTransition(state: state) }
            entries[screenID] = .ready(attempt: attempt, panels: panels + [panelID], watches: watches)
            return GUIStateTransition(state: .active(issued: issued, routed: routed, entries: entries))

        case .panelUnmounted(let screenID, let panelID):
            guard case .ready(let attempt, let panels, let watches) = entries[screenID], panels.contains(panelID) else {
                return GUIStateTransition(state: state)
            }
            entries[screenID] = .ready(attempt: attempt, panels: panels.filter { $0 != panelID }, watches: watches)
            return settleScreen(
                transition: GUIStateTransition(state: .active(issued: issued, routed: routed, entries: entries)),
                screenID: screenID
            )

        case .watchAdded(let screenID, let watchID, let source):
            if let existing = entries[screenID], existing.watches.contains(where: { $0.id == watchID }) {
                return GUIStateTransition(state: state)
            }
            let watch = Watch(id: watchID, source: source)
            switch entries[screenID] {
            case .ready(let attempt, let panels, let watches):
                entries[screenID] = .ready(attempt: attempt, panels: panels, watches: watches + [watch])
            case .watching(let watches):
                entries[screenID] = .watching(watches: watches + [watch])
            case nil:
                entries[screenID] = .watching(watches: [watch])
            }
            return GUIStateTransition(state: .active(issued: issued, routed: routed, entries: entries))

        case .watchRemoved(let screenID, let watchID):
            guard let existing = entries[screenID], existing.watches.contains(where: { $0.id == watchID }) else {
                return GUIStateTransition(state: state)
            }
            let remaining = existing.watches.filter { $0.id != watchID }
            switch existing {
            case .ready(let attempt, let panels, _):
                entries[screenID] = .ready(attempt: attempt, panels: panels, watches: remaining)
            case .watching:
                entries[screenID] = .watching(watches: remaining)
            }
            return settleScreen(
                transition: GUIStateTransition(state: .active(issued: issued, routed: routed, entries: entries)),
                screenID: screenID
            )
        }
    }

    public static func modelAttempt(_ state: State, screenID: Int) -> Int? {
        guard case .active(_, _, let entries) = state, case .ready(let attempt, _, _) = entries[screenID] else {
            return nil
        }
        return attempt
    }

    public static func models(_ state: State) -> [Int] {
        guard case .active(_, let routed, let entries) = state else { return [] }
        let ids = entries.keys.sorted()
        let ordered = routed.map { r in [r] + ids.filter { $0 != r } } ?? ids
        return ordered.filter { id in
            if case .ready = entries[id] { return true }
            return false
        }
    }

    public static func demand(_ state: State, screenID: Int) -> Demand {
        guard case .active(_, _, let entries) = state, let entry = entries[screenID] else {
            return Demand()
        }
        let watches = entry.watches
        return Demand(
            tree: watches.filter { $0.source == .tree }.count,
            files: watches.filter { $0.source == .files }.count,
            panel: watches.filter { $0.source == .panel }.count,
            details: watches.filter { $0.source == .details }.count
        )
    }

    private static func createModel(
        issued: Int,
        routed: Int?,
        entries: [Int: Entry],
        screenID: Int,
        panels: [Int]
    ) -> GUIStateTransition<State, Effect> {
        let attempt = issued + 1
        var nextEntries = entries
        nextEntries[screenID] = .ready(attempt: attempt, panels: panels, watches: entries[screenID]?.watches ?? [])
        return GUIStateTransition(
            state: .active(issued: attempt, routed: routed, entries: nextEntries),
            effects: [.modelCreate(screenID: screenID, attempt: attempt)]
        )
    }

    private static func settleScreen(
        transition: GUIStateTransition<State, Effect>,
        screenID: Int
    ) -> GUIStateTransition<State, Effect> {
        guard case .active(let issued, let routed, var entries) = transition.state, routed != screenID else {
            return transition
        }
        guard let entry = entries[screenID] else { return transition }
        if !entry.watches.isEmpty { return transition }
        if case .ready(_, let panels, _) = entry, !panels.isEmpty { return transition }

        entries.removeValue(forKey: screenID)
        var effects = transition.effects
        if case .ready(let attempt, _, _) = entry {
            effects.append(.modelDispose(screenID: screenID, attempt: attempt))
        }
        return GUIStateTransition(state: .active(issued: issued, routed: routed, entries: entries), effects: effects)
    }
}

// MARK: - Review Controller Actor

/// Actor combining review diff state, untracked folder expansion, detail loading, filter, and line comments.
public actor ReviewController {
    private var diffState: ReviewDiffMachine.State = ReviewDiffMachine.initialState
    private var folderState: ReviewFolderMachine.State = ReviewFolderMachine.initialState
    private var detailState: ReviewDetailMachine.State = ReviewDetailMachine.initialState
    private var commentStore = ReviewCommentStore()
    private var selectedFile: String?
    private var filterQuery = ""

    public init() {}

    public func dispatchDiff(_ event: ReviewDiffMachine.Event) -> [ReviewDiffMachine.Effect] {
        let transition = ReviewDiffMachine.reduce(state: diffState, event: event)
        diffState = transition.state
        return transition.effects
    }

    public func dispatchFolder(_ event: ReviewFolderMachine.Event) -> [ReviewFolderMachine.Effect] {
        let transition = ReviewFolderMachine.reduce(state: folderState, event: event)
        folderState = transition.state
        return transition.effects
    }

    public func dispatchDetail(_ event: ReviewDetailMachine.Event) -> [ReviewDetailMachine.Effect] {
        let transition = ReviewDetailMachine.reduce(state: detailState, event: event)
        detailState = transition.state
        return transition.effects
    }

    public func diffView() -> ReviewDiffMachine.View {
        ReviewDiffMachine.view(diffState)
    }

    public func expandedDiffs() -> [SessionSchema.FileDiffInfo] {
        guard case .ready(let rows, _) = ReviewDiffMachine.view(diffState) else { return [] }
        return ReviewFolderMachine.expandedDiffs(rows: rows, state: folderState)
    }

    public func setFilter(_ query: String) {
        filterQuery = query
    }

    public func filteredFiles() -> [String] {
        let files = expandedDiffs().map(\.file)
        return ReviewPathHelper.filterReviewFiles(files, query: filterQuery)
    }

    public func selectFile(_ file: String?) {
        selectedFile = file
    }

    public func activeFile() -> String? {
        let list = expandedDiffs()
        if let selectedFile, list.contains(where: { $0.file == selectedFile }) {
            return selectedFile
        }
        return list.first(where: { !ReviewPathHelper.isReviewFolder($0.file) })?.file
    }

    @discardableResult
    public func addComment(
        file: String,
        selection: LineRangeSelection,
        comment: String,
        preview: String? = nil
    ) -> ReviewLineComment {
        commentStore.add(file: file, selection: selection, comment: comment, preview: preview)
    }

    @discardableResult
    public func updateComment(id: String, comment: String, preview: String? = nil) -> ReviewLineComment? {
        commentStore.update(id: id, comment: comment, preview: preview)
    }

    @discardableResult
    public func removeComment(id: String) -> Bool {
        commentStore.remove(id: id)
    }

    public func allComments() -> [ReviewLineComment] {
        commentStore.comments
    }

    public func setCommentFocus(_ focus: ReviewCommentFocus?) {
        commentStore.setFocus(focus)
    }

    public func commentFocus() -> ReviewCommentFocus? {
        commentStore.focus
    }
}
