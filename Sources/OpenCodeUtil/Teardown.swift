import Synchronization

/// Tracks in-flight shutdown/teardown work so deadlines can report which tasks kept the process alive.
public enum Teardown {
    public struct PendingEntry: Equatable, Hashable, Sendable, Codable {
        public let label: String
        public let ms: Int64

        public init(label: String, ms: Int64) {
            self.label = label
            self.ms = ms
        }
    }

    private struct StoredEntry: Sendable {
        let id: UInt64
        let label: String
        let since: Int64
    }

    private struct State: Sendable {
        var nextID: UInt64 = 1
        var entries: [StoredEntry] = []
    }

    private static let state = Mutex(State())

    /// Records pending teardown work; invoke the returned closure once it settles.
    // parity: util/src/teardown.ts#track [status=implemented hash=0ab66b37ce02]
    public static func track(_ label: String, now: Int64? = nil) -> @Sendable () -> Void {
        let timestamp = now ?? currentMonotonicMillis()
        let id = state.withLock { s -> UInt64 in
            let id = s.nextID
            s.nextID += 1
            s.entries.append(StoredEntry(id: id, label: label, since: timestamp))
            return id
        }
        return {
            state.withLock { s in
                s.entries.removeAll { $0.id == id }
            }
        }
    }

    /// Pending teardown work, oldest first, with elapsed milliseconds for each entry.
    // parity: util/src/teardown.ts#pending [status=implemented hash=1e50b67cc5d1]
    public static func pending(now: Int64? = nil) -> [PendingEntry] {
        let timestamp = now ?? currentMonotonicMillis()
        return state.withLock { s in
            s.entries.map { PendingEntry(label: $0.label, ms: timestamp - $0.since) }
        }
    }

    /// Clears all tracked entries (intended for test isolation).
    public static func reset() {
        state.withLock { $0.entries.removeAll() }
    }

    private static func currentMonotonicMillis() -> Int64 {
        let elapsed = clockOrigin.duration(to: ContinuousClock.now)
        let (secs, atto) = elapsed.components
        return secs * 1_000 + atto / 1_000_000_000_000_000
    }

    private static let clockOrigin: ContinuousClock.Instant = .now
}
