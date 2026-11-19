import Foundation
import OpenCodeSchema

// MARK: - Updater Contracts & Action Resolver (`plugin/gui/updater.ts`, `updater/action.ts`, `updater/window-machine.ts`)

public enum UpdaterState: Equatable, Hashable, Sendable, Codable {
    case disabled
    case idle
    case checking
    case downloading(version: String)
    case ready(version: String)
    case downloadRequired(version: String)
    case upToDate
    case installing(version: String)
    case error(message: String)
}

public enum UpdaterActionKind: String, Equatable, Hashable, Sendable {
    case check
    case install
}

public enum UpdaterActionLabel: String, Equatable, Hashable, Sendable {
    case checkNow = "action.checkNow"
    case checking = "action.checking"
    case downloading = "action.downloading"
    case installRestart = "action.installRestart"
    case download = "action.download"
    case installing = "action.installing"
    case unavailable = "action.unavailable"
}

public struct UpdaterActionResolution: Equatable, Hashable, Sendable {
    public let label: UpdaterActionLabel
    public let run: UpdaterActionKind?
    public let description: String?

    public init(label: UpdaterActionLabel, run: UpdaterActionKind? = nil, description: String? = nil) {
        self.label = label
        self.run = run
        self.description = description
    }
}

public enum WindowUpdaterMachine: GUIStateMachine {
    public static let actionChunkTimeoutMs = 15_000

    public enum State: Equatable, Sendable {
        case idle(issued: Int)
        case checking(attempt: Int)
        case installing(attempt: Int)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case actionRequested(action: UpdaterActionKind, available: Bool)
        case actionSettled(attempt: Int)
        case actionFailed(attempt: Int, message: String?)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case run(action: UpdaterActionKind, attempt: Int)
        case toastFailed(message: String?)
    }

    public static let initialState: State = .idle(issued: 0)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed)

        case .actionRequested(let action, let available):
            if case .installing = state { return GUIStateTransition(state: state) }
            if !available {
                if case .idle = state {
                    return GUIStateTransition(state: state, effects: [.toastFailed(message: nil)])
                }
                return GUIStateTransition(state: state)
            }
            if case .checking = state, action == .check {
                return GUIStateTransition(state: state)
            }
            let currentIssued: Int
            switch state {
            case .idle(let issued): currentIssued = issued
            case .checking(let attempt), .installing(let attempt): currentIssued = attempt
            case .disposed: return GUIStateTransition(state: state)
            }
            let nextAttempt = currentIssued + 1
            let nextState: State = (action == .check) ? .checking(attempt: nextAttempt) : .installing(attempt: nextAttempt)
            return GUIStateTransition(state: nextState, effects: [.run(action: action, attempt: nextAttempt)])

        case .actionSettled(let attempt):
            switch state {
            case .checking(let current) where current == attempt,
                 .installing(let current) where current == attempt:
                return GUIStateTransition(state: .idle(issued: current))
            default:
                return GUIStateTransition(state: state)
            }

        case .actionFailed(let attempt, let message):
            switch state {
            case .checking(let current) where current == attempt,
                 .installing(let current) where current == attempt:
                return GUIStateTransition(state: .idle(issued: current), effects: [.toastFailed(message: message)])
            default:
                return GUIStateTransition(state: state)
            }
        }
    }

    /// Resolves the single action pill / settings row label and runnable action (`updater/action.ts`).
    public static func resolveAction(state: UpdaterState?, windowState: State? = nil) -> UpdaterActionResolution {
        let base = mainAction(state)
        if case .checking = windowState, base.run == .check {
            return UpdaterActionResolution(label: .checking)
        }
        if case .installing = windowState, base.run == .install {
            return UpdaterActionResolution(label: .installing)
        }
        return base
    }

    private static func mainAction(_ state: UpdaterState?) -> UpdaterActionResolution {
        guard let state else {
            return UpdaterActionResolution(label: .checkNow)
        }
        switch state {
        case .checking:
            return UpdaterActionResolution(label: .checking)
        case .downloading:
            return UpdaterActionResolution(label: .downloading)
        case .ready:
            return UpdaterActionResolution(label: .installRestart, run: .install)
        case .downloadRequired:
            return UpdaterActionResolution(label: .download, run: .install)
        case .installing:
            return UpdaterActionResolution(label: .installing)
        case .disabled:
            return UpdaterActionResolution(label: .unavailable, description: "check.unavailable")
        case .idle, .upToDate, .error:
            return UpdaterActionResolution(label: .checkNow, run: .check)
        }
    }
}

// MARK: - Desktop Updater Main Machine (`updater/machine.ts`)

public enum DesktopUpdaterMachine: GUIStateMachine {
    public static let checkTimeoutMs = 60_000
    public static let stageTimeoutMs = 60 * 60_000
    public static let externalTimeoutMs = 30_000

    public enum UpdateTarget: Equatable, Hashable, Sendable {
        case restart(version: String)
        case external(version: String, url: String)
    }

    public enum StagedRefresh: Equatable, Sendable {
        case checking(attempt: Int, checkWaiters: [Int])
        case staging(attempt: Int, nextVersion: String, checkWaiters: [Int])

        public var attempt: Int {
            switch self {
            case .checking(let a, _), .staging(let a, _, _): return a
            }
        }

        public var checkWaiters: [Int] {
            switch self {
            case .checking(_, let w), .staging(_, _, let w): return w
            }
        }
    }

    public struct ExternalRefresh: Equatable, Sendable {
        public let attempt: Int
        public let checkWaiters: [Int]

        public init(attempt: Int, checkWaiters: [Int]) {
            self.attempt = attempt
            self.checkWaiters = checkWaiters
        }
    }

    public enum InstallingPlan: Equatable, Sendable {
        case restartChecking(version: String, attempt: Int, checkWaiters: [Int])
        case restartStaging(version: String, attempt: Int, nextVersion: String, checkWaiters: [Int])
        case restarting(version: String, attempt: Int)
        case quitting(version: String)
        case externalChecking(version: String, url: String, attempt: Int, checkWaiters: [Int])
        case externalOpening(version: String, url: String, attempt: Int)

        public var version: String {
            switch self {
            case .restartChecking(let v, _, _),
                 .restartStaging(let v, _, _, _),
                 .restarting(let v, _),
                 .quitting(let v),
                 .externalChecking(let v, _, _, _),
                 .externalOpening(let v, _, _):
                return v
            }
        }
    }

    public struct Meta: Equatable, Sendable {
        public let currentVersion: String
        public let canExternalInstall: Bool
        public let issued: Int
        public let cached: String?

        public init(currentVersion: String, canExternalInstall: Bool, issued: Int, cached: String?) {
            self.currentVersion = currentVersion
            self.canExternalInstall = canExternalInstall
            self.issued = issued
            self.cached = cached
        }
    }

    public enum State: Equatable, Sendable {
        case disabled
        case idle(meta: Meta)
        case checking(meta: Meta, attempt: Int, checkWaiters: [Int])
        case downloading(meta: Meta, attempt: Int, version: String, checkWaiters: [Int])
        case upToDate(meta: Meta)
        case ready(meta: Meta, version: String, refresh: StagedRefresh?)
        case downloadRequired(meta: Meta, version: String, url: String, refresh: ExternalRefresh?)
        case installing(meta: Meta, plan: InstallingPlan, installWaiters: [Int])
        case error(meta: Meta, message: String)
        case disposed(last: UpdaterState)
    }

    public enum Failure: Equatable, Hashable, Sendable {
        case notReady
        case externalUnavailable
        case disposed
        case error(message: String)
    }

    public enum Event: Equatable, Sendable {
        case checkRequested(waiter: Int)
        case installRequested(waiter: Int)
        case waiterCancelled(waiter: Int)
        case checkSucceeded(attempt: Int, target: UpdateTarget?)
        case checkFailed(attempt: Int, message: String)
        case stageSucceeded(attempt: Int)
        case stageFailed(attempt: Int, message: String)
        case restartSucceeded(attempt: Int)
        case restartFailed(attempt: Int, message: String)
        case externalSucceeded(attempt: Int)
        case externalFailed(attempt: Int, message: String)
        case disposed
    }

    public enum LogLevel: String, Equatable, Sendable {
        case info
        case warning
    }

    public enum Effect: Equatable, Sendable {
        case platformCheck(attempt: Int)
        case platformStage(attempt: Int, differential: Bool)
        case platformRestart(attempt: Int)
        case platformExternal(attempt: Int, url: String)
        case attemptCancel(attempt: Int)
        case persistenceSet(version: String)
        case persistenceClear
        case checksResolve(waiters: [Int], state: UpdaterState)
        case installsResolve(waiters: [Int])
        case installsReject(waiters: [Int], failure: Failure)
        case log(level: LogLevel, message: String, data: [String: String])
    }

    public static func initialize(
        currentVersion: String,
        enabled: Bool,
        canExternalInstall: Bool,
        persistedVersion: String?
    ) -> GUIStateTransition<State, Effect> {
        guard enabled else {
            return GUIStateTransition(state: .disabled)
        }
        let installed = persistedVersion == currentVersion
        let meta = Meta(
            currentVersion: currentVersion,
            canExternalInstall: canExternalInstall,
            issued: 0,
            cached: installed ? nil : persistedVersion
        )
        return GUIStateTransition(
            state: .idle(meta: meta),
            effects: installed ? [.persistenceClear] : []
        )
    }

    public static func toUpdaterState(_ state: State) -> UpdaterState {
        switch state {
        case .disposed(let last): return last
        case .disabled: return .disabled
        case .idle: return .idle
        case .checking: return .checking
        case .downloading(_, _, let version, _): return .downloading(version: version)
        case .upToDate: return .upToDate
        case .ready(_, let version, _): return .ready(version: version)
        case .downloadRequired(_, let version, _, _): return .downloadRequired(version: version)
        case .installing(_, let plan, _): return .installing(version: plan.version)
        case .error(_, let message): return .error(message: message)
        }
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state {
            switch event {
            case .checkRequested(let waiter):
                return withChecks(state: state, waiters: [waiter])
            case .installRequested(let waiter):
                return GUIStateTransition(state: state, effects: [.installsReject(waiters: [waiter], failure: .disposed)])
            default:
                return GUIStateTransition(state: state)
            }
        }

        if case .disposed = event {
            return handleDispose(state)
        }

        if case .disabled = state {
            switch event {
            case .checkRequested(let waiter):
                return withChecks(state: state, waiters: [waiter])
            case .installRequested(let waiter):
                return GUIStateTransition(state: state, effects: [.installsReject(waiters: [waiter], failure: .notReady)])
            default:
                return GUIStateTransition(state: state)
            }
        }

        switch event {
        case .checkRequested(let waiter):
            return handleCheckRequested(state: state, waiter: waiter)
        case .installRequested(let waiter):
            return handleInstallRequested(state: state, waiter: waiter)
        case .waiterCancelled(let waiter):
            return handleWaiterCancelled(state: state, waiter: waiter)
        default:
            guard let eventAttempt = attemptOf(event), activeAttempt(of: state) == eventAttempt else {
                return GUIStateTransition(state: state)
            }
            return handleSettled(state: state, event: event)
        }
    }

    private static func handleDispose(_ state: State) -> GUIStateTransition<State, Effect> {
        let last = toUpdaterState(state)
        if case .disabled = state {
            return GUIStateTransition(state: .disposed(last: last))
        }
        var effects: [Effect] = []
        let isRestarting: Bool
        if case .installing(_, .restarting, _) = state { isRestarting = true } else { isRestarting = false }
        if let attempt = activeAttempt(of: state), !isRestarting {
            effects.append(.attemptCancel(attempt: attempt))
        }
        if case .installing(_, _, let installWaiters) = state, !installWaiters.isEmpty {
            effects.append(.installsReject(waiters: installWaiters, failure: .disposed))
        }
        return withChecks(state: .disposed(last: last), waiters: checkWaitersOf(state), effects: effects)
    }

