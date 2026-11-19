import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Synchronization
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
import OpenTUITerminal

// MARK: - CLI Services, Server Process & Session Target (`packages/cli/src/services/*`, `server-process.ts`, `session-target.ts`)

public enum CLIServices {
    // MARK: Plugin Startup Wait (`packages/cli/src/services/plugin-startup.ts`)

    /// Polls `client.plugin.list` until plugins activate (every 25ms, up to 5s), ignoring errors.
    // parity: cli/src/services/plugin-startup.ts#waitForPlugins [status=implemented hash=81d4c217560f]
    public static let waitForPlugins: @Sendable (OpenCodeClient, String) async -> Void = { client, directory in
        let deadline = Date().addingTimeInterval(5.0)
        while true {
            let input = PluginListInput(location: LocationQuery.LocationField(directory: directory))
            guard let response = try? await client.plugin.list(input) else {
                return
            }
            if !response.data.isEmpty {
                return
            }
            if Date() >= deadline {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: Port Owner Diagnostics (`packages/cli/src/services/port-owner.ts`)

    public enum PortOwner {
        /// Best-effort lookup naming the process listening on a TCP port (`PID <n> (<command>)`).
        // parity: cli/src/services/port-owner.ts#describe [status=implemented hash=06d60bf8da3a]
        public static let describe: @Sendable (Int, String?, CLIContext) async -> String? = { port, hostname, context in
            if context.platformOS == .windows { return nil }
            let proc = context.appProcess

            func runCmd(_ executable: String, _ args: [String]) async -> String {
                guard let result = try? await proc.run(
                    ProcessSpec(executable: executable, arguments: args),
                    options: AppProcess.RunOptions(maxOutputBytes: 4096, timeoutMs: 1_000)
                ), result.exitCode == 0 else {
                    return ""
                }
                return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let lsofOut = await runCmd("lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"])
            guard let pid = parseListeners(lsofOut).first(where: { matchesAddress($0.address, hostname: hostname) })?.pid else {
                return nil
            }
            let rawCommand = await runCmd("ps", ["-o", "command=", "-p", pid])
            let command = rawCommand.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if command.isEmpty {
                return "PID \(pid)"
            }
            let clipped = command.count > 200 ? String(command.prefix(199)) + "…" : command
            return "PID \(pid) (\(clipped))"
        }

        public static func describePort(
            _ port: Int,
            hostname: String? = nil,
            context: CLIContext = CLIContext.current
        ) async -> String? {
            await describe(port, hostname, context)
        }

        internal static func parseListeners(_ output: String) -> [(pid: String, address: String)] {
            var found: [(pid: String, address: String)] = []
            var pid: String? = nil
            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                if line.hasPrefix("p") {
                    let candidate = String(line.dropFirst())
                    pid = (!candidate.isEmpty && candidate.allSatisfy(\.isNumber)) ? candidate : nil
                } else if line.hasPrefix("n"), let activePid = pid, let colon = line.lastIndex(of: ":") {
                    var addr = String(line[line.index(after: line.startIndex)..<colon])
                    if addr.hasPrefix("[") && addr.hasSuffix("]") {
                        addr = String(addr.dropFirst().dropLast())
                    }
                    found.append((pid: activePid, address: addr))
                }
            }
            return found
        }

        internal static func matchesAddress(_ address: String, hostname: String?) -> Bool {
            guard var host = hostname else { return true }
            if host.hasPrefix("[") && host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }
            if !isIPAddress(host) || host == "0.0.0.0" || host == "::" {
                return true
            }
            return address == "*" || address == host
        }

        private static func isIPAddress(_ value: String) -> Bool {
            // Simple IPv4 / IPv6 check without relying on Node `net.isIP`.
            if value.contains(":") {
                let parts = value.split(separator: ":", omittingEmptySubsequences: false)
                return parts.count >= 2 && parts.allSatisfy { part in
                    part.isEmpty || part.allSatisfy { $0.isHexDigit || $0 == "." }
                }
            }
            let octets = value.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4 else { return false }
            return octets.allSatisfy { part in
                guard let n = Int(part), n >= 0, n <= 255 else { return false }
                return String(n) == String(part)
            }
        }
    }

    // MARK: Remote Access Tunnel (`packages/cli/src/services/remote-tunnel.ts`)

    public enum RemoteTunnel {
        public struct Connection: Sendable {
            public let hostname: String
            public let waitForClose: @Sendable () async -> Void
            public let close: @Sendable () async -> Void

            public init(
                hostname: String,
                waitForClose: @escaping @Sendable () async -> Void = {},
                close: @escaping @Sendable () async -> Void = {}
            ) {
                self.hostname = hostname
                self.waitForClose = waitForClose
                self.close = close
            }
        }

        public protocol Backend: Sendable {
            func getTunnelHostname() async throws -> String?
            func ensureTunnel() async throws -> String
            func connect(route: String, target: String) async throws -> Connection
            func loadStoredHostname() async -> String?
        }

        public struct RunInput: Sendable {
            public let route: String
            public let target: String
            public let onURL: @Sendable (String?) -> Void

            public init(route: String, target: String, onURL: @escaping @Sendable (String?) -> Void) {
                self.route = route
                self.target = target
                self.onURL = onURL
            }
        }

        public struct DefaultStorageBackend: Backend, Sendable {
            private let fileSystem: any OpenCodeFileSystem
            private let environment: any EnvironmentProviding

            public init(
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                environment: any EnvironmentProviding = SystemEnvironment.shared
            ) {
                self.fileSystem = fileSystem
                self.environment = environment
            }

            public func getTunnelHostname() async throws -> String? {
                await loadStoredHostname()
            }

            public func ensureTunnel() async throws -> String {
                if let existing = await loadStoredHostname() {
                    return existing
                }
                throw CLIError("OpenTunnel client is not configured in this build")
            }

            public func connect(route: String, target: String) async throws -> Connection {
                _ = (route, target)
                throw CLIError("OpenTunnel client is not configured in this build")
            }

            public func loadStoredHostname() async -> String? {
                let roots = GlobalPaths.roots(app: "opentunnel", environment: environment)
                let candidates = [
                    CLIPath.join(roots.state, "default.json"),
                    CLIPath.join(roots.config, "default.json"),
                    CLIPath.join(roots.data, "default.json"),
                ]
                for file in candidates {
                    guard let bytes = try? await fileSystem.readFile(at: file),
                          let json = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes)),
                          case .object(let obj) = json,
                          case .string(let host) = obj["hostname"],
                          !host.isEmpty
                    else { continue }
                    return host
                }
                return nil
            }
        }

        private static func resolvedBackend(for context: CLIContext) -> any Backend {
            context.remoteTunnelBackend ?? DefaultStorageBackend(fileSystem: context.fileSystem, environment: context.environment)
        }

        private static func isFatalTunnelError(_ error: any Error) -> Bool {
            let msg = CLIUtil.errorMessage(error)
            return msg.hasPrefix("Certificate issuance failed")
                || msg.contains("unsupported proxy scheme")
                || msg.contains("not a valid proxy URL")
                || msg.contains("not configured in this build")
        }

        // parity: cli/src/services/remote-tunnel.ts#run [status=adapted hash=4d91011149c3]
        public static let run: @Sendable (RunInput, CLIContext) async -> Void = { input, context in
            let backend = resolvedBackend(for: context)
            var delayMs: UInt64 = 1_000
            while !Task.isCancelled {
                do {
                    let conn = try await backend.connect(route: input.route, target: input.target)
                    input.onURL("https://\(input.route).\(conn.hostname)")
                    await conn.waitForClose()
                    input.onURL(nil)
                    delayMs = 1_000
                } catch {
                    input.onURL(nil)
                    if isFatalTunnelError(error) || Task.isCancelled {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    delayMs = min(30_000, delayMs * 2)
                }
            }
            input.onURL(nil)
        }

        // parity: cli/src/services/remote-tunnel.ts#ensure [status=adapted hash=6cb9479829b9]
        public static let ensure: @Sendable (CLIContext) async throws -> String = { context in
            let backend = resolvedBackend(for: context)
            if try await backend.getTunnelHostname() == nil {
                context.io.writeStderr("Setting up remote access; this can take a minute...\(context.io.eol)")
            }
            return try await backend.ensureTunnel()
        }

        // parity: cli/src/services/remote-tunnel.ts#hostname [status=adapted hash=f50b09bc4aea]
        public static let hostname: @Sendable (String, CLIContext) async -> String? = { route, context in
            let backend = resolvedBackend(for: context)
            guard let host = await backend.loadStoredHostname() else { return nil }
            return "\(route).\(host)"
        }
    }

    // MARK: Windows Retained Executable Links (`packages/cli/src/services/retained-image.ts`)

    public enum RetainedImage {
        public enum Role: String, Equatable, Hashable, Sendable {
            case service
            case upgrade
        }

        public struct RetainedHandle: Sendable {
            public let target: String?
            private let releaseFn: @Sendable () async -> Void

            public init(target: String?, release: @escaping @Sendable () async -> Void) {
                self.target = target
                self.releaseFn = release
            }

            public func release() async {
                await releaseFn()
            }
        }

        /// Holds a secondary hard link to the running binary in `directory`, sweeping links of dead PIDs.
        // parity: cli/src/services/retained-image.ts#retain [status=adapted hash=f0f97dfefac2]
        public static let retain: @Sendable (String, Role, CLIContext) async -> RetainedHandle = { directory, role, context in
            let fs = context.fileSystem
            try? await fs.makeDirectory(at: directory, recursive: true)
            let names = (try? await fs.readDirectory(at: directory)) ?? []
            for name in names {
                if let pid = retainedLinkPID(name), !context.signaler.isRunning(pid: pid) {
                    try? await fs.remove(at: CLIPath.join(directory, name))
                }
            }
            let target = CLIPath.join(directory, "opencode-\(role.rawValue)-\(context.currentPID)-\(CLIPath.randomHex(bytes: 4)).exe")
            let executable = (try? await fs.realPath(at: context.executablePath)) ?? context.executablePath
            let created: Bool = await {
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                if fs is LocalFileSystem {
                    return link(executable, target) == 0
                }
                #endif
                if let bytes = try? await fs.readFile(at: executable) {
                    return (try? await fs.writeFile(bytes, to: target, createDirectories: true)) != nil
                }
                return false
            }()
            guard created else {
                return RetainedHandle(target: nil, release: {})
            }
            return RetainedHandle(target: target) {
                try? await fs.remove(at: target)
            }
        }

        /// Moves retained executable links out of `directory` into `destination` so `directory` can be removed.
        // parity: cli/src/services/retained-image.ts#relocate [status=implemented hash=fbc831740602]
        public static let relocate: @Sendable (String, String, CLIContext) async -> Void = { directory, destination, context in
            let fs = context.fileSystem
            let names = (try? await fs.readDirectory(at: directory)) ?? []
            let links = names.filter { retainedLinkPID($0) != nil }
            guard !links.isEmpty else { return }
            try? await fs.makeDirectory(at: destination, recursive: true)
            for name in links {
                try? await fs.rename(from: CLIPath.join(directory, name), to: CLIPath.join(destination, name))
            }
        }

        /// Returns whether the running binary is an installed copy (npm, winget, or `~/.opencode/bin/opencode.exe`).
        // parity: cli/src/services/retained-image.ts#installed [status=implemented hash=a3eeb43a2a1a]
        public static func installed(home: String, execPath: String? = nil) -> Bool {
            let rawExec = execPath ?? CLIContext.current.executablePath
            let runtime = CLIPath.basename(rawExec, dropExtension: true).lowercased()
            if runtime == "bun" || runtime == "node" || runtime == "nodejs" {
                return false
            }
            let normalized = rawExec.replacing("\\", with: "/")
            let parts = normalized.split(separator: "/").map(String.init)
            if parts.contains("node_modules") { return true }
            if normalized.lowercased().contains("/winget/packages/") { return true }
            let curlExe = CLIPath.join(home, ".opencode", "bin", "opencode.exe").replacing("\\", with: "/")
            return normalized == curlExe
        }

        internal static func retainedLinkPID(_ name: String) -> Int? {
            guard name.hasSuffix(".exe") else { return nil }
            let body = String(name.dropLast(4))
            let prefix: String
            if body.hasPrefix("opencode-service-") {
                prefix = "opencode-service-"
            } else if body.hasPrefix("opencode-upgrade-") {
                prefix = "opencode-upgrade-"
            } else {
                return nil
            }
            let rest = String(body.dropFirst(prefix.count))
            let pieces = rest.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let pid = Int(pieces[0]), pid > 0,
                  !pieces[1].isEmpty, pieces[1].allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
            else {
                return nil
            }
            return pid
        }
    }

    // MARK: Service Config (`packages/cli/src/services/service-config.ts`)

    public enum ServiceConfig {
        public struct RemoteConfig: Equatable, Hashable, Sendable, Codable {
            public var route: String

            public init(route: String) {
                self.route = route
            }
        }

        // parity: cli/src/services/service-config.ts#Info [status=implemented hash=adf40c49135e]
        public struct Info: Equatable, Hashable, Sendable, Codable {
            public var disabled: Bool?
            public var remote: RemoteConfig?
            public var remoteAccepted: Bool?
            public var hostname: String?
            public var port: Int?
            public var password: String?
            public var cors: [String]?
            public var env: [String: String]?

            public init(
                disabled: Bool? = nil,
                remote: RemoteConfig? = nil,
                remoteAccepted: Bool? = nil,
                hostname: String? = nil,
                port: Int? = nil,
                password: String? = nil,
                cors: [String]? = nil,
                env: [String: String]? = nil
            ) {
                self.disabled = disabled
                self.remote = remote
                self.remoteAccepted = remoteAccepted
                self.hostname = hostname
                self.port = port
                self.password = password
                self.cors = cors
                self.env = env
            }
        }

        private struct LegacyInfo: Decodable {
            let disabled: Bool?
            let remote: Bool
            let remoteAccepted: Bool?
            let hostname: String?
            let port: Int?
            let password: String?
            let cors: [String]?
            let env: [String: String]?
        }

        private enum Key: String {
            case disabled, remote, hostname, port, password, cors, env
        }

        public struct OptionsInput: Equatable, Hashable, Sendable {
            public let checkVersion: Bool

            public init(checkVersion: Bool = false) {
                self.checkVersion = checkVersion
            }
        }

        // parity: cli/src/services/service-config.ts#filename [status=implemented hash=da395c994e9c]
        public static func filename(channel: String = CLIContext.current.channel) -> String {
            if channel == "latest" || channel == "dev" || channel == "beta" || channel == "next" {
                return "service.json"
            }
            return "service-\(CLIUtil.sanitizeChannelSegment(channel)).json"
        }

        // parity: cli/src/services/service-config.ts#defaultPort [status=implemented hash=8d51920277c9]
        public static func defaultPort(
            channel: String = CLIContext.current.channel,
            platform: PlatformOS = CLIContext.current.platformOS
        ) -> Int {
            let port = channelPort(channel)
            if platform == .windows && port >= 0x8000 {
                return 0x7000 | (port & 0x0FFF)
            }
            return port
        }

        private static func channelPort(_ channel: String) -> Int {
            if channel == "latest" || channel == "dev" || channel == "beta" || channel == "next" {
                return 0xC0DE
            }
            if channel == "local" {
                return 0xC0DF
            }
            let prefix = String(Hash.fast(channel).prefix(8))
            let num = UInt64(prefix, radix: 16) ?? 0
            return 10_000 + Int(num % 50_000)
        }

        // parity: cli/src/services/service-config.ts#legacyFilename [status=implemented hash=996eeb544cb8]
        public static func legacyFilename(channel: String = CLIContext.current.channel) -> String? {
            if channel == "latest" || channel == "local" {
                return nil
            }
            return "service-\(Hash.fast(channel)).json"
        }

        // parity: cli/src/services/service-config.ts#versionBelongsToChannel [status=implemented hash=59fbb017231b]
        public static func versionBelongsToChannel(
            _ version: String?,
            channel: String = CLIContext.current.channel,
            installedVersion: String = CLIContext.current.version
        ) -> Bool {
            guard let version else { return false }
            if version == installedVersion { return true }
            let prefix = "0.0.0-\(channel)-"
            guard version.hasPrefix(prefix) else { return false }
            let suffix = String(version.dropFirst(prefix.count))
            guard !suffix.isEmpty else { return false }
            let parts = suffix.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else { return false }
            return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }

