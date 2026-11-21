#if os(WASI)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform
import OpenCodeTUI
import OpenCodeUtil

/// Foundation/Filesystem/Mock helpers kept outside `import Testing` files per the macOS CLT cross-import rule.
enum TUIAttentionAudioTestHelper {
    #if !os(WASI)
    static func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func readFileBytes(at path: String) -> [UInt8]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return Array(data)
    }

    static func bundledResourcePath(for kind: TUIAttentionAudio.SoundKind) -> String? {
        TUIAttentionAudio.bundledSoundURL(for: kind, in: TUIAttentionAudio.resourceBundle)?.path
    }

    /// Creates a temporary flattened `.bundle` directory containing a copied `.mp3` at its root
    /// so tests can verify `bundledSoundURL` fallback from `Resources/Audio` to flattened lookup.
    static func withFlattenedBundle(
        containing kind: TUIAttentionAudio.SoundKind,
        body: (String?) throws -> Void
    ) throws {
        let rootDir = "\(SystemEnvironment.shared.temporaryDirectory)/opencode-flat-audio-\(uuid()).bundle"
        let fm = FileManager.default
        try fm.createDirectory(atPath: rootDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: rootDir) }

        guard let bytes = TUIAttentionAudio.bundledSoundBytes(for: kind) else {
            try body(nil)
            return
        }
        let target = "\(rootDir)/\(kind.filename)"
        try Data(bytes).write(to: URL(fileURLWithPath: target))

        let bundle = Bundle(path: rootDir)
        let resolved = bundle.flatMap { TUIAttentionAudio.bundledSoundURL(for: kind, in: $0)?.path }
        try body(resolved)
    }

    static func withTemporaryFile(
        named filename: String,
        bytes: [UInt8],
        body: (String) async throws -> Void
    ) async throws {
        let dir = "\(SystemEnvironment.shared.temporaryDirectory)/opencode-audio-test-\(uuid())"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        let filePath = "\(dir)/\(filename)"
        try Data(bytes).write(to: URL(fileURLWithPath: filePath))
        try await body(filePath)
    }
    #endif

    /// Recording mock `ProcessSpawner` supporting immediate return, errors, and explicit async gating
    /// to deterministically verify non-blocking playback without flaky sleeps.
    final class MockProcessSpawner: ProcessSpawner, Sendable {
        struct State: Sendable {
            var recordedSpecs: [ProcessSpec] = []
            var startedCount: Int = 0
            var completedCount: Int = 0
            var cancelledCount: Int = 0
            var shouldThrow: Bool = false
            var exitCode: Int32 = 0
            var blockExecution: Bool = false
            var released: Bool = false
            var startWaiters: [CheckedContinuation<Void, Never>] = []
            var gateWaiters: [CheckedContinuation<Void, any Error>] = []
        }

        private let state: Mutex<State>

        init(blockExecution: Bool = false, shouldThrow: Bool = false, exitCode: Int32 = 0) {
            self.state = Mutex(State(
                shouldThrow: shouldThrow,
                exitCode: exitCode,
                blockExecution: blockExecution
            ))
        }

        var specs: [ProcessSpec] {
            state.withLock { $0.recordedSpecs }
        }

        var startedCount: Int {
            state.withLock { $0.startedCount }
        }

        var completedCount: Int {
            state.withLock { $0.completedCount }
        }

        var cancelledCount: Int {
            state.withLock { $0.cancelledCount }
        }

        @discardableResult
        func waitUntilStarted(count: Int = 1, timeoutMs: Int = 5_000) async -> Bool {
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while state.withLock({ $0.startedCount < count }) {
                if ContinuousClock.now >= deadline {
                    return false
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }

        func release() {
            let waiters = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
                s.released = true
                let pending = s.gateWaiters
                s.gateWaiters.removeAll()
                return pending
            }
            for waiter in waiters {
                waiter.resume()
            }
        }

        func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
            let (shouldBlock, shouldThrow, exitCode, startWaiters) = state.withLock {
                s -> (Bool, Bool, Int32, [CheckedContinuation<Void, Never>]) in
                s.recordedSpecs.append(spec)
                s.startedCount += 1
                let waiters = s.startWaiters
                s.startWaiters.removeAll()
                return (s.blockExecution && !s.released, s.shouldThrow, s.exitCode, waiters)
            }
            for waiter in startWaiters {
                waiter.resume()
            }

            if shouldBlock {
                do {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                            let immediateResult = state.withLock { s -> Int in
                                if Task.isCancelled { return 2 }
                                if s.released { return 1 }
                                s.gateWaiters.append(cont)
                                return 0
                            }
                            if immediateResult == 1 {
                                cont.resume()
                            } else if immediateResult == 2 {
                                cont.resume(throwing: CancellationError())
                            }
                        }
                    } onCancel: {
                        let waiters = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
                            s.cancelledCount += 1
                            let pending = s.gateWaiters
                            s.gateWaiters.removeAll()
                            return pending
                        }
                        for waiter in waiters {
                            waiter.resume(throwing: CancellationError())
                        }
                    }
                } catch {
                    throw error
                }
            }

            if shouldThrow {
                state.withLock { $0.completedCount += 1 }
                throw PlatformError.ioFailure("Simulated audio playback failure")
            }

            state.withLock { $0.completedCount += 1 }
            return ProcessOutput(exitCode: exitCode, stdout: [], stderr: [])
        }
    }

    /// Mock `TUIAttention.AttentionRenderer` for deterministic focus/blur/notification verification.
    final class MockAttentionRenderer: TUIAttention.AttentionRenderer, Sendable {
        private struct State: Sendable {
            var destroyed: Bool = false
            var focusListeners: [@Sendable () -> Void] = []
            var blurListeners: [@Sendable () -> Void] = []
            var notifications: [(message: String, title: String?)] = []
        }

        private let state = Mutex(State())

        var isDestroyed: Bool {
            get { state.withLock { $0.destroyed } }
            set { state.withLock { $0.destroyed = newValue } }
        }

        var notifications: [(message: String, title: String?)] {
            state.withLock { $0.notifications }
        }

        func addFocusListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            state.withLock { $0.focusListeners.append(listener) }
            return {}
        }

        func addBlurListener(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            state.withLock { $0.blurListeners.append(listener) }
            return {}
        }

        func triggerNotification(_ message: String, title: String?) -> Bool {
            state.withLock { $0.notifications.append((message, title)) }
            return true
        }

        func emitFocus() {
            let listeners = state.withLock { $0.focusListeners }
            for listener in listeners { listener() }
        }

        func emitBlur() {
            let listeners = state.withLock { $0.blurListeners }
            for listener in listeners { listener() }
        }
    }
}
