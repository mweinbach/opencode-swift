#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Service Types (packages/client/src/service.ts)

/// Basic HTTP authentication credentials for a local OpenCode service.
public struct ServiceBasicAuth: Equatable, Hashable, Sendable, Codable {
    public let type: String
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.type = "basic"
        self.username = username
        self.password = password
    }
}

/// Connection details for a local OpenCode service.
// parity: client/src/service.ts#Endpoint [status=implemented hash=dddb0ff2aa66]
public struct ServiceEndpoint: Equatable, Hashable, Sendable, Codable {
    public let url: String
    public let auth: ServiceBasicAuth?

    public init(url: String, auth: ServiceBasicAuth? = nil) {
        self.url = url
        self.auth = auth
    }
}

/// Version constraint for local service discovery.
public enum ServiceVersionRequirement: Sendable {
    case exact(String)
    case predicate(@Sendable (String) -> Bool)
}

/// Options used to discover the local OpenCode service.
// parity: client/src/service.ts#DiscoverOptions [status=implemented hash=420a6d9e3fe0]
public struct ServiceDiscoverOptions: Sendable {
    public let file: String?
    public let version: ServiceVersionRequirement?
    public var timing: EnsureTiming?

    public init(
        file: String? = nil,
        version: ServiceVersionRequirement? = nil,
        timing: EnsureTiming? = nil
    ) {
        self.file = file
        self.version = version
        self.timing = timing
    }
}

/// Reason ensuring the service requires a new process.
// parity: client/src/service.ts#EnsureReason [status=implemented hash=6094d3b9656d]
public enum ServiceEnsureReason: String, Equatable, Hashable, Sendable, Codable {
    case missing
    case versionMismatch = "version-mismatch"
}

/// How to handle persistent terminals before stopping the service.
public enum ServicePtyStopMode: String, Equatable, Hashable, Sendable, Codable {
    case clear
    case handoff
}

/// Options used to ensure the local OpenCode service is running.
// parity: client/src/service.ts#EnsureOptions [status=implemented hash=304214b0de68]
public struct ServiceEnsureOptions: Sendable {
    public let file: String?
    public let version: ServiceVersionRequirement?
    public let command: [String]?
    public let env: [String: String]?
    public let onStart: (@Sendable (ServiceEnsureReason, String?) -> Void)?
    public var timing: EnsureTiming?

    public init(
        file: String? = nil,
        version: ServiceVersionRequirement? = nil,
        command: [String]? = nil,
        env: [String: String]? = nil,
        onStart: (@Sendable (ServiceEnsureReason, String?) -> Void)? = nil,
        timing: EnsureTiming? = nil
    ) {
        self.file = file
        self.version = version
        self.command = command
        self.env = env
        self.onStart = onStart
        self.timing = timing
    }

    public var discoverOptions: ServiceDiscoverOptions {
        ServiceDiscoverOptions(file: file, version: version, timing: timing)
    }
}

/// Options used to stop the local OpenCode service.
// parity: client/src/service.ts#StopOptions [status=implemented hash=b637633af48b]
public struct ServiceStopOptions: Sendable {
    public let file: String?
    public let pty: ServicePtyStopMode?
    public var timing: EnsureTiming?

    public init(
        file: String? = nil,
        pty: ServicePtyStopMode? = nil,
        timing: EnsureTiming? = nil
    ) {
        self.file = file
        self.pty = pty
        self.timing = timing
    }
}

/// Contents of the local service registration file.
// parity: client/src/service.ts#Info [status=implemented hash=b001353e6f63]
public struct ServiceInfo: Equatable, Hashable, Sendable, Codable {
    public let id: String?
    public let version: String?
    public let url: String
    public let pid: Int
    public let password: String?

    public init(
        id: String? = nil,
        version: String? = nil,
        url: String,
        pid: Int,
        password: String? = nil
    ) {
        self.id = id
        self.version = version
        self.url = url
        self.pid = pid
        self.password = password
    }
}

// MARK: - Service Timing (packages/client/src/service-timing.ts)

/// Timing parameters for background service discovery, probing, contention, and shutdown.
// parity: client/src/service-timing.ts#EnsureTiming [status=implemented hash=0f1915e55910]
public struct EnsureTiming: Equatable, Hashable, Sendable, Codable {
    public let pollInterval: Int64
    public let requestTimeout: Int64
    public let spawnDelay: Int64
    public let maxSpawnDelay: Int64
    public let promiseTimeout: Int64
    public let stopPollInterval: Int64
    public let stopPollAttempts: Int

    public init(
        pollInterval: Int64 = 25,
        requestTimeout: Int64 = 2_000,
        spawnDelay: Int64 = 5_000,
        maxSpawnDelay: Int64 = 30_000,
        promiseTimeout: Int64 = 120_000,
        stopPollInterval: Int64 = 50,
        stopPollAttempts: Int = 100
    ) {
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
        self.spawnDelay = spawnDelay
        self.maxSpawnDelay = maxSpawnDelay
        self.promiseTimeout = promiseTimeout
        self.stopPollInterval = stopPollInterval
        self.stopPollAttempts = stopPollAttempts
    }
}

/// Overrides struct for `withEnsureTiming`.
public struct EnsureTimingOverrides: Equatable, Hashable, Sendable {
    public let pollInterval: Int64?
    public let requestTimeout: Int64?
    public let spawnDelay: Int64?
    public let maxSpawnDelay: Int64?
    public let promiseTimeout: Int64?
    public let stopPollInterval: Int64?
    public let stopPollAttempts: Int?

    public init(
        pollInterval: Int64? = nil,
        requestTimeout: Int64? = nil,
        spawnDelay: Int64? = nil,
        maxSpawnDelay: Int64? = nil,
        promiseTimeout: Int64? = nil,
        stopPollInterval: Int64? = nil,
        stopPollAttempts: Int? = nil
    ) {
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
        self.spawnDelay = spawnDelay
        self.maxSpawnDelay = maxSpawnDelay
        self.promiseTimeout = promiseTimeout
        self.stopPollInterval = stopPollInterval
        self.stopPollAttempts = stopPollAttempts
    }

    public func applying(to base: EnsureTiming = defaultEnsureTiming) -> EnsureTiming {
        EnsureTiming(
            pollInterval: pollInterval ?? base.pollInterval,
            requestTimeout: requestTimeout ?? base.requestTimeout,
            spawnDelay: spawnDelay ?? base.spawnDelay,
            maxSpawnDelay: maxSpawnDelay ?? base.maxSpawnDelay,
            promiseTimeout: promiseTimeout ?? base.promiseTimeout,
            stopPollInterval: stopPollInterval ?? base.stopPollInterval,
            stopPollAttempts: stopPollAttempts ?? base.stopPollAttempts
        )
    }
}

