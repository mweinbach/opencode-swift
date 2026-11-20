#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Background Job Contracts (decoupled from sibling Job module)

/// Recovery metadata and background job summary types consumed by `CoreSessionBackground`,
/// `CoreSessionSubagentCompletion`, `CoreSessionSubagentReport`, `CoreSessionSubagentJob`,
/// and `CoreSessionRestart`.
public enum CoreSessionJobTypes {
    public enum Status: String, Equatable, Hashable, Sendable, Codable {
        case running
        case completed
        case error
        case cancelled
    }

    public enum Kind: String, Equatable, Hashable, Sendable, Codable {
        case codemode
        case shell
        case image
        case video
        case subagent
    }

    public enum OutstandingItem: Equatable, Hashable, Sendable, Codable {
        case codemode(jobID: String, sessionID: SessionID)
        case shell(sessionID: SessionID, shellID: String, command: String)
        case image(sessionID: SessionID, path: String, model: String)
        case video(sessionID: SessionID, path: String)
        case subagent(sessionID: SessionID, childSessionID: SessionID, agent: String, description: String)

        public var sessionID: SessionID {
            switch self {
            case .codemode(_, let sid), .shell(let sid, _, _), .image(let sid, _, _), .video(let sid, _),
                 .subagent(let sid, _, _, _):
                return sid
            }
        }
    }

    public struct SubagentRecovery: Equatable, Hashable, Sendable, Codable {
        public let parentSessionID: SessionID
        public let childSessionID: SessionID
        public let agent: String
        public let description: String
        public let outstanding: [OutstandingItem]?

        public init(
            parentSessionID: SessionID,
            childSessionID: SessionID,
            agent: String,
            description: String,
            outstanding: [OutstandingItem]? = nil
        ) {
            self.parentSessionID = parentSessionID
            self.childSessionID = childSessionID
            self.agent = agent
            self.description = description
            self.outstanding = outstanding
        }
    }

    public enum Recovery: Equatable, Hashable, Sendable, Codable {
        case codemode(jobID: String, sessionID: SessionID)
        case shell(sessionID: SessionID, shellID: String, command: String)
        case image(sessionID: SessionID, path: String, model: String)
        case video(sessionID: SessionID, path: String, videoID: String)
        case subagent(SubagentRecovery)
    }

    public struct BackgroundJobInfo: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let sessionID: SessionID
        public let kind: Kind
        public let status: Status
        public let title: String?
        public let output: String?
        public let error: String?
        public let notificationID: SessionMessageSchema.ID?
        public let recovery: Recovery?

        public init(
            id: String,
            sessionID: SessionID,
            kind: Kind,
            status: Status,
            title: String? = nil,
            output: String? = nil,
            error: String? = nil,
            notificationID: SessionMessageSchema.ID? = nil,
            recovery: Recovery? = nil
        ) {
            self.id = id
            self.sessionID = sessionID
            self.kind = kind
            self.status = status
            self.title = title
            self.output = output
            self.error = error
            self.notificationID = notificationID
            self.recovery = recovery
        }
    }

    public struct SubagentOutboxReport: Equatable, Hashable, Sendable, Codable {
        public let notificationID: SessionMessageSchema.ID
        public let status: Status
        public let output: String?
        public let error: String?
        public let recovery: SubagentRecovery

        public init(
            notificationID: SessionMessageSchema.ID,
            status: Status,
            output: String? = nil,
            error: String? = nil,
            recovery: SubagentRecovery
        ) {
            self.notificationID = notificationID
            self.status = status
            self.output = output
            self.error = error
            self.recovery = recovery
        }
    }

    public struct GenerationInfo: Equatable, Hashable, Sendable {
        public let generation: Int
        public let running: Bool

        public init(generation: Int, running: Bool) {
            self.generation = generation
            self.running = running
        }
    }

    public enum ReportPreparation: Sendable {
        case none
        case background(notificationID: SessionMessageSchema.ID, recovery: SubagentRecovery)
    }

    public protocol JobBridge: Sendable {
        func currentGeneration(_ sessionID: SessionID) async -> GenerationInfo?
        func prepareSubagentReport(_ sessionID: SessionID, boundGeneration: Int?) async -> ReportPreparation
        func recordOutbox(_ report: SubagentOutboxReport) throws
        func completeBackground(_ notificationID: SessionMessageSchema.ID) async throws
        func cancel(_ sessionID: SessionID) async
        func isCancelled(_ sessionID: SessionID) async -> Bool
        func get(_ sessionID: SessionID) async -> BackgroundJobInfo?
        func runningBackground() async -> [Recovery]
        func backgroundJobs() async -> [BackgroundJobInfo]
        func startSubagent(
            recovery: SubagentRecovery,
            notificationID: SessionMessageSchema.ID?,
            run: @escaping @Sendable () async throws -> String
        ) async throws -> BackgroundJobInfo
    }

    public final class NoopJobBridge: JobBridge, Sendable {
        public init() {}
        public func currentGeneration(_ sessionID: SessionID) async -> GenerationInfo? { nil }
        public func prepareSubagentReport(_ sessionID: SessionID, boundGeneration: Int?) async -> ReportPreparation { .none }
        public func recordOutbox(_ report: SubagentOutboxReport) throws {}
        public func completeBackground(_ notificationID: SessionMessageSchema.ID) async throws {}
        public func cancel(_ sessionID: SessionID) async {}
        public func isCancelled(_ sessionID: SessionID) async -> Bool { false }
        public func get(_ sessionID: SessionID) async -> BackgroundJobInfo? { nil }
        public func runningBackground() async -> [Recovery] { [] }
        public func backgroundJobs() async -> [BackgroundJobInfo] { [] }
        public func startSubagent(
            recovery: SubagentRecovery,
            notificationID: SessionMessageSchema.ID?,
            run: @escaping @Sendable () async throws -> String
        ) async throws -> BackgroundJobInfo {
            let task = Task { _ = try? await run() }
            _ = task
            return BackgroundJobInfo(
                id: recovery.childSessionID.rawValue,
                sessionID: recovery.parentSessionID,
                kind: .subagent,
                status: .running,
                title: recovery.description,
                notificationID: notificationID,
                recovery: .subagent(recovery)
            )
        }
    }
}

// MARK: - session/background.ts

/// Queries outstanding and unconsumed background work across a Session and its descendants
/// (`packages/core/src/session/background.ts`).
public enum CoreSessionBackground {
    // parity: core/src/session/background.ts#OutstandingItem [status=implemented hash=dbed1c4865ac]
    public typealias OutstandingItem = CoreSessionJobTypes.OutstandingItem

    // parity: core/src/session/background.ts#Lookup [status=implemented hash=8eaf63dfa4a0]
    public protocol Lookup: Sendable {
        func get(_ sessionID: SessionID) throws -> SessionSchema.Info?
    }