    private static func handleCheckRequested(state: State, waiter: Int) -> GUIStateTransition<State, Effect> {
        switch state {
        case .idle(let meta), .upToDate(let meta), .error(let meta, _):
            let attempt = meta.issued + 1
            let nextMeta = Meta(
                currentVersion: meta.currentVersion,
                canExternalInstall: meta.canExternalInstall,
                issued: attempt,
                cached: meta.cached
            )
            return GUIStateTransition(
                state: .checking(meta: nextMeta, attempt: attempt, checkWaiters: [waiter]),
                effects: [.platformCheck(attempt: attempt)]
            )

        case .checking(let meta, let attempt, let waiters):
            return GUIStateTransition(state: .checking(meta: meta, attempt: attempt, checkWaiters: waiters + [waiter]))

        case .downloading(let meta, let attempt, let version, let waiters):
            return GUIStateTransition(
                state: .downloading(meta: meta, attempt: attempt, version: version, checkWaiters: waiters + [waiter])
            )

        case .ready(let meta, let version, let refresh):
            if let refresh {
                let updated: StagedRefresh
                switch refresh {
                case .checking(let a, let w): updated = .checking(attempt: a, checkWaiters: w + [waiter])
                case .staging(let a, let v, let w): updated = .staging(attempt: a, nextVersion: v, checkWaiters: w + [waiter])
                }
                return GUIStateTransition(state: .ready(meta: meta, version: version, refresh: updated))
            }
            let attempt = meta.issued + 1
            let nextMeta = Meta(
                currentVersion: meta.currentVersion,
                canExternalInstall: meta.canExternalInstall,
                issued: attempt,
                cached: meta.cached
            )
            return GUIStateTransition(
                state: .ready(meta: nextMeta, version: version, refresh: .checking(attempt: attempt, checkWaiters: [waiter])),
                effects: [.platformCheck(attempt: attempt)]
            )

        case .downloadRequired(let meta, let version, let url, let refresh):
            if let refresh {
                return GUIStateTransition(
                    state: .downloadRequired(
                        meta: meta,
                        version: version,
                        url: url,
                        refresh: ExternalRefresh(attempt: refresh.attempt, checkWaiters: refresh.checkWaiters + [waiter])
                    )
                )
            }
            let attempt = meta.issued + 1
            let nextMeta = Meta(
                currentVersion: meta.currentVersion,
                canExternalInstall: meta.canExternalInstall,
                issued: attempt,
                cached: meta.cached
            )
            return GUIStateTransition(
                state: .downloadRequired(
                    meta: nextMeta,
                    version: version,
                    url: url,
                    refresh: ExternalRefresh(attempt: attempt, checkWaiters: [waiter])
                ),
                effects: [.platformCheck(attempt: attempt)]
            )

        case .installing:
            return withChecks(state: state, waiters: [waiter])

        case .disabled, .disposed:
            return GUIStateTransition(state: state)
        }
    }

    private static func handleInstallRequested(state: State, waiter: Int) -> GUIStateTransition<State, Effect> {
        switch state {
        case .installing(_, .quitting, _):
            return GUIStateTransition(state: state, effects: [.installsResolve(waiters: [waiter])])

        case .installing(let meta, let plan, let waiters):
            return GUIStateTransition(state: .installing(meta: meta, plan: plan, installWaiters: waiters + [waiter]))

        case .ready(let meta, let version, let refresh):
            if let refresh {
                let plan: InstallingPlan
                switch refresh {
                case .checking(let a, let w): plan = .restartChecking(version: version, attempt: a, checkWaiters: w)
                case .staging(let a, let nextVersion, let w):
                    plan = .restartStaging(version: version, attempt: a, nextVersion: nextVersion, checkWaiters: w)
                }
                return GUIStateTransition(state: .installing(meta: meta, plan: plan, installWaiters: [waiter]))
            }
            let attempt = meta.issued + 1
            let nextMeta = Meta(
                currentVersion: meta.currentVersion,
                canExternalInstall: meta.canExternalInstall,
                issued: attempt,
                cached: meta.cached
            )
            return GUIStateTransition(
                state: .installing(
                    meta: nextMeta,
                    plan: .restartChecking(version: version, attempt: attempt, checkWaiters: []),
                    installWaiters: [waiter]
                ),
                effects: [.platformCheck(attempt: attempt)]
            )

        case .downloadRequired(let meta, let version, let url, let refresh):
            guard meta.canExternalInstall else {
                return GUIStateTransition(state: state, effects: [.installsReject(waiters: [waiter], failure: .externalUnavailable)])
            }
            if let refresh {
                return GUIStateTransition(
                    state: .installing(
                        meta: meta,
                        plan: .externalChecking(version: version, url: url, attempt: refresh.attempt, checkWaiters: refresh.checkWaiters),
                        installWaiters: [waiter]
                    )
                )
            }
            let attempt = meta.issued + 1
            let nextMeta = Meta(
                currentVersion: meta.currentVersion,
                canExternalInstall: meta.canExternalInstall,
                issued: attempt,
                cached: meta.cached
            )
            return GUIStateTransition(
                state: .installing(
                    meta: nextMeta,
                    plan: .externalChecking(version: version, url: url, attempt: attempt, checkWaiters: []),
                    installWaiters: [waiter]
                ),
                effects: [.platformCheck(attempt: attempt)]
            )

        default:
            return GUIStateTransition(state: state, effects: [.installsReject(waiters: [waiter], failure: .notReady)])
        }
    }