        // parity: cli/src/services/service-config.ts#migrateRegistration [status=implemented hash=046fbf8478db]
        public static let migrateRegistration: @Sendable (String, String, String, String, any OpenCodeFileSystem) async -> Void = {
            legacy, file, channel, installedVersion, fs in
            guard let bytes = try? await fs.readFile(at: legacy),
                  let registration = try? JSONDecoder().decode(ServiceInfo.self, from: Data(bytes))
            else { return }
            guard versionBelongsToChannel(registration.version, channel: channel, installedVersion: installedVersion) else {
                return
            }
            try? await fs.makeDirectory(at: CLIPath.dirname(file), recursive: true)
            try? await fs.writeFileExclusive(bytes, to: file)
            try? await fs.chmod(at: file, mode: 0o600)
        }

        // parity: cli/src/services/service-config.ts#migrateConfig [status=implemented hash=0adf97b8f41c]
        public static let migrateConfig: @Sendable (String, String, any OpenCodeFileSystem) async -> Void = {
            legacy, file, fs in
            guard let bytes = try? await fs.readFile(at: legacy),
                  (try? decodeInfo(bytes)) != nil
            else { return }
            try? await fs.makeDirectory(at: CLIPath.dirname(file), recursive: true)
            try? await fs.writeFileExclusive(bytes, to: file)
            try? await fs.chmod(at: file, mode: 0o600)
        }

        /// Removes `XDG_STATE_HOME` from saved service environment so the service keeps its launch state directory.
        // parity: cli/src/services/service-config.ts#processEnv [status=implemented hash=d06c053845c1]
        public static func processEnv(_ env: [String: String]?) -> [String: String]? {
            guard var env else { return nil }
            env.removeValue(forKey: "XDG_STATE_HOME")
            return env
        }

        private struct ConfigPaths {
            let file: String
            let legacyConfigFile: String?
            let legacyRegistrationFiles: [String]
            let configFile: String
        }

        private static func resolvePaths(context: CLIContext) -> ConfigPaths {
            let global = context.globalPaths
            let name = filename(channel: context.channel)
            let legacy = legacyFilename(channel: context.channel)
            var legacyRegs: [String] = []
            if let legacy {
                legacyRegs.append(CLIPath.join(global.state, legacy))
            }
            if name != "service.json" && context.channel != "local" {
                legacyRegs.append(CLIPath.join(global.state, "service.json"))
            }
            return ConfigPaths(
                file: CLIPath.join(global.state, name),
                legacyConfigFile: legacy.map { CLIPath.join(global.config, $0) },
                legacyRegistrationFiles: legacyRegs,
                configFile: CLIPath.join(global.config, name)
            )
        }

        private static func decodeInfo(_ bytes: [UInt8]) throws -> Info {
            let decoded = try JSONDecoder().decode(Info.self, from: Data(bytes))
            if let p = decoded.port, (p < 1 || p > 65_535) {
                throw CLIError("Port must be between 1 and 65535")
            }
            return decoded
        }

        // parity: cli/src/services/service-config.ts#options [status=implemented hash=100f5e0e01eb]
        public static let options: @Sendable (OptionsInput, CLIContext) async throws -> ServiceEnsureOptions = { input, context in
            let paths = resolvePaths(context: context)
            for legacy in paths.legacyRegistrationFiles {
                await migrateRegistration(legacy, paths.file, context.channel, context.version, context.fileSystem)
            }
            let current = try await read(context: context)
            let cmd = (try? CLIUtil.selfCommand(execPath: context.executablePath)) ?? [context.executablePath]
            return ServiceEnsureOptions(
                file: paths.file,
                version: input.checkVersion ? .exact(context.version) : nil,
                command: cmd + ["serve", "--service"],
                env: processEnv(current.env)
            )
        }

        // parity: cli/src/services/service-config.ts#read [status=implemented hash=aa69177eb926]
        public static func read(context: CLIContext = CLIContext.current) async throws -> Info {
            let paths = resolvePaths(context: context)
            if let legacy = paths.legacyConfigFile {
                await migrateConfig(legacy, paths.configFile, context.fileSystem)
            }
            guard let bytes = try? await context.fileSystem.readFile(at: paths.configFile) else {
                return Info()
            }
            if let info = try? decodeInfo(bytes) {
                return info
            }
            if let legacy = try? JSONDecoder().decode(LegacyInfo.self, from: Data(bytes)) {
                let repaired = Info(
                    disabled: legacy.disabled,
                    remote: legacy.remote ? RemoteConfig(route: generateRoute()) : nil,
                    remoteAccepted: legacy.remoteAccepted,
                    hostname: legacy.hostname,
                    port: legacy.port,
                    password: legacy.password,
                    cors: legacy.cors,
                    env: legacy.env
                )
                try await write(repaired, context: context)
                return repaired
            }
            return Info()
        }

        private static func generateRoute() -> String {
            CLIPath.randomHex(bytes: 8)
        }