/// Protocol implemented by lifecycle option types carrying optional test timing overrides.
public protocol EnsureTimingConfigurable: Sendable {
    var timing: EnsureTiming? { get set }
}

extension ServiceDiscoverOptions: EnsureTimingConfigurable {}
extension ServiceEnsureOptions: EnsureTimingConfigurable {}
extension ServiceStopOptions: EnsureTimingConfigurable {}

/// Default timing values matching upstream `defaultEnsureTiming`.
// parity: client/src/service-timing.ts#defaultEnsureTiming [status=implemented hash=c3e0bc3d8e2e]
public let defaultEnsureTiming = EnsureTiming(
    pollInterval: 25,
    requestTimeout: 2_000,
    spawnDelay: 5_000,
    maxSpawnDelay: 30_000,
    promiseTimeout: 120_000,
    stopPollInterval: 50,
    stopPollAttempts: 100
)

/// Reads the timing overrides associated with `options`, falling back to `defaultEnsureTiming`.
// parity: client/src/service-timing.ts#ensureTiming [status=implemented hash=5e83787ff4db]
public func ensureTiming<Options: EnsureTimingConfigurable>(_ options: Options) -> EnsureTiming {
    options.timing ?? defaultEnsureTiming
}

/// Returns a copy of `options` with `overrides` applied on top of `defaultEnsureTiming`.
// parity: client/src/service-timing.ts#withEnsureTiming [status=implemented hash=7a1b8624de25]
public func withEnsureTiming<Options: EnsureTimingConfigurable>(
    _ options: Options,
    overrides: EnsureTimingOverrides
) -> Options {
    var copy = options
    copy.timing = overrides.applying(to: defaultEnsureTiming)
    return copy
}

// MARK: - Service Version Matching (packages/client/src/service-version.ts)

/// Returns whether a service's advertised `version` satisfies `options.version`.
// parity: client/src/service-version.ts#matchesVersion [status=implemented hash=50d304c54dae]
public func matchesVersion(_ version: String?, options: ServiceDiscoverOptions) -> Bool {
    guard let requirement = options.version else { return true }
    guard let version else { return false }
    switch requirement {
    case .exact(let expected):
        return version == expected
    case .predicate(let check):
        return check(version)
    }
}

// MARK: - Service Probing & Decision (packages/client/src/service-probe.ts)

public enum LocalServiceState: String, Equatable, Hashable, Sendable, Codable {
    case ready
    case waiting
    case failed
}

/// Probed state of a registered local OpenCode service.
// parity: client/src/service-probe.ts#LocalService [status=implemented hash=8fa2bdbfb81f]
public struct LocalService: Equatable, Hashable, Sendable {
    public let info: ServiceInfo
    public let endpoint: ServiceEndpoint
    public let version: String?
    public let state: LocalServiceState
    public let compatible: Bool

    public init(
        info: ServiceInfo,
        endpoint: ServiceEndpoint,
        version: String? = nil,
        state: LocalServiceState,
        compatible: Bool
    ) {
        self.info = info
        self.endpoint = endpoint
        self.version = version
        self.state = state
        self.compatible = compatible
    }
}

public struct ServiceLifecycleError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Error marker an `HTTPTransport` can throw to indicate a request timeout.
public struct ServiceProbeTimeoutError: Error, Equatable, Hashable, Sendable {
    public init() {}
}

/// Decision returned by `decide(_:options:)` for a registered service that answered.
public enum ServiceDecision: Equatable, Hashable, Sendable {
    case reuse
    case wait
    case replace(pty: ServicePtyStopMode)
    case fail(ServiceLifecycleError)
}

/// Result of probing a registered local service over HTTP.
public struct ServiceProbeResult: Equatable, Hashable, Sendable {
    public let service: LocalService?
    public let timedOut: Bool

    public init(service: LocalService?, timedOut: Bool) {
        self.service = service
        self.timedOut = timedOut
    }
}

/// What `ensure()` does with a registered service that answered: return it, keep polling while
/// it starts, replace it because its version does not meet the requirement, or fail.
// parity: client/src/service-probe.ts#decide [status=implemented hash=5876e8fe7367]
public func decide(_ service: LocalService, options: ServiceDiscoverOptions) -> ServiceDecision {
    if !matchesVersion(service.version, options: options) {
        return .replace(pty: service.state == .ready ? .handoff : .clear)
    }
    if !service.compatible {
        return .fail(
            ServiceLifecycleError(
                "Background service uses an incompatible health protocol. Update this client or explicitly restart the service."
            )
        )
    }
    if service.state == .ready { return .reuse }
    if service.state == .failed { return .fail(ServiceLifecycleError("Background service failed to start")) }
    return .wait
}

/// The default registration file (`$XDG_STATE_HOME/opencode/service.json` or `~/.local/state/opencode/service.json`).
// parity: client/src/service-probe.ts#fallback [status=implemented hash=8f495cdfa055]
public func fallback(environment: any EnvironmentProviding = SystemEnvironment.shared) -> String {
    let base: String
    if let xdg = environment.variable("XDG_STATE_HOME"), !xdg.isEmpty {
        base = xdg
    } else {
        let home = environment.homeDirectory ?? ""
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        base = trimmedHome + "/.local/state"
    }
    let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
    return trimmedBase + "/opencode/service.json"
}

/// Whether two registrations describe the same service instance.
// parity: client/src/service-probe.ts#same [status=implemented hash=2b678b9d33da]
public func same(_ left: ServiceInfo, _ right: ServiceInfo) -> Bool {
    left.id == right.id
        && left.version == right.version
        && left.url == right.url
        && left.pid == right.pid
}

/// Create HTTP authentication headers for a service endpoint.
// parity: client/src/service-probe.ts#headers [status=implemented hash=08586d9b4582]
public func headers(for endpoint: ServiceEndpoint) -> [String: String]? {
    guard let auth = endpoint.auth else { return nil }
    return [
        "authorization": ClientHTTPHeaders.basicAuthorization(username: auth.username, password: auth.password),
    ]
}

internal func serviceProbeFallback(environment: any EnvironmentProviding) -> String {
    fallback(environment: environment)
}

internal func serviceProbeHeaders(for endpoint: ServiceEndpoint) -> [String: String]? {
    headers(for: endpoint)
}