    private static func handleWaiterCancelled(state: State, waiter: Int) -> GUIStateTransition<State, Effect> {
        switch state {
        case .checking(let meta, let attempt, let waiters):
            return GUIStateTransition(state: .checking(meta: meta, attempt: attempt, checkWaiters: waiters.filter { $0 != waiter }))
        case .downloading(let meta, let attempt, let version, let waiters):
            return GUIStateTransition(
                state: .downloading(meta: meta, attempt: attempt, version: version, checkWaiters: waiters.filter { $0 != waiter })
            )
        case .ready(let meta, let version, let refresh?):
            let updated: StagedRefresh
            switch refresh {
            case .checking(let a, let w): updated = .checking(attempt: a, checkWaiters: w.filter { $0 != waiter })
            case .staging(let a, let v, let w): updated = .staging(attempt: a, nextVersion: v, checkWaiters: w.filter { $0 != waiter })
            }
            return GUIStateTransition(state: .ready(meta: meta, version: version, refresh: updated))
        case .downloadRequired(let meta, let version, let url, let refresh?):
            return GUIStateTransition(
                state: .downloadRequired(
                    meta: meta,
                    version: version,
                    url: url,
                    refresh: ExternalRefresh(attempt: refresh.attempt, checkWaiters: refresh.checkWaiters.filter { $0 != waiter })
                )
            )
        case .installing(let meta, let plan, let installWaiters):
            let nextPlan: InstallingPlan
            switch plan {
            case .restartChecking(let v, let a, let w):
                nextPlan = .restartChecking(version: v, attempt: a, checkWaiters: w.filter { $0 != waiter })
            case .restartStaging(let v, let a, let nv, let w):
                nextPlan = .restartStaging(version: v, attempt: a, nextVersion: nv, checkWaiters: w.filter { $0 != waiter })
            case .externalChecking(let v, let url, let a, let w):
                nextPlan = .externalChecking(version: v, url: url, attempt: a, checkWaiters: w.filter { $0 != waiter })
            case .restarting, .quitting, .externalOpening:
                nextPlan = plan
            }
            return GUIStateTransition(
                state: .installing(meta: meta, plan: nextPlan, installWaiters: installWaiters.filter { $0 != waiter })
            )
        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func handleSettled(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        switch state {
        case .checking(let meta, _, let waiters):
            switch event {
            case .checkSucceeded(_, let target):
                return discovered(meta: meta, target: target, checkWaiters: waiters)
            case .checkFailed(_, let message):
                return withChecks(state: .error(meta: meta, message: message), waiters: waiters)
            default:
                return GUIStateTransition(state: state)
            }

        case .downloading(let meta, _, let version, let waiters):
            switch event {
            case .stageSucceeded:
                let nextMeta = Meta(
                    currentVersion: meta.currentVersion,
                    canExternalInstall: meta.canExternalInstall,
                    issued: meta.issued,
                    cached: version
                )
                return withChecks(
                    state: .ready(meta: nextMeta, version: version, refresh: nil),
                    waiters: waiters,
                    effects: [.persistenceSet(version: version)]
                )
            case .stageFailed(_, let message):
                return withChecks(state: .error(meta: meta, message: message), waiters: waiters)
            default:
                return GUIStateTransition(state: state)
            }

        case .ready(let meta, let version, let refresh?):
            let cleanReady: State = .ready(meta: meta, version: version, refresh: nil)
            switch (refresh, event) {
            case (.checking(_, let waiters), .checkSucceeded(_, let target)):
                if keepsStaged(currentVersion: meta.currentVersion, staged: version, target: target) {
                    return withChecks(state: cleanReady, waiters: waiters)
                }
                guard case .restart(let nextVersion) = target else {
                    return discovered(meta: meta, target: target, checkWaiters: waiters)
                }
                let attempt = meta.issued + 1
                let nextMeta = Meta(
                    currentVersion: meta.currentVersion,
                    canExternalInstall: meta.canExternalInstall,
                    issued: attempt,
                    cached: meta.cached
                )
                return GUIStateTransition(
                    state: .ready(meta: nextMeta, version: version, refresh: .staging(attempt: attempt, nextVersion: nextVersion, checkWaiters: waiters)),
                    effects: stageEffects(meta: meta, attempt: attempt, version: nextVersion)
                )

            case (.staging(_, let nextVersion, let waiters), .stageSucceeded):
                let nextMeta = Meta(
                    currentVersion: meta.currentVersion,
                    canExternalInstall: meta.canExternalInstall,
                    issued: meta.issued,
                    cached: nextVersion
                )
                return withChecks(
                    state: .ready(meta: nextMeta, version: nextVersion, refresh: nil),
                    waiters: waiters,
                    effects: [.persistenceSet(version: nextVersion)]
                )

            case (_, .checkFailed(_, let message)), (_, .stageFailed(_, let message)):
                return withChecks(
                    state: cleanReady,
                    waiters: refresh.checkWaiters,
                    effects: [.log(level: .warning, message: "updater refresh failed, keeping staged update", data: ["staged": version, "message": message])]
                )

            default:
                return GUIStateTransition(state: state)
            }

        case .downloadRequired(let meta, let version, let url, let refresh?):
            switch event {
            case .checkSucceeded(_, let target):
                return discovered(meta: meta, target: target, checkWaiters: refresh.checkWaiters)
            case .checkFailed(_, let message):
                return withChecks(
                    state: .downloadRequired(meta: meta, version: version, url: url, refresh: nil),
                    waiters: refresh.checkWaiters,
                    effects: [.log(level: .warning, message: "external updater refresh failed, keeping download available", data: ["message": message])]
                )
            default:
                return GUIStateTransition(state: state)
            }

        case .installing(let meta, let plan, let installWaiters):
            return handleInstallingSettled(meta: meta, plan: plan, installWaiters: installWaiters, event: event)

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func handleInstallingSettled(
        meta: Meta,
        plan: InstallingPlan,
        installWaiters: [Int],
        event: Event
    ) -> GUIStateTransition<State, Effect> {
        switch (plan, event) {
        case (.restartChecking(let version, _, let checkWaiters), .checkSucceeded(_, let target)):
            if keepsStaged(currentVersion: meta.currentVersion, staged: version, target: target) {
                return beginRestart(meta: meta, version: version, installWaiters: installWaiters, checkWaiters: checkWaiters)
            }
            if case .external = target {
                let next = discovered(meta: meta, target: target, checkWaiters: checkWaiters)
                return GUIStateTransition(state: next.state, effects: next.effects + [.installsResolve(waiters: installWaiters)])
            }
            let nextVersion: String
            if case .restart(let v) = target { nextVersion = v } else { nextVersion = version }
            let attempt = meta.issued + 1
            let nextMeta = Meta(
                currentVersion: meta.currentVersion,
                canExternalInstall: meta.canExternalInstall,
                issued: attempt,
                cached: meta.cached
            )
            return GUIStateTransition(
                state: .installing(
                    meta: nextMeta,
                    plan: .restartStaging(version: version, attempt: attempt, nextVersion: nextVersion, checkWaiters: checkWaiters),
                    installWaiters: installWaiters
                ),
                effects: stageEffects(meta: meta, attempt: attempt, version: nextVersion)
            )

        case (.restartChecking(let version, _, let checkWaiters), .checkFailed(_, let message)),
             (.restartStaging(let version, _, _, let checkWaiters), .stageFailed(_, let message)):
            return beginRestart(
                meta: meta,
                version: version,
                installWaiters: installWaiters,
                checkWaiters: checkWaiters,
                priorEffects: [.log(level: .warning, message: "updater refresh failed, keeping staged update", data: ["staged": version, "message": message])]
            )

        case (.restartStaging(_, _, let nextVersion, let checkWaiters), .stageSucceeded):
            let updatedMeta = Meta(
                currentVersion: meta.currentVersion,
                canExternalInstall: meta.canExternalInstall,
                issued: meta.issued,
                cached: nextVersion
            )
            return beginRestart(
                meta: updatedMeta,
                version: nextVersion,
                installWaiters: installWaiters,
                checkWaiters: checkWaiters,
                priorEffects: [.persistenceSet(version: nextVersion)]
            )

        case (.restarting(let version, _), .restartSucceeded):
            return GUIStateTransition(
                state: .installing(meta: meta, plan: .quitting(version: version), installWaiters: []),
                effects: [.installsResolve(waiters: installWaiters)]
            )

        case (.restarting(let version, _), .restartFailed(_, let message)):
            return GUIStateTransition(
                state: .ready(meta: meta, version: version, refresh: nil),
                effects: [.installsReject(waiters: installWaiters, failure: .error(message: message))]
            )

        case (.externalChecking(_, _, _, let checkWaiters), .checkSucceeded(_, let target)):
            if case .external(let version, let url) = target {
                return beginExternalOpen(meta: meta, version: version, url: url, installWaiters: installWaiters, checkWaiters: checkWaiters)
            }
            let next = discovered(meta: meta, target: target, checkWaiters: checkWaiters)
            return GUIStateTransition(
                state: next.state,
                effects: next.effects + [.installsReject(waiters: installWaiters, failure: .externalUnavailable)]
            )

        case (.externalChecking(let version, let url, _, let checkWaiters), .checkFailed(_, let message)):
            return beginExternalOpen(
                meta: meta,
                version: version,
                url: url,
                installWaiters: installWaiters,
                checkWaiters: checkWaiters,
                priorEffects: [.log(level: .warning, message: "external updater refresh failed, keeping download available", data: ["message": message])]
            )

        case (.externalOpening(let version, let url, _), .externalSucceeded):
            return GUIStateTransition(
                state: .downloadRequired(meta: meta, version: version, url: url, refresh: nil),
                effects: [.installsResolve(waiters: installWaiters)]
            )

        case (.externalOpening(let version, let url, _), .externalFailed(_, let message)):
            return GUIStateTransition(
                state: .downloadRequired(meta: meta, version: version, url: url, refresh: nil),
                effects: [.installsReject(waiters: installWaiters, failure: .error(message: message))]
            )

        default:
            return GUIStateTransition(state: .installing(meta: meta, plan: plan, installWaiters: installWaiters))
        }
    }

    private static func discovered(meta: Meta, target: UpdateTarget?, checkWaiters: [Int]) -> GUIStateTransition<State, Effect> {
        guard let target else {
            return withChecks(state: .upToDate(meta: meta), waiters: checkWaiters, effects: [.persistenceClear])
        }
        switch target {
        case .restart(let version) where version == meta.currentVersion:
            return withChecks(state: .upToDate(meta: meta), waiters: checkWaiters, effects: [.persistenceClear])
        case .external(let version, let url):
            return withChecks(
                state: .downloadRequired(meta: meta, version: version, url: url, refresh: nil),
                waiters: checkWaiters,
                effects: [.persistenceClear]
            )
        case .restart(let version):
            let attempt = meta.issued + 1
            let nextMeta = Meta(
                currentVersion: meta.currentVersion,
                canExternalInstall: meta.canExternalInstall,
                issued: attempt,
                cached: meta.cached
            )
            return GUIStateTransition(
                state: .downloading(meta: nextMeta, attempt: attempt, version: version, checkWaiters: checkWaiters),
                effects: stageEffects(meta: meta, attempt: attempt, version: version)
            )
        }
    }

    private static func beginRestart(
        meta: Meta,
        version: String,
        installWaiters: [Int],
        checkWaiters: [Int],
        priorEffects: [Effect] = []
    ) -> GUIStateTransition<State, Effect> {
        let attempt = meta.issued + 1
        let nextMeta = Meta(
            currentVersion: meta.currentVersion,
            canExternalInstall: meta.canExternalInstall,
            issued: attempt,
            cached: meta.cached
        )
        return withChecks(
            state: .installing(meta: nextMeta, plan: .restarting(version: version, attempt: attempt), installWaiters: installWaiters),
            waiters: checkWaiters,
            effects: priorEffects + [.platformRestart(attempt: attempt)]
        )
    }

    private static func beginExternalOpen(
        meta: Meta,
        version: String,
        url: String,
        installWaiters: [Int],
        checkWaiters: [Int],
        priorEffects: [Effect] = []
    ) -> GUIStateTransition<State, Effect> {
        let attempt = meta.issued + 1
        let nextMeta = Meta(
            currentVersion: meta.currentVersion,
            canExternalInstall: meta.canExternalInstall,
            issued: attempt,
            cached: meta.cached
        )
        return withChecks(
            state: .installing(meta: nextMeta, plan: .externalOpening(version: version, url: url, attempt: attempt), installWaiters: installWaiters),
            waiters: checkWaiters,
            effects: priorEffects + [.platformExternal(attempt: attempt, url: url)]
        )
    }

    private static func keepsStaged(currentVersion: String, staged: String, target: UpdateTarget?) -> Bool {
        guard let target else { return true }
        if case .restart(let version) = target {
            return version == staged || version == currentVersion
        }
        return false
    }

    private static func stageEffects(meta: Meta, attempt: Int, version: String) -> [Effect] {
        let stage: Effect = .platformStage(attempt: attempt, differential: meta.cached == nil)
        guard let cached = meta.cached else { return [stage] }
        return [
            .log(
                level: .info,
                message: "skipping differential download, updater cache is stale",
                data: ["current": meta.currentVersion, "staged": cached, "version": version]
            ),
            stage,
        ]
    }

    private static func activeAttempt(of state: State) -> Int? {
        switch state {
        case .checking(_, let attempt, _), .downloading(_, let attempt, _, _):
            return attempt
        case .ready(_, _, let refresh?):
            return refresh.attempt
        case .downloadRequired(_, _, _, let refresh?):
            return refresh.attempt
        case .installing(_, let plan, _):
            switch plan {
            case .restartChecking(_, let a, _),
                 .restartStaging(_, let a, _, _),
                 .restarting(_, let a),
                 .externalChecking(_, _, let a, _),
                 .externalOpening(_, _, let a):
                return a
            case .quitting:
                return nil
            }
        default:
            return nil
        }
    }

    private static func attemptOf(_ event: Event) -> Int? {
        switch event {
        case .checkSucceeded(let a, _),
             .checkFailed(let a, _),
             .stageSucceeded(let a),
             .stageFailed(let a, _),
             .restartSucceeded(let a),
             .restartFailed(let a, _),
             .externalSucceeded(let a),
             .externalFailed(let a, _):
            return a
        default:
            return nil
        }
    }

    private static func checkWaitersOf(_ state: State) -> [Int] {
        switch state {
        case .checking(_, _, let w), .downloading(_, _, _, let w):
            return w
        case .ready(_, _, let refresh?):
            return refresh.checkWaiters
        case .downloadRequired(_, _, _, let refresh?):
            return refresh.checkWaiters
        case .installing(_, let plan, _):
            switch plan {
            case .restartChecking(_, _, let w), .restartStaging(_, _, _, let w), .externalChecking(_, _, _, let w):
                return w
            case .restarting, .quitting, .externalOpening:
                return []
            }
        default:
            return []
        }
    }

    private static func withChecks(
        state: State,
        waiters: [Int],
        effects: [Effect] = []
    ) -> GUIStateTransition<State, Effect> {
        guard !waiters.isEmpty else { return GUIStateTransition(state: state, effects: effects) }
        return GUIStateTransition(state: state, effects: effects + [.checksResolve(waiters: waiters, state: toUpdaterState(state))])
    }
}

// MARK: - Web Update & What's New Machines (`updater/web-machine.ts`, `updater/whats-new-machine.ts`)

public enum WebUpdateMachine: GUIStateMachine {
    public static let autoCheckSpacingMs = 60_000
    public static let checkTimeoutMs = 60_000

    public enum WorkerState: String, Equatable, Hashable, Sendable {
        case none
        case installing
        case waiting
    }

    public struct Meta: Equatable, Sendable {
        public let issued: Int
        public let checkedAt: Int?

        public init(issued: Int = 0, checkedAt: Int? = nil) {
            self.issued = issued
            self.checkedAt = checkedAt
        }
    }

    public enum State: Equatable, Sendable {
        case unavailable
        case idle(meta: Meta)
        case checking(meta: Meta, attempt: Int, manual: Bool)
        case upToDate(meta: Meta)
        case downloading(meta: Meta, manual: Bool)
        case ready(meta: Meta)
        case applying(meta: Meta)
        case reloading
        case error(meta: Meta, message: String)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case registered(worker: WorkerState)
        case checkRequested(manual: Bool, at: Int)
        case checkSettled(attempt: Int, worker: WorkerState)
        case checkFailed(attempt: Int, message: String)
        case checkTimeout(attempt: Int)
        case workerInstalling
        case workerInstalled
        case workerRedundant
        case applyRequested
        case applyTimeout
        case resetRequested
        case resetElsewhere
        case controllerChanged
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case update(attempt: Int)
        case skipWaiting
        case reload
        case reset
        case announce
        case reportUpToDate
        case reportFailed(message: String)
    }

    public enum ActionLabel: String, Equatable, Hashable, Sendable {
        case checking = "action.checking"
        case downloading = "action.downloading"
        case reload = "action.reload"
        case reloading = "action.reloading"
        case checkNow = "action.checkNow"
    }

    public enum ActionRun: String, Equatable, Hashable, Sendable {
        case apply
        case check
    }

    public struct Action: Equatable, Sendable {
        public let label: ActionLabel
        public let run: ActionRun?

        public init(label: ActionLabel, run: ActionRun? = nil) {
            self.label = label
            self.run = run
        }
    }

    public static let initialState: State = .unavailable

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }
        if case .disposed = event { return GUIStateTransition(state: .disposed) }
        if case .reloading = state { return GUIStateTransition(state: state) }

        switch event {
        case .controllerChanged, .resetElsewhere:
            return GUIStateTransition(state: .reloading, effects: [.reload])
        case .resetRequested:
            return GUIStateTransition(state: .reloading, effects: [.reset])
        default:
            break
        }

        if case .unavailable = state {
            if case .registered(let worker) = event {
                return found(meta: Meta(), worker: worker, manual: false)
            }
            return GUIStateTransition(state: state)
        }

        let meta = metaOf(state) ?? Meta()

        switch event {
        case .checkRequested(let manual, let at):
            switch state {
            case .checking(let m, let attempt, let currentManual):
                return manual && !currentManual
                    ? GUIStateTransition(state: .checking(meta: m, attempt: attempt, manual: true))
                    : GUIStateTransition(state: state)
            case .downloading(let m, let currentManual):
                return manual && !currentManual
                    ? GUIStateTransition(state: .downloading(meta: m, manual: true))
                    : GUIStateTransition(state: state)
            case .ready:
                return manual ? GUIStateTransition(state: state, effects: [.announce]) : GUIStateTransition(state: state)
            case .applying:
                return GUIStateTransition(state: state)
            default:
                if !manual, let checkedAt = meta.checkedAt, at - checkedAt < autoCheckSpacingMs {
                    return GUIStateTransition(state: state)
                }
                let attempt = meta.issued + 1
                return GUIStateTransition(
                    state: .checking(meta: Meta(issued: attempt, checkedAt: at), attempt: attempt, manual: manual),
                    effects: [.update(attempt: attempt)]
                )
            }

        case .checkSettled(let attempt, let worker):
            guard case .checking(_, let currentAttempt, let manual) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return found(meta: meta, worker: worker, manual: manual)

        case .checkFailed(let attempt, let message):
            guard case .checking(_, let currentAttempt, let manual) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if !manual { return GUIStateTransition(state: .idle(meta: meta)) }
            return GUIStateTransition(state: .error(meta: meta, message: message), effects: [.reportFailed(message: message)])

        case .checkTimeout(let attempt):
            guard case .checking(_, let currentAttempt, let manual) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if !manual { return GUIStateTransition(state: .idle(meta: meta)) }
            return GUIStateTransition(state: .error(meta: meta, message: ""), effects: [.reportFailed(message: "")])

        case .workerInstalling:
            switch state {
            case .downloading, .ready, .applying: return GUIStateTransition(state: state)
            case .checking(_, _, let manual): return GUIStateTransition(state: .downloading(meta: meta, manual: manual))
            default: return GUIStateTransition(state: .downloading(meta: meta, manual: false))
            }

        case .workerInstalled:
            switch state {
            case .ready, .applying: return GUIStateTransition(state: state)
            default: return GUIStateTransition(state: .ready(meta: meta), effects: [.announce])
            }

        case .workerRedundant:
            guard case .downloading(_, let manual) = state else { return GUIStateTransition(state: state) }
            if !manual { return GUIStateTransition(state: .idle(meta: meta)) }
            return GUIStateTransition(state: .error(meta: meta, message: ""), effects: [.reportFailed(message: "")])

        case .applyRequested:
            guard case .ready = state else { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .applying(meta: meta), effects: [.skipWaiting])

        case .applyTimeout:
            guard case .applying = state else { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .reloading, effects: [.reload])

        case .registered, .resetRequested, .resetElsewhere, .controllerChanged, .disposed:
            return GUIStateTransition(state: state)
        }
    }

    public static func action(_ state: State) -> Action {
        switch state {
        case .checking: return Action(label: .checking)
        case .downloading: return Action(label: .downloading)
        case .ready: return Action(label: .reload, run: .apply)
        case .applying, .reloading: return Action(label: .reloading)
        case .unavailable, .disposed: return Action(label: .checkNow)
        case .idle, .upToDate, .error: return Action(label: .checkNow, run: .check)
        }
    }

    public static func pending(_ state: State) -> Bool {
        switch state {
        case .ready, .applying, .reloading: return true
        default: return false
        }
    }

    private static func found(meta: Meta, worker: WorkerState, manual: Bool) -> GUIStateTransition<State, Effect> {
        switch worker {
        case .waiting:
            return GUIStateTransition(state: .ready(meta: meta), effects: [.announce])
        case .installing:
            return GUIStateTransition(state: .downloading(meta: meta, manual: manual))
        case .none:
            if !manual { return GUIStateTransition(state: .idle(meta: meta)) }
            return GUIStateTransition(state: .upToDate(meta: meta), effects: [.reportUpToDate])
        }
    }

    private static func metaOf(_ state: State) -> Meta? {
        switch state {
        case .idle(let m),
             .checking(let m, _, _),
             .upToDate(let m),
             .downloading(let m, _),
             .ready(let m),
             .applying(let m),
             .error(let m, _):
            return m
        case .unavailable, .reloading, .disposed:
            return nil
        }
    }
}

public enum WhatsNewMachine: GUIStateMachine {
    public static let timeoutMs = 15_000

    public struct Highlight: Equatable, Hashable, Sendable, Codable {
        public let title: String
        public let description: String

        public init(title: String, description: String) {
            self.title = title
            self.description = description
        }
    }

    public struct Content: Equatable, Sendable, Codable {
        public let highlights: [Highlight]

        public init(highlights: [Highlight]) {
            self.highlights = highlights
        }
    }

    public enum State: Equatable, Sendable {
        case loading(version: String)
        case done
    }

    public enum Event: Equatable, Sendable {
        case loaded(content: Content?)
        case loadFailed
        case loadTimedOut
        case disabled
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case load(previousVersion: String, version: String, timeoutMs: Int)
        case abortLoad
        case markSeen(version: String)
        case open(content: Content)
    }

    public static func initialize(
        version: String?,
        previousVersion: String?,
        enabled: Bool
    ) -> GUIStateTransition<State, Effect> {
        guard let version, !version.isEmpty, previousVersion != version else {
            return GUIStateTransition(state: .done)
        }
        guard let previousVersion, !previousVersion.isEmpty, enabled else {
            return GUIStateTransition(state: .done, effects: [.markSeen(version: version)])
        }
        return GUIStateTransition(
            state: .loading(version: version),
            effects: [.load(previousVersion: previousVersion, version: version, timeoutMs: timeoutMs)]
        )
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .loading(let version) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .loadFailed, .loadTimedOut, .disposed:
            return GUIStateTransition(state: .done, effects: [.abortLoad])
        case .disabled:
            return GUIStateTransition(state: .done, effects: [.abortLoad, .markSeen(version: version)])
        case .loaded(let content):
            let seen: [Effect] = [.abortLoad, .markSeen(version: version)]
            guard let content, !content.highlights.isEmpty else {
                return GUIStateTransition(state: .done, effects: seen)
            }
            return GUIStateTransition(state: .done, effects: seen + [.open(content: content)])
        }
    }

    public static func isLoading(_ state: State) -> Bool {
        if case .loading = state { return true }
        return false
    }
}

// MARK: - Injectable Updater Controller Actor

public protocol UpdaterPlatformDriver: Sendable {
    func checkForUpdate() async throws -> DesktopUpdaterMachine.UpdateTarget?
    func stageUpdate(differential: Bool) async throws
    func installAndRestart() async throws
    func externalInstall(url: String) async throws
    func persistVersion(_ version: String) async
    func clearPersistedVersion() async
}

public struct UpdaterControllerError: Error, Equatable, Sendable {
    public let failure: DesktopUpdaterMachine.Failure