        private static func write(_ value: Info, context: CLIContext) async throws {
            let paths = resolvePaths(context: context)
            let temp = "\(paths.configFile).\(context.currentPID).tmp"
            try await context.fileSystem.makeDirectory(at: CLIPath.dirname(paths.configFile), recursive: true)
            let text = try CLIPath.encodePrettyJSON(value) + "\n"
            try await context.fileSystem.writeFile(Array(text.utf8), to: temp, createDirectories: true)
            try? await context.fileSystem.chmod(at: temp, mode: 0o600)
            var lastError: (any Error)?
            for attempt in 0..<20 {
                do {
                    try await context.fileSystem.rename(from: temp, to: paths.configFile)
                    return
                } catch {
                    lastError = error
                    if attempt < 19 {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            if let lastError { throw lastError }
        }

        // parity: cli/src/services/service-config.ts#password [status=implemented hash=74bd8d8a4c9e]
        public static func password(
            _ value: String? = nil,
            context: CLIContext = CLIContext.current
        ) async throws -> String {
            var existing = try await read(context: context)
            if value == nil, let current = existing.password, !current.isEmpty {
                return current
            }
            let next = value ?? CLIPath.randomBase64URL(bytes: 32)
            existing.password = next
            try await write(existing, context: context)
            return next
        }

        // parity: cli/src/services/service-config.ts#acceptRemote [status=implemented hash=0e20e9312b61]
        public static func acceptRemote(context: CLIContext = CLIContext.current) async throws {
            var existing = try await read(context: context)
            existing.remoteAccepted = true
            try await write(existing, context: context)
        }

        private static func disableRemote(context: CLIContext) async throws {
            var existing = try await read(context: context)
            let hadRemote = existing.remote != nil
            existing.remote = nil
            if hadRemote {
                existing.remoteAccepted = true
            }
            try await write(existing, context: context)
        }

        // parity: cli/src/services/service-config.ts#remote [status=implemented hash=bc50c3de8a34]
        public static func remote(context: CLIContext = CLIContext.current) async throws -> String {
            var existing = try await read(context: context)
            if let existingRoute = existing.remote?.route {
                return existingRoute
            }
            let next = generateRoute()
            existing.remote = RemoteConfig(route: next)
            try await write(existing, context: context)
            return next
        }

        private static func stopService(context: CLIContext) async throws {
            let opts = try await options(OptionsInput(), context)
            try await EffectClient.Service.stop(
                options: ServiceStopOptions(file: opts.file),
                fileSystem: context.fileSystem,
                transport: context.transport,
                signaler: context.signaler,
                environment: context.environment
            )
        }

        // parity: cli/src/services/service-config.ts#get [status=implemented hash=f25109939dcd]
        public static func get(
            key: String? = nil,
            name: String? = nil,
            context: CLIContext = CLIContext.current
        ) async throws -> String {
            guard let key else {
                let info = try await read(context: context)
                var obj: [String: JSONValue] = [:]
                if let disabled = info.disabled { obj["disabled"] = .bool(disabled) }
                if info.remote != nil { obj["remote"] = .object([:]) }
                if let accepted = info.remoteAccepted { obj["remoteAccepted"] = .bool(accepted) }
                if let hostname = info.hostname { obj["hostname"] = .string(hostname) }
                if let port = info.port { obj["port"] = .int(Int64(port)) }
                if let cors = info.cors { obj["cors"] = .array(cors.map(JSONValue.string)) }
                if let env = info.env { obj["env"] = .object(env.mapValues(JSONValue.string)) }
                return try CLIPath.encodePrettyJSON(JSONValue.object(obj))
            }
            guard let selected = Key(rawValue: key) else {
                throw CLIError("Unknown service config key: \(key)")
            }
            if selected != .env && name != nil {
                throw CLIError("Usage: opencode service get \(selected.rawValue)")
            }
            let info = try await read(context: context)
            switch selected {
            case .disabled:
                return String(info.disabled ?? false)
            case .remote:
                return String(info.remote != nil)
            case .hostname:
                return info.hostname ?? ""
            case .port:
                return info.port.map(String.init) ?? ""
            case .password:
                return try await password(context: context)
            case .cors:
                return try CLIPath.encodePrettyJSON(info.cors ?? [])
            case .env:
                let env = info.env ?? [:]
                if let name {
                    return env[name] ?? ""
                }
                return try CLIPath.encodePrettyJSON(env)
            }
        }

        // parity: cli/src/services/service-config.ts#set [status=implemented hash=4b1d0504d3f0]
        public static func set(
            key: String,
            value: String,
            nestedValue: String? = nil,
            context: CLIContext = CLIContext.current
        ) async throws {
            guard let selected = Key(rawValue: key) else {
                throw CLIError("Unknown service config key: \(key)")
            }
            if selected != .env && nestedValue != nil {
                throw CLIError("Usage: opencode service set \(selected.rawValue) <value>")
            }
            switch selected {
            case .disabled:
                guard value == "true" || value == "false" else {
                    throw CLIError("Disabled must be true or false")
                }
                if value == "true" { try await stopService(context: context) }
                var info = try await read(context: context)
                info.disabled = (value == "true")
                try await write(info, context: context)

            case .remote:
                guard value == "true" || value == "false" else {
                    throw CLIError("Remote must be true or false")
                }
                if value == "true" {
                    _ = try await RemoteTunnel.ensure(context)
                }
                try await stopService(context: context)
                if value == "true" {
                    _ = try await remote(context: context)
                } else {
                    try await disableRemote(context: context)
                }

            case .hostname:
                try await stopService(context: context)
                var info = try await read(context: context)
                info.hostname = value
                try await write(info, context: context)

            case .port:
                guard let port = Int(value), port >= 1, port <= 65_535 else {
                    throw CLIError("Port must be between 1 and 65535")
                }
                try await stopService(context: context)
                var info = try await read(context: context)
                info.port = port
                try await write(info, context: context)

            case .password:
                try await stopService(context: context)
                _ = try await password(value, context: context)

            case .env:
                guard let nestedValue else {
                    throw CLIError("Usage: opencode service set env <key> <value>")
                }
                try await stopService(context: context)
                var info = try await read(context: context)
                var env = info.env ?? [:]
                env[value] = nestedValue
                info.env = env
                try await write(info, context: context)

            case .cors:
                let origins = value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                for origin in origins {
                    guard isValidHTTPOrigin(origin) else {
                        throw CLIError("CORS must be a comma-separated list of HTTP(S) origins without paths or trailing slashes")
                    }
                }
                try await stopService(context: context)
                var info = try await read(context: context)
                info.cors = origins
                try await write(info, context: context)
            }
        }

        // parity: cli/src/services/service-config.ts#unset [status=implemented hash=b1039612f7f3]
        public static func unset(
            key: String,
            name: String? = nil,
            context: CLIContext = CLIContext.current
        ) async throws {
            guard let selected = Key(rawValue: key) else {
                throw CLIError("Unknown service config key: \(key)")
            }
            if selected != .env && name != nil {
                throw CLIError("Usage: opencode service unset \(selected.rawValue)")
            }
            switch selected {
            case .disabled:
                var info = try await read(context: context)
                info.disabled = nil
                try await write(info, context: context)

            case .remote:
                try await stopService(context: context)
                try await disableRemote(context: context)

            case .hostname:
                try await stopService(context: context)
                var info = try await read(context: context)
                info.hostname = nil
                try await write(info, context: context)

            case .port:
                try await stopService(context: context)
                var info = try await read(context: context)
                info.port = nil
                try await write(info, context: context)

            case .password:
                try await stopService(context: context)
                var info = try await read(context: context)
                info.password = nil
                try await write(info, context: context)

            case .env:
                guard let name else {
                    throw CLIError("Usage: opencode service unset env <key>")
                }
                try await stopService(context: context)
                var info = try await read(context: context)
                var env = info.env ?? [:]
                env.removeValue(forKey: name)
                info.env = env.isEmpty ? nil : env
                try await write(info, context: context)

            case .cors:
                try await stopService(context: context)
                var info = try await read(context: context)
                info.cors = nil
                try await write(info, context: context)
            }
        }

        internal static func isValidHTTPOrigin(_ origin: String) -> Bool {
            guard let comps = URLComponents(string: origin),
                  let scheme = comps.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = comps.host, !host.isEmpty,
                  comps.path.isEmpty,
                  comps.query == nil,
                  comps.fragment == nil,
                  comps.user == nil,
                  comps.password == nil,
                  !origin.hasSuffix("/")
            else {
                return false
            }
            return true
        }
    }

    // MARK: Service Registration (`packages/cli/src/services/service-registration.ts`)

    public enum ServiceRegistration {
        public struct Options: Sendable {
            public let url: String
            public let password: String
            public let id: String
            public let file: String
            public let shutdown: @Sendable () async -> Void

            public init(
                url: String,
                password: String,
                id: String,
                file: String,
                shutdown: @escaping @Sendable () async -> Void
            ) {
                self.url = url
                self.password = password
                self.id = id
                self.file = file
                self.shutdown = shutdown
            }
        }

        public struct Handle: Sendable {
            public let info: ServiceInfo
            private let cleanupFn: @Sendable () async -> Void

            public init(info: ServiceInfo, cleanup: @escaping @Sendable () async -> Void) {
                self.info = info
                self.cleanupFn = cleanup
            }

            public func cleanup() async {
                await cleanupFn()
            }
        }

        /// Atomically writes `service.json` and starts an ownership watchdog that triggers `shutdown` if replaced.
        // parity: cli/src/services/service-registration.ts#register [status=implemented hash=8a73664bc3ae]
        public static let register: @Sendable (Options, CLIContext) async throws -> Handle = { options, context in
            let fs = context.fileSystem
            let temp = "\(options.file).\(options.id).tmp"
            try await fs.makeDirectory(at: CLIPath.dirname(options.file), recursive: true)
            let info = ServiceInfo(
                id: options.id,
                version: context.version,
                url: options.url,
                pid: Int(context.currentPID),
                password: options.password
            )
            let encoded = try CLIPath.encodeCompactJSON(info)
            try await fs.writeFile(Array(encoded.utf8), to: temp, createDirectories: true)
            try? await fs.chmod(at: temp, mode: 0o600)
            var lastError: (any Error)?
            for attempt in 0..<20 {
                do {
                    try await fs.rename(from: temp, to: options.file)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 19 {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            if let lastError { throw lastError }

            let owns: @Sendable (ServiceInfo) -> Bool = { found in
                found.id == info.id
                    && found.version == info.version
                    && found.url == info.url
                    && found.pid == info.pid
                    && found.password == info.password
            }

            let watcher = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if Task.isCancelled { break }
                    guard let bytes = try? await fs.readFile(at: options.file),
                          let found = try? JSONDecoder().decode(ServiceInfo.self, from: Data(bytes)),
                          owns(found)
                    else {
                        await options.shutdown()
                        break
                    }
                }
            }

            return Handle(info: info) {
                watcher.cancel()
                if let bytes = try? await fs.readFile(at: options.file),
                   let found = try? JSONDecoder().decode(ServiceInfo.self, from: Data(bytes)),
                   owns(found) {
                    try? await fs.remove(at: options.file)
                }
            }
        }
    }

    // MARK: Standalone Private Server (`packages/cli/src/services/standalone.ts`)

    public enum Standalone {
        public struct Options: Equatable, Hashable, Sendable {
            public let command: [String]?

            public init(command: [String]? = nil) {
                self.command = command
            }
        }

        public struct Handle: Sendable {
            public let endpoint: ServiceEndpoint
            public let pid: Int32
            private let stopFn: @Sendable () async -> Void
            private let waitExitFn: @Sendable () async -> Int32

            public init(
                endpoint: ServiceEndpoint,
                pid: Int32,
                stop: @escaping @Sendable () async -> Void = {},
                waitExit: @escaping @Sendable () async -> Int32 = { 0 }
            ) {
                self.endpoint = endpoint
                self.pid = pid
                self.stopFn = stop
                self.waitExitFn = waitExit
            }

            public func stop() async { await stopFn() }
            public func waitForExit() async -> Int32 { await waitExitFn() }
        }

        private struct ReadyLine: Decodable {
            let url: String
        }

        /// Starts a private standalone server (`opencode serve --stdio --port 0`) with a lease password.
        // parity: cli/src/services/standalone.ts#start [status=adapted hash=46dbdb7c1366]
        public static func start(
            _ options: Options = Options(),
            context: CLIContext = CLIContext.current
        ) async throws -> Handle {
            let password = CLIPath.randomBase64URL(bytes: 32)
            // Use an injected starter or the in-process OpenCodeServer directly when no custom command is specified.
            if let starter = context.serverStarter ?? (options.command == nil ? ServerProcess.defaultLoopbackStarter(context: context) : nil) {
                let started = try await starter(
                    ServerProcess.StartRequest(
                        hostname: "127.0.0.1",
                        port: 0,
                        cors: nil,
                        password: password,
                        databasePath: CLIUtil.databasePath(context.globalPaths.data, channel: context.channel, environment: context.environment),
                        mode: .stdio
                    )
                )
                return Handle(
                    endpoint: ServiceEndpoint(url: started.url, auth: ServiceBasicAuth(username: "opencode", password: password)),
                    pid: context.currentPID,
                    stop: started.shutdown,
                    waitExit: { 0 }
                )
            }

            #if os(macOS) || os(Linux) || os(Windows)
            let cmd = options.command ?? ((try? CLIUtil.selfCommand(execPath: context.executablePath)) ?? [context.executablePath]) + ["serve"]
            guard let executable = cmd.first else {
                throw CLIError("Failed to resolve standalone server command")
            }
            let args = Array(cmd.dropFirst()) + ["--stdio", "--port", "0"]
            let process = Process()
            if executable.contains("/") || executable.contains("\\") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + args
            }
            process.currentDirectoryURL = URL(fileURLWithPath: context.cwd)
            var env = ProcessInfo.processInfo.environment
            env["OPENCODE_PASSWORD"] = password
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            if context.envVariable("OPENCODE_PRINT_LOGS") != "1" {
                process.standardError = FileHandle.nullDevice
            }

            try process.run()
            let pid = process.processIdentifier

            // Read first newline-terminated JSON readiness line from stdout
            let url: String = try await withCheckedThrowingContinuation { continuation in
                let resolved = Mutex(false)
                let lineBuf = Mutex<[UInt8]>([])
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        let shouldFail = resolved.withLock { done -> Bool in
                            if done { return false }
                            done = true
                            return true
                        }
                        if shouldFail {
                            continuation.resume(throwing: CLIError("Standalone server exited before reporting readiness"))
                        }
                        return
                    }
                    let extracted: String? = lineBuf.withLock { buf in
                        buf.append(contentsOf: data)
                        if let nl = buf.firstIndex(of: 0x0A) {
                            let slice = buf[..<nl]
                            buf.removeFirst(nl + 1)
                            return String(decoding: slice, as: UTF8.self)
                        }
                        return nil
                    }
                    if let line = extracted {
                        let shouldResume = resolved.withLock { done -> Bool in
                            if done { return false }
                            done = true
                            return true
                        }
                        if shouldResume {
                            do {
                                let ready = try JSONDecoder().decode(ReadyLine.self, from: Data(line.utf8))
                                continuation.resume(returning: ready.url)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }

            return Handle(
                endpoint: ServiceEndpoint(url: url, auth: ServiceBasicAuth(username: "opencode", password: password)),
                pid: pid,
                stop: {
                    try? stdinPipe.fileHandleForWriting.close()
                    if process.isRunning {
                        process.terminate()
                    }
                },
                waitExit: {
                    process.waitUntilExit()
                    return process.terminationStatus
                }
            )
            #else
            throw PlatformError.unsupportedOnPlatform(context.platformOS, operation: "Standalone.start")
            #endif
        }
    }

    // MARK: Server Connection Resolution (`packages/cli/src/services/server-connection.ts`)

    public enum ServerConnection {
        public enum MismatchPolicy: String, Equatable, Hashable, Sendable {
            case replace
            case ignore
            case error
        }

        // parity: cli/src/services/server-connection.ts#Args [status=implemented hash=797903a68706]
        public struct Args: Sendable {
            public let server: String?
            public let standalone: Bool?
            public let mismatch: MismatchPolicy?
            public let autostart: Bool?
            public let onStart: (@Sendable (ServiceEnsureReason, String?) -> Void)?

            public init(
                server: String? = nil,
                standalone: Bool? = nil,
                mismatch: MismatchPolicy? = nil,
                autostart: Bool? = nil,
                onStart: (@Sendable (ServiceEnsureReason, String?) -> Void)? = nil
            ) {
                self.server = server
                self.standalone = standalone
                self.mismatch = mismatch
                self.autostart = autostart
                self.onStart = onStart
            }
        }

        public struct ManagedServiceHandle: Sendable {
            public let reconnect: @Sendable () async throws -> ServiceEndpoint
            public let restart: @Sendable () async throws -> Void

            public init(
                reconnect: @escaping @Sendable () async throws -> ServiceEndpoint,
                restart: @escaping @Sendable () async throws -> Void
            ) {
                self.reconnect = reconnect
                self.restart = restart
            }
        }

        // parity: cli/src/services/server-connection.ts#Resolved [status=implemented hash=3d4f745f6536]
        public struct Resolved: Sendable {
            public let endpoint: ServiceEndpoint
            public let service: ManagedServiceHandle?
            public let standalone: Bool
            public let standaloneHandle: Standalone.Handle?

            public init(
                endpoint: ServiceEndpoint,
                service: ManagedServiceHandle? = nil,
                standalone: Bool = false,
                standaloneHandle: Standalone.Handle? = nil
            ) {
                self.endpoint = endpoint
                self.service = service
                self.standalone = standalone
                self.standaloneHandle = standaloneHandle
            }
        }

        // parity: cli/src/services/server-connection.ts#resolve [status=implemented hash=b20fe4d93918]
        public static func resolve(
            _ args: Args = Args(),
            context: CLIContext = CLIContext.current
        ) async throws -> Resolved {
            let globals = context.globalFlags
            let server = args.server ?? globals.server
            let standalone = args.standalone ?? globals.standalone
            if server != nil && standalone {
                throw CLIError("--server and --standalone cannot be combined")
            }

            if let server {
                let pwd = CLIUtil.Env.password(context)
                let endpoint = ServiceEndpoint(
                    url: server,
                    auth: pwd.map { ServiceBasicAuth(username: "opencode", password: $0.value) }
                )
                let client = context.makeClient(endpoint: endpoint)
                do {
                    let health = try await client.server.info()
                    if health.version != context.version {
                        context.io.writeStderr(
                            "Warning: Server at \(endpoint.url) has version \(health.version); this client is \(context.version). Continuing anyway.\n"
                        )
                    }
                    return Resolved(endpoint: endpoint)
                } catch {
                    throw connectError(endpoint: endpoint, cause: error)
                }
            }

            let config = (try? await ServiceConfig.read(context: context)) ?? ServiceConfig.Info()
            if standalone || config.disabled == true {
                let handle = try await Standalone.start(context: context)
                return Resolved(endpoint: handle.endpoint, standalone: true, standaloneHandle: handle)
            }

            let mismatch = args.mismatch ?? .ignore
            let baseOpts = try await ServiceConfig.options(
                ServiceConfig.OptionsInput(checkVersion: mismatch != .ignore),
                context
            )
            let managed = makeManagedHandle(options: baseOpts, context: context)

            if args.autostart == false {
                let discoverOpts = ServiceDiscoverOptions(file: baseOpts.file, version: nil)
                if let endpoint = await EffectClient.Service.discover(
                    options: discoverOpts,
                    fileSystem: context.fileSystem,
                    transport: context.transport,
                    environment: context.environment
                ) {
                    return Resolved(endpoint: endpoint, service: managed)
                }
                let handle = try await Standalone.start(context: context)
                return Resolved(endpoint: handle.endpoint, standalone: true, standaloneHandle: handle)
            }

            let ensureOpts = ServiceEnsureOptions(
                file: baseOpts.file,
                version: baseOpts.version,
                command: baseOpts.command,
                env: baseOpts.env,
                onStart: args.onStart
            )
            let endpoint = try await resolveManaged(options: ensureOpts, mismatch: mismatch, context: context)
            return Resolved(endpoint: endpoint, service: managed)
        }

        private static func makeManagedHandle(options: ServiceEnsureOptions, context: CLIContext) -> ManagedServiceHandle {
            let reconnectOptions = ServiceEnsureOptions(
                file: options.file,
                version: nil,
                command: options.command,
                env: options.env,
                onStart: options.onStart,
                timing: options.timing
            )
            return ManagedServiceHandle(
                reconnect: {
                    try await EffectClient.Service.ensure(
                        options: reconnectOptions,
                        fileSystem: context.fileSystem,
                        transport: context.transport,
                        launcher: context.launcher,
                        signaler: context.signaler,
                        environment: context.environment
                    )
                },
                restart: {
                    try await EffectClient.Service.stop(
                        options: ServiceStopOptions(file: options.file, pty: .handoff),
                        fileSystem: context.fileSystem,
                        transport: context.transport,
                        signaler: context.signaler,
                        environment: context.environment
                    )
                    _ = try await EffectClient.Service.ensure(
                        options: reconnectOptions,
                        fileSystem: context.fileSystem,
                        transport: context.transport,
                        launcher: context.launcher,
                        signaler: context.signaler,
                        environment: context.environment
                    )
                }
            )
        }

        private static func resolveManaged(
            options: ServiceEnsureOptions,
            mismatch: MismatchPolicy,
            context: CLIContext
        ) async throws -> ServiceEndpoint {
            switch mismatch {
            case .replace:
                return try await EffectClient.Service.ensure(
                    options: options,
                    fileSystem: context.fileSystem,
                    transport: context.transport,
                    launcher: context.launcher,
                    signaler: context.signaler,
                    environment: context.environment
                )
            case .ignore:
                let ignored = ServiceEnsureOptions(
                    file: options.file,
                    version: nil,
                    command: options.command,
                    env: options.env,
                    onStart: options.onStart,
                    timing: options.timing
                )
                return try await EffectClient.Service.ensure(
                    options: ignored,
                    fileSystem: context.fileSystem,
                    transport: context.transport,
                    launcher: context.launcher,
                    signaler: context.signaler,
                    environment: context.environment
                )
            case .error:
                if let compatible = await EffectClient.Service.discover(
                    options: options.discoverOptions,
                    fileSystem: context.fileSystem,
                    transport: context.transport,
                    environment: context.environment
                ) {
                    return compatible
                }
                if await EffectClient.Service.discover(
                    options: ServiceDiscoverOptions(file: options.file, version: nil),
                    fileSystem: context.fileSystem,
                    transport: context.transport,
                    environment: context.environment
                ) != nil {
                    throw CLIError("Background server version does not match this client")
                }
                return try await EffectClient.Service.ensure(
                    options: options,
                    fileSystem: context.fileSystem,
                    transport: context.transport,
                    launcher: context.launcher,
                    signaler: context.signaler,
                    environment: context.environment
                )
            }
        }

        // parity: cli/src/services/server-connection.ts#shutdownPersistentPty [status=implemented hash=a66efe1fd1cc]
        public static func shutdownPersistentPty(
            _ options: ServiceDiscoverOptions,
            context: CLIContext = CLIContext.current
        ) async throws {
            let discoverOpts = ServiceDiscoverOptions(file: options.file, version: nil)
            guard let endpoint = await EffectClient.Service.discover(
                options: discoverOpts,
                fileSystem: context.fileSystem,
                transport: context.transport,
                environment: context.environment
            ) else {
                return
            }
            let client = context.makeClient(endpoint: endpoint)
            try await client.experimental.persistentPty.shutdown()
        }

        private static func connectError(endpoint: ServiceEndpoint, cause: any Error) -> CLIError {
            if isUnauthorizedError(cause) {
                return CLIError(
                    endpoint.auth == nil
                        ? "Server at \(endpoint.url) requires a password; set OPENCODE_PASSWORD"
                        : "Server at \(endpoint.url) rejected the password"
                )
            }
            if let clientErr = cause as? ClientError, clientErr.reason == .transport {
                return CLIError("Could not reach server at \(endpoint.url): \(CLIUtil.errorMessage(cause))")
            }
            return CLIError("Server at \(endpoint.url) did not provide a compatible V2 health response: \(CLIUtil.errorMessage(cause))")
        }
    }

    // MARK: Update Preflight Banner (`packages/cli/src/services/update-preflight.tsx`)

    public enum UpdatePreflight {
        public static let stages: [String] = [
            "Keeping your session safe",
            "Starting the new background service",
            "Loading OpenCode",
        ]

        // parity: cli/src/services/update-preflight.tsx#Handle [status=implemented hash=b3a928f8f38a]
        public struct Handle: Sendable {
            public let begin: @Sendable (String?) -> Bool
            public let loading: @Sendable () -> Void
            public let finish: @Sendable () async -> TUIApp.TerminalHandoff?
            public let fail: @Sendable (String) async -> Void
            public let close: @Sendable () async -> Void

            public init(
                begin: @escaping @Sendable (String?) -> Bool,
                loading: @escaping @Sendable () -> Void,
                finish: @escaping @Sendable () async -> TUIApp.TerminalHandoff?,
                fail: @escaping @Sendable (String) async -> Void,
                close: @escaping @Sendable () async -> Void
            ) {
                self.begin = begin
                self.loading = loading
                self.finish = finish
                self.fail = fail
                self.close = close
            }
        }

        // parity: cli/src/services/update-preflight.tsx#make [status=adapted hash=32bce119b707]
        public static let make: @Sendable () -> Handle = {
            makeHandle(context: CLIContext.current)
        }

        public static func makeHandle(context: CLIContext = CLIContext.current) -> Handle {
            struct State: Sendable {
                var active = false
                var stage = 0
                var closed = false
            }
            let state = Mutex(State())
            return Handle(
                begin: { from in
                    guard context.io.isStdoutTTY() && context.io.isStdinTTY() else { return false }
                    let started = state.withLock { s -> Bool in
                        if s.active { return false }
                        s.active = true
                        s.stage = 0
                        return true
                    }
                    if started {
                        let fromLabel = from.map { " from \($0)" } ?? ""
                        context.io.writeStderr("OpenCode is updating\(fromLabel) to \(context.version)...\n")
                    }
                    return true
                },
                loading: {
                    state.withLock { s in
                        if s.active && !s.closed { s.stage = 2 }
                    }
                },
                finish: {
                    let wasActive = state.withLock { s -> Bool in
                        let was = s.active && !s.closed
                        s.closed = true
                        return was
                    }
                    if wasActive {
                        context.io.writeStderr("✓ OpenCode updated to \(context.version)\n")
                    }
                    return nil
                },
                fail: { message in
                    let wasActive = state.withLock { s -> Bool in
                        let was = s.active && !s.closed
                        s.closed = true
                        return was
                    }
                    if wasActive {
                        context.io.writeStderr("! \(message)\n")
                    }
                },
                close: {
                    state.withLock { $0.closed = true }
                }
            )
        }
    }

    // MARK: Updater Action & SemVer Parser (`packages/cli/src/services/updater-action.ts`)

    public enum UpdaterAction {
        // parity: cli/src/services/updater-action.ts#Policy [status=implemented hash=176a81c40c85]
        public enum Policy: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case disable
            case notify
            case auto
        }

        // parity: cli/src/services/updater-action.ts#Action [status=implemented hash=bcab1d0bc5b1]
        public enum Action: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case none
            case notify
            case auto
        }

        public struct ReleaseVersion: Equatable, Hashable, Sendable {
            public let major: String
            public let core: String
            public let prerelease: [String]

            public init(major: String, core: String, prerelease: [String]) {
                self.major = major
                self.core = core
                self.prerelease = prerelease
            }
        }

        private static let maximumComponent = "9007199254740991"

        // parity: cli/src/services/updater-action.ts#action [status=implemented hash=7c8fdcbda39f]
        public static func action(current: String, latest: String, policy: Policy) -> Action {
            if policy == .disable { return .none }
            guard let currentVersion = parseReleaseVersion(current),
                  let latestVersion = parseReleaseVersion(latest),
                  !sameRelease(currentVersion, latestVersion)
            else {
                return .none
            }
            return policy == .auto ? .auto : .notify
        }

        // parity: cli/src/services/updater-action.ts#parseReleaseVersion [status=implemented hash=0c1aebe2ac3e]
        public static func parseReleaseVersion(_ input: String) -> ReleaseVersion? {
            if input.count > 256 { return nil }
            var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("v") {
                text.removeFirst()
            }
            guard !text.isEmpty else { return nil }

            // Strip optional build metadata (+...)
            if let plusIdx = text.firstIndex(of: "+") {
                let build = String(text[text.index(after: plusIdx)...])
                guard isValidDotIdentifiers(build) else { return nil }
                text = String(text[..<plusIdx])
            }

            // Split optional prerelease (-...)
            var prerelease: [String] = []
            if let dashIdx = text.firstIndex(of: "-") {
                let preRaw = String(text[text.index(after: dashIdx)...])
                guard isValidDotIdentifiers(preRaw) else { return nil }
                let parts = preRaw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                for id in parts {
                    if id.count > 1 && id.hasPrefix("0") && id.allSatisfy(\.isASCIIWholeNumber) {
                        return nil
                    }
                }
                prerelease = parts
                text = String(text[..<dashIdx])
            }

            let coreParts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard coreParts.count == 3 else { return nil }
            for part in coreParts {
                guard !part.isEmpty, part.allSatisfy(\.isASCIIWholeNumber) else { return nil }
                if invalidComponent(part) { return nil }
            }

            return ReleaseVersion(
                major: coreParts[0],
                core: "\(coreParts[0]).\(coreParts[1]).\(coreParts[2])",
                prerelease: prerelease
            )
        }

        private static func isValidDotIdentifiers(_ s: String) -> Bool {
            guard !s.isEmpty else { return false }
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            return parts.allSatisfy { part in
                !part.isEmpty && part.unicodeScalars.allSatisfy { sc in
                    let v = sc.value
                    return (v >= 0x30 && v <= 0x39)
                        || (v >= 0x41 && v <= 0x5A)
                        || (v >= 0x61 && v <= 0x7A)
                        || v == 0x2D
                }
            }
        }

        private static func sameRelease(_ current: ReleaseVersion, _ latest: ReleaseVersion) -> Bool {
            if current.core != latest.core || current.prerelease.count != latest.prerelease.count {
                return false
            }
            for (lhs, rhs) in zip(current.prerelease, latest.prerelease) {
                if lhs == rhs { continue }
                if lhs.allSatisfy(\.isASCIIWholeNumber),
                   rhs.allSatisfy(\.isASCIIWholeNumber),
                   let a = Double(lhs), let b = Double(rhs), a == b
                {
                    continue
                }
                return false
            }
            return true
        }

        private static func invalidComponent(_ value: String) -> Bool {
            if value.count > 1 && value.hasPrefix("0") { return true }
            if value.count != maximumComponent.count {
                return value.count > maximumComponent.count
            }
            return value > maximumComponent
        }
    }

    // MARK: CLI Updater Service (`packages/cli/src/services/updater.ts`)

    public enum Updater {
        // parity: cli/src/services/updater.ts#Method [status=implemented hash=c903d13d5e0e]
        public enum Method: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case curl, npm, pnpm, bun, yarn, vp, brew, winget
        }

        // parity: cli/src/services/updater.ts#methods [status=implemented hash=6019e3b3c852]
        public static let methods: [Method] = [.curl, .npm, .pnpm, .bun, .yarn, .vp, .brew, .winget]

        // parity: cli/src/services/updater.ts#RunResult [status=implemented hash=6bb83450e6e7]
        public struct RunResult: Equatable, Hashable, Sendable, Codable {
            public enum Kind: String, Equatable, Hashable, Sendable, Codable {
                case available
                case installed
            }

            public let type: Kind
            public let version: String

            public init(type: Kind, version: String) {
                self.type = type
                self.version = version
            }
        }

        // parity: cli/src/services/updater.ts#CheckResult [status=implemented hash=fe3c869ed16f]
        public enum CheckResult: Equatable, Hashable, Sendable, Codable {
            case available(version: String)
            case installed(version: String)
            case unavailable(message: String)
        }

        // parity: cli/src/services/updater.ts#UpgradeError [status=implemented hash=2b6993dc0062]
        public struct UpgradeError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
            public let title: String
            public let detail: String
            public let command: String?
            public let retry: String

            public init(title: String, detail: String, command: String? = nil, retry: String) {
                self.title = title
                self.detail = detail
                self.command = command
                self.retry = retry
            }

            public var description: String { detail }
        }

        public struct RemovalPlan: Sendable {
            public let command: [String]
            public let run: @Sendable () async throws -> Void

            public init(command: [String], run: @escaping @Sendable () async throws -> Void) {
                self.command = command
                self.run = run
            }
        }

        // parity: cli/src/services/updater.ts#Interface [status=implemented hash=dbb06308bc99]
        public protocol Interface: Sendable {
            func run(onInstall: (@Sendable (String) -> Void)?) async -> RunResult?
            func check() async throws -> CheckResult?
            func apply(version: String) async throws
            func method() async -> Method?
            func managed(version: String?) async throws -> UpgradeError?
            func latest(method: Method?) async throws -> String
            func upgrade(method: Method, version: String) async throws
            func removal(method: Method) -> RemovalPlan?
        }

        /// Decodes host-level `update` (or legacy `autoupdate`) policy from a JSON/JSONC config file.
        // parity: cli/src/services/updater.ts#decodePolicy [status=implemented hash=72999bbc8920]
        public static func decodePolicy(_ text: String) -> UpdaterAction.Policy? {
            guard let parsed = try? CoreConfigJSONC.parse(text),
                  case .object(let dict) = parsed
            else {
                return nil
            }
            if let update = dict["update"] {
                if case .string(let raw) = update {
                    return UpdaterAction.Policy(rawValue: raw)
                }
                return nil
            }
            guard let auto = dict["autoupdate"] else { return nil }
            switch auto {
            case .bool(false): return .disable
            case .bool(true): return .auto
            case .string("notify"): return .notify
            default: return nil
            }
        }

        // parity: cli/src/services/updater.ts#Service [status=adapted hash=48bbcf232e2e]
        public final class Service: Interface, Sendable {
            public static let serviceKey = "@opencode/cli/Updater"

            private static let wingetPackage = "Anomaly.OpenCode"
            private static let wingetArgs = [
                "--id", wingetPackage, "--exact", "--source", "winget",
                "--accept-source-agreements", "--disable-interactivity",
            ]
            private static let installNames: [Method: String] = [
                .curl: "The OpenCode installer",
                .npm: "npm",
                .pnpm: "pnpm",
                .bun: "Bun",
                .yarn: "Yarn",
                .vp: "Vite+",
                .brew: "Homebrew",
                .winget: "WinGet",
            ]

            private let context: CLIContext
            private let installedVersion: Mutex<String>

            public init(context: CLIContext = CLIContext.current) {
                self.context = context
                self.installedVersion = Mutex(context.version)
            }

            private var isLocal: Bool {
                context.channel == "local"
            }

            private var sanitizedChannel: String {
                CLIUtil.sanitizeChannelSegment(context.channel)
            }

            private func resolvedExecutable() async -> String {
                (try? await context.fileSystem.realPath(at: context.executablePath)) ?? context.executablePath
            }

            private func detectInstalledFormula(executable: String) -> String? {
                let norm = executable.replacing("\\", with: "/")
                for name in ["opencode", "opencode-beta", "opencode-v2"] {
                    if norm.contains("/Cellar/\(name)/") { return name }
                }
                return nil
            }

            private func detectInstalledWinget(executable: String) -> Bool {
                executable.replacing("\\", with: "/").lowercased().contains("/winget/packages/anomaly.opencode_")
            }

            private func detectInstalledPackage(executable: String) async -> String? {
                let dir = CLIPath.dirname(CLIPath.dirname(executable))
                let pkgPath = CLIPath.join(dir, "package.json")
                guard let bytes = try? await context.fileSystem.readFile(at: pkgPath),
                      let json = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes)),
                      case .object(let obj) = json,
                      case .string(let name) = obj["name"]
                else {
                    return nil
                }
                let validNames: Set<String> = [
                    "@opencode/cli", "@opencode/cli-node",
                    "@opencode-ai/cli", "@opencode-ai/cli-node",
                ]
                guard validNames.contains(name) else { return nil }
                if case .object(let bins) = obj["bin"] {
                    for (_, val) in bins {
                        if case .string(let binRel) = val, CLIPath.resolve(dir, binRel) == executable {
                            return name
                        }
                    }
                }
                return nil
            }