/// Ask a registered owner for its health and classify the answer via `HTTPTransport`.
// parity: client/src/service-probe.ts#probeResult [status=implemented hash=55161d51e500]
public func probeResult(
    _ info: ServiceInfo,
    timeoutMs: Int64 = defaultEnsureTiming.requestTimeout,
    transport: any HTTPTransport
) async -> ServiceProbeResult {
    let endpoint = ServiceEndpoint(
        url: info.url,
        auth: info.password.map { ServiceBasicAuth(username: "opencode", password: $0) }
    )
    let url = ClientURLBuilder.join(baseUrl: info.url, path: "/api/info")
    let request = HTTPRequest(method: "GET", url: url, headers: headers(for: endpoint) ?? [:])

    let outcome: ProbeFetchOutcome = await withTaskGroup(of: ProbeFetchOutcome.self) { group in
        group.addTask {
            do {
                let response = try await transport.send(request)
                return .response(response)
            } catch is ServiceProbeTimeoutError {
                return .timedOut
            } catch is CancellationError {
                return .timedOut
            } catch {
                return .failed
            }
        }
        if timeoutMs > 0 {
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                return .timedOut
            }
        }
        let first = await group.next() ?? .failed
        group.cancelAll()
        return first
    }

    switch outcome {
    case .timedOut:
        return ServiceProbeResult(service: nil, timedOut: true)
    case .failed:
        return ServiceProbeResult(service: nil, timedOut: false)
    case .response(let response):
        let status = response.head.statusCode
        if status == 404 {
            return ServiceProbeResult(
                service: LocalService(
                    info: info,
                    endpoint: endpoint,
                    version: info.version,
                    state: .ready,
                    compatible: false
                ),
                timedOut: false
            )
        }
        guard let decoded = decodeProbeServerInfo(response.body) else {
            return ServiceProbeResult(service: nil, timedOut: false)
        }
        guard decoded.pid == info.pid else {
            return ServiceProbeResult(service: nil, timedOut: false)
        }
        if let expectedVersion = info.version, decoded.version != expectedVersion {
            return ServiceProbeResult(service: nil, timedOut: false)
        }
        let state: LocalServiceState
        if (200..<300).contains(status) {
            state = .ready
        } else if status == 500 {
            state = .failed
        } else {
            state = .waiting
        }
        return ServiceProbeResult(
            service: LocalService(
                info: info,
                endpoint: endpoint,
                version: decoded.version,
                state: state,
                compatible: true
            ),
            timedOut: false
        )
    }
}

private enum ProbeFetchOutcome: Sendable {
    case response(HTTPResponse)
    case timedOut
    case failed
}

private struct ProbeServerInfoPayload: Sendable {
    let version: String
    let pid: Int
}

private func decodeProbeServerInfo(_ bytes: [UInt8]) -> ProbeServerInfoPayload? {
    guard let json = try? ClientCodec.decode(JSONValue.self, from: bytes),
          case .object(let obj) = json,
          case .string(let version) = obj["version"]
    else {
        return nil
    }
    let pid: Int
    switch obj["pid"] {
    case .int(let i) where i >= 0 && i <= Int64(Int.max):
        pid = Int(i)
    case .double(let d) where d.isFinite && d >= 0 && d.rounded(.towardZero) == d && d <= Double(Int.max):
        pid = Int(d)
    default:
        return nil
    }
    return ProbeServerInfoPayload(version: version, pid: pid)
}

// MARK: - Service Contender Pool (packages/client/src/service-contender.ts)

/// Injectable background child process handle for portable service spawning.
public protocol ServiceChildProcessHandle: Sendable {
    var pid: Int? { get }
    var exitCode: Int32? { get }
    var signalCode: String? { get }
    func setHandlers(
        onStderr: @escaping @Sendable ([UInt8]) -> Void,
        onError: @escaping @Sendable (any Error & Sendable) -> Void,
        onClose: @escaping @Sendable () -> Void
    )
    func releaseStderr()
}

/// Injectable spawner for detached background service contenders.
public protocol ServiceProcessLauncher: Sendable {
    func spawn(command: String, args: [String], env: [String: String]) throws -> any ServiceChildProcessHandle
}

/// Injectable process signaler (SIGTERM / SIGKILL / liveness probe) for stopping local services.
public protocol ServiceProcessSignaler: Sendable {
    func sendSignal(pid: Int, signal: String)
    func isRunning(pid: Int) -> Bool
}

/// One background service startup attempt managed by `ContenderPool`.
// parity: client/src/service-contender.ts#ServiceContender [status=adapted hash=52dca677166f]
public final class ServiceContender: Sendable {
    private struct State: Sendable {
        var error: (any Error & Sendable)?
        var closed: Bool = false
        var stderrBuffer: [UInt8] = []
    }

    public static let stderrLimit = 8 * 1024

    public let id: String
    public let child: any ServiceChildProcessHandle
    private let state = Mutex(State())

    public init(child: any ServiceChildProcessHandle, id: String = uuid()) {
        self.id = id
        self.child = child
        child.setHandlers(
            onStderr: { [weak self] chunk in
                self?.appendStderr(chunk)
            },
            onError: { [weak self] cause in
                self?.state.withLock { s in
                    if s.error == nil {
                        s.error = ServiceLifecycleError("Failed to start server: \(cause)")
                    }
                }
            },
            onClose: { [weak self] in
                self?.state.withLock { $0.closed = true }
            }
        )
    }

    private func appendStderr(_ chunk: [UInt8]) {
        state.withLock { s in
            let limit = Self.stderrLimit
            if chunk.count >= limit {
                s.stderrBuffer = Array(chunk.suffix(limit))
            } else {
                let keep = max(0, limit - chunk.count)
                if s.stderrBuffer.count > keep {
                    s.stderrBuffer = Array(s.stderrBuffer.suffix(keep))
                }
                s.stderrBuffer.append(contentsOf: chunk)
            }
        }
    }

    public func error() -> (any Error & Sendable)? {
        state.withLock { $0.error }
    }

    public func closed() -> Bool {
        state.withLock { $0.closed }
    }

    public func stderr() -> String {
        let bytes = state.withLock { $0.stderrBuffer }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func release() {
        child.releaseStderr()
        state.withLock { $0.stderrBuffer.removeAll(keepingCapacity: false) }
    }
}

/// Spawns one detached service contender via the supplied `ServiceProcessLauncher`.
// parity: client/src/service-contender.ts#spawnServiceContender [status=adapted hash=5c55363bf942]
public func spawnServiceContender(
    command: String,
    args: [String],
    env: [String: String] = [:],
    launcher: any ServiceProcessLauncher
) throws -> ServiceContender {
    let child = try launcher.spawn(command: command, args: args, env: env)
    return ServiceContender(child: child)
}

/// Returns whether a contender has failed to spawn or closed.
// parity: client/src/service-contender.ts#contenderFinished [status=implemented hash=a614b09b1629]
public func contenderFinished(_ contender: ServiceContender) -> Bool {
    contender.error() != nil || contender.closed()
}

/// Tracks the startup attempts of one `ensure()` call: keeps at most two attempts alive,
/// remembers the first startup failure, and backs off when attempts exit cleanly because another won.
public final class ContenderPool: Sendable {
    private struct State: Sendable {
        var contenders: [ServiceContender] = []
        var failure: (any Error & Sendable)?
        var spawnDelay: Int64
        var lastSpawn: Int64 = 0
    }