    public init(failure: DesktopUpdaterMachine.Failure) {
        self.failure = failure
    }
}

public actor UpdaterController {
    private var machineState: DesktopUpdaterMachine.State
    private var nextWaiterID = 0
    private var checkWaiters: [Int: CheckedContinuation<UpdaterState, Never>] = [:]
    private var installWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private let driver: (any UpdaterPlatformDriver)?

    public init(
        currentVersion: String,
        canExternalInstall: Bool = false,
        persistedVersion: String? = nil,
        driver: (any UpdaterPlatformDriver)?
    ) {
        let initialized = DesktopUpdaterMachine.initialize(
            currentVersion: currentVersion,
            enabled: driver != nil,
            canExternalInstall: canExternalInstall,
            persistedVersion: persistedVersion
        )
        self.machineState = initialized.state
        self.driver = driver
        if !initialized.effects.isEmpty {
            let startupEffects = initialized.effects
            Task {
                for effect in startupEffects {
                    await self.perform(effect)
                }
            }
        }
    }

    public func currentState() -> UpdaterState {
        DesktopUpdaterMachine.toUpdaterState(machineState)
    }

    public func check() async -> UpdaterState {
        nextWaiterID += 1
        let waiterID = nextWaiterID
        return await withCheckedContinuation { continuation in
            checkWaiters[waiterID] = continuation
            Task {
                await self.dispatch(.checkRequested(waiter: waiterID))
            }
        }
    }

    public func install() async throws {
        nextWaiterID += 1
        let waiterID = nextWaiterID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            installWaiters[waiterID] = continuation
            Task {
                await self.dispatch(.installRequested(waiter: waiterID))
            }
        }
    }

    public func dispose() async {
        await dispatch(.disposed)
    }

    private func dispatch(_ event: DesktopUpdaterMachine.Event) async {
        let transition = DesktopUpdaterMachine.reduce(state: machineState, event: event)
        machineState = transition.state
        for effect in transition.effects {
            await perform(effect)
        }
    }

    private func perform(_ effect: DesktopUpdaterMachine.Effect) async {
        switch effect {
        case .checksResolve(let waiters, let viewState):
            for waiter in waiters {
                checkWaiters.removeValue(forKey: waiter)?.resume(returning: viewState)
            }
        case .installsResolve(let waiters):
            for waiter in waiters {
                installWaiters.removeValue(forKey: waiter)?.resume()
            }
        case .installsReject(let waiters, let failure):
            for waiter in waiters {
                installWaiters.removeValue(forKey: waiter)?.resume(throwing: UpdaterControllerError(failure: failure))
            }
        case .persistenceSet(let version):
            await driver?.persistVersion(version)
        case .persistenceClear:
            await driver?.clearPersistedVersion()
        case .attemptCancel, .log:
            break
        case .platformCheck(let attempt):
            guard let driver else { return }
            do {
                let target = try await driver.checkForUpdate()
                await dispatch(.checkSucceeded(attempt: attempt, target: target))
            } catch {
                await dispatch(.checkFailed(attempt: attempt, message: String(describing: error)))
            }
        case .platformStage(let attempt, let differential):
            guard let driver else { return }
            do {
                try await driver.stageUpdate(differential: differential)
                await dispatch(.stageSucceeded(attempt: attempt))
            } catch {
                await dispatch(.stageFailed(attempt: attempt, message: String(describing: error)))
            }
        case .platformRestart(let attempt):
            guard let driver else { return }
            do {
                try await driver.installAndRestart()
                await dispatch(.restartSucceeded(attempt: attempt))
            } catch {
                await dispatch(.restartFailed(attempt: attempt, message: String(describing: error)))
            }
        case .platformExternal(let attempt, let url):
            guard let driver else { return }
            do {
                try await driver.externalInstall(url: url)
                await dispatch(.externalSucceeded(attempt: attempt))
            } catch {
                await dispatch(.externalFailed(attempt: attempt, message: String(describing: error)))
            }
        }
    }
}

// MARK: - BTW Side-Chat Machine (`btw/machine.ts`)

public enum BtwMachine: GUIStateMachine {
    public static let generateTimeoutMs = 300_000

    public struct ChatModel: Equatable, Hashable, Sendable, Codable {
        public let providerID: String
        public let id: String
        public let variant: String?

        public init(providerID: String, id: String, variant: String? = nil) {
            self.providerID = providerID
            self.id = id
            self.variant = variant
        }
    }

    public struct SavedChat: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let question: String
        public let answer: String?
        public let agent: String?
        public let model: ChatModel?
        public let created: Int?
        public let duration: Int?

