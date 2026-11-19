import Synchronization

/// Process-stable observability run identifier matching `util/src/observability/shared.ts`.
public enum ObservabilityShared {
    private static let generated = Mutex<String?>(nil)

    /// Lazily generates and caches an 8-character UUID prefix for the current process run.
    // parity: util/src/observability/shared.ts#runID [status=implemented hash=50a88adcd5e5]
    public static func runID() -> String {
        generated.withLock { current in
            if let current { return current }
            let next = String(uuid().prefix(8))
            current = next
            return next
        }
    }

    /// Resets the cached run ID (intended for test isolation).
    public static func resetRunID() {
        generated.withLock { $0 = nil }
    }
}