    private let timing: EnsureTiming
    private let now: @Sendable () -> Int64
    private let state: Mutex<State>

    public init(timing: EnsureTiming, now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }) {
        self.timing = timing
        self.now = now
        self.state = Mutex(State(spawnDelay: timing.spawnDelay))
    }

    /// The first startup failure seen since the last eviction.
    public func failure() -> (any Error & Sendable)? {
        state.withLock { $0.failure }
    }

    /// A registered service answered, so the next attempt waits the base delay again.
    public func serviceAnswered() {
        state.withLock { $0.spawnDelay = timing.spawnDelay }
    }

    /// The owner `pid` was replaced. Drop its attempt and any finished ones, forget their
    /// failure, and restart the spawn clock.
    public func evict(pid: Int) {
        let toRelease: [ServiceContender] = state.withLock { s in
            var kept: [ServiceContender] = []
            var dropped: [ServiceContender] = []
            for item in s.contenders {
                if item.child.pid == pid || contenderFinished(item) {
                    dropped.append(item)
                } else {
                    kept.append(item)
                }
            }
            s.contenders = kept
            s.failure = nil
            s.lastSpawn = 0
            return dropped
        }
        for item in toRelease {
            item.release()
        }
    }

    /// Let the next attempt start without waiting a spawn delay.
    public func recruitNow() {
        let currentNow = now()
        state.withLock { s in
            s.lastSpawn = currentNow - s.spawnDelay
        }
    }

    /// Collect finished attempts. Returns the startup failure once no attempt is left alive.
    public func reap() -> (any Error & Sendable)? {
        state.withLock { s in
            var finished: [ServiceContender] = []
            var alive: [ServiceContender] = []
            for item in s.contenders {
                if contenderFinished(item) {
                    finished.append(item)
                } else {
                    alive.append(item)
                }
            }
            if s.failure == nil {
                for item in finished {
                    if let err = Self.contenderFailure(item) {
                        s.failure = err
                        break
                    }
                }
            }
            if finished.contains(where: { $0.child.exitCode == 0 }) {
                s.spawnDelay = min(s.spawnDelay * 2, timing.maxSpawnDelay)
            }
            s.contenders = alive
            return s.contenders.isEmpty ? s.failure : nil
        }
    }

    /// Whether to start another attempt now. A registration that has not answered yet gets one
    /// spawn delay before an attempt competes with it.
    public func shouldRecruit(registered: Bool) -> Bool {
        let currentNow = now()
        return state.withLock { s in
            if s.lastSpawn == 0 && registered {
                s.lastSpawn = currentNow
            }
            return s.failure == nil && s.contenders.count < 2 && (currentNow - s.lastSpawn) >= s.spawnDelay
        }
    }

    public func add(_ contender: ServiceContender) {
        let currentNow = now()
        state.withLock { s in
            if !s.contenders.contains(where: { $0.id == contender.id }) {
                s.contenders.append(contender)
            }
            s.lastSpawn = currentNow
        }
    }

    public func releaseAll() {
        let all = state.withLock { $0.contenders }
        for item in all {
            item.release()
        }
    }

    private static func contenderFailure(_ contender: ServiceContender) -> (any Error & Sendable)? {
        if let err = contender.error() { return err }
        if let exitCode = contender.child.exitCode, exitCode != 0 {
            return startupError("Server process exited with code \(exitCode)", stderr: contender.stderr())
        }
        if let signalCode = contender.child.signalCode {
            return startupError("Server process terminated by \(signalCode)", stderr: contender.stderr())
        }
        return nil
    }

    private static func startupError(_ message: String, stderr: String) -> ServiceLifecycleError {
        ServiceLifecycleError(stderr.isEmpty ? message : "\(message)\n\(stderr)")
    }
}

/// Factory matching upstream `contenderPool(timing)`.
// parity: client/src/service-contender.ts#contenderPool [status=implemented hash=ae8494c66fea]
public func contenderPool(
    timing: EnsureTiming,
    now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
) -> ContenderPool {
    ContenderPool(timing: timing, now: now)
}

// MARK: - Persistent PTY Handoff (packages/client/src/pty-handoff.ts)

public enum PtyHandoff {
    private struct Source: Equatable, Sendable, Codable {
        let id: String?
        let pid: Int
        let url: String
    }

    private struct Sidecar: Equatable, Sendable, Codable {
        let source: Source
        let handoff: PersistentPtySchema.Handoff?
        let expiresAt: Double
    }

    private struct HandoffResponseBody: Sendable, Codable {
        let handoff: PersistentPtySchema.Handoff?
    }

    /// Publish the handoff ticket before stopping its owner so every replacement contender can adopt it.
    /// Never throws: terminals are best-effort, so any failure replaces the service without a handoff.
    // parity: client/src/pty-handoff.ts#prepare [status=implemented hash=4c0119d75e6c]
    public static func prepare(
        file: String,
        info: ServiceInfo,
        timeoutMs: Int64 = defaultEnsureTiming.requestTimeout,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
    ) async {
        let nowMs = Double(now())
        if let existing = await readSidecar(file: file, fileSystem: fileSystem),
           existing.expiresAt > nowMs,
           sameSource(existing.source, info) {
            return
        }

        let endpoint = ServiceEndpoint(
            url: info.url,
            auth: info.password.map { ServiceBasicAuth(username: "opencode", password: $0) }
        )
        let client = OpenCode.make(
            ClientOptions(
                baseUrl: info.url,
                transport: transport,
                headers: headers(for: endpoint) ?? [:]
            )
        )

        let handoffResult: PersistentPtySchema.Handoff??
        do {
            let response = try await withTimeoutMs(timeoutMs) {
                try await client.experimental.persistentPty.handoff()
            }
            if let ticket = response.handoff {
                guard ticket.expiresAt.isFinite && ticket.expiresAt > Double(now()) else {
                    throw ServiceLifecycleError("Invalid or expired persistent terminal handoff")
                }
                handoffResult = .some(ticket)
            } else {
                handoffResult = .some(nil)
            }
        } catch {
            if let concurrent = await readSidecar(file: file, fileSystem: fileSystem),
               concurrent.expiresAt > Double(now()),
               sameSource(concurrent.source, info) {
                return
            }
            _ = try? await withTimeoutMs(timeoutMs) {
                try await client.experimental.persistentPty.shutdown()
            }
            handoffResult = .some(nil)
        }

        guard let handoff = handoffResult else { return }
        await publishSidecar(file: file, info: info, handoff: handoff, fileSystem: fileSystem, now: now)
    }