    // parity: core/src/session/background.ts#ListFilter [status=implemented hash=52e0c5d7836d]
    public struct ListFilter: Equatable, Hashable, Sendable {
        public let sessionID: SessionID?
        public let kind: CoreSessionJobTypes.Kind?
        public let status: CoreSessionJobTypes.Status?
        public let descendants: Bool

        public init(
            sessionID: SessionID? = nil,
            kind: CoreSessionJobTypes.Kind? = nil,
            status: CoreSessionJobTypes.Status? = nil,
            descendants: Bool = false
        ) {
            self.sessionID = sessionID
            self.kind = kind
            self.status = status
            self.descendants = descendants
        }
    }

    private static func descends(
        store: any Lookup,
        parents: inout [SessionID: SessionID?],
        from: SessionID,
        ancestor: SessionID
    ) throws -> Bool {
        var seen = Set<SessionID>()
        var current: SessionID? = from
        while let id = current, !seen.contains(id) {
            if id == ancestor { return true }
            seen.insert(id)
            if let cached = parents[id] {
                current = cached
                continue
            }
            let parentID = try store.get(id)?.parentID
            parents[id] = parentID
            current = parentID
        }
        return false
    }

    // parity: core/src/session/background.ts#outstanding [status=implemented hash=8c554ce99da8]
    public static func outstanding(
        jobs: any CoreSessionJobTypes.JobBridge,
        store: any Lookup,
        sessionID: SessionID,
        active: Set<SessionID>? = nil
    ) async throws -> [CoreSessionJobTypes.OutstandingItem] {
        var parents: [SessionID: SessionID?] = [:]
        let running = await jobs.runningBackground()
        var items: [CoreSessionJobTypes.OutstandingItem] = []

        for recovery in running {
            let ownerID: SessionID = switch recovery {
            case .codemode(_, let sid), .shell(let sid, _, _), .image(let sid, _, _), .video(let sid, _, _): sid
            case .subagent(let sub): sub.parentSessionID
            }
            if try descends(store: store, parents: &parents, from: ownerID, ancestor: sessionID) {
                switch recovery {
                case .codemode(let jobID, let sid):
                    items.append(.codemode(jobID: jobID, sessionID: sid))
                case .shell(let sid, let shellID, let command):
                    items.append(.shell(sessionID: sid, shellID: shellID, command: command))
                case .image(let sid, let path, let model):
                    items.append(.image(sessionID: sid, path: path, model: model))
                case .video(let sid, let path, _):
                    items.append(.video(sessionID: sid, path: path))
                case .subagent(let sub):
                    items.append(.subagent(
                        sessionID: sub.parentSessionID,
                        childSessionID: sub.childSessionID,
                        agent: sub.agent,
                        description: sub.description
                    ))
                }
            }
        }

        guard let active, !active.isEmpty else { return items }
        var children = Set<SessionID>()
        for item in items {
            if case .subagent(_, let childID, _, _) = item {
                children.insert(childID)
            }
        }

        for activeID in active {
            if activeID == sessionID || children.contains(activeID) { continue }
            if let tracked = await jobs.get(activeID), tracked.status == .cancelled { continue }
            guard try descends(store: store, parents: &parents, from: activeID, ancestor: sessionID) else { continue }
            guard let info = try store.get(activeID), let parentID = info.parentID else { continue }
            items.append(.subagent(
                sessionID: parentID,
                childSessionID: activeID,
                agent: info.agent ?? "subagent",
                description: info.title ?? "Subagent"
            ))
        }
        return items
    }

    // parity: core/src/session/background.ts#list [status=implemented hash=a9a43474f966]
    public static func list(
        jobs: any CoreSessionJobTypes.JobBridge,
        store: any Lookup,
        filter: ListFilter = ListFilter()
    ) async throws -> [CoreSessionJobTypes.BackgroundJobInfo] {
        let items = await jobs.backgroundJobs().filter { item in
            (filter.kind == nil || item.kind == filter.kind)
                && (filter.status == nil || item.status == filter.status)
        }
        guard let sessionID = filter.sessionID else { return items }
        if !filter.descendants {
            return items.filter { $0.sessionID == sessionID }
        }
        var parents: [SessionID: SessionID?] = [:]
        var matched: [CoreSessionJobTypes.BackgroundJobInfo] = []
        for item in items {
            if try descends(store: store, parents: &parents, from: item.sessionID, ancestor: sessionID) {
                matched.append(item)
            }
        }
        return matched
    }
}

extension CoreSessionStore.Service: CoreSessionBackground.Lookup {}

// MARK: - session/subagent-completion.ts

/// Formats and delivers subagent completion notices to parent sessions
/// (`packages/core/src/session/subagent-completion.ts`).
public enum CoreSessionSubagentCompletion {
    // parity: core/src/session/subagent-completion.ts#NO_TEXT [status=implemented hash=e608bb600411]
    public static let NO_TEXT = "Subagent completed without a text response."

    // parity: core/src/session/subagent-completion.ts#RunningBackgroundItem [status=implemented hash=60093764a2ad]
    public typealias RunningBackgroundItem = CoreSessionJobTypes.OutstandingItem

    // parity: core/src/session/subagent-completion.ts#SyntheticSession [status=implemented hash=846e2db59689]
    public protocol SyntheticSession: Sendable {
        func synthetic(
            id: SessionMessageSchema.ID?,
            sessionID: SessionID,
            text: String,
            description: String?,
            metadata: SessionSchema.Metadata?
        ) async throws
    }

    // parity: core/src/session/subagent-completion.ts#text [status=implemented hash=a5fcca1ccc28]
    public static func text(_ message: SessionMessageSchema.Info?) -> String {
        guard case .assistant(let assistant) = message else { return NO_TEXT }
        let parts = assistant.content.compactMap { part -> String? in
            guard case .text(let t) = part, !t.text.isEmpty else { return nil }
            return t.text
        }
        return parts.isEmpty ? NO_TEXT : parts.joined(separator: "\n\n")
    }