        public init(
            id: String,
            question: String,
            answer: String? = nil,
            agent: String? = nil,
            model: ChatModel? = nil,
            created: Int? = nil,
            duration: Int? = nil
        ) {
            self.id = id
            self.question = question
            self.answer = answer
            self.agent = agent
            self.model = model
            self.created = created
            self.duration = duration
        }
    }

    public struct ChatInfo: Equatable, Hashable, Sendable {
        public let question: String
        public let created: Int?
        public let agent: String?
        public let model: ChatModel?

        public init(question: String, created: Int? = nil, agent: String? = nil, model: ChatModel? = nil) {
            self.question = question
            self.created = created
            self.agent = agent
            self.model = model
        }
    }

    public enum Failure: Equatable, Hashable, Sendable {
        case interrupted
        case empty
        case timeout
        case error(message: String?)
    }

    public enum Chat: Equatable, Sendable {
        case running(info: ChatInfo, attempt: Int, started: Int)
        case answered(info: ChatInfo, answer: String, duration: Int)
        case failed(info: ChatInfo, failure: Failure)

        public var info: ChatInfo {
            switch self {
            case .running(let info, _, _), .answered(let info, _, _), .failed(let info, _): return info
            }
        }
    }

    public enum State: Equatable, Sendable {
        case active(issued: Int, sessions: [String: [String: Chat]])
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case chatAsked(
            sessionKey: String,
            id: String,
            question: String,
            created: Int,
            agent: String? = nil,
            model: ChatModel? = nil
        )
        case chatRetried(
            sessionKey: String,
            id: String,
            now: Int,
            saved: SavedChat? = nil,
            agent: String? = nil,
            model: ChatModel? = nil
        )
        case generateSucceeded(sessionKey: String, id: String, attempt: Int, text: String, now: Int)
        case generateFailed(sessionKey: String, id: String, attempt: Int, message: String?)
        case generateTimedOut(sessionKey: String, id: String, attempt: Int)
        case chatRemoved(sessionKey: String, id: String)
        case sessionsPruned(keep: Set<String>)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case persistQuestion(id: String, info: ChatInfo)
        case openTab(id: String)
        case generate(id: String, attempt: Int, question: String, timeoutMs: Int)
        case persistAnswer(id: String, answer: String, duration: Int, agent: String?, model: ChatModel?)
        case deleteChat(id: String)
        case abort(attempt: Int)
    }

    public enum TabView: Equatable, Sendable {
        case loading
        case missing
        case ready(question: String)
    }

    public enum ChatView: Equatable, Sendable {
        case loading
        case missing
        case running(info: ChatInfo)
        case failed(info: ChatInfo, failure: Failure)
        case answered(info: ChatInfo, answer: String, duration: Int?)
    }

    public static func createState() -> State {
        .active(issued: 0, sessions: [:])
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .active(var issued, var sessions) = state else {
            return GUIStateTransition(state: state)
        }

        switch event {
        case .disposed:
            var effects: [Effect] = []
            for sessionKey in sessions.keys.sorted() {
                if let chats = sessions[sessionKey] {
                    effects.append(contentsOf: runningAborts(chats))
                }
            }
            return GUIStateTransition(state: .disposed, effects: effects)

        case .chatAsked(let sessionKey, let id, let rawQuestion, let created, let agent, let model):
            let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty, sessions[sessionKey]?[id] == nil else {
                return GUIStateTransition(state: state)
            }
            issued += 1
            let info = ChatInfo(question: question, created: created, agent: agent, model: model)
            sessions[sessionKey, default: [:]][id] = .running(info: info, attempt: issued, started: created)
            return GUIStateTransition(
                state: .active(issued: issued, sessions: sessions),
                effects: [
                    .persistQuestion(id: id, info: info),
                    .openTab(id: id),
                    .generate(id: id, attempt: issued, question: question, timeoutMs: generateTimeoutMs),
                ]
            )

        case .chatRetried(let sessionKey, let id, let now, let saved, let agent, let model):
            let live = sessions[sessionKey]?[id]
            let sourceInfo: ChatInfo
            if let live {
                guard case .failed(let info, _) = live else { return GUIStateTransition(state: state) }
                sourceInfo = info
            } else if let saved, (saved.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                sourceInfo = ChatInfo(question: saved.question, created: saved.created, agent: saved.agent, model: saved.model)
            } else {
                return GUIStateTransition(state: state)
            }
            issued += 1
            let nextInfo = ChatInfo(
                question: sourceInfo.question,
                created: sourceInfo.created,
                agent: agent ?? sourceInfo.agent,
                model: model ?? sourceInfo.model
            )
            sessions[sessionKey, default: [:]][id] = .running(info: nextInfo, attempt: issued, started: now)
            return GUIStateTransition(
                state: .active(issued: issued, sessions: sessions),
                effects: [.generate(id: id, attempt: issued, question: nextInfo.question, timeoutMs: generateTimeoutMs)]
            )

        case .chatRemoved(let sessionKey, let id):
            guard var chats = sessions[sessionKey], let chat = chats.removeValue(forKey: id) else {
                return GUIStateTransition(state: state, effects: [.deleteChat(id: id)])
            }
            if chats.isEmpty {
                sessions.removeValue(forKey: sessionKey)
            } else {
                sessions[sessionKey] = chats
            }
            var effects: [Effect] = []
            if case .running(_, let attempt, _) = chat {
                effects.append(.abort(attempt: attempt))
            }
            effects.append(.deleteChat(id: id))
            return GUIStateTransition(state: .active(issued: issued, sessions: sessions), effects: effects)

        case .sessionsPruned(let keep):
            let gone = sessions.keys.filter { !keep.contains($0) }.sorted()
            if gone.isEmpty { return GUIStateTransition(state: state) }
            var effects: [Effect] = []
            for key in gone {
                if let chats = sessions.removeValue(forKey: key) {
                    effects.append(contentsOf: runningAborts(chats))
                }
            }
            return GUIStateTransition(state: .active(issued: issued, sessions: sessions), effects: effects)

        case .generateTimedOut(let sessionKey, let id, let attempt):
            guard case .running(let info, let currentAttempt, _) = sessions[sessionKey]?[id], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            sessions[sessionKey]?[id] = .failed(info: info, failure: .timeout)
            return GUIStateTransition(state: .active(issued: issued, sessions: sessions), effects: [.abort(attempt: attempt)])

        case .generateFailed(let sessionKey, let id, let attempt, let message):
            guard case .running(let info, let currentAttempt, _) = sessions[sessionKey]?[id], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
            sessions[sessionKey]?[id] = .failed(info: info, failure: .error(message: normalized))
            return GUIStateTransition(state: .active(issued: issued, sessions: sessions), effects: [.abort(attempt: attempt)])

        case .generateSucceeded(let sessionKey, let id, let attempt, let text, let now):
            guard case .running(let info, let currentAttempt, let started) = sessions[sessionKey]?[id], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                sessions[sessionKey]?[id] = .failed(info: info, failure: .empty)
                return GUIStateTransition(state: .active(issued: issued, sessions: sessions), effects: [.abort(attempt: attempt)])
            }
            let duration = max(0, now - started)
            sessions[sessionKey]?[id] = .answered(info: info, answer: answer, duration: duration)
            return GUIStateTransition(
                state: .active(issued: issued, sessions: sessions),
                effects: [
                    .abort(attempt: attempt),
                    .persistAnswer(id: id, answer: answer, duration: duration, agent: info.agent, model: info.model),
                ]
            )
        }
    }

    public static func tabView(state: State, saved: [SavedChat]?, sessionKey: String, id: String) -> TabView {
        if case .active(_, let sessions) = state, let chat = sessions[sessionKey]?[id] {
            return .ready(question: chat.info.question)
        }
        if let saved {
            if let chat = saved.first(where: { $0.id == id }) {
                return .ready(question: chat.question)
            }
            return .missing
        }
        return .loading
    }

    public static func chatView(state: State, saved: [SavedChat]?, sessionKey: String, id: String) -> ChatView {
        if case .active(_, let sessions) = state, let live = sessions[sessionKey]?[id] {
            switch live {
            case .running(let info, _, _): return .running(info: info)
            case .failed(let info, let failure): return .failed(info: info, failure: failure)
            case .answered(let info, let answer, let duration):
                return .answered(info: info, answer: answer, duration: duration)
            }
        }
        guard let saved else { return .loading }
        guard let stored = saved.first(where: { $0.id == id }) else { return .missing }
        let info = ChatInfo(question: stored.question, created: stored.created, agent: stored.agent, model: stored.model)
        if let rawAnswer = stored.answer {
            let trimmed = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .answered(info: info, answer: trimmed, duration: stored.duration)
            }
            return .failed(info: info, failure: .empty)
        }
        return .failed(info: info, failure: .interrupted)
    }

    private static func runningAborts(_ chats: [String: Chat]) -> [Effect] {
        chats.keys.sorted().compactMap { id in
            if case .running(_, let attempt, _) = chats[id] { return .abort(attempt: attempt) }
            return nil
        }
    }
}

// MARK: - Context Machines & Formatters (`context/export.ts`, `context/format.ts`, `context/machine.ts`, `context/catalog-machine.ts`)

public enum SessionExportHelper {
    public static let requestTimeoutMs = 60_000

    public static func exportFilename(id: String, title: String? = nil, slug: String? = nil) -> String {
        let name: String
        if let title, !title.isEmpty {
            name = title
        } else if let slug, !slug.isEmpty {
            name = slug
        } else {
            name = id
        }
        var sanitized = ""
        var inDashRun = false
        for scalar in name.lowercased().unicodeScalars {
            let v = scalar.value
            let keep = (v >= 0x61 && v <= 0x7A)
                || (v >= 0x30 && v <= 0x39)
                || v == 0x5F
                || v == 0x2D
            if keep {
                sanitized.unicodeScalars.append(scalar)
                inDashRun = false
            } else if !inDashRun {
                sanitized.append("-")
                inDashRun = true
            }
        }
        let limited = String(sanitized.prefix(250)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(limited.isEmpty ? id : limited).json"
    }
}

public struct SessionContextFormatter: Sendable {
    public let localeIdentifier: String

    public init(localeIdentifier: String = "en_US") {
        self.localeIdentifier = localeIdentifier
    }

    public func number(_ value: Double?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(number(value))%"
    }

    public func time(epochMilliseconds: Double?) -> String {
        guard let epochMilliseconds, epochMilliseconds != 0 else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: epochMilliseconds / 1000.0))
    }
}

public enum SessionExportMachine {
    public enum State: Equatable, Sendable {
        case active(issued: Int, exporting: [String: Int])
        case disposed
    }

    public enum Event<Payload: Sendable>: Sendable {
        case exportRequested(sessionKey: String, sessionID: String)
        case exportFetched(attempt: Int, sessionKey: String, payload: Payload)
        case exportSaved(attempt: Int, sessionKey: String, filename: String, saved: Bool)
        case exportFailed(attempt: Int, sessionKey: String, message: String?)
        case disposed
    }

    public enum Effect<Payload: Sendable>: Sendable {
        case fetch(attempt: Int, sessionKey: String, sessionID: String)
        case save(attempt: Int, sessionKey: String, payload: Payload)
        case abort(attempt: Int)
        case toastExported(filename: String)
        case toastExportFailed(message: String?)
    }

    public static func createState() -> State {
        .active(issued: 0, exporting: [:])
    }

    public static func isExporting(_ state: State, sessionKey: String) -> Bool {
        if case .active(_, let exporting) = state { return exporting[sessionKey] != nil }
        return false
    }

    public static func reduce<Payload: Sendable>(
        state: State,
        event: Event<Payload>
    ) -> GUIStateTransition<State, Effect<Payload>> {
        guard case .active(var issued, var exporting) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            let aborts = exporting.keys.sorted().compactMap { exporting[$0] }.map { Effect<Payload>.abort(attempt: $0) }
            return GUIStateTransition(state: .disposed, effects: aborts)

        case .exportRequested(let sessionKey, let sessionID):
            if exporting[sessionKey] != nil { return GUIStateTransition(state: state) }
            issued += 1
            exporting[sessionKey] = issued
            return GUIStateTransition(
                state: .active(issued: issued, exporting: exporting),
                effects: [.fetch(attempt: issued, sessionKey: sessionKey, sessionID: sessionID)]
            )

        case .exportFetched(let attempt, let sessionKey, let payload):
            guard exporting[sessionKey] == attempt else { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: state,
                effects: [.save(attempt: attempt, sessionKey: sessionKey, payload: payload)]
            )

        case .exportFailed(let attempt, let sessionKey, let message):
            guard exporting[sessionKey] == attempt else { return GUIStateTransition(state: state) }
            exporting.removeValue(forKey: sessionKey)
            return GUIStateTransition(
                state: .active(issued: issued, exporting: exporting),
                effects: [.toastExportFailed(message: message)]
            )

        case .exportSaved(let attempt, let sessionKey, let filename, let saved):
            guard exporting[sessionKey] == attempt else { return GUIStateTransition(state: state) }
            exporting.removeValue(forKey: sessionKey)
            return GUIStateTransition(
                state: .active(issued: issued, exporting: exporting),
                effects: saved ? [.toastExported(filename: filename)] : []
            )
        }
    }
}

extension SessionExportMachine.Event: Equatable where Payload: Equatable {}
extension SessionExportMachine.Effect: Equatable where Payload: Equatable {}

public enum ContextScrollMachine: GUIStateMachine {
    public struct ScrollPosition: Equatable, Hashable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public enum FrameKind: String, Equatable, Hashable, Sendable {
        case restore
        case save
    }

    public enum State: Equatable, Sendable {
        case inactive(attempt: Int)
        case restoring(sessionKey: String, attempt: Int, frame: Bool, applied: ScrollPosition?)
        case tracking(sessionKey: String, attempt: Int, pending: ScrollPosition?)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case targetSynced(sessionKey: String, active: Bool)
        case contentChanged
        case restoreApplied(attempt: Int, applied: ScrollPosition?)
        case interacted
        case scrolled(position: ScrollPosition)
        case saveFlushed(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case frameSchedule(kind: FrameKind, attempt: Int)
        case frameCancel
        case saveWrite(sessionKey: String, position: ScrollPosition)
    }