    /// Reads the handoff sidecar and injects `OPENCODE_PTY_HANDOFF` into the environment when valid.
    // parity: client/src/pty-handoff.ts#environment [status=implemented hash=2a117adfc4cf]
    public static func environment(
        file: String,
        env: [String: String]? = nil,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        now: @escaping @Sendable () -> Int64 = { ClientClock.nowEpochMs() }
    ) async -> [String: String] {
        var result = env ?? [:]
        let record = await readSidecar(file: file, fileSystem: fileSystem)
        let current: ServiceInfo?
        if let bytes = try? await fileSystem.readFile(at: file),
           let decoded = try? ClientCodec.decode(ServiceInfo.self, from: bytes) {
            current = decoded
        } else {
            current = nil
        }

        let validHandoff: PersistentPtySchema.Handoff?
        if let record,
           record.expiresAt > Double(now()),
           (current == nil || (current.map { sameSource(record.source, $0) } ?? false)) {
            validHandoff = record.handoff
        } else {
            validHandoff = nil
        }

        if let validHandoff, let encoded = try? ClientCodec.encodeString(validHandoff) {
            result["OPENCODE_PTY_HANDOFF"] = encoded
        } else {
            result.removeValue(forKey: "OPENCODE_PTY_HANDOFF")
        }
        return result
    }

    /// Clears the sidecar once a replacement service with a different identity is active.
    // parity: client/src/pty-handoff.ts#complete [status=implemented hash=fcb63add1828]
    public static func complete(
        file: String,
        info: ServiceInfo,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async {
        guard let record = await readSidecar(file: file, fileSystem: fileSystem) else { return }
        if !sameSource(record.source, info) {
            await clear(file: file, fileSystem: fileSystem)
        }
    }

    /// Removes the handoff sidecar file if present.
    // parity: client/src/pty-handoff.ts#clear [status=implemented hash=436dd74888ae]
    public static func clear(
        file: String,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
    ) async {
        try? await fileSystem.remove(at: file + ".pty-handoff")
    }

    private static func publishSidecar(
        file: String,
        info: ServiceInfo,
        handoff: PersistentPtySchema.Handoff?,
        fileSystem: any OpenCodeFileSystem,
        now: @escaping @Sendable () -> Int64
    ) async {
        let temporary = "\(file).pty-handoff.\(uuid()).tmp"
        let sidecar = Sidecar(
            source: Source(id: info.id, pid: info.pid, url: info.url),
            handoff: handoff,
            expiresAt: handoff?.expiresAt ?? Double(now() + 30_000)
        )
        guard let bytes = try? ClientCodec.encode(sidecar) else { return }
        do {
            try await fileSystem.writeFileExclusive(bytes, to: temporary)
            try? await fileSystem.chmod(at: temporary, mode: 0o600)
            try await fileSystem.rename(from: temporary, to: file + ".pty-handoff")
        } catch {
            try? await fileSystem.remove(at: temporary)
        }
    }

    private static func readSidecar(
        file: String,
        fileSystem: any OpenCodeFileSystem
    ) async -> Sidecar? {
        guard let bytes = try? await fileSystem.readFile(at: file + ".pty-handoff"),
              let sidecar = try? ClientCodec.decode(Sidecar.self, from: bytes),
              sidecar.expiresAt.isFinite
        else {
            return nil
        }
        if let h = sidecar.handoff, !h.expiresAt.isFinite {
            return nil
        }
        return sidecar
    }

    private static func sameSource(_ left: Source, _ right: ServiceInfo) -> Bool {
        left.id == right.id && left.pid == right.pid && left.url == right.url
    }
}

private func withTimeoutMs<T: Sendable>(
    _ timeoutMs: Int64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard timeoutMs > 0 else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .milliseconds(timeoutMs))
            throw ServiceProbeTimeoutError()
        }
        guard let result = try await group.next() else {
            throw ServiceProbeTimeoutError()
        }
        group.cancelAll()
        return result
    }
}

// MARK: - RPC Runtime Helpers (packages/client/src/rpc-runtime.ts)

/// Structured RPC method error payload surfaced by `RpcRuntime.readError` and Promise/Effect RPC clients.
public struct RpcMethodErrorPayload: Error, Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let type: String
    public let message: String
    public let data: JSONValue?

    public init(type: String, message: String, data: JSONValue? = nil) {
        self.type = type
        self.message = message
        self.data = data
    }

    public var description: String {
        "\(type): \(message)"
    }
}

/// Decoded RPC event envelope returned by `RpcRuntime.event`.
public struct RpcDecodedEvent: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let type: String
    public let created: Double?
    public let metadata: [String: JSONValue]?
    public let location: OpenCodeLocation?
    public let data: JSONValue

    public init(
        id: String,
        type: String,
        created: Double? = nil,
        metadata: [String: JSONValue]? = nil,
        location: OpenCodeLocation? = nil,
        data: JSONValue
    ) {
        self.id = id
        self.type = type
        self.created = created
        self.metadata = metadata
        self.location = location
        self.data = data
    }
}

public enum RpcRuntime {
    /// Decodes/validates an RPC output or error value against `schema`.
    // parity: client/src/rpc-runtime.ts#read [status=implemented hash=77382a741e34]
    public static func read(schema: ToolSchema.ValueSchema, value: JSONValue?) throws -> JSONValue {
        _ = schema
        return value ?? .null
    }

    /// Converts an `RpcError` or `RpcInternalError` (or `ProtocolErrorEnvelope` wrapping one)
    /// into a structured `RpcMethodErrorPayload`, preserving non-RPC errors untouched.
    // parity: client/src/rpc-runtime.ts#readError [status=implemented hash=bfedb46703d8]
    public static func readError(method: RpcSchema.Method, error: any Error & Sendable) -> any Error & Sendable {
        let extracted: (type: String, message: String, data: JSONValue?)?
        if let rpcErr = error as? RpcError {
            extracted = (rpcErr.type, rpcErr.message, rpcErr.data)
        } else if let internalErr = error as? RpcInternalError {
            extracted = (internalErr.type.rawValue, internalErr.message, internalErr.data)
        } else if let envelope = error as? ProtocolErrorEnvelope {
            switch envelope {
            case .rpc(let e):
                extracted = (e.type, e.message, e.data)
            case .rpcInternal(let e):
                extracted = (e.type.rawValue, e.message, e.data)
            default:
                extracted = nil
            }
        } else {
            extracted = nil
        }

        guard let extracted else { return error }

        guard let errorsMap = method.errors, let errorSchema = errorsMap[extracted.type] else {
            return RpcMethodErrorPayload(type: extracted.type, message: extracted.message, data: extracted.data)
        }

        do {
            let decoded = try read(schema: errorSchema, value: extracted.data)
            let normalizedData: JSONValue? = (extracted.data == nil && decoded == .null) ? nil : decoded
            return RpcMethodErrorPayload(type: extracted.type, message: extracted.message, data: normalizedData)
        } catch {
            return error
        }
    }