    private static func clean(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // parity: core/src/session/subagent-completion.ts#formatBody [status=implemented hash=aae647425600]
    public static func formatBody(
        _ body: String,
        childSessionID: SessionID,
        background: [RunningBackgroundItem]? = nil
    ) -> String {
        guard let background, !background.isEmpty else { return body }
        let lines = background.map { item -> String in
            let location = item.sessionID != childSessionID ? ", in \(item.sessionID.rawValue)" : ""
            switch item {
            case .codemode(let jobID, _):
                return "- Code Mode script (\(jobID)\(location))"
            case .shell(_, let shellID, let command):
                return "- shell (\(shellID)\(location)): \(clean(command))"
            case .image(_, let path, let model):
                return "- image (\(model)\(location)): \(path)"
            case .video(_, let path):
                return "- video (\(path)\(location))"
            case .subagent(_, let childID, let agent, let description):
                return "- subagent (\(agent), sessionID: \(childID.rawValue)): \(clean(description))"
            }
        }
        return "\(body)\n\nBackground work still running:\n\(lines.joined(separator: "\n"))"
    }

    // parity: core/src/session/subagent-completion.ts#deliver [status=implemented hash=4d11cba8a3c1]
    public static func deliver(
        sessions: any SyntheticSession,
        jobs: any CoreSessionJobTypes.JobBridge,
        report: CoreSessionJobTypes.SubagentOutboxReport
    ) async throws {
        guard report.status != .running else { return }
        let recovery = report.recovery
        let body: String = switch report.status {
        case .completed:
            report.output ?? NO_TEXT
        case .error:
            report.error ?? "Subagent failed"
        case .cancelled:
            report.output ?? report.error ?? "Subagent cancelled"
        case .running:
            NO_TEXT
        }
        let state: String = (report.status == .completed && !(recovery.outstanding?.isEmpty ?? true))
            ? "running"
            : report.status.rawValue
        let formatted = formatBody(body, childSessionID: recovery.childSessionID, background: recovery.outstanding)
        try await sessions.synthetic(
            id: report.notificationID,
            sessionID: recovery.parentSessionID,
            text: CoreSessionBackgroundResult.render(
                "kind=\"subagent\" sessionID=\"\(recovery.childSessionID.rawValue)\" state=\"\(state)\" description=\"\(recovery.description)\"",
                formatted
            ),
            description: recovery.description,
            metadata: [
                "source": .string("subagent"),
                "childID": .string(recovery.childSessionID.rawValue),
                "agent": .string(recovery.agent),
                "state": .string(report.status.rawValue),
            ]
        )
        try await jobs.completeBackground(report.notificationID)
    }
}

// MARK: - session/subagent-depth.ts

/// Checks whether spawning another generation of subagent children exceeds the configured depth limit
/// (`packages/core/src/session/subagent-depth.ts`).
public enum CoreSessionSubagentDepth {
    // parity: core/src/session/subagent-depth.ts#reached [status=implemented hash=19ed7cf2dc05]
    public static func reached(
        parent: SessionSchema.Info,
        store: any CoreSessionStore.Interface,
        limit: Int = 1
    ) throws -> Int? {
        var current = parent
        for _ in 0..<max(0, limit) {
            guard let parentID = current.parentID else { return nil }
            guard let next = try store.get(parentID) else {
                throw CoreSessionErrors.NotFoundError(sessionID: parentID)
            }
            current = next
        }
        return limit
    }
}

// MARK: - session/execution/subagent-report.ts

/// Coordinates transactional subagent completion outbox emission and best-effort parent delivery
/// (`packages/core/src/session/execution/subagent-report.ts`).
public enum CoreSessionSubagentReport {
    // parity: core/src/session/execution/subagent-report.ts#Outcome [status=implemented hash=23fac0b0c484]
    public enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(error: SessionErrorSchema.Error)
        case interrupted(reason: SessionEventSchema.Execution.InterruptReason)
    }

    // parity: core/src/session/execution/subagent-report.ts#Period [status=implemented hash=73b485475a06]
    public struct Period: Equatable, Hashable, Sendable {
        public let startedSeq: Int64
        public let boundGeneration: Int?

        public init(startedSeq: Int64, boundGeneration: Int? = nil) {
            self.startedSeq = startedSeq
            self.boundGeneration = boundGeneration
        }
    }

    // parity: core/src/session/execution/subagent-report.ts#Inbox [status=implemented hash=827906fcf558]
    public protocol Inbox: Sendable {
        func admit(
            id: SessionMessageSchema.ID,
            sessionID: SessionID,
            item: SessionInboxSchema.Item
        ) async throws -> SessionInboxSchema.Info
    }

    // parity: core/src/session/execution/subagent-report.ts#Deps [status=implemented hash=fb389bc15390]
    public struct Deps: Sendable {
        public let store: any CoreSessionStore.Interface
        public let jobs: any CoreSessionJobTypes.JobBridge
        public let inbox: any Inbox
        public let wake: @Sendable (SessionID) async -> Void
        public let draining: @Sendable () async -> Set<SessionID>

        public init(
            store: any CoreSessionStore.Interface,
            jobs: any CoreSessionJobTypes.JobBridge,
            inbox: any Inbox,
            wake: @escaping @Sendable (SessionID) async -> Void,
            draining: @escaping @Sendable () async -> Set<SessionID>
        ) {
            self.store = store
            self.jobs = jobs
            self.inbox = inbox
            self.wake = wake
            self.draining = draining
        }
    }

    public struct Settlement: Sendable {
        public let commit: @Sendable (Int64) throws -> Void
        public let deliver: @Sendable () async -> Void

        public init(
            commit: @escaping @Sendable (Int64) throws -> Void,
            deliver: @escaping @Sendable () async -> Void
        ) {
            self.commit = commit
            self.deliver = deliver
        }
    }

    public final class Coordinator: Sendable {
        private let deps: Deps
        private let periods = Mutex<[SessionID: Period]>([:])

        fileprivate init(deps: Deps) {
            self.deps = deps
        }

        public func started(_ sessionID: SessionID, period: Period) {
            periods.withLock { $0[sessionID] = period }
        }

        public func clear(_ sessionID: SessionID) {
            periods.withLock { _ = $0.removeValue(forKey: sessionID) }
        }

        private struct InboxSyntheticAdapter: CoreSessionSubagentCompletion.SyntheticSession {
            let inbox: any Inbox
            let fallbackID: SessionMessageSchema.ID

            func synthetic(
                id: SessionMessageSchema.ID?,
                sessionID: SessionID,
                text: String,
                description: String?,
                metadata: SessionSchema.Metadata?
            ) async throws {
                _ = try await inbox.admit(
                    id: id ?? fallbackID,
                    sessionID: sessionID,
                    item: .synthetic(
                        payload: SessionInboxSchema.SyntheticPayload(
                            text: text,
                            description: description,
                            metadata: metadata
                        ),
                        delivery: .steer
                    )
                )
            }
        }