    public static func createState() -> State {
        .inactive(attempt: 0)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        if case .disposed = event {
            return GUIStateTransition(state: .disposed, effects: leaveEffects(state))
        }

        if case .targetSynced(let sessionKey, let active) = event {
            let currentAttempt = attemptOf(state)
            if !active {
                if case .inactive = state { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .inactive(attempt: currentAttempt + 1), effects: leaveEffects(state))
            }
            if sessionKeyOf(state) == sessionKey {
                return GUIStateTransition(state: state)
            }
            let nextAttempt = currentAttempt + 1
            return GUIStateTransition(
                state: .restoring(sessionKey: sessionKey, attempt: nextAttempt, frame: true, applied: nil),
                effects: leaveEffects(state) + [.frameSchedule(kind: .restore, attempt: nextAttempt)]
            )
        }

        switch state {
        case .inactive, .disposed:
            return GUIStateTransition(state: state)

        case .restoring(let sessionKey, let attempt, let frame, let applied):
            switch event {
            case .contentChanged:
                if frame { return GUIStateTransition(state: state) }
                let nextAttempt = attempt + 1
                return GUIStateTransition(
                    state: .restoring(sessionKey: sessionKey, attempt: nextAttempt, frame: true, applied: applied),
                    effects: [.frameSchedule(kind: .restore, attempt: nextAttempt)]
                )
            case .restoreApplied(let eventAttempt, let newApplied):
                guard frame && eventAttempt == attempt else { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .restoring(sessionKey: sessionKey, attempt: attempt, frame: false, applied: newApplied)
                )
            case .interacted:
                return GUIStateTransition(
                    state: .tracking(sessionKey: sessionKey, attempt: attempt + 1, pending: nil),
                    effects: frame ? [.frameCancel] : []
                )
            case .scrolled(let position):
                if applied == position {
                    return GUIStateTransition(
                        state: .restoring(sessionKey: sessionKey, attempt: attempt, frame: frame, applied: nil)
                    )
                }
                let nextAttempt = attempt + 1
                let save: Effect = .frameSchedule(kind: .save, attempt: nextAttempt)
                return GUIStateTransition(
                    state: .tracking(sessionKey: sessionKey, attempt: nextAttempt, pending: position),
                    effects: frame ? [.frameCancel, save] : [save]
                )
            default:
                return GUIStateTransition(state: state)
            }

        case .tracking(let sessionKey, let attempt, let pending):
            switch event {
            case .scrolled(let position):
                guard let pending else {
                    let nextAttempt = attempt + 1
                    return GUIStateTransition(
                        state: .tracking(sessionKey: sessionKey, attempt: nextAttempt, pending: position),
                        effects: [.frameSchedule(kind: .save, attempt: nextAttempt)]
                    )
                }
                if pending == position { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .tracking(sessionKey: sessionKey, attempt: attempt, pending: position))
            case .saveFlushed(let eventAttempt):
                guard let pending, eventAttempt == attempt else { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .tracking(sessionKey: sessionKey, attempt: attempt, pending: nil),
                    effects: [.saveWrite(sessionKey: sessionKey, position: pending)]
                )
            default:
                return GUIStateTransition(state: state)
            }
        }
    }

    private static func leaveEffects(_ state: State) -> [Effect] {
        switch state {
        case .restoring(_, _, true, _):
            return [.frameCancel]
        case .tracking(let sessionKey, _, let pending?):
            return [.frameCancel, .saveWrite(sessionKey: sessionKey, position: pending)]
        default:
            return []
        }
    }

    private static func attemptOf(_ state: State) -> Int {
        switch state {
        case .inactive(let a), .restoring(_, let a, _, _), .tracking(_, let a, _): return a
        case .disposed: return 0
        }
    }

    private static func sessionKeyOf(_ state: State) -> String? {
        switch state {
        case .restoring(let k, _, _, _), .tracking(let k, _, _): return k
        case .inactive, .disposed: return nil
        }
    }
}

public enum CatalogMachine: GUIStateMachine {
    public static let loadTimeoutMs = 15_000
    public static let maxRetries = 11

    public struct Target: Equatable, Hashable, Sendable {
        public let serverID: String
        public let directory: String

        public init(serverID: String, directory: String) {
            self.serverID = serverID
            self.directory = directory
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case loading(attempt: Int, retries: Int)
        case retrying(attempt: Int, retries: Int)
        case loaded
        case failed
    }

    public enum State: Equatable, Sendable {
        case open(issued: Int, active: Bool, target: Target?, phase: Phase)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case inputChanged(active: Bool, target: Target?)
        case loadSucceeded(attempt: Int)
        case loadFailed(attempt: Int, retryable: Bool)
        case loadTimedOut(attempt: Int)
        case retryDue(attempt: Int)
        case retryRequested
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case load(attempt: Int, target: Target)
        case scheduleRetry(attempt: Int, delayMs: Int)
        case cancel(attempt: Int)
    }

    public static func createState() -> State {
        .open(issued: 0, active: false, target: nil, phase: .idle)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .open(let issued, let active, let target, let phase) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed, effects: cancelEffects(phase))

        case .inputChanged(let nextActive, let nextTarget):
            guard let nextTarget else {
                if active == nextActive && target == nil { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .open(issued: issued, active: nextActive, target: nil, phase: .idle),
                    effects: cancelEffects(phase)
                )
            }
            if target != nextTarget {
                let cancels = cancelEffects(phase)
                if !nextActive {
                    return GUIStateTransition(
                        state: .open(issued: issued, active: false, target: nextTarget, phase: .idle),
                        effects: cancels
                    )
                }
                let attempt = issued + 1
                return GUIStateTransition(
                    state: .open(issued: attempt, active: true, target: nextTarget, phase: .loading(attempt: attempt, retries: 0)),
                    effects: cancels + [.load(attempt: attempt, target: nextTarget)]
                )
            }
            if nextActive && (phase == .idle || phase == .failed) {
                let attempt = issued + 1
                return GUIStateTransition(
                    state: .open(issued: attempt, active: true, target: nextTarget, phase: .loading(attempt: attempt, retries: 0)),
                    effects: [.load(attempt: attempt, target: nextTarget)]
                )
            }
            if !nextActive, case .retrying = phase {
                return GUIStateTransition(
                    state: .open(issued: issued, active: false, target: nextTarget, phase: .failed),
                    effects: cancelEffects(phase)
                )
            }
            if active == nextActive { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .open(issued: issued, active: nextActive, target: nextTarget, phase: phase))

        case .loadSucceeded(let attempt):
            guard case .loading(let currentAttempt, _) = phase, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .open(issued: issued, active: active, target: target, phase: .loaded))

        case .loadFailed(let attempt, let retryable):
            guard case .loading(let currentAttempt, let retries) = phase, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if !retryable || !active || retries >= maxRetries {
                return GUIStateTransition(state: .open(issued: issued, active: active, target: target, phase: .failed))
            }
            let nextAttempt = issued + 1
            let delay = min(1_000 * (1 << min(retries, 10)), 5_000)
            return GUIStateTransition(
                state: .open(issued: nextAttempt, active: active, target: target, phase: .retrying(attempt: nextAttempt, retries: retries + 1)),
                effects: [.scheduleRetry(attempt: nextAttempt, delayMs: delay)]
            )

        case .loadTimedOut(let attempt):
            guard case .loading(let currentAttempt, _) = phase, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .open(issued: issued, active: active, target: target, phase: .failed))

        case .retryDue(let attempt):
            guard case .retrying(let currentAttempt, let retries) = phase, currentAttempt == attempt, let target else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .open(issued: issued, active: active, target: target, phase: .loading(attempt: attempt, retries: retries)),
                effects: [.load(attempt: attempt, target: target)]
            )

        case .retryRequested:
            guard case .failed = phase, let target else { return GUIStateTransition(state: state) }
            let attempt = issued + 1
            return GUIStateTransition(
                state: .open(issued: attempt, active: active, target: target, phase: .loading(attempt: attempt, retries: 0)),
                effects: [.load(attempt: attempt, target: target)]
            )
        }
    }

    private static func cancelEffects(_ phase: Phase) -> [Effect] {
        switch phase {
        case .loading(let attempt, _), .retrying(let attempt, _): return [.cancel(attempt: attempt)]
        default: return []
        }
    }
}

// MARK: - Autonomous Goal Pill Machine (`goal/machine.ts`)

public enum GoalMachine: GUIStateMachine {
    public static let snapshotTimeoutMs = 15_000
    public static let commandTimeoutMs = 15_000
    public static let retryDelaysMs = [1_000, 2_000, 4_000]

    public enum Action: String, Equatable, Hashable, Sendable {
        case pause
        case resume
        case clear
    }

    public enum Entry: Equatable, Sendable {
        case loading(attempt: Int, retries: Int, cached: GoalSchema.State?)
        case retrying(attempt: Int, retries: Int)
        case live(goal: GoalSchema.State?)
        case stale(goal: GoalSchema.State)
        case failed
    }

    public struct Target: Equatable, Hashable, Sendable {
        public let subscription: Int
        public let key: String
        public let serverID: String
        public let sessionID: String
        public let directory: String

        public init(subscription: Int, key: String, serverID: String, sessionID: String, directory: String) {
            self.subscription = subscription
            self.key = key
            self.serverID = serverID
            self.sessionID = sessionID
            self.directory = directory
        }
    }

    public struct InFlightCommand: Equatable, Sendable {
        public let attempt: Int
        public let action: Action

        public init(attempt: Int, action: Action) {
            self.attempt = attempt
            self.action = action
        }
    }

    public enum State: Equatable, Sendable {
        case active(
            issued: Int,
            target: Target?,
            sessions: [String: Entry],
            commands: [String: InFlightCommand]
        )
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case targetAttached(key: String, serverID: String, sessionID: String, directory: String)
        case targetDetached
        case changed(subscription: Int, key: String, goal: GoalSchema.State?)
        case snapshotLoaded(attempt: Int, goal: GoalSchema.State?)
        case snapshotFailed(attempt: Int)
        case retryDue(attempt: Int)
        case commandRequested(key: String, serverID: String, sessionID: String, action: Action)
        case commandSucceeded(key: String, attempt: Int)
        case commandFailed(key: String, attempt: Int, message: String?)
        case sessionsPruned(keep: Set<String>)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case subscribe(subscription: Int, serverID: String)
        case unsubscribe(subscription: Int)
        case fetch(attempt: Int, serverID: String, sessionID: String, directory: String)
        case scheduleRetry(attempt: Int, delayMs: Int)
        case command(attempt: Int, key: String, serverID: String, sessionID: String, action: Action)
        case cancel(attempt: Int)
        case toastError(message: String?)
    }

    public static func createState() -> State {
        .active(issued: 0, target: nil, sessions: [:], commands: [:])
    }

    public static func selectGoal(_ state: State, key: String) -> GoalSchema.State? {
        guard case .active(_, _, let sessions, _) = state, let entry = sessions[key] else { return nil }
        return shownGoal(entry)
    }