    /// Decodes a published `rpc.*` server event into a typed `RpcDecodedEvent`.
    // parity: client/src/rpc-runtime.ts#event [status=implemented hash=f62bd9a19d57]
    public static func event(
        definition: RpcSchema.Definition,
        name: String,
        schema: RpcSchema.EventDefinition,
        event: OpenCodeEvent
    ) throws -> RpcDecodedEvent {
        let data = try read(schema: schema.schema, value: event.data)
        return RpcDecodedEvent(
            id: event.id,
            type: eventType(definition: definition, name: name),
            created: event.created,
            metadata: event.metadata,
            location: event.location,
            data: data
        )
    }

    /// Formats the canonical RPC event type name (`rpc.<definition.id>.<name>`).
    // parity: client/src/rpc-runtime.ts#eventType [status=implemented hash=af67e4ef4ac5]
    public static func eventType(definition: RpcSchema.Definition, name: String) -> String {
        "rpc.\(definition.id).\(name)"
    }

    /// Overload for `RpcSchema.PortableDefinition`.
    public static func eventType(definition: RpcSchema.PortableDefinition, name: String) -> String {
        "rpc.\(definition.id).\(name)"
    }
}

// MARK: - Shared Events Multiplexer (packages/client/src/shared-events.ts)

/// Event constraint for shared multiplexed event streams.
public protocol TypedClientEvent: Sendable {
    var type: String { get }
}

extension OpenCodeEvent: TypedClientEvent {}

/// Selected event member alias matching upstream `SelectedEvent<A, Type>`.
// parity: client/src/shared-events.ts#SelectedEvent [status=adapted hash=0f341f24c204]
public typealias SelectedEvent<Event: TypedClientEvent> = Event

/// Options for subscribing to a `SharedEventsHub`.
// parity: client/src/shared-events.ts#SubscribeOptions [status=implemented hash=85e2283095e1]
public struct SubscribeOptions: Sendable {
    public let types: [String]?
    public let signal: AbortSignal?
    /// Reports transport activity on the shared stream, including keepalive frames that carry no event.
    public let onActivity: (@Sendable () -> Void)?

    public init(
        types: [String]? = nil,
        signal: AbortSignal? = nil,
        onActivity: (@Sendable () -> Void)? = nil
    ) {
        self.types = types
        self.signal = signal
        self.onActivity = onActivity
    }
}

/// Error thrown to a slow subscriber whose local queue exceeds `SharedEvents.capacity`.
public struct SharedEventsCapacityError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public var description: String {
        "Event subscriber exceeded its \(capacity)-event capacity"
    }
}

/// Multiplexes a single upstream event stream across any number of subscribers,
/// caching and replaying `server.connected` and enforcing per-subscriber bounded buffering.
public final class SharedEventsHub<Event: TypedClientEvent>: Sendable {
    public static var capacity: Int { 4_096 }

    private final class Subscriber: Sendable {
        struct Box: Sendable {
            var queued: [Event] = []
            var pending: [CheckedContinuation<Event?, any Error>] = []
            var finished: Bool = false
            var finishError: (any Error & Sendable)?
            var abortCleanup: (@Sendable () -> Void)?
        }

        let id: UInt64
        let types: Set<String>?
        let onActivity: (@Sendable () -> Void)?
        let box = Mutex(Box())

        init(id: UInt64, types: Set<String>?, onActivity: (@Sendable () -> Void)?) {
            self.id = id
            self.types = types
            self.onActivity = onActivity
        }

        func accepts(_ event: Event) -> Bool {
            guard let types else { return true }
            return event.type == "server.connected" || types.contains(event.type)
        }
    }

    private final class Connection: Sendable {
        struct Box: Sendable {
            var subscribers: [UInt64: Subscriber] = [:]
            var connected: Event?
            var task: Task<Void, Never>?
        }

        let id: UInt64
        let controller = AbortController()
        let box = Mutex(Box())

        init(id: UInt64) {
            self.id = id
        }
    }

    private struct HubState: Sendable {
        var nextID: UInt64 = 1
        var current: Connection?
    }

    private let connect: @Sendable (AbortSignal, @escaping @Sendable () -> Void) -> AsyncThrowingStream<Event, any Error>
    private let hubState = Mutex(HubState())

    public init(
        connect: @escaping @Sendable (AbortSignal, @escaping @Sendable () -> Void) -> AsyncThrowingStream<Event, any Error>
    ) {
        self.connect = connect
    }

    public func subscribe(_ options: SubscribeOptions? = nil) -> AsyncThrowingStream<Event, any Error> {
        let typeFilter: Set<String>?
        if let list = options?.types, !list.isEmpty {
            typeFilter = Set(list)
        } else {
            typeFilter = nil
        }

        let subscriberID = hubState.withLock { s -> UInt64 in
            let id = s.nextID
            s.nextID += 1
            return id
        }
        let subscriber = Subscriber(id: subscriberID, types: typeFilter, onActivity: options?.onActivity)
        let signal = options?.signal

        if let signal, signal.isAborted {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        return AsyncThrowingStream { continuation in
            let (connection, fresh, cachedConnected) = self.attach(subscriber: subscriber)

            if let signal {
                let cleanup = signal.onAbort { [weak self] in
                    self?.finishSubscriber(subscriber, connection: connection, error: nil, discard: true)
                }
                subscriber.box.withLock { $0.abortCleanup = cleanup }
            }

            if let cachedConnected {
                self.push(event: cachedConnected, to: subscriber, connection: connection)
            }

            if fresh {
                let runner = Task<Void, Never> { [weak self] in
                    guard let self else { return }
                    await self.run(connection: connection)
                }
                connection.box.withLock { $0.task = runner }
            }

            let pump = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        guard let event = try await self?.nextEvent(for: subscriber) else {
                            continuation.finish()
                            return
                        }
                        continuation.yield(event)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                self?.finishSubscriber(subscriber, connection: connection, error: nil, discard: true)
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                pump.cancel()
                self?.finishSubscriber(subscriber, connection: connection, error: nil, discard: true)
            }
        }
    }

    private func attach(subscriber: Subscriber) -> (Connection, Bool, Event?) {
        hubState.withLock { s in
            if let existing = s.current {
                let cached = existing.box.withLock { b -> Event? in
                    b.subscribers[subscriber.id] = subscriber
                    return b.connected
                }
                return (existing, false, cached)
            }
            let connID = s.nextID
            s.nextID += 1
            let created = Connection(id: connID)
            created.box.withLock { b in
                b.subscribers[subscriber.id] = subscriber
            }
            s.current = created
            return (created, true, nil)
        }
    }

    private func stop(connection: Connection) {
        connection.box.withLock { b in
            b.connected = nil
            b.task?.cancel()
            b.task = nil
        }
        connection.controller.abort()
        hubState.withLock { s in
            if s.current?.id == connection.id {
                s.current = nil
            }
        }
    }