        public func prepare(sessionID: SessionID, outcome: Outcome) async -> Settlement {
            let period = periods.withLock { $0.removeValue(forKey: sessionID) }
            let jobState = await deps.jobs.prepareSubagentReport(sessionID, boundGeneration: period?.boundGeneration)
            let initial = try? deps.store.get(sessionID)

            let hasParent = initial?.parentID != nil
            if !hasParent, case .none = jobState {
                let store = deps.store
                return Settlement(
                    commit: { _ in try store.release(sessionID) },
                    deliver: {}
                )
            }

            let drainingSet = await deps.draining()
            let lookupStore = deps.store as? (any CoreSessionBackground.Lookup)
            let running: [CoreSessionJobTypes.OutstandingItem]
            if hasParent, let lookupStore {
                running = (try? await CoreSessionBackground.outstanding(
                    jobs: deps.jobs,
                    store: lookupStore,
                    sessionID: sessionID,
                    active: drainingSet
                )) ?? []
            } else {
                running = []
            }

            let postCommitBox = Mutex<CoreSessionJobTypes.SubagentOutboxReport?>(nil)
            let store = deps.store
            let jobs = deps.jobs
            let inbox = deps.inbox
            let wake = deps.wake

            let commit: @Sendable (Int64) throws -> Void = { _ in
                postCommitBox.withLock { $0 = nil }
                try store.release(sessionID)
                guard let child = try store.get(sessionID),
                      let parentID = child.parentID,
                      try store.get(parentID) != nil
                else { return }

                let resolved: (status: CoreSessionJobTypes.Status, body: String)? = {
                    switch outcome {
                    case .failed(let error):
                        return (.error, error.message)
                    case .interrupted:
                        return (.cancelled, "Subagent cancelled")
                    case .succeeded:
                        do {
                            if let assistant = try store.lastAssistantAfter(sessionID: sessionID, afterSeq: period?.startedSeq) {
                                return (.completed, CoreSessionSubagentCompletion.text(.assistant(assistant)))
                            }
                        } catch {
                            return (.error, String(describing: error))
                        }
                        if case .background = jobState {
                            return (.completed, CoreSessionSubagentCompletion.NO_TEXT)
                        }
                        return nil
                    }
                }()
                guard let resolved else { return }

                let notifID: SessionMessageSchema.ID
                let recovery: CoreSessionJobTypes.SubagentRecovery
                switch jobState {
                case .background(let id, let rec):
                    notifID = id
                    recovery = CoreSessionJobTypes.SubagentRecovery(
                        parentSessionID: rec.parentSessionID,
                        childSessionID: rec.childSessionID,
                        agent: rec.agent,
                        description: rec.description,
                        outstanding: running.isEmpty ? nil : running
                    )
                case .none:
                    notifID = SessionMessageSchema.ID.create()
                    recovery = CoreSessionJobTypes.SubagentRecovery(
                        parentSessionID: parentID,
                        childSessionID: sessionID,
                        agent: child.agent ?? "subagent",
                        description: child.title ?? "Subagent",
                        outstanding: running.isEmpty ? nil : running
                    )
                }

                let report = CoreSessionJobTypes.SubagentOutboxReport(
                    notificationID: notifID,
                    status: resolved.status,
                    output: resolved.status == .completed ? resolved.body : nil,
                    error: resolved.status != .completed ? resolved.body : nil,
                    recovery: recovery
                )
                try jobs.recordOutbox(report)
                postCommitBox.withLock { $0 = report }
            }

            let deliver: @Sendable () async -> Void = {
                guard let report = postCommitBox.withLock({ $0 }) else { return }
                let parentID = report.recovery.parentSessionID
                guard (try? store.get(parentID)) != nil else {
                    try? await jobs.completeBackground(report.notificationID)
                    return
                }
                do {
                    try await CoreSessionSubagentCompletion.deliver(
                        sessions: InboxSyntheticAdapter(inbox: inbox, fallbackID: report.notificationID),
                        jobs: jobs,
                        report: report
                    )
                    if let parent = try? store.get(parentID), parent.revert == nil {
                        await wake(parentID)
                    }
                } catch is CoreSessionInbox.LifecycleConflict {
                    // Retain outbox row when notification ID conflicted.
                } catch {
                    if (try? store.get(parentID)) == nil {
                        try? await jobs.completeBackground(report.notificationID)
                    }
                }
            }

            return Settlement(commit: commit, deliver: deliver)
        }
    }

    // parity: core/src/session/execution/subagent-report.ts#make [status=implemented hash=3ab05a2596d3]
    public static func make(_ deps: Deps) -> Coordinator {
        Coordinator(deps: deps)
    }
}

extension CoreSessionInbox.Service: CoreSessionSubagentReport.Inbox {}

// MARK: - session/run-coordinator.ts

/// Serializes process-local execution per key while allowing distinct keys to drain concurrently,
/// coalescing wakeups via a doorbell and distinguishing explicit vs teardown interruptions
/// (`packages/core/src/session/run-coordinator.ts`).
public enum CoreSessionRunCoordinator {
    public enum ExecutionExit: Sendable {
        case succeeded
        case failed(any Error & Sendable)
        case interrupted
    }

    // parity: core/src/session/run-coordinator.ts#Coordinator [status=implemented hash=4d61362eae70]
    public protocol Coordinator<Key, Reason>: Sendable {
        associatedtype Key: Hashable & Sendable
        associatedtype Reason: Sendable

        func active() async -> Set<Key>
        func draining() async -> Set<Key>
        func isActive(_ key: Key) async -> Bool
        func run(_ key: Key) async throws
        func wake(_ key: Key, scope: CoreSessionInbox.Promotable) async
        func interrupt(_ key: Key, reason: Reason?) async -> Bool
        func interruption(_ key: Key) -> Reason?
        func awaitIdle(_ key: Key) async
    }

    public final class LiveCoordinator<Key: Hashable & Sendable, Reason: Sendable>: Coordinator, @unchecked Sendable {
        private final class Entry: @unchecked Sendable {
            var scope: CoreSessionInbox.Promotable
            var pendingWake: CoreSessionInbox.Promotable?
            var stopping = false
            var interruptionReason: Reason?
            var task: Task<Void, Never>?
            var exit: ExecutionExit?
            var waiters: [CheckedContinuation<ExecutionExit, Never>] = []

            init(scope: CoreSessionInbox.Promotable) {
                self.scope = scope
            }
        }

        private let state = Mutex<[Key: Entry]>([:])
        private let drainFn: @Sendable (Key, Bool, CoreSessionInbox.Promotable) async throws -> Void
        private let startedFn: (@Sendable (Key) async -> Void)?
        private let settledFn: (@Sendable (Key, ExecutionExit, Reason?) async -> Void)?

        fileprivate init(
            drain: @escaping @Sendable (Key, Bool, CoreSessionInbox.Promotable) async throws -> Void,
            started: (@Sendable (Key) async -> Void)?,
            settled: (@Sendable (Key, ExecutionExit, Reason?) async -> Void)?
        ) {
            self.drainFn = drain
            self.startedFn = started
            self.settledFn = settled
        }

        public func active() async -> Set<Key> {
            state.withLock { Set($0.keys) }
        }