    public static func selectBusy(_ state: State, key: String) -> Bool {
        guard case .active(_, _, _, let commands) = state else { return false }
        return commands[key] != nil
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .active(var issued, let target, var sessions, var commands) = state else {
            return GUIStateTransition(state: state)
        }

        switch event {
        case .disposed:
            let (_, leaveEffects) = leaveTarget(issued: issued, target: target, sessions: sessions, commands: commands)
            let cmdCancels = commands.keys.sorted().compactMap { commands[$0]?.attempt }.map { Effect.cancel(attempt: $0) }
            return GUIStateTransition(state: .disposed, effects: leaveEffects + cmdCancels)

        case .targetAttached(let key, let serverID, let sessionID, let directory):
            if target?.key == key && target?.directory == directory {
                return GUIStateTransition(state: state)
            }
            let (leftSessions, leaveEffects) = leaveTarget(issued: issued, target: target, sessions: sessions, commands: commands)
            var nextSessions = leftSessions
            let cached: GoalSchema.State?
            if case .stale(let goal) = nextSessions[key] { cached = goal } else { cached = nil }
            let subscription = issued + 1
            let attempt = subscription + 1
            let nextTarget = Target(subscription: subscription, key: key, serverID: serverID, sessionID: sessionID, directory: directory)
            nextSessions[key] = .loading(attempt: attempt, retries: 0, cached: cached)
            return GUIStateTransition(
                state: .active(issued: attempt, target: nextTarget, sessions: nextSessions, commands: commands),
                effects: leaveEffects + [
                    .subscribe(subscription: subscription, serverID: serverID),
                    .fetch(attempt: attempt, serverID: serverID, sessionID: sessionID, directory: directory),
                ]
            )

        case .targetDetached:
            guard target != nil else { return GUIStateTransition(state: state) }
            let (nextSessions, leaveEffects) = leaveTarget(issued: issued, target: target, sessions: sessions, commands: commands)
            return GUIStateTransition(
                state: .active(issued: issued, target: nil, sessions: nextSessions, commands: commands),
                effects: leaveEffects
            )

        case .changed(let subscription, let key, let goal):
            guard let target, target.subscription == subscription else { return GUIStateTransition(state: state) }
            let existing = sessions[key]
            if key == target.key {
                sessions[key] = .live(goal: goal)
                var effects: [Effect] = []
                switch existing {
                case .loading(let a, _, _), .retrying(let a, _): effects.append(.cancel(attempt: a))
                default: break
                }
                return GUIStateTransition(
                    state: .active(issued: issued, target: target, sessions: sessions, commands: commands),
                    effects: effects
                )
            }
            guard existing != nil else { return GUIStateTransition(state: state) }
            if let goal {
                sessions[key] = .stale(goal: goal)
            } else {
                sessions.removeValue(forKey: key)
            }
            return GUIStateTransition(state: .active(issued: issued, target: target, sessions: sessions, commands: commands))

        case .snapshotLoaded(let attempt, let goal):
            guard let target, case .loading(let currentAttempt, _, _) = sessions[target.key], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            sessions[target.key] = .live(goal: goal)
            return GUIStateTransition(state: .active(issued: issued, target: target, sessions: sessions, commands: commands))

        case .snapshotFailed(let attempt):
            guard let target, case .loading(let currentAttempt, let retries, _) = sessions[target.key], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            guard retries < retryDelaysMs.count else {
                sessions[target.key] = .failed
                return GUIStateTransition(state: .active(issued: issued, target: target, sessions: sessions, commands: commands))
            }
            issued += 1
            let delay = retryDelaysMs[retries]
            sessions[target.key] = .retrying(attempt: issued, retries: retries + 1)
            return GUIStateTransition(
                state: .active(issued: issued, target: target, sessions: sessions, commands: commands),
                effects: [.scheduleRetry(attempt: issued, delayMs: delay)]
            )

        case .retryDue(let attempt):
            guard let target, case .retrying(let currentAttempt, let retries) = sessions[target.key], currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            sessions[target.key] = .loading(attempt: currentAttempt, retries: retries, cached: nil)
            return GUIStateTransition(
                state: .active(issued: issued, target: target, sessions: sessions, commands: commands),
                effects: [.fetch(attempt: currentAttempt, serverID: target.serverID, sessionID: target.sessionID, directory: target.directory)]
            )

        case .commandRequested(let key, let serverID, let sessionID, let action):
            if commands[key] != nil { return GUIStateTransition(state: state) }
            issued += 1
            commands[key] = InFlightCommand(attempt: issued, action: action)
            return GUIStateTransition(
                state: .active(issued: issued, target: target, sessions: sessions, commands: commands),
                effects: [.command(attempt: issued, key: key, serverID: serverID, sessionID: sessionID, action: action)]
            )

        case .commandSucceeded(let key, let attempt):
            guard commands[key]?.attempt == attempt else { return GUIStateTransition(state: state) }
            commands.removeValue(forKey: key)
            return GUIStateTransition(state: .active(issued: issued, target: target, sessions: sessions, commands: commands))

        case .commandFailed(let key, let attempt, let message):
            guard commands[key]?.attempt == attempt else { return GUIStateTransition(state: state) }
            commands.removeValue(forKey: key)
            return GUIStateTransition(
                state: .active(issued: issued, target: target, sessions: sessions, commands: commands),
                effects: [.toastError(message: message)]
            )

        case .sessionsPruned(let keep):
            let isKept: (String) -> Bool = { keep.contains($0) || $0 == target?.key }
            let droppedCmdKeys = commands.keys.filter { !isKept($0) }.sorted()
            if droppedCmdKeys.isEmpty && sessions.keys.allSatisfy(isKept) {
                return GUIStateTransition(state: state)
            }
            let cancels = droppedCmdKeys.compactMap { commands[$0]?.attempt }.map { Effect.cancel(attempt: $0) }
            sessions = sessions.filter { isKept($0.key) }
            commands = commands.filter { isKept($0.key) }
            return GUIStateTransition(
                state: .active(issued: issued, target: target, sessions: sessions, commands: commands),
                effects: cancels
            )
        }
    }

    private static func leaveTarget(
        issued: Int,
        target: Target?,
        sessions: [String: Entry],
        commands: [String: InFlightCommand]
    ) -> ([String: Entry], [Effect]) {
        guard let target else { return (sessions, []) }
        var nextSessions = sessions
        let entry = sessions[target.key]
        if let entry, let goal = shownGoal(entry) {
            nextSessions[target.key] = .stale(goal: goal)
        } else {
            nextSessions.removeValue(forKey: target.key)
        }
        var effects: [Effect] = [.unsubscribe(subscription: target.subscription)]
        switch entry {
        case .loading(let a, _, _), .retrying(let a, _):
            effects.append(.cancel(attempt: a))
        default:
            break
        }
        return (nextSessions, effects)
    }

    private static func shownGoal(_ entry: Entry) -> GoalSchema.State? {
        switch entry {
        case .live(let goal): return goal
        case .loading(_, _, let cached): return cached
        case .retrying, .stale, .failed: return nil
        }
    }
}

// MARK: - Debug Tools Contracts & State Machines (`debug/{options,focus-machine,heap-machine,memory-machine,motion-machine}.ts`)

public enum DebugOptions {
    public static func isDebugBuild(packaged: Bool, channel: String) -> Bool {
        !packaged || channel == "beta"
    }

    /// Parses `OPENCODE_DESKTOP_MEMORY_LOG` seconds into milliseconds (`1...2_147_483` seconds).
    public static func memoryLogIntervalMs(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) }) else {
            return nil
        }
        guard let seconds = Double(value), seconds >= 1 && seconds <= 2_147_483 else {
            return nil
        }
        return seconds * 1_000
    }
}

public enum DebugFocusToggleMachine: GUIStateMachine {
    public enum State: Equatable, Sendable {
        case idle(attempt: Int, enabled: Bool)
        case changing(attempt: Int, target: Bool, desired: Bool)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case toggle
        case setSucceeded(attempt: Int)
        case setFailed(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case set(attempt: Int, enabled: Bool)
        case reset
        case notifyFailed
    }

    public static let initialState: State = .idle(attempt: 0, enabled: false)

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        switch event {
        case .toggle:
            switch state {
            case .idle(let attempt, let enabled):
                let nextAttempt = attempt + 1
                return GUIStateTransition(
                    state: .changing(attempt: nextAttempt, target: !enabled, desired: !enabled),
                    effects: [.set(attempt: nextAttempt, enabled: !enabled)]
                )
            case .changing(let attempt, let target, let desired):
                return GUIStateTransition(state: .changing(attempt: attempt, target: target, desired: !desired))
            case .disposed:
                return GUIStateTransition(state: state)
            }

        case .setSucceeded(let attempt):
            guard case .changing(let currentAttempt, let target, let desired) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if desired != target {
                let nextAttempt = currentAttempt + 1
                return GUIStateTransition(
                    state: .changing(attempt: nextAttempt, target: desired, desired: desired),
                    effects: [.set(attempt: nextAttempt, enabled: desired)]
                )
            }
            return GUIStateTransition(state: .idle(attempt: currentAttempt, enabled: target))

        case .setFailed(let attempt):
            guard case .changing(let currentAttempt, let target, let desired) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .idle(attempt: currentAttempt, enabled: !target),
                effects: desired == target ? [.notifyFailed] : []
            )

        case .disposed:
            let wasOn: Bool
            switch state {
            case .idle(_, let enabled): wasOn = enabled
            case .changing(_, let target, _): wasOn = target
            case .disposed: wasOn = false
            }
            return GUIStateTransition(state: .disposed, effects: wasOn ? [.reset] : [])
        }
    }

    public static func isActive(_ state: State) -> Bool {
        switch state {
        case .changing(_, _, let desired): return desired
        case .idle(_, let enabled): return enabled
        case .disposed: return false
        }
    }
}

public struct HeapCaptureResult: Equatable, Hashable, Sendable, Codable {
    public let directory: String
    public let complete: Bool

    public init(directory: String, complete: Bool) {
        self.directory = directory
        self.complete = complete
    }
}

public enum HeapCaptureMachine: GUIStateMachine {
    public enum Job: Equatable, Sendable {
        case command(root: String, includeServer: Bool, replyIDs: [Int])
        case signal(root: String, includeServer: Bool)

        public var root: String {
            switch self {
            case .command(let r, _, _), .signal(let r, _): return r
            }
        }

        public var includeServer: Bool {
            switch self {
            case .command(_, let inc, _), .signal(_, let inc): return inc
            }
        }
    }

    public enum State: Equatable, Sendable {
        case idle(attempt: Int)
        case capturing(attempt: Int, active: Job, pending: Job?)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case commandRequested(root: String, includeServer: Bool, replyID: Int)
        case signalReceived(root: String, includeServer: Bool)
        case captureSucceeded(attempt: Int, result: HeapCaptureResult)
        case captureFailed(attempt: Int, errorMessage: String)
        case disposed
    }

    public enum Outcome: Equatable, Sendable {
        case ok(HeapCaptureResult)
        case error(String)
    }

    public enum Effect: Equatable, Sendable {
        case captureRun(attempt: Int, root: String, includeServer: Bool)
        case repliesSettle(replyIDs: [Int], outcome: Outcome)
        case signalFailed(error: String)
    }

    public static func createState() -> State {
        .idle(attempt: 0)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state {
            if case .commandRequested(_, _, let replyID) = event {
                return GUIStateTransition(state: state, effects: [.repliesSettle(replyIDs: [replyID], outcome: .error("Heap capture disposed"))])
            }
            return GUIStateTransition(state: state)
        }

        switch event {
        case .disposed:
            guard case .capturing(_, let active, let pending) = state else {
                return GUIStateTransition(state: .disposed)
            }
            var replyIDs: [Int] = []
            if case .command(_, _, let ids) = active { replyIDs.append(contentsOf: ids) }
            if case .command(_, _, let ids) = pending { replyIDs.append(contentsOf: ids) }
            let effects: [Effect] = replyIDs.isEmpty ? [] : [.repliesSettle(replyIDs: replyIDs, outcome: .error("Heap capture disposed"))]
            return GUIStateTransition(state: .disposed, effects: effects)

        case .commandRequested(let root, let includeServer, let replyID):
            switch state {
            case .idle(let attempt):
                let nextAttempt = attempt + 1
                let job: Job = .command(root: root, includeServer: includeServer, replyIDs: [replyID])
                return GUIStateTransition(
                    state: .capturing(attempt: nextAttempt, active: job, pending: nil),
                    effects: [.captureRun(attempt: nextAttempt, root: root, includeServer: includeServer)]
                )
            case .capturing(let attempt, .command(let r, let inc, let ids), let pending):
                return GUIStateTransition(
                    state: .capturing(attempt: attempt, active: .command(root: r, includeServer: inc, replyIDs: ids + [replyID]), pending: pending)
                )
            case .capturing(let attempt, let active, let pending):
                let nextPendingReplyIDs: [Int]
                if case .command(_, _, let existingIDs) = pending {
                    nextPendingReplyIDs = existingIDs + [replyID]
                } else {
                    nextPendingReplyIDs = [replyID]
                }
                return GUIStateTransition(
                    state: .capturing(
                        attempt: attempt,
                        active: active,
                        pending: .command(root: root, includeServer: includeServer, replyIDs: nextPendingReplyIDs)
                    )
                )
            case .disposed:
                return GUIStateTransition(state: state)
            }

        case .signalReceived(let root, let includeServer):
            switch state {
            case .idle(let attempt):
                let nextAttempt = attempt + 1
                let job: Job = .signal(root: root, includeServer: includeServer)
                return GUIStateTransition(
                    state: .capturing(attempt: nextAttempt, active: job, pending: nil),
                    effects: [.captureRun(attempt: nextAttempt, root: root, includeServer: includeServer)]
                )
            case .capturing(let attempt, let active, let pending):
                if case .signal = active { return GUIStateTransition(state: state) }
                if pending != nil { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .capturing(attempt: attempt, active: active, pending: .signal(root: root, includeServer: includeServer))
                )
            case .disposed:
                return GUIStateTransition(state: state)
            }

        case .captureSucceeded(let attempt, let result):
            return settleCapture(state: state, attempt: attempt, outcome: .ok(result))

        case .captureFailed(let attempt, let errorMessage):
            return settleCapture(state: state, attempt: attempt, outcome: .error(errorMessage))
        }
    }

    private static func settleCapture(state: State, attempt: Int, outcome: Outcome) -> GUIStateTransition<State, Effect> {
        guard case .capturing(let currentAttempt, let active, let pending) = state, currentAttempt == attempt else {
            return GUIStateTransition(state: state)
        }
        var effects: [Effect] = []
        switch active {
        case .command(_, _, let replyIDs):
            effects.append(.repliesSettle(replyIDs: replyIDs, outcome: outcome))
        case .signal:
            if case .error(let message) = outcome {
                effects.append(.signalFailed(error: message))
            }
        }
        guard let pending else {
            return GUIStateTransition(state: .idle(attempt: currentAttempt), effects: effects)
        }
        let nextAttempt = currentAttempt + 1
        return GUIStateTransition(
            state: .capturing(attempt: nextAttempt, active: pending, pending: nil),
            effects: effects + [.captureRun(attempt: nextAttempt, root: pending.root, includeServer: pending.includeServer)]
        )
    }
}

