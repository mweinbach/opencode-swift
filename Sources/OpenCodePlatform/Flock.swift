#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeUtil

// parity: util/src/flock.ts#FlockGlobal [status=implemented hash=bdde41bbbfd8]
public struct FlockGlobal: Equatable, Hashable, Sendable, Codable {
    public let state: String

    public init(state: String) {
        self.state = state
    }
}

/// Cross-platform atomic lock-directory mutex with stale-lock breaker & heartbeat
/// matching `packages/util/src/flock.ts`.
// parity: util/src/flock.ts#Flock [status=implemented hash=2a891a8a2fc7]
public enum Flock {
    // parity: util/src/flock.ts#Flock.WaitEvent [status=implemented hash=74ccb8545e32]
    public struct WaitEvent: Equatable, Hashable, Sendable {
        public let key: String
        public let attempt: Int
        public let delay: Int
        public let waited: Int

        public init(key: String, attempt: Int, delay: Int, waited: Int) {
            self.key = key
            self.attempt = attempt
            self.delay = delay
            self.waited = waited
        }
    }

    // parity: util/src/flock.ts#Flock.Wait [status=implemented hash=777e07a5676c]
    public typealias Wait = @Sendable (WaitEvent) async -> Void

    // parity: util/src/flock.ts#Flock.Options [status=implemented hash=b07b03fcbc8b]
    public struct Options: Sendable {
        public let dir: String?
        public let signal: AbortSignal?
        public let staleMs: Int
        public let timeoutMs: Int
        public let baseDelayMs: Int
        public let maxDelayMs: Int
        public let onWait: Wait?

        public init(
            dir: String? = nil,
            signal: AbortSignal? = nil,
            staleMs: Int = 60_000,
            timeoutMs: Int = 5 * 60_000,
            baseDelayMs: Int = 100,
            maxDelayMs: Int = 2_000,
            onWait: Wait? = nil
        ) {
            self.dir = dir
            self.signal = signal
            self.staleMs = staleMs
            self.timeoutMs = timeoutMs
            self.baseDelayMs = baseDelayMs
            self.maxDelayMs = maxDelayMs
            self.onWait = onWait
        }
    }

    // parity: util/src/flock.ts#Flock.Lease [status=implemented hash=9aa8eb520102]
    public struct Lease: Sendable {
        private let releaseImpl: @Sendable () async throws -> Void

        public init(release: @escaping @Sendable () async throws -> Void) {
            self.releaseImpl = release
        }

        public func release() async throws {
            try await releaseImpl()
        }
    }

    private static let globalState = Mutex<FlockGlobal?>(nil)

    // parity: util/src/flock.ts#Flock.setGlobal [status=implemented hash=cfd65ca1b154]
    public static func setGlobal(_ global: FlockGlobal) {
        globalState.withLock { $0 = global }
    }

    public static func currentEpochMs() -> Int64 {
        #if os(WASI)
        return 0
        #else
        return Int64((Date().timeIntervalSince1970 * 1_000.0).rounded())
        #endif
    }