            private func detectOwner(executable: String, installedPackage: String?) -> (name: String, command: String)? {
                guard installedPackage != nil else { return nil }
                let norm = executable.replacing("\\", with: "/")
                if norm.contains("/tools/image/packages/") {
                    return ("Volta", "volta install ")
                }
                if norm.range(of: #"/installs/npm-[^/]+/"#, options: .regularExpression) != nil {
                    return ("mise", "mise use -g npm:")
                }
                return nil
            }

            private func execCommand(_ command: [String], timeoutMs: Int = 30_000) async throws -> (code: Int32, stdout: String, stderr: String) {
                guard let exe = command.first else {
                    throw CLIError("Empty command")
                }
                let result = try await context.appProcess.run(
                    ProcessSpec(executable: exe, arguments: Array(command.dropFirst())),
                    options: AppProcess.RunOptions(maxOutputBytes: 100_000, maxErrorBytes: 100_000, timeoutMs: timeoutMs)
                )
                return (
                    code: result.exitCode,
                    stdout: String(decoding: result.stdout, as: UTF8.self),
                    stderr: String(decoding: result.stderr, as: UTF8.self)
                )
            }

            public func method() async -> Method? {
                let executable = await resolvedExecutable()
                let curlName = context.platformOS == .windows ? "opencode.exe" : "opencode"
                let curlPath = CLIPath.join(context.globalPaths.home, ".opencode", "bin", curlName)
                let curlBinary = (try? await context.fileSystem.realPath(at: curlPath)) ?? curlPath
                if executable == curlBinary { return .curl }
                if detectInstalledFormula(executable: executable) != nil { return .brew }
                if detectInstalledWinget(executable: executable) { return .winget }
                let pkg = await detectInstalledPackage(executable: executable)
                guard let pkg, detectOwner(executable: executable, installedPackage: pkg) == nil else {
                    return nil
                }

                let checks: [(Method, [String])] = [
                    (.npm, ["npm", "list", "-g", "--depth=0", pkg]),
                    (.pnpm, ["pnpm", "list", "-g", "--depth=0", pkg]),
                    (.bun, ["bun", "pm", "ls", "-g"]),
                    (.yarn, ["yarn", "global", "list"]),
                    (.vp, ["vp", "list", "-g", "--json", pkg]),
                ]
                for (candidate, cmd) in checks {
                    guard let res = try? await execCommand(cmd) else { continue }
                    if candidate == .vp {
                        if let data = res.stdout.data(using: .utf8),
                           let items = try? JSONDecoder().decode([[String: JSONValue]].self, from: data),
                           items.contains(where: { $0["name"] == .string(pkg) }) {
                            return .vp
                        }
                    } else if res.stdout.contains(pkg) {
                        return candidate
                    }
                }
                return nil
            }

            private func fetchRelease(method: Method?) async throws -> (package: String, version: String) {
                let executable = await resolvedExecutable()
                let formula = detectInstalledFormula(executable: executable)
                let distribution = method == .brew ? "homebrew" : "npm"
                let isCoreBrew = method == .brew && formula == "opencode"
                let url = isCoreBrew
                    ? "https://formulae.brew.sh/api/formula/opencode.json"
                    : "https://opencode.ai/update/api/\(ClientURLBuilder.encodeURIComponent(sanitizedChannel))/\(ClientURLBuilder.encodeURIComponent(context.artifact))/\(distribution)?current=\(ClientURLBuilder.encodeURIComponent(context.version))"

                let response: HTTPResponse
                do {
                    response = try await context.transport.send(HTTPRequest(method: "GET", url: url))
                } catch {
                    throw UpgradeError(
                        title: "Could not check for OpenCode updates",
                        detail: CLIUtil.errorMessage(error),
                        retry: "Check your network, then run opencode upgrade again."
                    )
                }
                guard (200..<300).contains(response.head.statusCode) else {
                    throw UpgradeError(
                        title: "Could not check for OpenCode updates",
                        detail: "The update service returned HTTP \(response.head.statusCode).",
                        retry: "Try again in a few minutes."
                    )
                }
                guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(response.body)),
                      case .object(let obj) = json
                else {
                    throw UpgradeError(
                        title: "Could not read the OpenCode update information",
                        detail: "Invalid JSON response",
                        retry: "Try again in a few minutes."
                    )
                }
                let version: String?
                let packageName: String?
                if isCoreBrew {
                    if case .object(let versions) = obj["versions"], case .string(let stable) = versions["stable"] {
                        version = stable
                    } else {
                        version = nil
                    }
                    packageName = "opencode"
                } else {
                    if case .string(let v) = obj["version"] { version = v } else { version = nil }
                    if case .object(let meta) = obj["metadata"], case .string(let pkg) = meta["package"] {
                        packageName = pkg
                    } else {
                        packageName = nil
                    }
                }
                guard let version, !version.isEmpty, let packageName, !packageName.isEmpty else {
                    throw UpgradeError(
                        title: "Could not read the OpenCode update information",
                        detail: "The update service returned incomplete release information.",
                        retry: "Try again in a few minutes."
                    )
                }
                return (package: packageName, version: version)
            }