        public func draining() async -> Set<Key> {
            state.withLock { map in
                Set(map.compactMap { $0.value.stopping ? nil : $0.key })
            }
        }

        public func isActive(_ key: Key) async -> Bool {
            state.withLock { $0[key] != nil }
        }

        public func interruption(_ key: Key) -> Reason? {
            state.withLock { $0[key]?.interruptionReason }
        }

        private func startLocked(key: Key, force: Bool, scope: CoreSessionInbox.Promotable, map: inout [Key: Entry]) -> Entry {
            let entry = Entry(scope: scope)
            map[key] = entry
            let task = Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                if let started = self.startedFn {
                    await started(key)
                }

                let result: ExecutionExit
                do {
                    var currentForce = force
                    while true {
                        try Task.checkCancellation()
                        let currentScope = self.state.withLock { _ in entry.scope }
                        try await self.drainFn(key, currentForce, currentScope)
                        let shouldContinue: Bool = self.state.withLock { _ in
                            guard !entry.stopping, let next = entry.pendingWake else { return false }
                            entry.scope = next
                            entry.pendingWake = nil
                            return true
                        }
                        if !shouldContinue { break }
                        currentForce = false
                        await Task.yield()
                    }
                    result = Task.isCancelled ? .interrupted : .succeeded
                } catch is CancellationError {
                    result = .interrupted
                } catch {
                    if Task.isCancelled {
                        result = .interrupted
                    } else {
                        result = .failed(error)
                    }
                }

                let reason: Reason? = self.state.withLock { _ in
                    entry.task = nil
                    return entry.interruptionReason
                }
                if let settled = self.settledFn {
                    await settled(key, result, reason)
                }

                let waiters: [CheckedContinuation<ExecutionExit, Never>] = self.state.withLock { map in
                    entry.exit = result
                    let pending = entry.waiters
                    entry.waiters.removeAll(keepingCapacity: false)
                    if let nextScope = entry.pendingWake {
                        _ = self.startLocked(key: key, force: false, scope: nextScope, map: &map)
                    } else {
                        map.removeValue(forKey: key)
                    }
                    return pending
                }
                for waiter in waiters {
                    waiter.resume(returning: result)
                }
            }
            entry.task = task
            return entry
        }

        private func awaitEntry(_ entry: Entry) async -> ExecutionExit {
            await withCheckedContinuation { cont in
                let resolved: ExecutionExit? = state.withLock { _ in
                    if let done = entry.exit {
                        return done
                    }
                    entry.waiters.append(cont)
                    return nil
                }
                if let resolved {
                    cont.resume(returning: resolved)
                }
            }
        }

        public func run(_ key: Key) async throws {
            while true {
                let (entry, wasStopping): (Entry, Bool) = state.withLock { map in
                    if let existing = map[key] {
                        return (existing, existing.stopping)
                    }
                    return (startLocked(key: key, force: true, scope: .input, map: &map), false)
                }
                let exit = await awaitEntry(entry)
                if wasStopping {
                    continue
                }
                switch exit {
                case .succeeded:
                    return
                case .interrupted:
                    throw CancellationError()
                case .failed(let error):
                    throw error
                }
            }
        }

        public func wake(_ key: Key, scope: CoreSessionInbox.Promotable = .input) async {
            state.withLock { map in
                if let existing = map[key] {
                    existing.pendingWake = (existing.pendingWake == .input) ? .input : scope
                    return
                }
                _ = startLocked(key: key, force: false, scope: scope, map: &map)
            }
        }

        public func interrupt(_ key: Key, reason: Reason? = nil) async -> Bool {
            let taskToCancel: Task<Void, Never>? = state.withLock { map in
                guard let existing = map[key], !existing.stopping else { return nil }
                existing.stopping = true
                existing.pendingWake = nil
                existing.interruptionReason = reason
                return existing.task
            }
            guard let taskToCancel else { return false }
            taskToCancel.cancel()
            return true
        }

        public func awaitIdle(_ key: Key) async {
            while true {
                let current: Entry? = state.withLock { $0[key] }
                guard let current else { return }
                _ = await awaitEntry(current)
            }
        }
    }

    // parity: core/src/session/run-coordinator.ts#make [status=implemented hash=eddaf5988bd9]
    public static func make<Key: Hashable & Sendable, Reason: Sendable>(
        drain: @escaping @Sendable (Key, Bool, CoreSessionInbox.Promotable) async throws -> Void,
        started: (@Sendable (Key) async -> Void)? = nil,
        settled: (@Sendable (Key, ExecutionExit, Reason?) async -> Void)? = nil
    ) -> LiveCoordinator<Key, Reason> {
        LiveCoordinator(drain: drain, started: started, settled: settled)
    }
}

// MARK: - session/execution.ts

/// Process-global, Session-ID keyed execution coordinator with write-ahead claim lifecycle
/// (`packages/core/src/session/execution.ts`).
public enum CoreSessionExecution {
    public typealias InterruptReason = SessionEventSchema.Execution.InterruptReason

    // parity: core/src/session/execution.ts#Interface [status=implemented hash=705b721fd19e]
    public protocol Interface: Sendable {
        func active() async -> Set<SessionID>
        func isActive(_ sessionID: SessionID) async -> Bool
        func resume(_ sessionID: SessionID) async throws
        func wake(_ sessionID: SessionID) async
        func interrupt(_ sessionID: SessionID, resume: Bool) async -> Bool
        func awaitIdle(_ sessionID: SessionID) async
    }

    // parity: core/src/session/execution.ts#terminal [status=implemented hash=783a80aaa9e1]
    public static func terminal(
        _ exit: CoreSessionRunCoordinator.ExecutionExit,
        reason: InterruptReason? = nil
    ) -> CoreSessionSubagentReport.Outcome {
        switch exit {
        case .succeeded:
            return .succeeded
        case .interrupted:
            return .interrupted(reason: reason ?? .shutdown)
        case .failed(let error):
            return .failed(error: CoreSessionErrorMapping.toSessionError(error))
        }
    }

    // parity: core/src/session/execution.ts#Service [status=implemented hash=c5a1a6093001]
    public final class Service: Interface, @unchecked Sendable {
        public static let serviceKey = "@opencode/SessionExecution"

        private let db: any SQLiteDatabase
        private let store: any CoreSessionStore.Interface
        private let bus: CoreBus.Service
        private let jobs: any CoreSessionJobTypes.JobBridge
        private let inbox: any CoreSessionInbox.Interface
        private let runnerForLocation: @Sendable (SessionSchema.Info) async throws -> any CoreSessionRunner.Interface
        private var coordinator: CoreSessionRunCoordinator.LiveCoordinator<SessionID, InterruptReason>!