public enum HeapCommandMachine: GUIStateMachine {
    public enum State: Equatable, Sendable {
        case idle(issued: Int)
        case capturing(attempt: Int)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case run
        case succeeded(attempt: Int, result: HeapCaptureResult)
        case failed(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case captureStart(attempt: Int)
        case captureAbort(attempt: Int)
        case toastResult(attempt: Int, result: HeapCaptureResult)
        case toastFailed(attempt: Int)
    }

    public static func createState() -> State {
        .idle(issued: 0)
    }

    public static func isEnabled(_ state: State) -> Bool {
        if case .idle = state { return true }
        return false
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }
        switch event {
        case .disposed:
            if case .capturing(let attempt) = state {
                return GUIStateTransition(state: .disposed, effects: [.captureAbort(attempt: attempt)])
            }
            return GUIStateTransition(state: .disposed)
        case .run:
            guard case .idle(let issued) = state else { return GUIStateTransition(state: state) }
            let attempt = issued + 1
            return GUIStateTransition(state: .capturing(attempt: attempt), effects: [.captureStart(attempt: attempt)])
        case .succeeded(let attempt, let result):
            guard case .capturing(let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .idle(issued: currentAttempt), effects: [.toastResult(attempt: attempt, result: result)])
        case .failed(let attempt):
            guard case .capturing(let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .idle(issued: currentAttempt), effects: [.toastFailed(attempt: attempt)])
        }
    }
}

public enum DebugBarVisibility: String, Equatable, Hashable, Sendable {
    case hidden
    case shown
    case pinned
}

public struct DebugBarView: Equatable, Sendable {
    public let visibility: DebugBarVisibility
    public let open: Bool
    public let closable: Bool
    public let togglable: Bool
    public let motion: Bool

    public init(visibility: DebugBarVisibility, open: Bool, closable: Bool, togglable: Bool, motion: Bool) {
        self.visibility = visibility
        self.open = open
        self.closable = closable
        self.togglable = togglable
        self.motion = motion
    }
}

public enum MemoryDiagnosticsMachine: GUIStateMachine {
    public enum State: Equatable, Sendable {
        case off(issued: Int, probing: Set<Int>)
        case on(issued: Int, run: Int, sampling: Int?, probing: Set<Int>)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case synced(enabled: Bool)
        case tick(run: Int)
        case probeStarted(contentsID: Int)
        case probeSettled(contentsID: Int)
        case sampleCollected(attempt: Int, line: String)
        case sampleWritten(attempt: Int)
        case sampleFailed(attempt: Int, error: String)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case logStart(run: Int)
        case logStop(run: Int)
        case timerSchedule(run: Int)
        case timerCancel
        case sampleCollect(attempt: Int)
        case sampleWrite(attempt: Int, line: String)
        case sampleReport(error: String)
    }

    public static func createState() -> State {
        .off(issued: 0, probing: [])
    }

    public static func isOn(_ state: State) -> Bool {
        if case .on = state { return true }
        return false
    }

    public static func isRendererProbing(_ state: State, contentsID: Int) -> Bool {
        switch state {
        case .off(_, let probing), .on(_, _, _, let probing): return probing.contains(contentsID)
        case .disposed: return false
        }
    }

    public static func debugBarView(visible: Bool, motion: Bool, memoryOn: Bool) -> DebugBarView {
        let visibility: DebugBarVisibility = memoryOn ? .pinned : (visible ? .shown : .hidden)
        return DebugBarView(
            visibility: visibility,
            open: visibility != .hidden,
            closable: visibility == .shown,
            togglable: visibility != .pinned,
            motion: visibility != .hidden && motion
        )
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        if case .disposed = event {
            if case .on(_, let run, _, _) = state {
                return GUIStateTransition(state: .disposed, effects: [.timerCancel, .logStop(run: run)])
            }
            return GUIStateTransition(state: .disposed)
        }

        switch event {
        case .probeStarted(let contentsID):
            switch state {
            case .off(let issued, var probing):
                if !probing.insert(contentsID).inserted { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .off(issued: issued, probing: probing))
            case .on(let issued, let run, let sampling, var probing):
                if !probing.insert(contentsID).inserted { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .on(issued: issued, run: run, sampling: sampling, probing: probing))
            case .disposed:
                return GUIStateTransition(state: state)
            }

        case .probeSettled(let contentsID):
            switch state {
            case .off(let issued, var probing):
                guard probing.remove(contentsID) != nil else { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .off(issued: issued, probing: probing))
            case .on(let issued, let run, let sampling, var probing):
                guard probing.remove(contentsID) != nil else { return GUIStateTransition(state: state) }
                return GUIStateTransition(state: .on(issued: issued, run: run, sampling: sampling, probing: probing))
            case .disposed:
                return GUIStateTransition(state: state)
            }

        case .synced(let enabled):
            switch state {
            case .on(let issued, let run, _, let probing):
                if enabled { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .off(issued: issued, probing: probing),
                    effects: [.timerCancel, .logStop(run: run)]
                )
            case .off(let issued, let probing):
                if !enabled { return GUIStateTransition(state: state) }
                let run = issued + 1
                return GUIStateTransition(
                    state: .on(issued: run, run: run, sampling: nil, probing: probing),
                    effects: [.logStart(run: run), .timerSchedule(run: run)]
                )
            case .disposed:
                return GUIStateTransition(state: state)
            }

        case .tick(let run):
            guard case .on(let issued, let currentRun, nil, let probing) = state, currentRun == run else {
                return GUIStateTransition(state: state)
            }
            let attempt = issued + 1
            return GUIStateTransition(
                state: .on(issued: attempt, run: currentRun, sampling: attempt, probing: probing),
                effects: [.sampleCollect(attempt: attempt)]
            )

        case .sampleCollected(let attempt, let line):
            guard case .on(_, _, let sampling, _) = state, sampling == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: state, effects: [.sampleWrite(attempt: attempt, line: line)])

        case .sampleWritten(let attempt):
            guard case .on(let issued, let run, let sampling, let probing) = state, sampling == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .on(issued: issued, run: run, sampling: nil, probing: probing),
                effects: [.timerSchedule(run: run)]
            )

        case .sampleFailed(let attempt, let error):
            guard case .on(let issued, let run, let sampling, let probing) = state, sampling == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .on(issued: issued, run: run, sampling: nil, probing: probing),
                effects: [.sampleReport(error: error), .timerSchedule(run: run)]
            )

        case .disposed:
            return GUIStateTransition(state: state)
        }
    }
}

public enum MotionPanelMachine: GUIStateMachine {
    public static let wideAtPx = 560
    public static let focusMs = 1_600

    public enum Nav: Equatable, Hashable, Sendable {
        case list
        case feature(key: String)
    }

    public enum Handle: String, Equatable, Hashable, Sendable {
        case header
        case edge
    }

    public enum Gesture: Equatable, Sendable {
        case idle
        case held(handle: Handle, pointerID: Int)
    }

    public enum Outline: Equatable, Sendable {
        case none
        case hover(target: String)
        case focus(target: String, attempt: Int)
    }

    public enum State: Equatable, Sendable {
        case open(wide: Bool, selected: String?, nav: Nav, gesture: Gesture, outline: Outline, issued: Int)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case featureOpened(key: String)
        case back
        case escape
        case featuresChanged(present: Bool)
        case resized(wide: Bool)
        case pointerDown(handle: Handle, pointerID: Int, button: Int)
        case pointerReleased(pointerID: Int)
        case rowEntered(target: String?)
        case rowLeft
        case targetFocused(target: String)
        case outlineExpired(attempt: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case save
        case close
        case focusPage
        case focusRow(key: String)
        case focusList
        case settle
        case outlineFrame(target: String?)
        case outlineFocus(target: String, attempt: Int, delayMs: Int)
        case outlineDispose
    }

    public static func createState(wide: Bool, selected: String?) -> State {
        .open(wide: wide, selected: selected, nav: .list, gesture: .idle, outline: .none, issued: 0)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        guard case .open(let wide, let selected, let nav, let gesture, let outline, let issued) = state else {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed, effects: [.outlineDispose])

        case .featureOpened(let key):
            let clearEffects: [Effect] = outline == .none ? [] : [.outlineFrame(target: nil)]
            let nextNav: Nav = wide ? .list : .feature(key: key)
            let focusEffects: [Effect] = wide ? [] : [.focusPage]
            return GUIStateTransition(
                state: .open(wide: wide, selected: key, nav: nextNav, gesture: gesture, outline: .none, issued: issued),
                effects: clearEffects + [.save] + focusEffects
            )

        case .back:
            guard case .feature(let key) = nav else { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .open(wide: wide, selected: selected, nav: .list, gesture: gesture, outline: outline, issued: issued),
                effects: [.focusRow(key: key)]
            )

        case .escape:
            if !wide, case .feature(let key) = nav {
                return GUIStateTransition(
                    state: .open(wide: wide, selected: selected, nav: .list, gesture: gesture, outline: outline, issued: issued),
                    effects: [.focusRow(key: key)]
                )
            }
            return GUIStateTransition(state: state, effects: [.close])

        case .featuresChanged(let present):
            guard case .feature = nav, !present else { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .open(wide: wide, selected: selected, nav: .list, gesture: gesture, outline: outline, issued: issued),
                effects: [.focusList]
            )

        case .resized(let nextWide):
            if wide == nextWide { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .open(wide: nextWide, selected: selected, nav: nextWide ? .list : nav, gesture: gesture, outline: outline, issued: issued)
            )

        case .pointerDown(let handle, let pointerID, let button):
            guard button == 0, gesture == .idle else { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .open(wide: wide, selected: selected, nav: nav, gesture: .held(handle: handle, pointerID: pointerID), outline: outline, issued: issued)
            )

        case .pointerReleased(let pointerID):
            guard case .held(_, let currentPointer) = gesture, currentPointer == pointerID else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .open(wide: wide, selected: selected, nav: nav, gesture: .idle, outline: outline, issued: issued),
                effects: [.settle]
            )

        case .rowEntered(let target):
            guard let target else {
                if outline == .none { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .open(wide: wide, selected: selected, nav: nav, gesture: gesture, outline: .none, issued: issued),
                    effects: [.outlineFrame(target: nil)]
                )
            }
            if case .hover(let current) = outline, current == target {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .open(wide: wide, selected: selected, nav: nav, gesture: gesture, outline: .hover(target: target), issued: issued),
                effects: [.outlineFrame(target: target)]
            )

        case .rowLeft:
            guard case .hover = outline else { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .open(wide: wide, selected: selected, nav: nav, gesture: gesture, outline: .none, issued: issued),
                effects: [.outlineFrame(target: nil)]
            )

        case .targetFocused(let target):
            let attempt = issued + 1
            return GUIStateTransition(
                state: .open(wide: wide, selected: selected, nav: nav, gesture: gesture, outline: .focus(target: target, attempt: attempt), issued: attempt),
                effects: [.outlineFocus(target: target, attempt: attempt, delayMs: focusMs)]
            )

        case .outlineExpired(let attempt):
            guard case .focus(_, let currentAttempt) = outline, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .open(wide: wide, selected: selected, nav: nav, gesture: gesture, outline: .none, issued: issued),
                effects: [.outlineFrame(target: nil)]
            )
        }
    }

    public static func selectPushed(_ state: State) -> Bool {
        guard case .open(let wide, _, .feature, _, _, _) = state else { return false }
        return !wide
    }

    public static func selectWide(_ state: State) -> Bool {
        if case .open(let wide, _, _, _, _, _) = state { return wide }
        return false
    }

    public static func selectHeld(_ state: State, handle: Handle, pointerID: Int) -> Bool {
        guard case .open(_, _, _, .held(let h, let p), _, _) = state else { return false }
        return h == handle && p == pointerID
    }

    public static func selectIdle(_ state: State) -> Bool {
        if case .open(_, _, _, .idle, _, _) = state { return true }
        return false
    }

    public static func selectSelected(_ state: State) -> String? {
        if case .open(_, let selected, _, _, _, _) = state { return selected }
        return nil
    }
}