    /// Acquires an exclusive lock directory for `key` with stale recovery, exponential backoff, and heartbeat.
    // parity: util/src/flock.ts#Flock.acquire [status=implemented hash=ee502e5c3024]
    public static func acquire(
        _ key: String,
        options: Options = Options(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        nowMs: @escaping @Sendable () -> Int64 = { currentEpochMs() }
    ) async throws -> Lease {
        let baseDir: String
        if let explicitDir = options.dir {
            baseDir = explicitDir
        } else if let global = globalState.withLock({ $0 }) {
            baseDir = "\(global.state)/locks"
        } else {
            throw EffectFlock.LockCompromisedError(detail: "Flock global not set")
        }

        try await fileSystem.makeDirectory(at: baseDir, recursive: true)
        let lockDir = "\(baseDir)/\(Hash.sha256(key)).lock"
        let startedAt = nowMs()
        var attempt = 0
        var delayMs = options.baseDelayMs

        while true {
            if let signal = options.signal, signal.isAborted {
                throw signal.reason ?? AbortError.sharedReason
            }
            if let lease = try await tryAcquireLockDir(
                lockDir: lockDir,
                staleMs: options.staleMs,
                fileSystem: fileSystem,
                nowMs: nowMs
            ) {
                return lease
            }

            let waited = Int(max(0, nowMs() - startedAt))
            if waited >= options.timeoutMs {
                throw EffectFlock.LockTimeoutError(key: key)
            }
            attempt += 1
            let sleepMs = min(delayMs, max(1, options.timeoutMs - waited))
            if let onWait = options.onWait {
                await onWait(WaitEvent(key: key, attempt: attempt, delay: sleepMs, waited: waited))
            }
            try await Task.sleep(for: .milliseconds(sleepMs))
            delayMs = min(options.maxDelayMs, Int((Double(delayMs) * 1.7).rounded()))
        }
    }

    /// Runs `body` while holding an exclusive lock for `key`, guaranteeing release on exit.
    // parity: util/src/flock.ts#Flock.withLock [status=implemented hash=7ef59d710f47]
    public static func withLock<T: Sendable>(
        _ key: String,
        options: Options = Options(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        let lease = try await acquire(key, options: options, fileSystem: fileSystem)
        do {
            let value = try await body()
            try await lease.release()
            return value
        } catch {
            try? await lease.release()
            throw error
        }
    }

    internal static func tryAcquireLockDir(
        lockDir: String,
        staleMs: Int,
        fileSystem: any OpenCodeFileSystem,
        nowMs: @escaping @Sendable () -> Int64
    ) async throws -> Lease? {
        let token = uuid()
        let metaPath = "\(lockDir)/meta.json"
        let heartbeatPath = "\(lockDir)/heartbeat"

        let created: Bool
        do {
            try await fileSystem.makeDirectory(at: lockDir, recursive: false)
            created = true
        } catch PlatformError.alreadyExists {
            created = false
        }

        if !created {
            guard await isStale(
                lockDir: lockDir,
                heartbeatPath: heartbeatPath,
                metaPath: metaPath,
                staleMs: staleMs,
                fileSystem: fileSystem,
                nowMs: nowMs
            ) else {
                return nil
            }

            let breakerPath = "\(lockDir).breaker"
            let claimedBreaker: Bool
            do {
                try await fileSystem.makeDirectory(at: breakerPath, recursive: false)
                claimedBreaker = true
            } catch PlatformError.alreadyExists {
                if let bStat = try? await fileSystem.stat(at: breakerPath),
                   nowMs() - bStat.modifiedAtMs > Int64(staleMs) {
                    try? await fileSystem.remove(at: breakerPath)
                }
                claimedBreaker = false
            } catch PlatformError.notFound {
                claimedBreaker = false
            }

            guard claimedBreaker else { return nil }
            let reacquired: Bool
            do {
                guard await isStale(
                    lockDir: lockDir,
                    heartbeatPath: heartbeatPath,
                    metaPath: metaPath,
                    staleMs: staleMs,
                    fileSystem: fileSystem,
                    nowMs: nowMs
                ) else {
                    try? await fileSystem.remove(at: breakerPath)
                    return nil
                }

                try? await fileSystem.remove(at: lockDir)
                do {
                    try await fileSystem.makeDirectory(at: lockDir, recursive: false)
                    reacquired = true
                } catch PlatformError.alreadyExists {
                    reacquired = false
                }
            } catch {
                try? await fileSystem.remove(at: breakerPath)
                throw error
            }
            try? await fileSystem.remove(at: breakerPath)
            guard reacquired else { return nil }
        }

        do {
            try await fileSystem.writeFileExclusive([], to: heartbeatPath)
        } catch {
            try? await fileSystem.remove(at: lockDir)
            throw EffectFlock.LockCompromisedError(detail: "Lock acquired but heartbeat already existed (possible compromise).")
        }

        let metaPayload = "{\"token\":\"\(token)\",\"createdAtMs\":\(nowMs())}"
        do {
            try await fileSystem.writeFileExclusive(Array(metaPayload.utf8), to: metaPath)
        } catch {
            try? await fileSystem.remove(at: lockDir)
            throw EffectFlock.LockCompromisedError(detail: "Lock acquired but meta.json already existed (possible compromise).")
        }

        let heartbeatInterval = max(100, staleMs / 3)
        let heartbeatTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(heartbeatInterval))
                if Task.isCancelled { break }
                try? await fileSystem.setModificationTime(at: heartbeatPath, epochMs: nowMs())
            }
        }