        public init(
            db: any SQLiteDatabase,
            store: any CoreSessionStore.Interface,
            bus: CoreBus.Service,
            jobs: any CoreSessionJobTypes.JobBridge = CoreSessionJobTypes.NoopJobBridge(),
            inbox: any CoreSessionInbox.Interface,
            runnerForLocation: @escaping @Sendable (SessionSchema.Info) async throws -> any CoreSessionRunner.Interface
        ) {
            self.db = db
            self.store = store
            self.bus = bus
            self.jobs = jobs
            self.inbox = inbox
            self.runnerForLocation = runnerForLocation

            let holder = Mutex<CoreSessionRunCoordinator.LiveCoordinator<SessionID, InterruptReason>?>(nil)
            let wakeClosure: @Sendable (SessionID) async -> Void = { sid in
                guard let coord = holder.withLock({ $0 }) else { return }
                await coord.wake(sid, scope: .input)
            }
            let drainingClosure: @Sendable () async -> Set<SessionID> = {
                guard let coord = holder.withLock({ $0 }) else { return [] }
                return await coord.draining()
            }
            let reportInbox = (inbox as? (any CoreSessionSubagentReport.Inbox))
                ?? CoreSessionInbox.Service(db: db, bus: bus)
            let subagentReport = CoreSessionSubagentReport.make(CoreSessionSubagentReport.Deps(
                store: store,
                jobs: jobs,
                inbox: reportInbox,
                wake: wakeClosure,
                draining: drainingClosure
            ))

            let drainClosure: @Sendable (SessionID, Bool, CoreSessionInbox.Promotable) async throws -> Void = { [store, runnerForLocation] sessionID, force, promotable in
                var currentForce = force
                var currentContinuation: CoreSessionRunner.Continuation? = nil
                var currentStepped = false

                while true {
                    guard let session = try store.get(sessionID) else {
                        throw CoreSessionErrors.NotFoundError(sessionID: sessionID)
                    }
                    let runner = try await runnerForLocation(session)
                    let result = try await runner.drain(CoreSessionRunner.DrainInput(
                        sessionID: sessionID,
                        force: currentForce,
                        continuation: currentContinuation,
                        promotable: promotable,
                        stepped: currentStepped,
                        interruption: { holder.withLock { $0 }?.interruption(sessionID) }
                    ))
                    switch result {
                    case .complete:
                        return
                    case .moved(let cont, let stepped):
                        currentForce = false
                        currentContinuation = cont
                        currentStepped = stepped
                    case .reloaded(let nextForce, let cont, let stepped):
                        currentForce = nextForce
                        currentContinuation = cont
                        currentStepped = stepped
                    }
                }
            }

            let startedClosure: @Sendable (SessionID) async -> Void = { [store, bus, jobs] sessionID in
                let before = await jobs.currentGeneration(sessionID)
                guard let event = try? await bus.publish(
                    SessionEventSchema.Execution.Started,
                    data: SessionEventSchema.SessionBaseData(sessionID: sessionID),
                    options: CoreBus.PublishOptions(commit: { _ in
                        // Write-ahead execution claim inside the same SQLite transaction.
                        try store.claim(sessionID)
                    })
                ) else { return }
                let bound = (before?.running == true) ? before : await jobs.currentGeneration(sessionID)
                subagentReport.started(sessionID, period: CoreSessionSubagentReport.Period(
                    startedSeq: event.durable.seq.rawValue,
                    boundGeneration: (bound?.running == true) ? bound?.generation : nil
                ))
            }

            let settledClosure: @Sendable (SessionID, CoreSessionRunCoordinator.ExecutionExit, InterruptReason?) async -> Void = { [bus, jobs] sessionID, exit, reason in
                let outcome = CoreSessionExecution.terminal(exit, reason: reason)
                if case .interrupted(let r) = outcome, r == .shutdown {
                    subagentReport.clear(sessionID)
                    // Shutdown preserves the write-ahead claim so the next server start resumes the turn.
                    _ = try? await bus.publish(
                        SessionEventSchema.Execution.Interrupted,
                        data: SessionEventSchema.Execution.InterruptedData(sessionID: sessionID, reason: .shutdown)
                    )
                    return
                }
                let settlement = await subagentReport.prepare(sessionID: sessionID, outcome: outcome)
                if case .interrupted = outcome {
                    await jobs.cancel(sessionID)
                }
                do {
                    try await Self.publishTerminal(bus: bus, sessionID: sessionID, outcome: outcome, commit: settlement.commit)
                } catch {
                    // Best-effort lifecycle settlement.
                }
                await settlement.deliver()
            }

            let coord = CoreSessionRunCoordinator.make(
                drain: drainClosure,
                started: startedClosure,
                settled: settledClosure
            )
            holder.withLock { $0 = coord }
            self.coordinator = coord
        }

        private static func publishTerminal(
            bus: CoreBus.Service,
            sessionID: SessionID,
            outcome: CoreSessionSubagentReport.Outcome,
            commit: @escaping @Sendable (Int64) throws -> Void
        ) async throws {
            let opts = CoreBus.PublishOptions(commit: commit)
            switch outcome {
            case .succeeded:
                _ = try await bus.publish(
                    SessionEventSchema.Execution.Succeeded,
                    data: SessionEventSchema.SessionBaseData(sessionID: sessionID),
                    options: opts
                )
            case .interrupted(let reason):
                _ = try await bus.publish(
                    SessionEventSchema.Execution.Interrupted,
                    data: SessionEventSchema.Execution.InterruptedData(sessionID: sessionID, reason: reason),
                    options: opts
                )
            case .failed(let error):
                _ = try await bus.publish(
                    SessionEventSchema.Execution.Failed,
                    data: SessionEventSchema.Execution.FailedData(sessionID: sessionID, error: error),
                    options: opts
                )
            }
        }

        public func active() async -> Set<SessionID> {
            await coordinator.active()
        }

        public func isActive(_ sessionID: SessionID) async -> Bool {
            await coordinator.isActive(sessionID)
        }

        public func resume(_ sessionID: SessionID) async throws {
            try await coordinator.run(sessionID)
        }

        public func wake(_ sessionID: SessionID) async {
            await coordinator.wake(sessionID, scope: .input)
        }

        public func interrupt(_ sessionID: SessionID, resume: Bool = false) async -> Bool {
            let interrupted = await coordinator.interrupt(sessionID, reason: .user)
            guard resume else { return interrupted }
            if let next = try? CoreSessionInbox.nextPromotable(db: db, sessionID: sessionID, promotable: .input) {
                if next.delivery == .steer || next.isControl {
                    await coordinator.wake(sessionID, scope: .steer)
                }
            }
            return interrupted
        }

        /// Triggers a shutdown interruption preserving write-ahead claims for restart recovery.
        public func shutdownInterrupt(_ sessionID: SessionID) async -> Bool {
            await coordinator.interrupt(sessionID, reason: .shutdown)
        }