            public func latest(method selected: Method? = nil) async throws -> String {
                let effective: Method?
                if let selected {
                    effective = selected
                } else {
                    effective = await self.method()
                }
                if effective == .winget {
                    let res = try await execCommand(["winget", "search"] + Self.wingetArgs, timeoutMs: 60_000)
                    for line in res.stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
                        if let idx = tokens.firstIndex(where: { $0.lowercased() == Self.wingetPackage.lowercased() }),
                           idx + 1 < tokens.count,
                           UpdaterAction.parseReleaseVersion(tokens[idx + 1]) != nil
                        {
                            return tokens[idx + 1]
                        }
                    }
                    throw UpgradeError(
                        title: "Could not check for OpenCode updates",
                        detail: Self.conciseDetail(res.stderr) ?? Self.conciseDetail(res.stdout) ?? "The command exited with code \(res.code) without any error output.",
                        command: (["winget", "search"] + Self.wingetArgs).joined(separator: " "),
                        retry: "Fix the issue above, then run opencode upgrade again."
                    )
                }
                return try await fetchRelease(method: effective).version
            }

            public func managed(version input: String? = nil) async throws -> UpgradeError? {
                let executable = await resolvedExecutable()
                let pkg = await detectInstalledPackage(executable: executable)
                guard let owner = detectOwner(executable: executable, installedPackage: pkg) else { return nil }
                if let input, UpdaterAction.parseReleaseVersion(input) == nil {
                    throw CLIError("Invalid version: \(input)")
                }
                let data = try await fetchRelease(method: .npm)
                let cleaned = input?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^v", with: "", options: .regularExpression) ?? data.version
                return UpgradeError(
                    title: "OpenCode is managed by \(owner.name)",
                    detail: "This copy was installed with \(owner.name), which keeps its own record of the installed version, so OpenCode won't update it directly.",
                    command: "\(owner.command)\(data.package)@\(cleaned)",
                    retry: "Run the command above, then restart OpenCode."
                )
            }

            public func upgrade(method: Method, version input: String) async throws {
                guard UpdaterAction.parseReleaseVersion(input) != nil else {
                    throw CLIError("Invalid version: \(input)")
                }
                var version = input.trimmingCharacters(in: .whitespacesAndNewlines)
                if version.hasPrefix("v") { version.removeFirst() }
                let executable = await resolvedExecutable()
                let formula = detectInstalledFormula(executable: executable)
                let packageName: String
                if method == .winget {
                    packageName = Self.wingetPackage
                } else if method == .brew && formula == "opencode" {
                    packageName = "opencode"
                } else {
                    packageName = try await fetchRelease(method: method).package
                }
                let target = "\(packageName)@\(version)"
                let command: [String]
                switch method {
                case .npm:
                    command = ["npm", "install", "--global", "--allow-scripts=\(packageName)", target]
                case .pnpm:
                    command = ["pnpm", "add", "--global", "--allow-build=\(packageName)", target]
                case .yarn:
                    command = ["yarn", "global", "add", target]
                case .bun:
                    command = ["bun", "install", "--global", "--trust", target]
                case .vp:
                    command = ["vp", "update", "-g", target]
                case .brew:
                    command = ["brew", "upgrade", packageName]
                case .winget:
                    command = ["winget", "upgrade"] + Self.wingetArgs + ["--version", version, "--silent", "--accept-package-agreements"]
                case .curl:
                    command = ["bash", "-c", "curl -fsSL https://opencode.ai/v2/install | bash -s -- --version \(version) --no-modify-path"]
                }

                let res = try await execCommand(command, timeoutMs: 300_000)
                if res.code != 0 {
                    throw UpgradeError(
                        title: "\(Self.installNames[method] ?? method.rawValue) could not install OpenCode",
                        detail: Self.conciseDetail(res.stderr) ?? Self.conciseDetail(res.stdout) ?? "The command exited with code \(res.code) without any error output.",
                        command: command.joined(separator: " "),
                        retry: "Fix the issue above, then run opencode upgrade again."
                    )
                }
            }

            public func removal(method: Method) -> RemovalPlan? {
                if method == .winget {
                    let cmd = ["winget", "uninstall"] + Self.wingetArgs
                    return RemovalPlan(command: cmd) { [self] in
                        let res = try await self.execCommand(cmd, timeoutMs: 300_000)
                        if res.code != 0 { throw CLIError(Self.conciseDetail(res.stderr) ?? "Uninstall failed") }
                    }
                }
                if method == .curl || method == .brew { return nil }
                let pkg = "@opencode/cli"
                let cmd: [String]
                switch method {
                case .npm: cmd = ["npm", "uninstall", "--global", pkg]
                case .pnpm: cmd = ["pnpm", "remove", "--global", pkg]
                case .bun: cmd = ["bun", "remove", "--global", pkg]
                case .yarn: cmd = ["yarn", "global", "remove", pkg]
                case .vp: cmd = ["vp", "uninstall", "-g", pkg]
                default: return nil
                }
                return RemovalPlan(command: cmd) { [self] in
                    let res = try await self.execCommand(cmd, timeoutMs: 300_000)
                    if res.code != 0 { throw CLIError(Self.conciseDetail(res.stderr) ?? "Uninstall failed") }
                }
            }

            private func readPolicy() async -> UpdaterAction.Policy {
                var policy: UpdaterAction.Policy?
                for name in ["config.json", "opencode.json", "opencode.jsonc"] {
                    let file = CLIPath.join(context.globalPaths.config, name)
                    if let bytes = try? await context.fileSystem.readFile(at: file),
                       let decoded = Updater.decodePolicy(String(decoding: bytes, as: UTF8.self)) {
                        policy = decoded
                    }
                }
                return policy ?? .notify
            }

            public func check() async throws -> CheckResult? {
                if isLocal {
                    return .unavailable(message: "This build runs from a source checkout. Use an installed OpenCode release to check for updates.")
                }
                let detected = await method()
                if detected == nil {
                    if let managedErr = try await managed(version: nil) {
                        return .unavailable(message: "\(managedErr.title). Update it with \(managedErr.command ?? "")")
                    }
                    return .unavailable(message: "Could not detect the installation method. Update with your package manager or download the latest release.")
                }
                let version = try await latest(method: detected)
                guard UpdaterAction.parseReleaseVersion(version) != nil else {
                    throw CLIError("Invalid version: \(version)")
                }
                let current = installedVersion.withLock { $0 }
                if UpdaterAction.action(current: current, latest: version, policy: .auto) == .none {
                    if UpdaterAction.action(current: context.version, latest: current, policy: .auto) == .none {
                        return nil
                    }
                    return .installed(version: current)
                }
                return .available(version: version)
            }

            public func apply(version: String) async throws {
                if let detected = await method() {
                    try await upgrade(method: detected, version: version)
                    installedVersion.withLock { $0 = version }
                    return
                }
                if let err = try await managed(version: version) {
                    throw CLIError("\(err.title). Update it with \(err.command ?? "")")
                }
                throw CLIError("Could not detect the installation method. Update with your package manager or download the latest release.")
            }

            public func run(onInstall: (@Sendable (String) -> Void)? = nil) async -> RunResult? {
                let disabled = context.envVariable("OPENCODE_DISABLE_AUTOUPDATE")?.lowercased()
                if isLocal || disabled == "1" || disabled == "true" {
                    return nil
                }
                let policy = await readPolicy()
                if policy == .disable { return nil }
                let current = installedVersion.withLock { $0 }
                guard let latestVer = try? await latest() else { return nil }
                let act = UpdaterAction.action(current: current, latest: latestVer, policy: policy)
                if act == .none { return nil }
                if act == .notify { return RunResult(type: .available, version: latestVer) }
                onInstall?(latestVer)
                guard let detected = await method(),
                      (try? await upgrade(method: detected, version: latestVer)) != nil
                else {
                    return nil
                }
                installedVersion.withLock { $0 = latestVer }
                return RunResult(type: .installed, version: latestVer)
            }

            internal static func conciseDetail(_ input: String) -> String? {
                let cleaned = CLIPath.stripANSI(input)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacing("\r", with: "\n")
                let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> String in
                        var s = String(line)
                        while let last = s.last, last.isWhitespace { s.removeLast() }
                        return s
                    }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let tail = lines.suffix(12).joined(separator: "\n")
                let clipped = tail.count > 2_000
                let detail = clipped ? "…" + String(tail.suffix(1_999)) : tail
                guard !detail.isEmpty else { return nil }
                if lines.count <= 12 && !clipped { return detail }
                return "\(detail)\n\nOutput shortened to the last 12 lines."
            }
        }

        // parity: cli/src/services/updater.ts#layer [status=adapted hash=0df0809780fe]
        public static let layer: LayerNode.ExecutableLayer = LayerNode.ExecutableLayer { _, _ in
            LayerNode.Output([Service.serviceKey: Service(context: CLIContext.current)])
        }
    }

    // MARK: Web UI Static Asset Middleware (`packages/cli/src/services/web-ui.ts`)

    public enum WebUi {
        public struct Options: Sendable {
            public let assets: CLIUtil.AppAssets.AssetMap?
            public let brotli: CLIUtil.AppAssets.BrotliMap?

            public init(assets: CLIUtil.AppAssets.AssetMap? = nil, brotli: CLIUtil.AppAssets.BrotliMap? = nil) {
                self.assets = assets
                self.brotli = brotli
            }
        }

        public struct WebRequest: Equatable, Sendable {
            public let method: String
            public let url: String
            public let headers: [String: String]

            public init(method: String = "GET", url: String, headers: [String: String] = [:]) {
                self.method = method
                self.url = url
                self.headers = headers
            }
        }

        public struct WebResponse: Equatable, Sendable {
            public let status: Int
            public let headers: [String: String]
            public let body: [UInt8]

            public init(status: Int, headers: [String: String] = [:], body: [UInt8] = []) {
                self.status = status
                self.headers = headers
                self.body = body
            }
        }

        public typealias Middleware = @Sendable (WebRequest, @escaping @Sendable (WebRequest) async throws -> WebResponse?) async throws -> WebResponse

        /// Creates the Web UI routing/CSP/brotli handler middleware matching `WebUi.handler`.
        // parity: cli/src/services/web-ui.ts#handler [status=implemented hash=9c5428ac37c1]
        public static func handler(
            options: Options? = nil,
            context: CLIContext = CLIContext.current
        ) async throws -> Middleware {
            let loaded: CLIUtil.AppAssets.LoadedAssets
            if let assets = options?.assets {
                loaded = CLIUtil.AppAssets.LoadedAssets(files: assets, brotli: options?.brotli)
            } else {
                loaded = (try? await CLIUtil.AppAssets.load(fileSystem: context.fileSystem))
                    ?? CLIUtil.AppAssets.LoadedAssets(files: [:], brotli: nil)
            }

            return { request, apiHandler in
                let pathname = extractPathname(request.url)
                if pathname == "/api"
                    || pathname.hasPrefix("/api/")
                    || pathname.hasPrefix("/auth/")
                    || pathname == "/openapi.json"
                {
                    if let apiResp = try await apiHandler(request) {
                        return apiResp
                    }
                    return WebResponse(status: 404)
                }
                return serveUI(request: request, pathname: pathname, assets: loaded.files, brotli: loaded.brotli)
            }
        }

        private static func extractPathname(_ rawURL: String) -> String {
            if let comps = URLComponents(string: rawURL) {
                return comps.path.isEmpty ? "/" : comps.path
            }
            let base = rawURL.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawURL
            return base.hasPrefix("/") ? base : "/\(base)"
        }

        private static func serveUI(
            request: WebRequest,
            pathname: String,
            assets: CLIUtil.AppAssets.AssetMap,
            brotli: CLIUtil.AppAssets.BrotliMap?
        ) -> WebResponse {
            let key = pathname.hasPrefix("/") ? String(pathname.dropFirst()) : pathname
            let acceptEnc = request.headers.first(where: { $0.key.lowercased() == "accept-encoding" })?.value
            let encoded: [UInt8]? = (key != "index.html" && acceptsBrotli(acceptEnc)) ? brotli?[key] : nil
            let requested: CLIUtil.AppAssets.AssetContent? = encoded.map { .binary($0) } ?? assets[key]

            if (key.hasPrefix("_assets/") || key.hasPrefix("icons/")) && requested == nil {
                return WebResponse(status: 404, headers: ["cache-control": "no-store"])
            }
            let name = requested != nil ? key : "index.html"
            guard let file = requested ?? assets["index.html"] else {
                return WebResponse(status: 404)
            }
            let method = request.method.uppercased()
            if method != "GET" && method != "HEAD" {
                return WebResponse(status: 405)
            }
            let isHtml = name == "index.html"
            let revalidate = isHtml || name == "sw.js" || name == "registerSW.js"
            var headers: [String: String] = [
                "content-type": FSPathUtil.mimeType(name),
                "cache-control": revalidate ? "no-cache" : "public, max-age=31536000, immutable",
                "content-security-policy": isHtml ? cspForHtml(file.utf8String) : csp(),
                "x-content-type-options": "nosniff",
            ]
            if !isHtml && brotli?[name] != nil {
                headers["vary"] = "accept-encoding"
            }
            if encoded != nil {
                headers["content-encoding"] = "br"
            }
            return WebResponse(
                status: 200,
                headers: headers,
                body: method == "HEAD" ? [] : file.bytes
            )
        }

        internal static func acceptsBrotli(_ header: String?) -> Bool {
            guard let header else { return false }
            for entry in header.split(separator: ",") {
                let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard parts.first == "br" else { continue }
                let zeroQ = parts.dropFirst().contains { part in
                    part.hasPrefix("q=") && Double(part.dropFirst(2)) == 0.0
                }
                if !zeroQ { return true }
            }
            return false
        }

        internal static func csp(hash: String = "") -> String {
            let hashPart = hash.isEmpty ? "" : " 'sha256-\(hash)'"
            return "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'\(hashPart); style-src 'self' 'unsafe-inline'; img-src 'self' data: https: blob:; font-src 'self' data:; media-src 'self' data:; connect-src * data: blob:; worker-src 'self' blob:; frame-src 'self' blob:; object-src 'self' blob:"
        }

        internal static func cspForHtml(_ body: String) -> String {
            let pattern = #"<script\b(?![^>]*\bsrc\s*=)[^>]*\bid=(["'])oc-theme-preload-script\1[^>]*>([\s\S]*?)<\/script>"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
               let scriptRange = Range(match.range(at: 2), in: body)
            {
                let scriptBody = String(body[scriptRange])
                let hexDigest = Hash.sha256(scriptBody)
                let digestBytes = hexToBytes(hexDigest)
                return csp(hash: bytesToBase64(digestBytes))
            }
            return csp()
        }

        private static func hexToBytes(_ hex: String) -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(hex.count / 2)
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                if let byte = UInt8(hex[idx..<next], radix: 16) {
                    bytes.append(byte)
                }
                idx = next
            }
            return bytes
        }
    }

    // MARK: Server Process Lifecycle (`packages/cli/src/server-process.ts`)

    public enum ServerProcess {
        // parity: cli/src/server-process.ts#Mode [status=implemented hash=f907e3596c34]
        public enum Mode: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
            case `default`
            case service
            case stdio
        }

        // parity: cli/src/server-process.ts#Options [status=implemented hash=ca92243fd4ec]
        public struct Options: Equatable, Hashable, Sendable {
            public let mode: Mode
            public let hostname: String?
            public let port: Int?
            public let cors: [String]?

            public init(mode: Mode, hostname: String? = nil, port: Int? = nil, cors: [String]? = nil) {
                self.mode = mode
                self.hostname = hostname
                self.port = port
                self.cors = cors
            }
        }

        public struct StartRequest: Equatable, Sendable {
            public let hostname: String
            public let port: Int
            public let cors: [String]?
            public let password: String
            public let databasePath: String
            public let mode: Mode

            public init(
                hostname: String,
                port: Int,
                cors: [String]?,
                password: String,
                databasePath: String,
                mode: Mode
            ) {
                self.hostname = hostname
                self.port = port
                self.cors = cors
                self.password = password
                self.databasePath = databasePath
                self.mode = mode
            }
        }

        public struct StartedServer: Sendable {
            public let url: String
            public let hostname: String
            public let port: Int
            public let waitForShutdown: @Sendable () async -> Void
            public let shutdown: @Sendable () async -> Void

            public init(
                url: String,
                hostname: String = "127.0.0.1",
                port: Int = 0,
                waitForShutdown: @escaping @Sendable () async -> Void = {},
                shutdown: @escaping @Sendable () async -> Void = {}
            ) {
                self.url = url
                self.hostname = hostname
                self.port = port
                self.waitForShutdown = waitForShutdown
                self.shutdown = shutdown
            }
        }

        public typealias Starter = @Sendable (StartRequest) async throws -> StartedServer

        /// Runs the OpenCode HTTP/WebUI server process in `default`, `service`, or `stdio` mode.
        // parity: cli/src/server-process.ts#run [status=adapted hash=a2135daa6b45]
        public static let run: @Sendable (Options, CLIContext) async throws -> Void = { options, context in
            let global = context.globalPaths
            let foreground = options.mode == .default
            let serviceOptions = options.mode == .service
                ? try await ServiceConfig.options(ServiceConfig.OptionsInput(), context)
                : nil
            let config = options.mode == .service ? try await ServiceConfig.read(context: context) : ServiceConfig.Info()
            let hostname = options.hostname ?? config.hostname ?? "127.0.0.1"
            let port = options.port ?? config.port ?? (options.mode == .service ? ServiceConfig.defaultPort(channel: context.channel, platform: context.platformOS) : 0)

            if let serviceOptions, port > 0 {
                let candidateURL = serviceURL(hostname: hostname, port: port)
                if await EffectClient.Service.incumbent(
                    url: candidateURL,
                    options: serviceOptions.discoverOptions,
                    fileSystem: context.fileSystem,
                    transport: context.transport,
                    environment: context.environment
                ) != nil {
                    return
                }
            }

            if let savedEnv = ServiceConfig.processEnv(config.env) {
                for (k, v) in savedEnv {
                    context.setEnvOverride(k, value: v)
                }
            }

            var retainedHandle: RetainedImage.RetainedHandle? = nil
            if options.mode == .service && context.platformOS == .windows && RetainedImage.installed(home: global.home, execPath: context.executablePath) {
                retainedHandle = await RetainedImage.retain(global.cache, .service, context)
            }
            defer {
                if let retainedHandle {
                    Task { await retainedHandle.release() }
                }
            }

            let environmentPassword = CLIUtil.Env.password(context)
            if options.mode == .stdio {
                context.setEnvOverride("OPENCODE_PASSWORD", value: nil)
                context.setEnvOverride("OPENCODE_SERVER_PASSWORD", value: nil)
            }
            let password: String
            if options.mode == .service {
                password = (config.password?.isEmpty == false ? config.password! : CLIPath.randomBase64URL(bytes: 32))
            } else if let envPwd = environmentPassword?.value, !envPwd.isEmpty {
                password = envPwd
            } else {
                password = CLIPath.randomBase64URL(bytes: 32)
            }

            let dbPath = CLIUtil.databasePath(global.data, channel: context.channel, environment: context.environment)
            let starter = context.serverStarter ?? defaultLoopbackStarter(context: context)
            let started: StartedServer
            do {
                started = try await starter(
                    StartRequest(
                        hostname: hostname,
                        port: port,
                        cors: options.cors ?? config.cors,
                        password: password,
                        databasePath: dbPath,
                        mode: options.mode
                    )
                )
            } catch {
                if options.mode == .service, port > 0 {
                    let owner = await PortOwner.describe(port, hostname, context)
                    throw CLIError(
                        "Managed service port \(port) on \(hostname) is already in use by \(owner ?? "another process"). "
                            + "Configure another port with `opencode service set port <port>` and start the service again."
                    )
                }
                throw error
            }

            var registration: ServiceRegistration.Handle? = nil
            if let serviceOptions, let regFile = serviceOptions.file {
                if config.password == nil || config.password?.isEmpty == true {
                    _ = try await ServiceConfig.password(password, context: context)
                }
                registration = try await ServiceRegistration.register(
                    ServiceRegistration.Options(
                        url: started.url,
                        password: password,
                        id: uuid(),
                        file: regFile,
                        shutdown: started.shutdown
                    ),
                    context
                )
            }
            defer {
                if let registration {
                    Task { await registration.cleanup() }
                }
            }

            var tunnelTask: Task<Void, Never>? = nil
            if serviceOptions != nil, let remoteRoute = config.remote?.route, started.port > 0 {
                let targetHost = (started.hostname == "0.0.0.0" || started.hostname == "::") ? "127.0.0.1" : started.hostname
                let target = "\(targetHost):\(started.port)"
                tunnelTask = Task.detached {
                    await RemoteTunnel.run(
                        RemoteTunnel.RunInput(route: remoteRoute, target: target, onURL: { _ in }),
                        context
                    )
                }
            }
            defer { tunnelTask?.cancel() }

            if options.mode == .stdio {
                let ready = try CLIPath.encodeCompactJSON(["url": started.url])
                context.io.writeStdout(ready + context.io.eol)
                _ = try? await CLIUtil.readStdin(context: context)
                await started.shutdown()
            } else {
                context.io.writeStdout("server listening on \(started.url)\(context.io.eol)")
                if foreground && environmentPassword == nil {
                    context.io.writeStdout("server password \(password)\(context.io.eol)")
                }
                await started.waitForShutdown()
            }
        }

        internal static func serviceURL(hostname: String, port: Int) -> String {
            let formatted = hostname.contains(":") ? "[\(hostname)]" : hostname
            return "http://\(formatted):\(port)"
        }

        /// Boots the full native `OpenCodeServer.ServerProcess` (all 173 protocol endpoints, SQLite, SSE, auth, CORS).
        internal static func defaultLoopbackStarter(context: CLIContext) -> Starter {
            { request in
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                let running = try await OpenCodeServer.ServerProcess.start(
                    options: OpenCodeServer.ServerOptions(
                        app: OpenCodeServer.ServerOptions.AppOptions(
                            name: context.artifact,
                            version: context.version,
                            channel: context.channel
                        ),
                        hostname: request.hostname,
                        port: request.port,
                        password: request.password,
                        cors: request.cors,
                        database: CoreDatabaseStore.Options(path: request.databasePath)
                    ),
                    fileSystem: context.fileSystem,
                    httpTransport: context.transport,
                    environment: context.environment,
                    defaultDirectory: context.cwd
                )
                let shutdownSignal = Mutex<CheckedContinuation<Void, Never>?>(nil)
                let stopped = Mutex(false)
                let shutdownFn: @Sendable () async -> Void = {
                    let shouldStop = stopped.withLock { flag -> Bool in
                        if flag { return false }
                        flag = true
                        return true
                    }
                    if shouldStop {
                        await running.stop()
                        if let cont = shutdownSignal.withLock({ c -> CheckedContinuation<Void, Never>? in
                            let prev = c
                            c = nil
                            return prev
                        }) {
                            cont.resume()
                        }
                    }
                }
                let url = serviceURL(hostname: running.address.host, port: running.address.port)
                return StartedServer(
                    url: url,
                    hostname: running.address.host,
                    port: running.address.port,
                    waitForShutdown: {
                        if stopped.withLock({ $0 }) { return }
                        await withCheckedContinuation { cont in
                            let already = stopped.withLock { $0 }
                            if already {
                                cont.resume()
                            } else {
                                shutdownSignal.withLock { $0 = cont }
                            }
                        }
                    },
                    shutdown: shutdownFn
                )
                #else
                _ = request
                throw PlatformError.unsupportedOnPlatform(context.platformOS, operation: "ServerProcess.run")
                #endif
            }
        }
    }

    // MARK: Session Target Resolution (`packages/cli/src/session-target.ts`)

    public enum SessionTargetService {
        // parity: cli/src/session-target.ts#SessionTarget [status=implemented hash=556b9e636954]
        public struct SessionTarget: Equatable, Sendable {
            public let session: SessionSchema.Info
            public let location: LocationSchema.PublicInfo
            public let model: ModelSchema.Ref?
            public let agent: String?
            public let resume: Bool

            public init(
                session: SessionSchema.Info,
                location: LocationSchema.PublicInfo,
                model: ModelSchema.Ref?,
                agent: String?,
                resume: Bool
            ) {
                self.session = session
                self.location = location
                self.model = model
                self.agent = agent
                self.resume = resume
            }
        }

        public struct PreparationInput: Sendable {
            public let client: OpenCodeClient
            public let location: LocationSchema.PublicInfo
            public let session: SessionSchema.Info?
            public let model: ModelSchema.Ref?
            public let agent: String?
            public let signal: AbortSignal?

            public init(
                client: OpenCodeClient,
                location: LocationSchema.PublicInfo,
                session: SessionSchema.Info?,
                model: ModelSchema.Ref?,
                agent: String?,
                signal: AbortSignal? = nil
            ) {
                self.client = client
                self.location = location
                self.session = session
                self.model = model
                self.agent = agent
                self.signal = signal
            }
        }

        // parity: cli/src/session-target.ts#SessionTargetPreparation [status=implemented hash=e247489fd23c]
        public typealias SessionTargetPreparation = @Sendable (PreparationInput) async throws -> (model: ModelSchema.Ref?, agent: String?)

        // parity: cli/src/session-target.ts#SessionTargetMutationError [status=implemented hash=e83e5f87e320]
        public struct SessionTargetMutationError: Error, Equatable, Sendable, CustomStringConvertible {
            public let message: String

            public init(_ cause: Any) {
                self.message = CLIUtil.errorMessage(cause)
            }

            public var description: String { message }
        }

        public struct ResolveInput: Sendable {
            public let client: OpenCodeClient
            public let directory: String?
            public let `continue`: Bool
            public let session: String?
            public let fork: Bool
            public let model: ModelSchema.Ref?
            public let agent: String?
            public let environment: [String: String]?
            public let prepare: SessionTargetPreparation
            public let signal: AbortSignal?

            public init(
                client: OpenCodeClient,
                directory: String? = nil,
                continue continueLast: Bool = false,
                session: String? = nil,
                fork: Bool = false,
                model: ModelSchema.Ref? = nil,
                agent: String? = nil,
                environment: [String: String]? = nil,
                prepare: @escaping SessionTargetPreparation,
                signal: AbortSignal? = nil
            ) {
                self.client = client
                self.directory = directory
                self.`continue` = continueLast
                self.session = session
                self.fork = fork
                self.model = model
                self.agent = agent
                self.environment = environment
                self.prepare = prepare
                self.signal = signal
            }
        }

        // parity: cli/src/session-target.ts#parseSessionTargetModel [status=implemented hash=e82b61c8a602]
        public static func parseSessionTargetModel(_ value: String?) throws -> ModelSchema.Ref? {
            guard let value, !value.isEmpty else { return nil }
            return try ModelSchema.Ref.parse(value)
        }

        // parity: cli/src/session-target.ts#findSession [status=implemented hash=6322c5c9a735]
        public static func findSession(
            client: OpenCodeClient,
            sessionID: String,
            signal: AbortSignal? = nil
        ) async throws -> SessionSchema.Info? {
            do {
                let reqOpts = signal.map { RequestOptions(signal: $0) }
                return try await client.session.get(SessionGetInput(sessionID: sessionID), options: reqOpts)
            } catch {
                if isSessionNotFoundError(error) {
                    return nil
                }
                throw error
            }
        }

        // parity: cli/src/session-target.ts#createWorktreeLocation [status=implemented hash=e80d4fa366bd]
        public static func createWorktreeLocation(
            client: OpenCodeClient,
            directory: String? = nil,
            name: String? = nil,
            signal: AbortSignal? = nil
        ) async throws -> (root: String, directory: String) {
            let reqOpts = signal.map { RequestOptions(signal: $0) }
            let base = try await resolveLocation(client: client, directory: directory, signal: signal)
            let created: WorktreeCreateOutput
            do {
                created = try await client.worktree.create(
                    WorktreeCreateInput(
                        projectID: base.project.id.rawValue,
                        from: base.project.directory.rawValue,
                        name: name
                    ),
                    options: reqOpts
                )
            } catch {
                throw SessionTargetMutationError(error)
            }
            let subfolder = CLIPath.relative(from: base.project.directory.rawValue, to: base.directory.rawValue)
            if subfolder.isEmpty || subfolder == "." || subfolder.hasPrefix("..") || CLIPath.isAbsolute(subfolder) {
                return (root: created.directory.rawValue, directory: created.directory.rawValue)
            }
            let subPath = CLIPath.join(created.directory.rawValue, subfolder)
            if (try? await resolveLocation(client: client, directory: subPath, signal: signal)) != nil {
                return (root: created.directory.rawValue, directory: subPath)
            }
            return (root: created.directory.rawValue, directory: created.directory.rawValue)
        }

        // parity: cli/src/session-target.ts#resolveSessionTarget [status=implemented hash=42f36e93ae92]
        public static func resolveSessionTarget(_ input: ResolveInput) async throws -> SessionTarget {
            let reqOpts = input.signal.map { RequestOptions(signal: $0) }
            let selection = try await selectSession(input)
            let selected = selection.session
            let location: LocationSchema.PublicInfo
            if let existingLoc = selection.location {
                location = existingLoc
            } else {
                let targetDir = selected?.location.directory ?? input.directory
                location = try await resolveLocation(client: input.client, directory: targetDir, signal: input.signal)
            }

            let selectedModel: ModelSchema.Ref? = selected?.model.map {
                ModelSchema.Ref(
                    id: ModelSchema.ID(rawValue: $0.id),
                    providerID: ProviderSchema.ID(rawValue: $0.providerID),
                    variant: $0.variant.map(ModelSchema.VariantID.init(rawValue:))
                )
            }
            let prepared = try await input.prepare(
                PreparationInput(
                    client: input.client,
                    location: location,
                    session: selected,
                    model: input.model ?? selectedModel,
                    agent: input.agent ?? selected?.agent,
                    signal: input.signal
                )
            )

            let session: SessionSchema.Info
            if let selected {
                session = selected
            } else {
                do {
                    session = try await input.client.session.create(
                        SessionCreateInput(
                            id: input.session,
                            agent: prepared.agent,
                            model: prepared.model,
                            location: LocationSchema.PublicRef(directory: location.directory)
                        ),
                        options: reqOpts
                    )
                } catch {
                    throw SessionTargetMutationError(error)
                }
            }

            if let envVars = input.environment {
                do {
                    try await input.client.session.environment(
                        SessionEnvironmentInput(sessionID: session.id.rawValue, variables: envVars),
                        options: reqOpts
                    )
                } catch {
                    throw SessionTargetMutationError(error)
                }
            }

            return SessionTarget(
                session: session,
                location: location,
                model: prepared.model,
                agent: prepared.agent ?? session.agent,
                resume: selected != nil
            )
        }

        private static func selectSession(_ input: ResolveInput) async throws -> (session: SessionSchema.Info?, location: LocationSchema.PublicInfo?) {
            let reqOpts = input.signal.map { RequestOptions(signal: $0) }
            if let requestedID = input.session {
                let explicit = try await findSession(client: input.client, sessionID: requestedID, signal: input.signal)
                guard let explicit else {
                    if input.fork { throw CLIError("Session not found") }
                    return (nil, nil)
                }
                if input.fork {
                    do {
                        let forked = try await input.client.session.fork(SessionForkInput(sessionID: explicit.id.rawValue), options: reqOpts)
                        return (forked, nil)
                    } catch {
                        throw SessionTargetMutationError(error)
                    }
                }
                return (explicit, nil)
            }
            if !input.`continue` {
                return (nil, nil)
            }
            let location = try await resolveLocation(client: input.client, directory: input.directory, signal: input.signal)
            let latest = try await latestSession(client: input.client, location: location, cursor: nil, signal: input.signal)
            guard let latest else {
                return (nil, location)
            }
            if input.fork {
                do {
                    let forked = try await input.client.session.fork(SessionForkInput(sessionID: latest.id.rawValue), options: reqOpts)
                    return (forked, location)
                } catch {
                    throw SessionTargetMutationError(error)
                }
            }
            return (latest, location)
        }

        private static func latestSession(
            client: OpenCodeClient,
            location: LocationSchema.PublicInfo,
            cursor: String?,
            signal: AbortSignal?
        ) async throws -> SessionSchema.Info? {
            let reqOpts = signal.map { RequestOptions(signal: $0) }
            var currentCursor = cursor
            while true {
                let page = try await client.session.list(
                    SessionListInput(
                        limit: 50,
                        order: .desc,
                        parentID: nil,
                        archived: false,
                        directory: location.directory.rawValue,
                        cursor: currentCursor
                    ),
                    options: reqOpts
                )
                if let match = page.data.first(where: { $0.location.directory == location.directory.rawValue && $0.parentID == nil }) {
                    return match
                }
                guard let next = page.cursor.next, !page.data.isEmpty else {
                    return nil
                }
                currentCursor = next.rawValue
            }
        }

        private static func resolveLocation(
            client: OpenCodeClient,
            directory: String?,
            signal: AbortSignal?
        ) async throws -> LocationSchema.PublicInfo {
            let reqOpts = signal.map { RequestOptions(signal: $0) }
            if let directory {
                return try await client.location.get(
                    LocationGetInput(location: LocationQuery.LocationField(directory: directory)),
                    options: reqOpts
                )
            }
            return try await client.location.get(nil, options: reqOpts)
        }
    }
}

