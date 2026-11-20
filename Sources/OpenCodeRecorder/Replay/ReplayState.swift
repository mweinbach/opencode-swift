import OpenCodePlatform

private func isCIEnvironment(_ environment: any EnvironmentProviding) -> Bool {
    guard let value = environment.variable("CI") else { return false }
    return !value.isEmpty && value != "false" && value != "0"
}

/// Resolves `"auto"` mode to `.replay` under CI or when the cassette already exists, otherwise `.record`.
// parity: http-recorder/src/replay/state.ts#resolveAutoMode [status=implemented hash=c18dad0e6975]
public func resolveAutoMode(
    cassette: any CassetteStoreInterface,
    name: String,
    environment: any EnvironmentProviding = SystemEnvironment.shared
) async -> RecordReplayMode {
    if isCIEnvironment(environment) {
        return .replay
    }
    return await cassette.exists(name) ? .replay : .record
}

/// Claimed recorded interaction paired with its zero-based index in the projected interaction list.
public struct ReplayClaim<T: Sendable>: Sendable {
    public let interaction: T
    public let index: Int

    public init(interaction: T, index: Int) {
        self.interaction = interaction
        self.index = index
    }
}

/// Errors produced by replay state tracking and scope exhaustion checks.
public enum ReplayStateError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case unusedInteractions(cassetteName: String, used: Int, total: Int)
    case unavailableInteraction(index: Int)

    public var description: String {
        switch self {
        case let .unusedInteractions(cassetteName, used, total):
            return "Unused recorded interactions in \(cassetteName): used \(used) of \(total)"
        case .unavailableInteraction:
            return "Replay selected an unavailable interaction"
        }
    }
}

/// Pool-based replay tracker supporting atomic out-of-order and concurrent claiming of recorded interactions.
// parity: http-recorder/src/replay/state.ts#ReplayPoolState [status=implemented hash=eac312cda8ec]
public actor ReplayPoolState<T: Sendable> {
    private let cassette: any CassetteStoreInterface
    private let name: String
    private let project: @Sendable ([Interaction]) -> [T]

    private var loadTask: Task<[T], any Error>?
    private var used: Set<Int> = []
    private var attempted: Bool = false

    public init(
        cassette: any CassetteStoreInterface,
        name: String,
        project: @escaping @Sendable ([Interaction]) -> [T]
    ) {
        self.cassette = cassette
        self.name = name
        self.project = project
    }

    private func loadInteractions() async throws -> [T] {
        if let loadTask {
            return try await loadTask.value
        }
        let cassetteRef = self.cassette
        let cassetteName = self.name
        let projectFn = self.project
        let task = Task<[T], any Error> {
            let raw = try await cassetteRef.read(cassetteName)
            return projectFn(raw)
        }
        self.loadTask = task
        return try await task.value
    }

    /// Atomically selects and marks one unused recorded interaction as consumed.
    /// If `select` throws, no interaction is consumed.
    public func claim(
        _ select: @Sendable ([T], Set<Int>) throws -> Int
    ) async throws -> ReplayClaim<T> {
        attempted = true
        let interactions = try await loadInteractions()
        let index = try select(interactions, used)
        guard index >= 0 && index < interactions.count && !used.contains(index) else {
            throw ReplayStateError.unavailableInteraction(index: index)
        }
        used.insert(index)
        return ReplayClaim(interaction: interactions[index], index: index)
    }

    /// Returns the number of interactions claimed so far.
    public var usedCount: Int {
        used.count
    }

    /// Verifies that every recorded interaction in the cassette was consumed.
    /// Mirrors upstream's scope finalizer: skips when the first claim failed before consuming any interaction,
    /// and ignores missing cassettes when nothing was attempted.
    public func verifyAllConsumed() async throws {
        if used.isEmpty && attempted {
            return
        }
        let interactions: [T]
        do {
            interactions = try await loadInteractions()
        } catch is CassetteNotFoundError {
            return
        }
        if used.count < interactions.count {
            throw ReplayStateError.unusedInteractions(
                cassetteName: name,
                used: used.count,
                total: interactions.count
            )
        }
    }
}

/// Sequential replay tracker that validates and consumes interactions strictly in recorded order.
// parity: http-recorder/src/replay/state.ts#ReplayState [status=implemented hash=b9acc0b5e531]
public struct ReplayState<T: Sendable>: Sendable {
    private let pool: ReplayPoolState<T>

    public init(pool: ReplayPoolState<T>) {
        self.pool = pool
    }

    /// Validates the next unconsumed interaction at `index == used.count` and claims it if valid.
    public func claim(
        _ validate: @Sendable (_ interaction: T?, _ index: Int, _ interactions: [T]) throws -> Void
    ) async throws -> ReplayClaim<T> {
        try await pool.claim { interactions, used in
            let index = used.count
            let candidate = index < interactions.count ? interactions[index] : nil
            try validate(candidate, index, interactions)
            return index
        }
    }

    public func verifyAllConsumed() async throws {
        try await pool.verifyAllConsumed()
    }
}

/// Constructs a `ReplayPoolState` backed by `cassette` and projected by `project`.
// parity: http-recorder/src/replay/state.ts#makeReplayPoolState [status=implemented hash=9a3fa9907ee3]
public func makeReplayPoolState<T: Sendable>(
    cassette: any CassetteStoreInterface,
    name: String,
    project: @escaping @Sendable ([Interaction]) -> [T]
) -> ReplayPoolState<T> {
    ReplayPoolState(cassette: cassette, name: name, project: project)
}

/// Constructs a sequential `ReplayState` backed by `cassette` and projected by `project`.
// parity: http-recorder/src/replay/state.ts#makeReplayState [status=implemented hash=d9baad7886ac]
public func makeReplayState<T: Sendable>(
    cassette: any CassetteStoreInterface,
    name: String,
    project: @escaping @Sendable ([Interaction]) -> [T]
) -> ReplayState<T> {
    ReplayState(pool: makeReplayPoolState(cassette: cassette, name: name, project: project))
}