        let released = Mutex(false)
        return Lease {
            let shouldRelease = released.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            guard shouldRelease else { return }
            heartbeatTask.cancel()
            if let bytes = try? await fileSystem.readFile(at: metaPath),
               let json = PureJSON.parse(String(decoding: bytes, as: UTF8.self)),
               case .object(let entries) = json,
               let storedToken = entries.first(where: { $0.0 == "token" })?.1,
               case .string(let actual) = storedToken,
               actual != token {
                throw EffectFlock.LockCompromisedError(detail: "Lock ownership changed before release")
            }
            try? await fileSystem.remove(at: lockDir)
        }
    }

    private static func isStale(
        lockDir: String,
        heartbeatPath: String,
        metaPath: String,
        staleMs: Int,
        fileSystem: any OpenCodeFileSystem,
        nowMs: @Sendable () -> Int64
    ) async -> Bool {
        let now = nowMs()
        if let hb = try? await fileSystem.stat(at: heartbeatPath) {
            return now - hb.modifiedAtMs > Int64(staleMs)
        }
        if let meta = try? await fileSystem.stat(at: metaPath) {
            return now - meta.modifiedAtMs > Int64(staleMs)
        }
        if let dir = try? await fileSystem.stat(at: lockDir) {
            return now - dir.modifiedAtMs > Int64(staleMs)
        }
        return false
    }
}

/// Service-injected flock abstraction matching `packages/util/src/effect-flock.ts`.
// parity: util/src/effect-flock.ts#EffectFlock [status=implemented hash=10da3a02061c]
public enum EffectFlock {
    // parity: util/src/effect-flock.ts#EffectFlock.LockTimeoutError [status=implemented hash=99a198d0e976]
    public struct LockTimeoutError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let key: String

        public init(key: String) {
            self.key = key
        }

        public var description: String { "LockTimeoutError: timed out acquiring lock '\(key)'" }
    }

    // parity: util/src/effect-flock.ts#EffectFlock.LockCompromisedError [status=implemented hash=5f2400a5b830]
    public struct LockCompromisedError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        public let detail: String

        public init(detail: String) {
            self.detail = detail
        }

        public var description: String { "LockCompromisedError: \(detail)" }
    }

    // parity: util/src/effect-flock.ts#EffectFlock.LockError [status=implemented hash=cfffac0f0f43]
    public enum LockError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
        case timeout(LockTimeoutError)
        case compromised(LockCompromisedError)

        public var description: String {
            switch self {
            case .timeout(let err): return err.description
            case .compromised(let err): return err.description
            }
        }
    }

    // parity: util/src/effect-flock.ts#EffectFlock.Options [status=implemented hash=4bb6b62d1ce3]
    public struct Options: Equatable, Hashable, Sendable {
        public let staleMs: Int?
        public let timeoutMs: Int?

        public init(staleMs: Int? = nil, timeoutMs: Int? = nil) {
            self.staleMs = staleMs
            self.timeoutMs = timeoutMs
        }
    }

    // parity: util/src/effect-flock.ts#EffectFlock.Interface [status=implemented hash=4d38bddc4e28]
    public protocol Interface: Sendable {
        func acquire(key: String, dir: String?, options: Options?) async throws -> Flock.Lease
        func withLock<T: Sendable>(key: String, dir: String?, body: @Sendable () async throws -> T) async throws -> T
    }

    // parity: util/src/effect-flock.ts#EffectFlock.Service [status=implemented hash=38947169279d]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "EffectFlock"
        private let lockRoot: String
        private let fileSystem: any OpenCodeFileSystem

        public init(lockRoot: String, fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared) {
            self.lockRoot = lockRoot
            self.fileSystem = fileSystem
        }

        public func acquire(key: String, dir: String? = nil, options: Options? = nil) async throws -> Flock.Lease {
            try await Flock.acquire(
                key,
                options: Flock.Options(
                    dir: dir ?? lockRoot,
                    staleMs: options?.staleMs ?? 60_000,
                    timeoutMs: options?.timeoutMs ?? 5 * 60_000
                ),
                fileSystem: fileSystem
            )
        }

        public func withLock<T: Sendable>(
            key: String,
            dir: String? = nil,
            body: @Sendable () async throws -> T
        ) async throws -> T {
            let lease = try await acquire(key: key, dir: dir, options: nil)
            do {
                let result = try await body()
                try await lease.release()
                return result
            } catch {
                try? await lease.release()
                throw error
            }
        }
    }

    // parity: util/src/effect-flock.ts#EffectFlock.node [status=implemented hash=48efd3a37f87]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths ?? Global.make()
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self)
            let fs = fsUtil?.fileSystem ?? LocalFileSystem.shared
            return LayerNode.Output([Service.serviceKey: Service(lockRoot: "\(global.state)/locks", fileSystem: fs)])
        },
        [Global.node, FSUtil.node]
    )
}