// MARK: - Non-Interactive Run & Mini Interactive Runners (`packages/cli/src/run/*`, `mini.ts`, `mini-host.ts`)

public enum CLIRun {
    // MARK: Run UI Helpers (`packages/cli/src/run/ui.ts`)

    public enum UI {
        // parity: cli/src/run/ui.ts#Style [status=implemented hash=9352ce083f88]
        public static let Style: [String: String] = [
            "TEXT_DIM": "\u{1B}[90m",
            "TEXT_NORMAL": "\u{1B}[0m",
            "TEXT_WARNING_BOLD": "\u{1B}[93m\u{1B}[1m",
            "TEXT_DANGER_BOLD": "\u{1B}[91m\u{1B}[1m",
        ]

        public static let textDim = "\u{1B}[90m"
        public static let textNormal = "\u{1B}[0m"
        public static let textWarningBold = "\u{1B}[93m\u{1B}[1m"
        public static let textDangerBold = "\u{1B}[91m\u{1B}[1m"

        private static let blankState = Mutex(false)

        // parity: cli/src/run/ui.ts#println [status=implemented hash=4b04cd6c4f57]
        public static func println(_ message: String..., context: CLIContext = CLIContext.current) {
            println(message, context: context)
        }

        public static func println(_ parts: [String], context: CLIContext = CLIContext.current) {
            context.io.writeStderr(parts.joined(separator: " ") + context.io.eol)
        }

        // parity: cli/src/run/ui.ts#empty [status=implemented hash=dbe8c0c13303]
        public static func empty(context: CLIContext = CLIContext.current) {
            let shouldPrint = blankState.withLock { blank -> Bool in
                if blank { return false }
                blank = true
                return true
            }
            if shouldPrint {
                println([textNormal], context: context)
            }
        }

        public static func resetEmptyState() {
            blankState.withLock { $0 = false }
        }

        // parity: cli/src/run/ui.ts#error [status=implemented hash=ec1624f01cdc]
        public static func error(_ rawMessage: String, context: CLIContext = CLIContext.current) {
            let message = rawMessage.hasPrefix("Error: ")
                ? String(rawMessage.dropFirst("Error: ".count))
                : rawMessage
            println([textDangerBold + "Error: " + textNormal + message], context: context)
        }
    }

    // MARK: Non-Interactive Prompt Execution (`packages/cli/src/run/noninteractive.ts`)