        public func awaitIdle(_ sessionID: SessionID) async {
            await coordinator.awaitIdle(sessionID)
        }
    }

    public final class NoopService: Interface, Sendable {
        public init() {}
        public func active() async -> Set<SessionID> { [] }
        public func isActive(_ sessionID: SessionID) async -> Bool { false }
        public func resume(_ sessionID: SessionID) async throws {}
        public func wake(_ sessionID: SessionID) async {}
        public func interrupt(_ sessionID: SessionID, resume: Bool = false) async -> Bool { false }
        public func awaitIdle(_ sessionID: SessionID) async {}
    }

    // parity: core/src/session/execution.ts#layer [status=adapted hash=f09dffe0d932]
    public static func layer(
        runnerForLocation: @escaping @Sendable (SessionSchema.Info) async throws -> any CoreSessionRunner.Interface
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, _ in
            guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
                  let store = deps.get(CoreSessionStore.Service.serviceKey, as: CoreSessionStore.Service.self),
                  let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self),
                  let inbox = deps.get(CoreSessionInbox.Service.serviceKey, as: CoreSessionInbox.Service.self)
            else {
                throw SQLiteError.databaseClosed
            }
            let jobs = deps.get("@opencode/JobBridge", as: (any CoreSessionJobTypes.JobBridge).self)
                ?? CoreSessionJobTypes.NoopJobBridge()
            let service = Service(
                db: db,
                store: store,
                bus: bus,
                jobs: jobs,
                inbox: inbox,
                runnerForLocation: runnerForLocation
            )
            return LayerNode.Output([Service.serviceKey: service])
        }
    }

    // parity: core/src/session/execution.ts#noopLayer [status=adapted hash=8ebdbcf829b6]
    public static let noopLayer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { _, _ in
        LayerNode.Output([Service.serviceKey: NoopService()])
    }

    // parity: core/src/session/execution.ts#node [status=adapted hash=6bec4735d0d4]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        noopLayer,
        [CoreSessionStore.node, CoreBus.node, CoreDatabaseStore.node, CoreSessionInbox.node]
    )
}

// MARK: - session/subagent-job.ts

/// Launches a background subagent job tied to `CoreSessionExecution.resume`
/// (`packages/core/src/session/subagent-job.ts`).
public enum CoreSessionSubagentJob {
    // parity: core/src/session/subagent-job.ts#Interface [status=implemented hash=e40f45901d67]
    public protocol Interface: Sendable {
        func start(_ recovery: CoreSessionJobTypes.SubagentRecovery) async throws -> CoreSessionJobTypes.BackgroundJobInfo
    }

    // parity: core/src/session/subagent-job.ts#start [status=implemented hash=bf2e51011b41]
    public static func start(
        jobs: any CoreSessionJobTypes.JobBridge,
        execution: any CoreSessionExecution.Interface,
        recovery: CoreSessionJobTypes.SubagentRecovery,
        notificationID: SessionMessageSchema.ID? = nil
    ) async throws -> CoreSessionJobTypes.BackgroundJobInfo {
        let id = recovery.childSessionID
        return try await jobs.startSubagent(recovery: recovery, notificationID: notificationID) {
            do {
                try await execution.resume(id)
                return ""
            } catch is CancellationError {
                if await jobs.isCancelled(id) {
                    _ = await execution.interrupt(id, resume: false)
                }
                throw CancellationError()
            }
        }
    }

    // parity: core/src/session/subagent-job.ts#Service [status=implemented hash=ad3499f5bcb8]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SubagentJob"
        public let jobs: any CoreSessionJobTypes.JobBridge
        public let execution: any CoreSessionExecution.Interface

        public init(jobs: any CoreSessionJobTypes.JobBridge, execution: any CoreSessionExecution.Interface) {
            self.jobs = jobs
            self.execution = execution
        }

        public func start(_ recovery: CoreSessionJobTypes.SubagentRecovery) async throws -> CoreSessionJobTypes.BackgroundJobInfo {
            try await CoreSessionSubagentJob.start(jobs: jobs, execution: execution, recovery: recovery)
        }
    }

    // parity: core/src/session/subagent-job.ts#layer [status=adapted hash=0df0809780fe]
    public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { deps, _ in
        guard let execution = deps.get(CoreSessionExecution.Service.serviceKey, as: (any CoreSessionExecution.Interface).self) else {
            throw SQLiteError.databaseClosed
        }
        let jobs = deps.get("@opencode/JobBridge", as: (any CoreSessionJobTypes.JobBridge).self)
            ?? CoreSessionJobTypes.NoopJobBridge()
        return LayerNode.Output([Service.serviceKey: Service(jobs: jobs, execution: execution)])
    }

    // parity: core/src/session/subagent-job.ts#node [status=adapted hash=8ec1fbe10975]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        layer,
        [CoreSessionExecution.node]
    )
}

// MARK: - session/execution/restart.ts

/// Startup recovery sweep for claimed/suspended sessions (`time_suspended IS NOT NULL`)
/// with durable per-turn `resume_attempts` accounting (`packages/core/src/session/execution/restart.ts`).
public enum CoreSessionRestart {
    public static let continueAfterRestartText =
        "The server restarted while you were working. Continue from where you left off without repeating completed work."

    public static let resumeExhaustedError = SessionErrorSchema.Error(
        type: "aborted",
        message: "Execution was interrupted repeatedly and will not be resumed automatically."
    )

    public static let defaultMaxAttempts = 10

    // parity: core/src/session/execution/restart.ts#Options [status=implemented hash=3423e53fef52]
    public struct Options: Equatable, Hashable, Sendable {
        public let maxAttempts: Int

        public init(maxAttempts: Int = CoreSessionRestart.defaultMaxAttempts) {
            self.maxAttempts = maxAttempts
        }
    }

    // parity: core/src/session/execution/restart.ts#Interface [status=implemented hash=1654f7ef22d0]
    public protocol Interface: Sendable {
        func resumeSuspendedSessions() async throws
    }

    // parity: core/src/session/execution/restart.ts#Service [status=implemented hash=d238b3099c06]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/SessionRestart"
        public let db: any SQLiteDatabase
        public let store: any CoreSessionStore.Interface
        public let execution: any CoreSessionExecution.Interface
        public let bus: CoreBus.Service
        public let jobs: any CoreSessionJobTypes.JobBridge
        public let options: Options

        public init(
            db: any SQLiteDatabase,
            store: any CoreSessionStore.Interface,
            execution: any CoreSessionExecution.Interface,
            bus: CoreBus.Service,
            jobs: any CoreSessionJobTypes.JobBridge = CoreSessionJobTypes.NoopJobBridge(),
            options: Options = Options()
        ) {
            self.db = db
            self.store = store
            self.execution = execution
            self.bus = bus
            self.jobs = jobs
            self.options = options
        }