    private func run(connection: Connection) async {
        var completionError: (any Error & Sendable)?
        do {
            if !connection.controller.signal.isAborted {
                let stream = connect(connection.controller.signal) {
                    let callbacks: [@Sendable () -> Void] = connection.box.withLock { b in
                        b.subscribers.values.compactMap(\.onActivity)
                    }
                    for cb in callbacks { cb() }
                }
                for try await event in stream {
                    if connection.controller.signal.isAborted || Task.isCancelled { break }
                    let targets: [Subscriber] = connection.box.withLock { b in
                        if event.type == "server.connected" {
                            b.connected = event
                        }
                        return Array(b.subscribers.values)
                    }
                    for subscriber in targets {
                        push(event: event, to: subscriber, connection: connection)
                    }
                }
            }
        } catch {
            completionError = error
        }

        stop(connection: connection)
        let remaining = connection.box.withLock { b -> [Subscriber] in
            let all = Array(b.subscribers.values)
            b.subscribers.removeAll()
            return all
        }
        for subscriber in remaining {
            finishSubscriber(subscriber, connection: connection, error: completionError, discard: false)
        }
    }

    private enum PushAction {
        case deliver(CheckedContinuation<Event?, any Error>)
        case overflow
        case queued
    }

    private enum NextEventResult {
        case value(Event)
        case end
        case fail(any Error)
        case parked
    }

    private func push(event: Event, to subscriber: Subscriber, connection: Connection) {
        guard subscriber.accepts(event) else { return }
        let action: PushAction = subscriber.box.withLock { b in
            if b.finished { return .queued }
            if !b.pending.isEmpty {
                return .deliver(b.pending.removeFirst())
            }
            if b.queued.count >= Self.capacity {
                return .overflow
            }
            b.queued.append(event)
            return .queued
        }
        switch action {
        case .deliver(let cont):
            cont.resume(returning: event)
        case .overflow:
            finishSubscriber(
                subscriber,
                connection: connection,
                error: SharedEventsCapacityError(capacity: Self.capacity),
                discard: true
            )
        case .queued:
            break
        }
    }

    private func nextEvent(for subscriber: Subscriber) async throws -> Event? {
        try await withCheckedThrowingContinuation { continuation in
            let result: NextEventResult = subscriber.box.withLock { b in
                if !b.queued.isEmpty {
                    return .value(b.queued.removeFirst())
                }
                if b.finished {
                    if let err = b.finishError { return .fail(err) }
                    return .end
                }
                b.pending.append(continuation)
                return .parked
            }
            switch result {
            case .value(let e):
                continuation.resume(returning: e)
            case .end:
                continuation.resume(returning: nil)
            case .fail(let err):
                continuation.resume(throwing: err)
            case .parked:
                break
            }
        }
    }

    private func finishSubscriber(
        _ subscriber: Subscriber,
        connection: Connection,
        error: (any Error & Sendable)?,
        discard: Bool
    ) {
        let (pending, cleanup): ([CheckedContinuation<Event?, any Error>], (@Sendable () -> Void)?) = subscriber.box.withLock { b in
            if b.finished { return ([], nil) }
            b.finished = true
            b.finishError = error
            if discard {
                b.queued.removeAll()
            }
            let waiters = b.pending
            b.pending.removeAll()
            let cb = b.abortCleanup
            b.abortCleanup = nil
            return (waiters, cb)
        }
        cleanup?()

        let shouldStop = connection.box.withLock { b -> Bool in
            _ = b.subscribers.removeValue(forKey: subscriber.id)
            return b.subscribers.isEmpty
        }
        if shouldStop {
            stop(connection: connection)
        }

        for waiter in pending {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }
}

public enum SharedEvents {
    /// Creates a shared, lazily connected, capacity-bounded event multiplexer.
    // parity: client/src/shared-events.ts#make [status=implemented hash=e1157cdafa50]
    public static func make<Event: TypedClientEvent>(
        connect: @escaping @Sendable (AbortSignal, @escaping @Sendable () -> Void) -> AsyncThrowingStream<Event, any Error>
    ) -> SharedEventsHub<Event> {
        SharedEventsHub(connect: connect)
    }
}

// MARK: - Client MCP Server Over WebSocket (packages/client/src/mcp.ts)

/// Context passed to a client-hosted MCP tool handler.
// parity: client/src/mcp.ts#ClientMcpToolContext [status=implemented hash=09733521d097]
public struct ClientMcpToolContext: Equatable, Hashable, Sendable {
    public let sessionID: String?

    public init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }
}

/// Content item returned by a client-hosted MCP tool handler.
public enum ClientMcpToolContent: Equatable, Hashable, Sendable, Codable {
    case text(String)
    case image(data: String, mimeType: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                data: try c.decode(String.self, forKey: .data),
                mimeType: try c.decode(String.self, forKey: .mimeType)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown MCP content type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
        }
    }
}

/// Result returned by a client-hosted MCP tool handler.
// parity: client/src/mcp.ts#ClientMcpToolResult [status=implemented hash=83ed200e1691]
public struct ClientMcpToolResult: Equatable, Hashable, Sendable, Codable {
    public let content: [ClientMcpToolContent]
    public let isError: Bool?

    public init(content: [ClientMcpToolContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }
}

/// A tool exposed by the client to the OpenCode server over `/api/experimental/client-mcp`.
// parity: client/src/mcp.ts#ClientMcpTool [status=implemented hash=77992f6e00a7]
public struct ClientMcpTool: Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: [String: JSONValue]?
    public let handler: @Sendable ([String: JSONValue], ClientMcpToolContext) async throws -> ClientMcpToolResult