    public enum OutputFormat: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case `default`
        case json
    }

    public struct NonInteractivePromptInput: Sendable {
        public let client: OpenCodeClient
        public let sessionID: String
        public let directory: String
        public let message: String
        public let files: [PromptInputSchema.FileAttachment]
        public let agent: String?
        public let model: ModelSchema.Ref?
        public let thinking: Bool
        public let format: OutputFormat
        public let auto: Bool
        public let standalone: Bool
        public let signal: AbortSignal
        public let renderTool: @Sendable (SessionMessageSchema.AssistantTool) async -> Void
        public let renderToolError: @Sendable (SessionMessageSchema.AssistantTool) async -> Void

        public init(
            client: OpenCodeClient,
            sessionID: String,
            directory: String,
            message: String,
            files: [PromptInputSchema.FileAttachment] = [],
            agent: String? = nil,
            model: ModelSchema.Ref? = nil,
            thinking: Bool = false,
            format: OutputFormat = .default,
            auto: Bool = false,
            standalone: Bool = false,
            signal: AbortSignal = AbortController().signal,
            renderTool: @escaping @Sendable (SessionMessageSchema.AssistantTool) async -> Void = { _ in },
            renderToolError: @escaping @Sendable (SessionMessageSchema.AssistantTool) async -> Void = { _ in }
        ) {
            self.client = client
            self.sessionID = sessionID
            self.directory = directory
            self.message = message
            self.files = files
            self.agent = agent
            self.model = model
            self.thinking = thinking
            self.format = format
            self.auto = auto
            self.standalone = standalone
            self.signal = signal
            self.renderTool = renderTool
            self.renderToolError = renderToolError
        }
    }

    private static let questionCancelledFeedback =
        "This non-interactive run cannot ask the user questions, so the question was cancelled. Continue without an answer; make reasonable assumptions and state them."

    private static let permissionRejectedFeedback =
        "This non-interactive run cannot ask the user for permission, so the request was rejected. Continue without this action."

    // parity: cli/src/run/noninteractive.ts#runNonInteractivePrompt [status=implemented hash=8d175a858a72]
    public static func runNonInteractivePrompt(
        _ input: NonInteractivePromptInput,
        context: CLIContext = CLIContext.current
    ) async throws {
        let messageID = SessionMessageSchema.ID.create()
        if let agent = input.agent {
            try await input.client.session.switchAgent(SessionSwitchAgentInput(sessionID: input.sessionID, agent: agent))
        }
        if let model = input.model {
            try await input.client.session.switchModel(SessionSwitchModelInput(sessionID: input.sessionID, model: model))
        }
        if input.signal.isAborted { return }

        let streamController = AbortController()
        let eventStream = input.client.event.subscribe(SubscribeOptions(signal: streamController.signal))
        let ownedCache = Mutex<[String: Bool]>([input.sessionID: true])

        func ownsSession(_ sessionID: String) async -> Bool {
            if let cached = ownedCache.withLock({ $0[sessionID] }) { return cached }
            let result: Bool
            if let info = try? await input.client.session.get(SessionGetInput(sessionID: sessionID)),
               let parent = info.parentID
            {
                result = await ownsSession(parent.rawValue)
            } else {
                result = false
            }
            ownedCache.withLock { $0[sessionID] = result }
            return result
        }

        func replyPermission(sessionID: String, requestID: String, action: String, resources: [String]) async {
            if !input.auto {
                UI.println(
                    [UI.textWarningBold + "!", UI.textNormal + "permission requested: \(action) (\(resources.joined(separator: ", "))); auto-rejecting"],
                    context: context
                )
            }
            _ = try? await input.client.permission.reply(
                PermissionReplyInput(
                    sessionID: sessionID,
                    requestID: requestID,
                    decision: input.auto ? .once : .reject,
                    message: input.auto ? nil : permissionRejectedFeedback
                )
            )
        }

        func cancelForm(sessionID: String, formID: String, isQuestion: Bool) async {
            let headers: [String: String]? = sessionID == "global"
                ? ["x-opencode-directory": ClientURLBuilder.encodeURIComponent(input.directory)]
                : nil
            _ = try? await input.client.session.form.cancel(
                SessionFormCancelInput(
                    sessionID: sessionID,
                    formID: formID,
                    message: isQuestion ? nil : questionCancelledFeedback
                ),
                options: headers.map { RequestOptions(headers: $0) }
            )
        }

        let consumerTask = Task {
            do {
                for try await event in eventStream {
                    if streamController.signal.isAborted { break }
                    if event.type == "permission.asked", case .object(let data) = event.data,
                       case .string(let sid) = data["sessionID"],
                       case .string(let rid) = data["id"],
                       case .string(let action) = data["action"]
                    {
                        if await ownsSession(sid) {
                            var resources: [String] = []
                            if case .array(let arr) = data["resources"] {
                                resources = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                            }
                            await replyPermission(sessionID: sid, requestID: rid, action: action, resources: resources)
                        }
                    } else if event.type == "form.created", case .object(let data) = event.data,
                              case .object(let form) = data["form"],
                              case .string(let fid) = form["id"],
                              case .string(let sid) = form["sessionID"]
                    {
                        let owned = sid == "global"
                            ? (input.standalone && event.location?.directory == input.directory)
                            : await ownsSession(sid)
                        if owned {
                            var isQuestion = false
                            if case .object(let meta) = form["metadata"], case .string("question") = meta["kind"] {
                                isQuestion = true
                            }
                            await cancelForm(sessionID: sid, formID: fid, isQuestion: isQuestion)
                        }
                    }
                }
            } catch {
                // Stream ended or cancelled
            }
        }
        defer {
            streamController.abort()
            consumerTask.cancel()
        }

        _ = try await input.client.session.prompt(
            SessionPromptInput(
                sessionID: input.sessionID,
                id: messageID.rawValue,
                text: input.message,
                files: input.files.isEmpty ? nil : input.files,
                delivery: .steer
            )
        )

        // Wait for session execution to finish
        try await input.client.experimental.session.wait(ExperimentalSessionWaitInput(sessionID: input.sessionID))
        if input.signal.isAborted {
            _ = try? await input.client.session.interrupt(SessionInterruptInput(sessionID: input.sessionID))
            return
        }

        // Reconcile projected messages after prompt admission
        let projected = try await collectProjectedMessages(client: input.client, sessionID: input.sessionID, after: messageID)
        for msg in projected.messages {
            if case .assistant(let assistant) = msg {
                let ts = assistant.time.completed ?? assistant.time.created
                for (ordinal, item) in assistant.content.enumerated() {
                    switch item {
                    case .text(let textPart):
                        emitTextOrReasoning(
                            kind: "text",
                            partID: "prt_\(assistant.id.rawValue.dropFirst(4))_text-\(ordinal)",
                            messageID: assistant.id.rawValue,
                            text: textPart.text,
                            start: assistant.time.created,
                            end: ts,
                            input: input,
                            context: context
                        )
                    case .reasoning(let reasoningPart):
                        if input.thinking {
                            emitTextOrReasoning(
                                kind: "reasoning",
                                partID: "prt_\(assistant.id.rawValue.dropFirst(4))_reasoning-\(ordinal)",
                                messageID: assistant.id.rawValue,
                                text: reasoningPart.text,
                                start: assistant.time.created,
                                end: ts,
                                input: input,
                                context: context
                            )
                        }
                    case .tool(let toolPart):
                        switch toolPart.state {
                        case .completed:
                            if input.format == .json {
                                let payload: [String: JSONValue] = [
                                    "type": .string("tool_use"),
                                    "timestamp": .int(ts),
                                    "sessionID": .string(input.sessionID),
                                    "part": .object([
                                        "id": .string(toolPart.id),
                                        "tool": .string(toolPart.name),
                                        "type": .string("tool"),
                                    ]),
                                ]
                                if let encoded = try? CLIPath.encodeCompactJSON(JSONValue.object(payload)) {
                                    context.io.writeStdout(encoded + context.io.eol)
                                }
                            } else {
                                await input.renderTool(toolPart)
                            }
                        case .error(let errState):
                            if input.format == .json {
                                let payload: [String: JSONValue] = [
                                    "type": .string("tool_use"),
                                    "timestamp": .int(ts),
                                    "sessionID": .string(input.sessionID),
                                    "part": .object([
                                        "id": .string(toolPart.id),
                                        "tool": .string(toolPart.name),
                                        "error": .string(errState.error.message),
                                    ]),
                                ]
                                if let encoded = try? CLIPath.encodeCompactJSON(JSONValue.object(payload)) {
                                    context.io.writeStdout(encoded + context.io.eol)
                                }
                            } else {
                                await input.renderToolError(toolPart)
                                UI.error(errState.error.message, context: context)
                            }
                        default:
                            break
                        }
                    }
                }
            }
        }

        // Check idle outcome
        if !projected.found {
            reportRunError(format: input.format, message: "Prompt was not promoted", sessionID: input.sessionID, context: context)
            return
        }
        let idles: [SessionMessageSchema.Idle] = projected.messages.compactMap {
            if case .idle(let idle) = $0 { return idle }
            return nil
        }
        if let finalIdle = idles.first(where: { $0.outcome != .succeeded }) ?? idles.first {
            if finalIdle.outcome != .succeeded {
                let errMsg = finalIdle.error?.message ?? "Session \(finalIdle.outcome.rawValue)"
                reportRunError(format: input.format, message: errMsg, sessionID: input.sessionID, context: context)
            }
        }
    }

    private static func emitTextOrReasoning(
        kind: String,
        partID: String,
        messageID: String,
        text: String,
        start: Int64,
        end: Int64,
        input: NonInteractivePromptInput,
        context: CLIContext
    ) {
        if input.format == .json {
            let payload: [String: JSONValue] = [
                "type": .string(kind),
                "timestamp": .int(end),
                "sessionID": .string(input.sessionID),
                "part": .object([
                    "id": .string(partID),
                    "sessionID": .string(input.sessionID),
                    "messageID": .string(messageID),
                    "type": .string(kind),
                    "text": .string(text),
                    "time": .object(["start": .int(start), "end": .int(end)]),
                ]),
            ]
            if let encoded = try? CLIPath.encodeCompactJSON(JSONValue.object(payload)) {
                context.io.writeStdout(encoded + context.io.eol)
            }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = kind == "text" ? trimmed : "Thinking: \(trimmed)"
        if !context.io.isStdoutTTY() {
            context.io.writeStdout(line + context.io.eol)
        } else {
            UI.empty(context: context)
            UI.println([kind == "text" ? line : "\(UI.textDim)\u{1B}[3m\(line)\u{1B}[0m\(UI.textNormal)"], context: context)
            UI.empty(context: context)
        }
    }

    private static func collectProjectedMessages(
        client: OpenCodeClient,
        sessionID: String,
        after messageID: SessionMessageSchema.ID
    ) async throws -> (found: Bool, messages: [SessionMessageSchema.Info]) {
        var collected: [SessionMessageSchema.Info] = []
        var cursor: String? = nil
        while true {
            let page = try await client.message.list(
                MessageListInput(
                    sessionID: sessionID,
                    limit: 200,
                    order: cursor == nil ? .desc : nil,
                    cursor: cursor
                )
            )
            for item in page.data {
                if item.id == messageID {
                    return (true, collected.reversed())
                }
                collected.append(item)
            }
            guard let next = page.cursor.next else {
                return (false, [])
            }
            cursor = next
        }
    }

    // MARK: Non-Interactive Run Orchestrator (`packages/cli/src/run/run.ts`)

    // parity: cli/src/run/run.ts#RunCommandInput [status=implemented hash=81de16998231]
    public struct RunCommandInput: Sendable {
        public let server: CLIServices.ServerConnection.Resolved
        public let message: [String]
        public let `continue`: Bool
        public let session: String?
        public let fork: Bool
        public let worktree: CLIFramework.Flag.OptionalValue?
        public let model: String?
        public let agent: String?
        public let format: OutputFormat
        public let file: [String]
        public let title: String?
        public let archived: Bool
        public let thinking: Bool
        public let auto: Bool

        public init(
            server: CLIServices.ServerConnection.Resolved,
            message: [String] = [],
            continue continueLast: Bool = false,
            session: String? = nil,
            fork: Bool = false,
            worktree: CLIFramework.Flag.OptionalValue? = nil,
            model: String? = nil,
            agent: String? = nil,
            format: OutputFormat = .default,
            file: [String] = [],
            title: String? = nil,
            archived: Bool = false,
            thinking: Bool = false,
            auto: Bool = false
        ) {
            self.server = server
            self.message = message
            self.`continue` = continueLast
            self.session = session
            self.fork = fork
            self.worktree = worktree
            self.model = model
            self.agent = agent
            self.format = format
            self.file = file
            self.title = title
            self.archived = archived
            self.thinking = thinking
            self.auto = auto
        }
    }

    public struct ParsedRunModel: Equatable, Hashable, Sendable {
        public let providerID: String
        public let modelID: String
        public let variant: String?

        public init(providerID: String, modelID: String, variant: String? = nil) {
            self.providerID = providerID
            self.modelID = modelID
            self.variant = variant
        }
    }

    private enum PreparedFilePart {
        case text(String)
        case attachment(PromptInputSchema.FileAttachment)
    }

    private static let attachFileMaxBytes = 10 * 1024 * 1024
    private static let pipedInputGraceMs = 1_000

    // parity: cli/src/run/run.ts#mergeInput [status=implemented hash=49bab4c26ebd]
    public static func mergeInput(message: String?, piped: String?) -> String? {
        guard let message, !message.isEmpty else {
            return (piped?.isEmpty == false) ? piped : nil
        }
        guard let piped, !piped.isEmpty else { return message }
        return message + "\n" + piped
    }

    // parity: cli/src/run/run.ts#parseRunModel [status=implemented hash=6125a8d2b414]
    public static func parseRunModel(_ value: String?) throws -> ParsedRunModel? {
        guard let ref = try CLIServices.SessionTargetService.parseSessionTargetModel(value) else {
            return nil
        }
        return ParsedRunModel(providerID: ref.providerID.rawValue, modelID: ref.id.rawValue, variant: ref.variant?.rawValue)
    }

    // parity: cli/src/run/run.ts#reportRunError [status=implemented hash=1b177eb60a9c]
    public static func reportRunError(
        format: OutputFormat,
        message: String,
        sessionID: String? = nil,
        context: CLIContext = CLIContext.current
    ) {
        context.exitCode.value = 1
        if format == .json {
            let payload: [String: JSONValue] = [
                "type": .string("error"),
                "timestamp": .int(CLIPath.currentEpochMs()),
                "sessionID": .string(sessionID ?? ""),
                "error": .object([
                    "type": .string("unknown"),
                    "message": .string(message),
                ]),
            ]
            if let encoded = try? CLIPath.encodeCompactJSON(JSONValue.object(payload)) {
                context.io.writeStdout(encoded + "\n")
            }
            return
        }
        UI.error(message, context: context)
    }

    // parity: cli/src/run/run.ts#runNonInteractive [status=implemented hash=60ffe51914d2]
    public static func runNonInteractive(
        _ input: RunCommandInput,
        signal: AbortSignal = AbortController().signal,
        context: CLIContext = CLIContext.current
    ) async {
        do {
            try await executeRun(input, signal: signal, context: context)
        } catch {
            reportRunError(format: input.format, message: CLIUtil.errorMessage(error), context: context)
        }
    }

    private static func executeRun(
        _ input: RunCommandInput,
        signal: AbortSignal,
        context: CLIContext
    ) async throws {
        if input.fork && !input.`continue` && input.session == nil {
            throw CLIError("--fork requires --continue or --session")
        }
        if input.worktree != nil && (input.`continue` || input.session != nil) {
            throw CLIError("--worktree starts a new session and cannot be combined with --continue or --session")
        }
        let root = context.envVariable("PWD") ?? context.cwd
        let argument = input.message.isEmpty ? nil : input.message.joined(separator: " ")
        let piped: String?
        if context.io.isStdinTTY() {
            piped = nil
        } else if argument != nil {
            piped = try await CLIUtil.readStdinIfReady(grace: pipedInputGraceMs, context: context)
        } else {
            piped = try await CLIUtil.readStdin(context: context)
        }
        guard let message = mergeInput(message: argument, piped: piped),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CLIError("You must provide a message")
        }

        var files: [PreparedFilePart] = []
        for filePath in input.file {
            files.append(try await prepareFile(filePath, directory: root, fileSystem: context.fileSystem))
        }

        let client = context.makeClient(endpoint: input.server.endpoint)
        let explicit = try parseRunModel(input.model)
        var targetDirectory = root
        if let wt = input.worktree {
            let created = try await CLIServices.SessionTargetService.createWorktreeLocation(
                client: client,
                directory: root,
                name: wt.stringValue,
                signal: signal
            )
            UI.println([UI.textDim + "worktree " + created.root + UI.textNormal], context: context)
            targetDirectory = created.directory
        }

        let modelRef = explicit.map {
            ModelSchema.Ref(
                id: ModelSchema.ID(rawValue: $0.modelID),
                providerID: ProviderSchema.ID(rawValue: $0.providerID),
                variant: $0.variant.map(ModelSchema.VariantID.init(rawValue:))
            )
        }
        let target = try await CLIServices.SessionTargetService.resolveSessionTarget(
            CLIServices.SessionTargetService.ResolveInput(
                client: client,
                directory: targetDirectory,
                continue: input.`continue`,
                session: input.session,
                fork: input.fork,
                model: modelRef,
                agent: input.agent,
                environment: input.server.service != nil ? CLIUtil.Env.session() : nil,
                prepare: { next in
                    if explicit?.variant != nil && next.model == nil {
                        throw CLIError("Cannot select a variant before selecting a model")
                    }
                    return (model: next.model, agent: next.agent)
                },
                signal: signal
            )
        )

        let computedTitle: String? = {
            guard !target.resume, let rawTitle = input.title else { return nil }
            if !rawTitle.isEmpty { return rawTitle }
            return message.count > 50 ? String(message.prefix(50)) + "..." : message
        }()
        let shouldArchive: Bool? = (input.archived && (!target.resume || input.fork)) ? true : nil
        if computedTitle != nil || shouldArchive != nil {
            try await client.session.update(
                SessionUpdateInput(sessionID: target.session.id.rawValue, title: computedTitle, archived: shouldArchive)
            )
        }

        var textSections = [message]
        var attachments: [PromptInputSchema.FileAttachment] = []
        for part in files {
            switch part {
            case .text(let snippet): textSections.append(snippet)
            case .attachment(let att): attachments.append(att)
            }
        }
        let dir = target.location.directory.rawValue
        try await runNonInteractivePrompt(
            NonInteractivePromptInput(
                client: client,
                sessionID: target.session.id.rawValue,
                directory: dir,
                message: textSections.joined(separator: "\n\n"),
                files: attachments,
                agent: target.agent,
                model: target.model,
                thinking: input.thinking,
                format: input.format,
                auto: input.auto,
                standalone: input.server.standalone,
                signal: signal,
                renderTool: { tool in
                    let info = TUIMini.toolInlineInfo(tool, directory: dir)
                    if info.mode == .block {
                        UI.empty(context: context)
                        UI.println([UI.textNormal + info.icon, UI.textNormal + info.title], context: context)
                        if let body = info.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            UI.println([body], context: context)
                        }
                        UI.empty(context: context)
                    } else {
                        let desc = info.description.map { UI.textDim + $0 + UI.textNormal } ?? ""
                        UI.println([UI.textNormal + info.icon, UI.textNormal + info.title, desc], context: context)
                    }
                },
                renderToolError: { tool in
                    let info = TUIMini.toolInlineInfo(tool, directory: dir)
                    UI.println([UI.textNormal + "✗", UI.textNormal + "\(info.title) failed"], context: context)
                }
            ),
            context: context
        )
    }

    private static func prepareFile(
        _ input: String,
        directory: String,
        fileSystem: any OpenCodeFileSystem
    ) async throws -> PreparedFilePart {
        let resolved = CLIPath.resolve(directory, input)
        guard let stat = try? await fileSystem.stat(at: resolved) else {
            throw CLIError("File not found: \(input)")
        }
        guard stat.type == .file && stat.size <= Int64(attachFileMaxBytes) else {
            throw CLIError("Cannot attach a directory, special file, or file larger than 10 MiB: \(input)")
        }
        let bytes = try await fileSystem.readFile(at: resolved)
        let detected = FSPathUtil.mimeType(resolved)
        let name = CLIPath.basename(resolved)
        if !detected.hasPrefix("image/") && detected != "application/pdf" && !isBinaryContent(bytes),
           let text = String(bytes: bytes, encoding: .utf8)
        {
            return .text("<file name=\"\(name)\">\n\(text)\n</file>")
        }
        let dataURI = "data:\(detected);base64,\(bytesToBase64(bytes))"
        return .attachment(PromptInputSchema.FileAttachment(uri: dataURI, name: name))
    }

    internal static func isBinaryContent(_ bytes: [UInt8]) -> Bool {
        if bytes.isEmpty { return false }
        if bytes.contains(0) { return true }
        let controlCount = bytes.reduce(0) { count, b in
            count + ((b < 9 || (b > 13 && b < 32)) ? 1 : 0)
        }
        return Double(controlCount) / Double(bytes.count) > 0.3
    }

    // MARK: Mini Host Capabilities (`packages/cli/src/mini-host.ts`)

    public enum MiniHost {
        // parity: cli/src/mini-host.ts#INTERACTIVE_INPUT_ERROR [status=implemented hash=81516167fe98]
        public static let INTERACTIVE_INPUT_ERROR = "opencode mini requires a controlling terminal for input"

        // parity: cli/src/mini-host.ts#InteractiveStdin [status=adapted hash=8754e6b57e8b]
        public struct InteractiveStdin: Sendable {
            public let devicePath: String
            public let isTTY: Bool
            private let cleanupFn: @Sendable () -> Void

            public init(devicePath: String = "/dev/stdin", isTTY: Bool = true, cleanup: @escaping @Sendable () -> Void = {}) {
                self.devicePath = devicePath
                self.isTTY = isTTY
                self.cleanupFn = cleanup
            }

            public func cleanup() {
                cleanupFn()
            }
        }

        // parity: cli/src/mini-host.ts#resolveInteractiveStdin [status=adapted hash=d230f6e458de]
        public static func resolveInteractiveStdin(
            isTTY: Bool? = nil,
            open: (@Sendable (String) throws -> InteractiveStdin)? = nil,
            platform: PlatformOS = CLIContext.current.platformOS
        ) throws -> InteractiveStdin {
            let stdinIsTTY = isTTY ?? CLIContext.current.io.isStdinTTY()
            if stdinIsTTY {
                return InteractiveStdin(devicePath: "/dev/stdin", isTTY: true, cleanup: {})
            }
            let target = platform == .windows ? "CONIN$" : "/dev/tty"
            do {
                if let open {
                    return try open(target)
                }
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                let fd = DarwinOrPosixOpenReadOnly(target)
                guard fd >= 0 else {
                    throw CLIError(INTERACTIVE_INPUT_ERROR)
                }
                let cleaned = Mutex(false)
                return InteractiveStdin(devicePath: target, isTTY: true) {
                    let shouldClose = cleaned.withLock { c -> Bool in
                        if c { return false }
                        c = true
                        return true
                    }
                    if shouldClose { _ = close(fd) }
                }
                #else
                throw CLIError(INTERACTIVE_INPUT_ERROR)
                #endif
            } catch {
                throw CLIError(INTERACTIVE_INPUT_ERROR)
            }
        }

        // parity: cli/src/mini-host.ts#usingInteractiveStdin [status=implemented hash=1f91b61acfda]
        public static func usingInteractiveStdin<T: Sendable>(
            resolve: @Sendable () throws -> InteractiveStdin = { try resolveInteractiveStdin() },
            _ run: @Sendable (InteractiveStdin) async throws -> T
        ) async throws -> T {
            let terminal = try resolve()
            defer { terminal.cleanup() }
            return try await run(terminal)
        }

        public struct HostPaths: Equatable, Hashable, Sendable {
            public let home: String
            public let state: String
            public let log: String

            public init(home: String, state: String, log: String) {
                self.home = home
                self.state = state
                self.log = log
            }
        }

        // parity: cli/src/mini-host.ts#createMiniHost [status=adapted hash=76e58330bbdf]
        public static func createMiniHost(
            terminal: InteractiveStdin,
            directory: String,
            paths: HostPaths,
            context: CLIContext = CLIContext.current
        ) -> TUIMini.MiniHost {
            _ = (terminal, directory)
            let showTTFD = context.envVariable("OPENCODE_SHOW_TTFD")?.lowercased()
            let prefRepo = TUIModelPreference.createModelPreferenceRepository(
                CLIPath.join(paths.state, "model.json"),
                fs: context.fileSystem
            )
            return TUIMini.MiniHost(
                version: context.version,
                platform: context.platformOS.rawValue,
                home: paths.home,
                showTiming: showTTFD == "1" || showTTFD == "true",
                writeStdout: { value in context.io.writeStdout(value) },
                readText: { path in
                    let bytes = try await context.fileSystem.readFile(at: path)
                    return String(decoding: bytes, as: UTF8.self)
                },
                trace: nil,
                resolveVariant: { model in
                    guard let model else { return nil }
                    return await prefRepo.resolveVariant(
                        for: TUIModelPreference.ModelPreferenceModel(providerID: model.providerID, modelID: model.modelID)
                    )
                },
                saveVariant: { model, variant in
                    guard let model else { return }
                    try? await prefRepo.saveVariant(
                        TUIModelPreference.ModelPreferenceModel(providerID: model.providerID, modelID: model.modelID),
                        value: variant
                    )
                }
            )
        }
    }

    // MARK: Mini Interactive Command (`packages/cli/src/mini.ts`)

    public enum Mini {
        public struct ServerInput: Sendable {
            public let endpoint: ServiceEndpoint
            public let reconnect: (@Sendable (AbortSignal) async throws -> ServiceEndpoint)?

            public init(
                endpoint: ServiceEndpoint,
                reconnect: (@Sendable (AbortSignal) async throws -> ServiceEndpoint)? = nil
            ) {
                self.endpoint = endpoint
                self.reconnect = reconnect
            }
        }

        // parity: cli/src/mini.ts#MiniCommandInput [status=implemented hash=3a726d65f837]
        public struct MiniCommandInput: Sendable {
            public let server: ServerInput
            public let `continue`: Bool
            public let session: String?
            public let fork: Bool
            public let model: String?
            public let agent: String?
            public let prompt: String?
            public let replay: Bool
            public let replayLimit: Int?
            public let demo: Bool
            public let tuiConfig: TUIConfig.Resolved?
            public let paths: MiniHost.HostPaths

            public init(
                server: ServerInput,
                continue continueLast: Bool = false,
                session: String? = nil,
                fork: Bool = false,
                model: String? = nil,
                agent: String? = nil,
                prompt: String? = nil,
                replay: Bool = true,
                replayLimit: Int? = nil,
                demo: Bool = false,
                tuiConfig: TUIConfig.Resolved? = nil,
                paths: MiniHost.HostPaths
            ) {
                self.server = server
                self.`continue` = continueLast
                self.session = session
                self.fork = fork
                self.model = model
                self.agent = agent
                self.prompt = prompt
                self.replay = replay
                self.replayLimit = replayLimit
                self.demo = demo
                self.tuiConfig = tuiConfig
                self.paths = paths
            }
        }

        public struct MiniConnection: Sendable {
            public let sdk: OpenCodeClient
            public let reconnect: (@Sendable (AbortSignal) async throws -> OpenCodeClient)?

            public init(
                sdk: OpenCodeClient,
                reconnect: (@Sendable (AbortSignal) async throws -> OpenCodeClient)?
            ) {
                self.sdk = sdk
                self.reconnect = reconnect
            }
        }

        // parity: cli/src/mini.ts#createMiniConnection [status=implemented hash=b04b5e052d38]
        public static func createMiniConnection(
            _ input: ServerInput,
            transport: any HTTPTransport = CLIContext.current.transport
        ) -> MiniConnection {
            let makeClient: @Sendable (ServiceEndpoint) -> OpenCodeClient = { endpoint in
                OpenCode.make(
                    ClientOptions(
                        baseUrl: endpoint.url,
                        transport: transport,
                        headers: OpenCodeClient.serviceHeaders(for: endpoint) ?? [:]
                    )
                )
            }
            let wrappedReconnect: (@Sendable (AbortSignal) async throws -> OpenCodeClient)?
            if let fn = input.reconnect {
                wrappedReconnect = { signal in
                    let next = try await fn(signal)
                    return makeClient(next)
                }
            } else {
                wrappedReconnect = nil
            }
            return MiniConnection(
                sdk: makeClient(input.endpoint),
                reconnect: wrappedReconnect
            )
        }

        // parity: cli/src/mini.ts#resolveMiniTarget [status=implemented hash=adb03fecc256]
        public static func resolveMiniTarget<A: Sendable>(
            sdk initial: OpenCodeClient,
            reconnect: (@Sendable (AbortSignal) async throws -> OpenCodeClient)? = nil,
            signal: AbortSignal = AbortController().signal,
            resolve: @Sendable (OpenCodeClient) async throws -> A
        ) async throws -> (sdk: OpenCodeClient, value: A) {
            var sdk = initial
            while true {
                do {
                    return (sdk: sdk, value: try await resolve(sdk))
                } catch {
                    guard let reconnect,
                          let clientErr = error as? ClientError,
                          clientErr.reason == .transport
                    else {
                        throw error
                    }
                    while true {
                        do {
                            sdk = try await reconnect(signal)
                            break
                        } catch {
                            if signal.isAborted { throw error }
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                }
            }
        }

        // parity: cli/src/mini.ts#validateMiniTerminal [status=implemented hash=dd704a0ceea8]
        public static func validateMiniTerminal(context: CLIContext = CLIContext.current) throws {
            guard context.io.isStdoutTTY() else {
                throw CLIError("opencode mini requires a TTY stdout")
            }
        }

        // parity: cli/src/mini.ts#mergeInput [status=implemented hash=7c4e745851d2]
        public static func mergeInput(piped: String?, prompt: String?) -> String? {
            guard let prompt, !prompt.isEmpty else {
                return (piped?.isEmpty == false) ? piped : nil
            }
            guard let piped, !piped.isEmpty else { return prompt }
            return piped + "\n" + prompt
        }

        // parity: cli/src/mini.ts#runMini [status=adapted hash=c037e038ac63]
        public static func runMini(
            _ input: MiniCommandInput,
            context: CLIContext = CLIContext.current
        ) async throws {
            try validateMiniTerminal(context: context)
            if let limit = input.replayLimit, limit <= 0 {
                throw CLIError("--replay-limit must be a positive integer")
            }
            if input.fork && !input.`continue` && input.session == nil {
                throw CLIError("--fork requires --continue or --session")
            }
            if let miniRunner = context.miniRunner {
                try await miniRunner(input)
                return
            }
            try await MiniHost.usingInteractiveStdin { terminal in
                let piped = context.io.isStdinTTY() ? nil : (try? await CLIUtil.readStdin(context: context))
                let initialInput = mergeInput(piped: piped, prompt: input.prompt)
                let directory = context.envVariable("PWD") ?? context.cwd
                let requested: ModelSchema.Ref?
                do {
                    requested = try CLIServices.SessionTargetService.parseSessionTargetModel(input.model)
                } catch {
                    throw CLIError("--model must use the format provider/model[#variant]")
                }
                let host = MiniHost.createMiniHost(terminal: terminal, directory: directory, paths: input.paths, context: context)
                let modelSel = requested.map { TUIMini.PromptModelSelection(providerID: $0.providerID.rawValue, modelID: $0.id.rawValue) }
                let termBackend = SSHTerminalBackend(
                    size: TerminalSize(width: context.io.columns(), height: context.io.rows()),
                    writeHandler: { bytes in
                        context.io.writeStdout(String(decoding: bytes, as: UTF8.self))
                    }
                )
                let factory = createCliRendererSSHFactory()
                let attached = try await factory(
                    SSHRendererCreateOptions(
                        width: context.io.columns(),
                        height: context.io.rows(),
                        term: context.envVariable("TERM") ?? "xterm-256color",
                        hasPty: true,
                        environment: CLIUtil.Env.session(),
                        backend: termBackend
                    )
                )
                if let adapter = attached as? SSHCliRendererAdapter {
                    let frontendInput = TUIMini.MiniFrontendInput(
                        host: host,
                        renderer: adapter.renderer,
                        directory: directory,
                        agent: input.agent,
                        model: modelSel,
                        variant: requested?.variant?.rawValue,
                        initialInput: initialInput,
                        demo: input.demo,
                        tuiConfig: input.tuiConfig
                    )
                    await TUIMini.runMiniFrontend(frontendInput)
                    adapter.destroy()
                }
            }
        }
    }
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
private func DarwinOrPosixOpenReadOnly(_ path: String) -> Int32 {
    #if canImport(Darwin)
    return Darwin.open(path, O_RDONLY)
    #elseif canImport(Glibc)
    return Glibc.open(path, O_RDONLY)
    #else
    return Musl.open(path, O_RDONLY)
    #endif
}
#endif

private extension Character {
    var isASCIIWholeNumber: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first!.value >= 0x30 && unicodeScalars.first!.value <= 0x39
    }
}