        private func wakeIfActiveOwner(_ sessionID: SessionID) async {
            if let owner = try? store.get(sessionID), owner.revert == nil {
                await execution.wake(sessionID)
            }
        }

        private func prepareResume(_ sessionID: SessionID) async throws -> Bool {
            guard let attempts = try store.countResume(sessionID) else { return false }
            if attempts > options.maxAttempts {
                _ = try await bus.publish(
                    SessionEventSchema.Execution.Failed,
                    data: SessionEventSchema.Execution.FailedData(
                        sessionID: sessionID,
                        error: CoreSessionRestart.resumeExhaustedError
                    ),
                    options: CoreBus.PublishOptions(commit: { [store] _ in
                        try store.release(sessionID)
                    })
                )
                return false
            }
            _ = try await bus.publish(
                SessionEventSchema.Synthetic,
                data: SessionEventSchema.SyntheticData(
                    sessionID: sessionID,
                    text: CoreSessionRestart.continueAfterRestartText,
                    description: "Continuing after restart",
                    metadata: ["notice": .string("restart")]
                )
            )
            return true
        }

        private func failIncompleteTools(_ sessionID: SessionID) async throws {
            let incomplete = try CoreSessionHistory.incompleteAssistants(db, sessionID: sessionID)
            let err = SessionErrorSchema.Error(
                type: "aborted",
                message: "Tool execution was interrupted by a server restart."
            )
            for msg in incomplete {
                guard case .assistant(let assistant) = msg else { continue }
                for part in assistant.content {
                    guard case .tool(let tool) = part else { continue }
                    switch tool.state {
                    case .running, .streaming:
                        _ = try await bus.publish(
                            SessionEventSchema.Tool.Failed,
                            data: SessionEventSchema.Tool.FailedData(
                                sessionID: sessionID,
                                assistantMessageID: assistant.id,
                                id: tool.id,
                                error: err,
                                executed: tool.executed ?? false
                            )
                        )
                    case .completed, .error:
                        break
                    }
                }
            }
        }

        /// The restart notice of a background video job (upstream `restartMessage` for `kind: "video"`).
        static func videoRestartNotice(
            _ background: CoreSessionJobTypes.BackgroundJobInfo,
            path: String
        ) -> (description: String, text: String, metadata: [String: JSONValue]) {
            let state = background.status == .running ? "cancelled" : background.status.rawValue
            let body: String
            if background.status == .running {
                body = "Video request for \(path) couldn't be saved after the server restarted: its project folder no longer exists."
            } else if state == "completed" {
                body = background.output ?? "Video request finished. Saved video: \(path)."
            } else if state == "error" {
                body = background.error ?? "Video request failed for \(path)."
            } else {
                body = "Video request for \(path) was cancelled."
            }
            return (
                "Video generation",
                CoreSessionBackgroundResult.render("kind=\"video\" id=\"\(background.id)\" state=\"\(state)\"", body),
                [
                    "source": .string("experimental_video_generate"),
                    "jobID": .string(background.id),
                    "state": .string(state),
                    "path": .string(path),
                ]
            )
        }

        /// No video service keeps polling a running video in this host, so a recovered video job is reported with
        /// its restart notice and its outbox row acknowledged (upstream `recoverVideoJob` without the session's
        /// video services falls back to `recoverToolJob`).
        private func recoverVideoJob(_ background: CoreSessionJobTypes.BackgroundJobInfo, sessionID: SessionID, path: String) async {
            let notice = Self.videoRestartNotice(background, path: path)
            do {
                if try store.get(sessionID) != nil {
                    _ = try await bus.publish(
                        SessionEventSchema.Synthetic,
                        data: SessionEventSchema.SyntheticData(
                            sessionID: sessionID,
                            text: notice.text,
                            description: notice.description,
                            metadata: notice.metadata
                        )
                    )
                }
            } catch {
                // Unexpected failure delivering the recovered notice: keep the row for the next sweep.
                return
            }
            if let notificationID = background.notificationID {
                try? await jobs.completeBackground(notificationID)
            }
        }

        public func resumeSuspendedSessions() async throws {
            // Release claims of orphaned child sessions whose parent was deleted.
            try store.releaseOrphanedChildClaims()

            for bg in await jobs.backgroundJobs() {
                if case .video(let sessionID, let path, _) = bg.recovery {
                    await recoverVideoJob(bg, sessionID: sessionID, path: path)
                }
            }

            // Recover running background subagent jobs first so they own their children.
            var ownedBySubagentJob = Set<SessionID>()
            for bg in await jobs.backgroundJobs() {
                if case .subagent(let sub) = bg.recovery, bg.status == .running {
                    ownedBySubagentJob.insert(sub.childSessionID)
                    try await failIncompleteTools(sub.childSessionID)
                    if try await prepareResume(sub.childSessionID) {
                        _ = try? await CoreSessionSubagentJob.start(
                            jobs: jobs,
                            execution: execution,
                            recovery: sub,
                            notificationID: bg.notificationID
                        )
                    }
                }
            }

            let suspended = try store.listSuspended()
            for sessionID in suspended {
                if ownedBySubagentJob.contains(sessionID) { continue }
                try await failIncompleteTools(sessionID)
                if try await prepareResume(sessionID) {
                    await wakeIfActiveOwner(sessionID)
                }
            }
        }
    }

    // parity: core/src/session/execution/restart.ts#layer [status=adapted hash=b993cac97ee2]
    public static func layer(_ options: Options = Options()) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { deps, _ in
            guard let db = deps.get(CoreDatabaseStore.Service.serviceKey, as: CoreDatabaseStore.Service.self)?.db,
                  let store = deps.get(CoreSessionStore.Service.serviceKey, as: CoreSessionStore.Service.self),
                  let execution = deps.get(CoreSessionExecution.Service.serviceKey, as: (any CoreSessionExecution.Interface).self),
                  let bus = deps.get(CoreBus.Service.serviceKey, as: CoreBus.Service.self)
            else {
                throw SQLiteError.databaseClosed
            }
            let jobs = deps.get("@opencode/JobBridge", as: (any CoreSessionJobTypes.JobBridge).self)
                ?? CoreSessionJobTypes.NoopJobBridge()
            return LayerNode.Output([Service.serviceKey: Service(
                db: db,
                store: store,
                execution: execution,
                bus: bus,
                jobs: jobs,
                options: options
            )])
        }
    }

    // parity: core/src/session/execution/restart.ts#node [status=adapted hash=0b590b72a06b]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        layer(),
        [CoreSessionStore.node, CoreSessionExecution.node, CoreBus.node, CoreDatabaseStore.node]
    )
}