    public init(
        name: String,
        description: String? = nil,
        inputSchema: [String: JSONValue]? = nil,
        handler: @escaping @Sendable ([String: JSONValue], ClientMcpToolContext) async throws -> ClientMcpToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// Configuration for `connectClientMcp`.
// parity: client/src/mcp.ts#ClientMcpOptions [status=implemented hash=586cc07d698a]
public struct ClientMcpOptions: Sendable {
    public let url: String
    public let name: String
    public let directory: String?
    public let headers: [String: String]?
    public let tools: [ClientMcpTool]
    public let webSocketFactory: any ClientWebSocketFactory
    public let reconnectMinMs: Int64
    public let reconnectMaxMs: Int64

    public init(
        url: String,
        name: String,
        directory: String? = nil,
        headers: [String: String]? = nil,
        tools: [ClientMcpTool],
        webSocketFactory: any ClientWebSocketFactory,
        reconnectMinMs: Int64 = 500,
        reconnectMaxMs: Int64 = 10_000
    ) {
        self.url = url
        self.name = name
        self.directory = directory
        self.headers = headers
        self.tools = tools
        self.webSocketFactory = webSocketFactory
        self.reconnectMinMs = reconnectMinMs
        self.reconnectMaxMs = reconnectMaxMs
    }
}

/// Active client-hosted MCP connection handle.
// parity: client/src/mcp.ts#ClientMcpConnection [status=implemented hash=494d9f3f81c4]
public final class ClientMcpConnection: Sendable {
    private let onClose: @Sendable () async -> Void

    public init(onClose: @escaping @Sendable () async -> Void) {
        self.onClose = onClose
    }

    public func close() async {
        await onClose()
    }
}

/// Exposes tools to the opencode server: opens a WebSocket to `/api/experimental/client-mcp` and answers
/// MCP JSON-RPC over it (one message per text frame), reconnecting with exponential backoff until `close()`.
// parity: client/src/mcp.ts#connectClientMcp [status=implemented hash=94be1873c13d]
public func connectClientMcp(options: ClientMcpOptions) -> ClientMcpConnection {
    let sessionIDMetaKey = "ai.opencode/sessionID"
    let defaultProtocolVersion = "2025-11-25"

    struct ConnectionState: Sendable {
        var disposed: Bool = false
        var delayMs: Int64
        var socket: (any ClientWebSocket)?
        var loopTask: Task<Void, Never>?
    }

    let state = Mutex(ConnectionState(delayMs: options.reconnectMinMs))

    var query: [(String, String)] = []
    if let dir = options.directory, !dir.isEmpty {
        query.append(("location[directory]", dir))
    }
    query.append(("name", options.name))
    let endpointURL = ClientURLBuilder.webSocketURL(
        baseUrl: options.url,
        relativePath: "api/experimental/client-mcp",
        query: query,
        preserveBaseQuery: true
    )

    @Sendable
    func respond(method: String, params: [String: JSONValue]?) async -> [String: JSONValue] {
        switch method {
        case "initialize":
            let chosenVersion: String
            if case .string(let v) = params?["protocolVersion"] {
                chosenVersion = v
            } else {
                chosenVersion = defaultProtocolVersion
            }
            return [
                "result": .object([
                    "protocolVersion": .string(chosenVersion),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object([
                        "name": .string(options.name),
                        "version": .string("1.0.0"),
                    ]),
                ]),
            ]
        case "ping":
            return ["result": .object([:])]
        case "tools/list":
            let toolEntries: [JSONValue] = options.tools.map { tool in
                var schema = tool.inputSchema ?? [:]
                schema["type"] = .string("object")
                var entry: [String: JSONValue] = [
                    "name": .string(tool.name),
                    "inputSchema": .object(schema),
                ]
                if let desc = tool.description {
                    entry["description"] = .string(desc)
                }
                return .object(entry)
            }
            return ["result": .object(["tools": .array(toolEntries)])]
        case "tools/call":
            let toolName: String?
            if case .string(let n) = params?["name"] {
                toolName = n
            } else {
                toolName = nil
            }
            guard let toolName, let tool = options.tools.first(where: { $0.name == toolName }) else {
                let rawName = params?["name"].map { "\($0)" } ?? "undefined"
                return [
                    "error": .object([
                        "code": .int(-32602),
                        "message": .string("Unknown tool: \(toolName ?? rawName)"),
                    ]),
                ]
            }
            let args: [String: JSONValue]
            if case .object(let a) = params?["arguments"] {
                args = a
            } else {
                args = [:]
            }
            var sessionID: String?
            if case .object(let meta) = params?["_meta"], case .string(let sid) = meta[sessionIDMetaKey] {
                sessionID = sid
            }
            do {
                let res = try await tool.handler(args, ClientMcpToolContext(sessionID: sessionID))
                let encoded = (try? ClientCodec.toJSONValue(res)) ?? .object(["content": .array([])])
                return ["result": encoded]
            } catch {
                let errResult = ClientMcpToolResult(
                    content: [.text(String(describing: error))],
                    isError: true
                )
                let encoded = (try? ClientCodec.toJSONValue(errResult)) ?? .object(["isError": .bool(true)])
                return ["result": encoded]
            }
        default:
            return [
                "error": .object([
                    "code": .int(-32601),
                    "message": .string("Method not found: \(method)"),
                ]),
            ]
        }
    }

    let loop = Task {
        while !Task.isCancelled {
            let isDisposed = state.withLock { $0.disposed }
            if isDisposed { break }

            let socket: any ClientWebSocket
            do {
                socket = try await options.webSocketFactory.connect(url: endpointURL, headers: options.headers ?? [:])
            } catch {
                let delay = state.withLock { s -> Int64 in
                    let current = s.delayMs
                    s.delayMs = min(s.delayMs * 2, options.reconnectMaxMs)
                    return current
                }
                try? await Task.sleep(for: .milliseconds(delay))
                continue
            }

            let stillActive = state.withLock { s -> Bool in
                if s.disposed { return false }
                s.socket = socket
                return true
            }
            if !stillActive {
                await socket.close(code: 1000)
                break
            }

            for await message in socket.messages {
                if state.withLock({ $0.disposed }) { break }
                switch message {
                case .text(let text):
                    guard let decoded = try? ClientCodec.decode(JSONValue.self, from: text),
                          case .object(let obj) = decoded
                    else { continue }
                    let method: String?
                    if case .string(let m) = obj["method"] { method = m } else { method = nil }
                    if method == "notifications/initialized" {
                        state.withLock { $0.delayMs = options.reconnectMinMs }
                    }
                    guard let method, let id = obj["id"] else { continue }
                    switch id {
                    case .string, .int, .double:
                        break
                    default:
                        continue
                    }
                    let params: [String: JSONValue]?
                    if case .object(let p) = obj["params"] { params = p } else { params = nil }
                    let replyFields = await respond(method: method, params: params)
                    var envelope: [String: JSONValue] = [
                        "jsonrpc": .string("2.0"),
                        "id": id,
                    ]
                    for (k, v) in replyFields {
                        envelope[k] = v
                    }
                    if socket.isOpen, let wire = try? ClientCodec.encodeString(JSONValue.object(envelope)) {
                        try? await socket.send(text: wire)
                    }
                case .binary:
                    continue
                case .closed:
                    break
                }
            }

            let shouldReconnect: Int64? = state.withLock { s in
                s.socket = nil
                if s.disposed { return nil }
                let delay = s.delayMs
                s.delayMs = min(s.delayMs * 2, options.reconnectMaxMs)
                return delay
            }
            if let delay = shouldReconnect {
                try? await Task.sleep(for: .milliseconds(delay))
            } else {
                break
            }
        }
    }

    state.withLock { $0.loopTask = loop }

    return ClientMcpConnection {
        let (socket, task) = state.withLock { s -> ((any ClientWebSocket)?, Task<Void, Never>?) in
            s.disposed = true
            let sock = s.socket
            s.socket = nil
            let t = s.loopTask
            s.loopTask = nil
            return (sock, t)
        }
        task?.cancel()
        if let socket {
            await socket.close(code: 1000)
        }
    }
}
