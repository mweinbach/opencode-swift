import Foundation

// MARK: - WSL Contract (`wsl/contract.ts`)

public struct WSLServerConfig: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let distro: String

    public init(id: String, distro: String) {
        self.id = id
        self.distro = distro
    }
}

public enum WSLServerRuntime: Equatable, Hashable, Sendable, Codable {
    case starting
    case ready(url: String, password: String?)
    case failed(message: String)
    case stopped
}

public enum WSLDistroJob: String, Equatable, Hashable, Sendable, Codable {
    case probing
    case installing
    case updating
    case starting
    case removing
}

public enum WSLHostJobStatus: String, Equatable, Hashable, Sendable, Codable {
    case idle
    case busy
}

public struct WSLRuntimeCheck: Equatable, Hashable, Sendable, Codable {
    public let available: Bool
    public let version: String?
    public let error: String?

    public init(available: Bool, version: String?, error: String?) {
        self.available = available
        self.version = version
        self.error = error
    }
}

public struct WSLInstalledDistro: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let version: Int?
    public let isDefault: Bool

    public init(name: String, version: Int?, isDefault: Bool) {
        self.name = name
        self.version = version
        self.isDefault = isDefault
    }
}

public struct WSLOnlineDistro: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let label: String

    public init(name: String, label: String) {
        self.name = name
        self.label = label
    }
}

public struct WSLDistroProbe: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let canExecute: Bool
    public let hasBash: Bool
    public let hasCurl: Bool
    public let error: String?

    public init(name: String, canExecute: Bool, hasBash: Bool, hasCurl: Bool, error: String?) {
        self.name = name
        self.canExecute = canExecute
        self.hasBash = hasBash
        self.hasCurl = hasCurl
        self.error = error
    }
}

public struct WSLOpenCodeCheck: Equatable, Hashable, Sendable, Codable {
    public let distro: String
    public let resolvedPath: String?
    public let version: String?
    public let expectedVersion: String?
    public let matchesDesktop: Bool?
    public let error: String?

    public init(
        distro: String,
        resolvedPath: String?,
        version: String?,
        expectedVersion: String?,
        matchesDesktop: Bool?,
        error: String?
    ) {
        self.distro = distro
        self.resolvedPath = resolvedPath
        self.version = version
        self.expectedVersion = expectedVersion
        self.matchesDesktop = matchesDesktop
        self.error = error
    }
}

public struct WSLServerItem: Equatable, Hashable, Sendable, Codable {
    public let config: WSLServerConfig
    public let runtime: WSLServerRuntime

    public init(config: WSLServerConfig, runtime: WSLServerRuntime) {
        self.config = config
        self.runtime = runtime
    }
}

public struct WSLServersState: Equatable, Sendable, Codable {
    public let runtime: WSLRuntimeCheck?
    public let installed: [WSLInstalledDistro]
    public let online: [WSLOnlineDistro]
    public let distroProbes: [String: WSLDistroProbe]
    public let opencodeChecks: [String: WSLOpenCodeCheck]
    public let pendingRestart: Bool
    public let servers: [WSLServerItem]
    public let hostJob: WSLHostJobStatus
    public let distroJobs: [String: WSLDistroJob]

    public init(
        runtime: WSLRuntimeCheck? = nil,
        installed: [WSLInstalledDistro] = [],
        online: [WSLOnlineDistro] = [],
        distroProbes: [String: WSLDistroProbe] = [:],
        opencodeChecks: [String: WSLOpenCodeCheck] = [:],
        pendingRestart: Bool = false,
        servers: [WSLServerItem] = [],
        hostJob: WSLHostJobStatus = .idle,
        distroJobs: [String: WSLDistroJob] = [:]
    ) {
        self.runtime = runtime
        self.installed = installed
        self.online = online
        self.distroProbes = distroProbes
        self.opencodeChecks = opencodeChecks
        self.pendingRestart = pendingRestart
        self.servers = servers
        self.hostJob = hostJob
        self.distroJobs = distroJobs
    }
}

// MARK: - WSL Runtime Helpers & Parsers (`wsl/runtime.ts`)

public enum WSLOutputEncoding: String, Equatable, Sendable {
    case utf8 = "utf-8"
    case utf16le = "utf-16le"
}

public enum WSLRuntimeHelper {
    public static let defaultTimeoutMs = 20_000
    public static let defaultInstallTimeoutMs = 15 * 60_000

    public static func wslArgs(_ args: [String], distro: String? = nil, user: String? = nil) -> [String] {
        var result: [String] = []
        if let distro, !distro.isEmpty {
            result.append(contentsOf: ["-d", distro])
        }
        if let user, !user.isEmpty {
            result.append(contentsOf: ["--user", user])
        }
        result.append("--exec")
        result.append(contentsOf: args)
        return result
    }

    public static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    public static func wslCliInstallCommand(version: String, binary: String? = nil) throws(RemoteCLIFailure) -> String {
        let escapedBinary = binary.map { "\"$(wslpath -a \(shellEscape($0)))\"" }
        return try RemoteCLI.installScript(version: version, source: .installer(binary: escapedBinary))
    }

    public static func summarize(_ value: String) -> String {
        value
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Detects whether `wsl.exe` stdout/stderr bytes are UTF-16LE (common on Windows) or UTF-8.
    public static func detectOutputEncoding(_ bytes: [UInt8]) -> WSLOutputEncoding {
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            return .utf16le
        }
        let pairs = bytes.count / 2
        if pairs < 2 {
            return .utf8
        }
        var oddZeroes = 0
        var evenZeroes = 0
        for index in 0..<pairs {
            if bytes[index * 2 + 1] == 0 { oddZeroes += 1 }
            if bytes[index * 2] == 0 { evenZeroes += 1 }
        }
        let threshold = (pairs + 2) / 3
        return (oddZeroes >= threshold && evenZeroes * 2 <= oddZeroes) ? .utf16le : .utf8
    }

    /// Decodes raw bytes from `wsl.exe` according to detected UTF-16LE or UTF-8 encoding.
    public static func decodeOutput(_ bytes: [UInt8]) -> String {
        let encoding = detectOutputEncoding(bytes)
        if encoding == .utf16le {
            let start = (bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) ? 2 : 0
            let pairCount = (bytes.count - start) / 2
            var units: [UInt16] = []
            units.reserveCapacity(pairCount)
            for i in 0..<pairCount {
                let lo = UInt16(bytes[start + i * 2])
                let hi = UInt16(bytes[start + i * 2 + 1])
                units.append(lo | (hi << 8))
            }
            return String(decoding: units, as: UTF16.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Parses `wsl --list --verbose` output into installed distro entries.
    public static func parseInstalledDistros(_ output: String) -> [WSLInstalledDistro] {
        var result: [WSLInstalledDistro] = []
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        for rawLine in lines {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Matches: /^\s*(\*)?\s*(.*?)\s{2,}\S+\s+(\d+)\s*$/
            var rest = line[...]
            while let first = rest.first, first == " " || first == "\t" {
                rest = rest.dropFirst()
            }
            var isDefault = false
            if rest.first == "*" {
                isDefault = true
                rest = rest.dropFirst()
                while let first = rest.first, first == " " || first == "\t" {
                    rest = rest.dropFirst()
                }
            }
            let body = String(rest).trimmingCharacters(in: .whitespaces)
            // Split from right: version (digits), whitespace, state (non-ws), >=2 spaces, name
            let tokens = splitByMultiSpaceOrTail(body)
            guard let parsed = tokens else { continue }
            if parsed.name.isEmpty || parsed.name.lowercased() == "name" {
                continue
            }
            result.append(WSLInstalledDistro(name: parsed.name, version: parsed.version, isDefault: isDefault))
        }
        return result
    }

    /// Parses `wsl --list --online` output into online catalog distro entries.
    public static func parseOnlineDistros(_ output: String) -> [WSLOnlineDistro] {
        var result: [WSLOnlineDistro] = []
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let sepRange = trimmed.range(of: "  ") else { continue }
            let name = String(trimmed[..<sepRange.lowerBound])
            guard !name.isEmpty,
                  name.lowercased() != "name",
                  name.utf8.allSatisfy({
                      ($0 >= 0x30 && $0 <= 0x39)
                          || ($0 >= 0x41 && $0 <= 0x5A)
                          || ($0 >= 0x61 && $0 <= 0x7A)
                          || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
                  })
            else { continue }
            let label = String(trimmed[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            result.append(WSLOnlineDistro(name: name, label: label))
        }
        return result
    }

    /// Converts a Windows drive path (`C:\Users\dev\repo`) into a WSL `/mnt/<drive>/...` path.
    public static func windowsPathToWSL(_ windowsPath: String) -> String? {
        let chars = Array(windowsPath)
        guard chars.count >= 2, chars[0].isLetter, chars[1] == ":" else {
            return nil
        }
        let drive = String(chars[0]).lowercased()
        let rest = String(chars.dropFirst(2))
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rest.isEmpty ? "/mnt/\(drive)" : "/mnt/\(drive)/\(rest)"
    }

    /// Converts a WSL Linux path into a Windows UNC path (`\\wsl.localhost\<distro>\...`) or drive path for `/mnt/<drive>`.
    public static func wslPathToWindows(_ wslPath: String, distro: String) -> String {
        let normalized = wslPath.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/mnt/") {
            let tail = normalized.dropFirst("/mnt/".count)
            if let driveChar = tail.first, driveChar.isLetter {
                let afterDrive = tail.dropFirst()
                if afterDrive.isEmpty {
                    return "\(String(driveChar).uppercased()):\\"
                }
                if afterDrive.first == "/" {
                    let sub = String(afterDrive.dropFirst()).replacingOccurrences(of: "/", with: "\\")
                    return "\(String(driveChar).uppercased()):\\\(sub)"
                }
            }
        }
        let stripped = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if stripped.isEmpty {
            return "\\\\wsl.localhost\\\(distro)"
        }
        return "\\\\wsl.localhost\\\(distro)\\\(stripped.replacingOccurrences(of: "/", with: "\\"))"
    }

    private static func splitByMultiSpaceOrTail(_ text: String) -> (name: String, version: Int)? {
        // Parse trailing version integer
        let chars = Array(text)
        var end = chars.count
        while end > 0 && chars[end - 1].isWhitespace { end -= 1 }
        let versionEnd = end
        while end > 0 && chars[end - 1].isNumber { end -= 1 }
        guard end < versionEnd, let version = Int(String(chars[end..<versionEnd])) else { return nil }

        // Whitespace before version
        var wsBeforeVersion = 0
        while end > 0 && chars[end - 1].isWhitespace {
            end -= 1
            wsBeforeVersion += 1
        }
        guard wsBeforeVersion >= 1 else { return nil }

        // State token (non-whitespace)
        let stateEnd = end
        while end > 0 && !chars[end - 1].isWhitespace { end -= 1 }
        guard end < stateEnd else { return nil }

        // At least 2 whitespace chars separating name and state
        var wsBeforeState = 0
        while end > 0 && chars[end - 1].isWhitespace {
            end -= 1
            wsBeforeState += 1
        }
        guard wsBeforeState >= 2 else { return nil }

        let name = String(chars[0..<end]).trimmingCharacters(in: .whitespaces)
        return (name: name, version: version)
    }
}

// MARK: - WSL Add Dialog Load Machine (`wsl/add-machine.ts`)

public enum WSLAddMachine {
    public static let dialogLoadTimeoutMs = 15_000

    public enum State: Equatable, Sendable {
        case idle(issued: Int)
        case loading(attempt: Int)
        case disposed
    }

    public enum Event<Module: Sendable>: Sendable {
        case addRequested
        case addLoaded(attempt: Int, module: Module)
        case addFailed(attempt: Int, error: String)
        case disposed
    }

    public enum Effect<Module: Sendable>: Sendable {
        case load(attempt: Int)
        case open(module: Module)
        case toastFailed(error: String)
    }

    public static let initialState: State = .idle(issued: 0)

    public static func reduce<Module: Sendable>(
        state: State,
        event: Event<Module>
    ) -> GUIStateTransition<State, Effect<Module>> {
        if state == .disposed {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed)
        case .addRequested:
            if case .loading = state {
                return GUIStateTransition(state: state)
            }
            if case .idle(let issued) = state {
                let attempt = issued + 1
                return GUIStateTransition(state: .loading(attempt: attempt), effects: [.load(attempt: attempt)])
            }
            return GUIStateTransition(state: state)
        case .addLoaded(let attempt, let module):
            guard case .loading(let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .idle(issued: currentAttempt), effects: [.open(module: module)])
        case .addFailed(let attempt, let error):
            guard case .loading(let currentAttempt) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .idle(issued: currentAttempt), effects: [.toastFailed(error: error)])
        }
    }
}

extension WSLAddMachine.Event: Equatable where Module: Equatable {}
extension WSLAddMachine.Effect: Equatable where Module: Equatable {}

// MARK: - WSL Dialog Machine (`wsl/dialog-machine.ts`)

public enum WSLDialogMachine: GUIStateMachine {
    public static let actionTimeoutMs = 60_000
    public static let installTimeoutMs = 17 * 60_000

    public enum MainOp: Equatable, Hashable, Sendable {
        case installWSL
        case refreshDistros
        case installOpencode(distro: String)
        case addServer(distro: String)
    }

    public enum DialogAction: Equatable, Hashable, Sendable {
        case main(MainOp)
        case installDistro(distro: String)
    }

    public enum PrimaryActionKind: String, Equatable, Hashable, Sendable {
        case installOpencode = "install-opencode"
        case add
    }

    public enum ViewKind: String, Equatable, Hashable, Sendable {
        case main
        case catalog
    }

    public enum State: Equatable, Sendable {
        case main(issued: Int, selectedDistro: String?)
        case mainRunning(issued: Int, selectedDistro: String?, attempt: Int, op: MainOp)
        case catalog(issued: Int, selectedDistro: String?, catalogSearch: String, catalogTarget: String?)
        case catalogInstalling(
            issued: Int,
            selectedDistro: String?,
            catalogSearch: String,
            catalogTarget: String?,
            attempt: Int,
            distro: String
        )
        case completed(selectedDistro: String?)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case distroSelected(String)
        case catalogOpened(defaultTarget: String?, busy: Bool)
        case catalogClosed(busy: Bool)
        case catalogSearchChanged(String)
        case catalogTargetChanged(String)
        case catalogInstallRequested(distro: String?, busy: Bool)
        case wslInstallRequested(busy: Bool)
        case distrosRefreshRequested(busy: Bool)
        case primaryRequested(distro: String?, action: PrimaryActionKind?, disabled: Bool)
        case actionSucceeded(attempt: Int)
        case actionFailed(attempt: Int, cause: String?)
        case availabilityChanged(available: Bool)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case actionRun(attempt: Int, action: DialogAction, timeoutMs: Int)
        case actionAbort(attempt: Int)
        case probesReset
        case dialogClose
        case toastError(cause: String?)
    }

    public static func createState() -> State {
        .main(issued: 0, selectedDistro: nil)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if state == .disposed {
            return GUIStateTransition(state: state)
        }
        if case .disposed = event {
            switch state {
            case .mainRunning(_, _, let attempt, _), .catalogInstalling(_, _, _, _, let attempt, _):
                return GUIStateTransition(state: .disposed, effects: [.actionAbort(attempt: attempt)])
            default:
                return GUIStateTransition(state: .disposed)
            }
        }

        switch state {
        case .main(let issued, let selectedDistro):
            return reduceMain(issued: issued, selectedDistro: selectedDistro, event: event)
        case .catalog(let issued, let selectedDistro, let catalogSearch, let catalogTarget):
            return reduceCatalog(
                issued: issued,
                selectedDistro: selectedDistro,
                catalogSearch: catalogSearch,
                catalogTarget: catalogTarget,
                event: event
            )
        case .completed, .disposed:
            return GUIStateTransition(state: state)
        case .mainRunning, .catalogInstalling:
            return reduceRunning(state: state, event: event)
        }
    }

    public static func selectView(_ state: State) -> ViewKind {
        switch state {
        case .catalog, .catalogInstalling: return .catalog
        default: return .main
        }
    }

    public static func selectSelectedDistro(_ state: State) -> String? {
        switch state {
        case .main(_, let d),
             .mainRunning(_, let d, _, _),
             .catalog(_, let d, _, _),
             .catalogInstalling(_, let d, _, _, _, _),
             .completed(let d):
            return d
        case .disposed:
            return nil
        }
    }

    public static func selectCatalogSearch(_ state: State) -> String {
        switch state {
        case .catalog(_, _, let search, _), .catalogInstalling(_, _, let search, _, _, _):
            return search
        default:
            return ""
        }
    }

    public static func selectCatalogTarget(_ state: State) -> String? {
        switch state {
        case .catalog(_, _, _, let target), .catalogInstalling(_, _, _, let target, _, _):
            return target
        default:
            return nil
        }
    }

    public static func selectBusy(_ state: State) -> Bool {
        switch state {
        case .mainRunning, .catalogInstalling, .completed: return true
        default: return false
        }
    }

    public static func selectAdding(_ state: State) -> Bool {
        switch state {
        case .mainRunning(_, _, _, .addServer), .completed: return true
        default: return false
        }
    }

    public static func selectInstallingCatalog(_ state: State) -> Bool {
        if case .catalogInstalling = state { return true }
        return false
    }

    public static func selectInstallingOpencode(_ state: State, distro: String?) -> Bool {
        guard let distro, case .mainRunning(_, _, _, .installOpencode(let target)) = state else {
            return false
        }
        return target == distro
    }

    private static func reduceMain(
        issued: Int,
        selectedDistro: String?,
        event: Event
    ) -> GUIStateTransition<State, Effect> {
        let state: State = .main(issued: issued, selectedDistro: selectedDistro)
        switch event {
        case .distroSelected(let distro):
            if selectedDistro == distro { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .main(issued: issued, selectedDistro: distro))

        case .catalogOpened(let defaultTarget, let busy):
            if busy { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .catalog(
                    issued: issued,
                    selectedDistro: selectedDistro,
                    catalogSearch: "",
                    catalogTarget: defaultTarget
                )
            )

        case .wslInstallRequested(let busy):
            if busy { return GUIStateTransition(state: state) }
            return runMainOp(issued: issued, selectedDistro: selectedDistro, op: .installWSL, timeoutMs: installTimeoutMs)

        case .distrosRefreshRequested(let busy):
            if busy { return GUIStateTransition(state: state) }
            return runMainOp(
                issued: issued,
                selectedDistro: selectedDistro,
                op: .refreshDistros,
                timeoutMs: actionTimeoutMs,
                before: [.probesReset]
            )

        case .primaryRequested(let distro, let action, let disabled):
            guard !disabled, let distro, let action else {
                return GUIStateTransition(state: state)
            }
            switch action {
            case .installOpencode:
                return runMainOp(
                    issued: issued,
                    selectedDistro: selectedDistro,
                    op: .installOpencode(distro: distro),
                    timeoutMs: installTimeoutMs
                )
            case .add:
                return runMainOp(
                    issued: issued,
                    selectedDistro: selectedDistro,
                    op: .addServer(distro: distro),
                    timeoutMs: actionTimeoutMs
                )
            }

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func reduceCatalog(
        issued: Int,
        selectedDistro: String?,
        catalogSearch: String,
        catalogTarget: String?,
        event: Event
    ) -> GUIStateTransition<State, Effect> {
        let state: State = .catalog(
            issued: issued,
            selectedDistro: selectedDistro,
            catalogSearch: catalogSearch,
            catalogTarget: catalogTarget
        )
        switch event {
        case .catalogClosed(let busy):
            if busy { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .main(issued: issued, selectedDistro: selectedDistro),
                effects: [.probesReset]
            )

        case .catalogSearchChanged(let value):
            if catalogSearch == value { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .catalog(
                    issued: issued,
                    selectedDistro: selectedDistro,
                    catalogSearch: value,
                    catalogTarget: catalogTarget
                )
            )

        case .catalogTargetChanged(let distro):
            if catalogTarget == distro { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: .catalog(
                    issued: issued,
                    selectedDistro: selectedDistro,
                    catalogSearch: catalogSearch,
                    catalogTarget: distro
                )
            )

        case .catalogInstallRequested(let distro, let busy):
            guard !busy, let distro, !distro.isEmpty else {
                return GUIStateTransition(state: state)
            }
            let attempt = issued + 1
            return GUIStateTransition(
                state: .catalogInstalling(
                    issued: attempt,
                    selectedDistro: selectedDistro,
                    catalogSearch: catalogSearch,
                    catalogTarget: distro,
                    attempt: attempt,
                    distro: distro
                ),
                effects: [
                    .probesReset,
                    .actionRun(attempt: attempt, action: .installDistro(distro: distro), timeoutMs: installTimeoutMs),
                ]
            )

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func reduceRunning(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        let settledState: State
        let currentAttempt: Int
        let isCatalogInstall: Bool
        let isAddServer: Bool
        let issued: Int
        let selectedDistro: String?

        switch state {
        case .mainRunning(let i, let sel, let attempt, let op):
            issued = i
            selectedDistro = sel
            currentAttempt = attempt
            isCatalogInstall = false
            if case .addServer = op { isAddServer = true } else { isAddServer = false }
            settledState = .main(issued: i, selectedDistro: sel)
        case .catalogInstalling(let i, let sel, let search, let target, let attempt, _):
            issued = i
            selectedDistro = sel
            currentAttempt = attempt
            isCatalogInstall = true
            isAddServer = false
            settledState = .catalog(issued: i, selectedDistro: sel, catalogSearch: search, catalogTarget: target)
        default:
            return GUIStateTransition(state: state)
        }

        if case .availabilityChanged(let available) = event {
            if available { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: settledState, effects: [.actionAbort(attempt: currentAttempt)])
        }

        switch event {
        case .actionFailed(let attempt, let cause) where attempt == currentAttempt:
            return GUIStateTransition(
                state: settledState,
                effects: [.actionAbort(attempt: attempt), .toastError(cause: cause)]
            )

        case .actionSucceeded(let attempt) where attempt == currentAttempt:
            if isCatalogInstall {
                return GUIStateTransition(
                    state: .main(issued: issued, selectedDistro: selectedDistro),
                    effects: [.actionAbort(attempt: attempt)]
                )
            }
            if isAddServer {
                return GUIStateTransition(
                    state: .completed(selectedDistro: selectedDistro),
                    effects: [.actionAbort(attempt: attempt), .dialogClose]
                )
            }
            return GUIStateTransition(state: settledState, effects: [.actionAbort(attempt: attempt)])

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func runMainOp(
        issued: Int,
        selectedDistro: String?,
        op: MainOp,
        timeoutMs: Int,
        before: [Effect] = []
    ) -> GUIStateTransition<State, Effect> {
        let attempt = issued + 1
        return GUIStateTransition(
            state: .mainRunning(issued: attempt, selectedDistro: selectedDistro, attempt: attempt, op: op),
            effects: before + [.actionRun(attempt: attempt, action: .main(op), timeoutMs: timeoutMs)]
        )
    }
}

// MARK: - WSL Main Machine (`wsl/machine.ts`)

public enum WSLMachine: GUIStateMachine {
    public enum Server: Equatable, Sendable {
        case stopped
        case failed(message: String)
        case ready(attempt: String, url: String, password: String)
    }

    public enum DistroPhase: Equatable, Sendable {
        case idle(server: Server)
        case probing(attempt: String, server: Server)
        case installing(attempt: String)
        case updating(attempt: String)
        case starting(attempt: String)
        case removing(attempt: String)

        public var job: WSLDistroJob? {
            switch self {
            case .idle: return nil
            case .probing: return .probing
            case .installing: return .installing
            case .updating: return .updating
            case .starting: return .starting
            case .removing: return .removing
            }
        }

        public var activeAttempt: String? {
            switch self {
            case .idle: return nil
            case .probing(let a, _),
                 .installing(let a),
                 .updating(let a),
                 .starting(let a),
                 .removing(let a):
                return a
            }
        }
    }

    public enum HostPhase: Equatable, Sendable {
        case idle
        case busy(attempt: String)
    }

    public enum HostJob: String, Equatable, Hashable, Sendable {
        case probeRuntime = "probe-runtime"
        case refreshDistros = "refresh-distros"
        case installWSL = "install-wsl"
    }

    public struct DataSnapshot: Equatable, Sendable {
        public var runtime: WSLRuntimeCheck?
        public var installed: [WSLInstalledDistro]
        public var online: [WSLOnlineDistro]
        public var distroProbes: [String: WSLDistroProbe]
        public var opencodeChecks: [String: WSLOpenCodeCheck]
        public var pendingRestart: Bool
        public var configured: [WSLServerConfig]

        public init(
            runtime: WSLRuntimeCheck? = nil,
            installed: [WSLInstalledDistro] = [],
            online: [WSLOnlineDistro] = [],
            distroProbes: [String: WSLDistroProbe] = [:],
            opencodeChecks: [String: WSLOpenCodeCheck] = [:],
            pendingRestart: Bool = false,
            configured: [WSLServerConfig] = []
        ) {
            self.runtime = runtime
            self.installed = installed
            self.online = online
            self.distroProbes = distroProbes
            self.opencodeChecks = opencodeChecks
            self.pendingRestart = pendingRestart
            self.configured = configured
        }
    }

    public enum State: Equatable, Sendable {
        case open(data: DataSnapshot, host: HostPhase, distros: [String: DistroPhase])
        case closed(data: DataSnapshot)
    }

    public enum Failure: Equatable, Hashable, Sendable {
        case busy(distro: String)
        case alreadyAdded(distro: String)
        case unavailable
        case error(message: String)
    }

    public enum Event: Equatable, Sendable {
        case host(attempt: String, job: HostJob)
        case probe(distro: String, attempt: String)
        case installDistro(distro: String, attempt: String)
        case update(distro: String, attempt: String)
        case add(config: WSLServerConfig, attempt: String)
        case start(id: String, attempt: String)
        case remove(id: String, attempt: String)
        case close
        case runtimeProbed(attempt: String, runtime: WSLRuntimeCheck)
        case runtimeInstalled(attempt: String, runtime: WSLRuntimeCheck)
        case distrosListed(attempt: String, installed: [WSLInstalledDistro], online: [WSLOnlineDistro])
        case hostFailed(attempt: String, message: String)
        case distroProbed(distro: String, attempt: String, probe: WSLDistroProbe)
        case cliInspected(distro: String, attempt: String, check: WSLOpenCodeCheck)
        case distroInstalled(
            distro: String,
            attempt: String,
            installed: [WSLInstalledDistro],
            online: [WSLOnlineDistro],
            probe: WSLDistroProbe
        )
        case cliInstalled(distro: String, attempt: String, check: WSLOpenCodeCheck)
        case jobFailed(distro: String, attempt: String, message: String, check: WSLOpenCodeCheck? = nil)
        case serverStopped(distro: String, attempt: String)
        case serverSpawned(distro: String, attempt: String, url: String, password: String)
        case serverFailed(distro: String, attempt: String, message: String)
        case serverExited(distro: String, attempt: String, code: Int?, signal: String?, message: String)
        case cliChecked(distro: String, check: WSLOpenCodeCheck)
    }

    public enum LogLevel: String, Equatable, Sendable {
        case info
        case error
    }

    public enum Effect: Equatable, Sendable {
        case host(attempt: String, job: HostJob)
        case probeDistro(distro: String, attempt: String)
        case inspectCLI(distro: String, attempt: String)
        case installDistro(distro: String, attempt: String)
        case installCLI(distro: String, attempt: String)
        case stop(distro: String, attempt: String, server: String)
        case spawn(distro: String, attempt: String)
        case checkCLI(distro: String)
        case persist(servers: [WSLServerConfig])
        case log(level: LogLevel, message: String, data: [String: String])
        case resolve(attempt: String)
        case reject(attempt: String, failure: Failure)
    }

    public static func createState(configured: [WSLServerConfig] = []) -> State {
        .open(data: DataSnapshot(configured: configured), host: .idle, distros: [:])
    }

    public static func toServersState(_ state: State) -> WSLServersState {
        switch state {
        case .closed(let data):
            return WSLServersState(
                runtime: data.runtime,
                installed: data.installed,
                online: data.online,
                distroProbes: data.distroProbes,
                opencodeChecks: data.opencodeChecks,
                pendingRestart: data.pendingRestart,
                servers: data.configured.map { WSLServerItem(config: $0, runtime: .stopped) },
                hostJob: .idle,
                distroJobs: [:]
            )
        case .open(let data, let host, let distros):
            let servers = data.configured.map { config in
                let phase = distros[config.distro] ?? .idle(server: .stopped)
                return WSLServerItem(config: config, runtime: runtime(for: phase))
            }
            var distroJobs: [String: WSLDistroJob] = [:]
            for (distro, phase) in distros {
                if let job = phase.job {
                    distroJobs[distro] = job
                }
            }
            let hostJobStatus: WSLHostJobStatus = host == .idle ? .idle : .busy
            return WSLServersState(
                runtime: data.runtime,
                installed: data.installed,
                online: data.online,
                distroProbes: data.distroProbes,
                opencodeChecks: data.opencodeChecks,
                pendingRestart: data.pendingRestart,
                servers: servers,
                hostJob: hostJobStatus,
                distroJobs: distroJobs
            )
        }
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        switch state {
        case .closed:
            switch event {
            case .host(let attempt, _),
                 .probe(_, let attempt),
                 .installDistro(_, let attempt),
                 .update(_, let attempt),
                 .add(_, let attempt),
                 .start(_, let attempt),
                 .remove(_, let attempt):
                return GUIStateTransition(state: state, effects: [.reject(attempt: attempt, failure: .unavailable)])
            default:
                return GUIStateTransition(state: state)
            }

        case .open(var data, let host, var distros):
            switch event {
            case .close:
                var attempts: [String] = []
                if case .busy(let attempt) = host {
                    attempts.append(attempt)
                }
                for key in distros.keys.sorted() {
                    if let attempt = distros[key]?.activeAttempt {
                        attempts.append(attempt)
                    }
                }
                return GUIStateTransition(
                    state: .closed(data: data),
                    effects: attempts.map { .reject(attempt: $0, failure: .unavailable) }
                )

            case .host(let attempt, let job):
                if case .busy = host {
                    return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])
                }
                return GUIStateTransition(
                    state: .open(data: data, host: .busy(attempt: attempt), distros: distros),
                    effects: [.host(attempt: attempt, job: job)]
                )

            case .runtimeProbed(let attempt, let runtime):
                guard case .busy(let current) = host, current == attempt else {
                    return GUIStateTransition(state: state)
                }
                data.runtime = runtime
                data.pendingRestart = data.pendingRestart && !runtime.available
                return GUIStateTransition(
                    state: .open(data: data, host: .idle, distros: distros),
                    effects: [.resolve(attempt: attempt)]
                )

            case .runtimeInstalled(let attempt, let runtime):
                guard case .busy(let current) = host, current == attempt else {
                    return GUIStateTransition(state: state)
                }
                data.runtime = runtime
                data.pendingRestart = !runtime.available
                return GUIStateTransition(
                    state: .open(data: data, host: .idle, distros: distros),
                    effects: [.resolve(attempt: attempt)]
                )

            case .distrosListed(let attempt, let installed, let online):
                guard case .busy(let current) = host, current == attempt else {
                    return GUIStateTransition(state: state)
                }
                data.installed = installed
                data.online = online
                return GUIStateTransition(
                    state: .open(data: data, host: .idle, distros: distros),
                    effects: [.resolve(attempt: attempt)]
                )

            case .hostFailed(let attempt, let message):
                guard case .busy(let current) = host, current == attempt else {
                    return GUIStateTransition(state: state)
                }
                return GUIStateTransition(
                    state: .open(data: data, host: .idle, distros: distros),
                    effects: [.reject(attempt: attempt, failure: .error(message: message))]
                )

            case .probe(let distro, let attempt):
                let current = distros[distro] ?? .idle(server: .stopped)
                guard case .idle(let server) = current else {
                    return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])
                }
                if data.distroProbes[distro] == nil {
                    distros[distro] = .probing(attempt: attempt, server: server)
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [.probeDistro(distro: distro, attempt: attempt)]
                    )
                }
                if needsCLICheck(data: data, distro: distro) {
                    distros[distro] = .probing(attempt: attempt, server: server)
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [.inspectCLI(distro: distro, attempt: attempt)]
                    )
                }
                return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])

            case .distroProbed(let distro, let attempt, let probe):
                guard case .probing(let currentAttempt, let server) = distros[distro], currentAttempt == attempt else {
                    return GUIStateTransition(state: state)
                }
                data.distroProbes[distro] = probe
                if needsCLICheck(data: data, distro: distro) {
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [.inspectCLI(distro: distro, attempt: attempt)]
                    )
                }
                distros[distro] = .idle(server: server)
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.resolve(attempt: attempt)]
                )

            case .cliInspected(let distro, let attempt, let check):
                guard case .probing(let currentAttempt, let server) = distros[distro], currentAttempt == attempt else {
                    return GUIStateTransition(state: state)
                }
                data.opencodeChecks[distro] = check
                distros[distro] = .idle(server: server)
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.resolve(attempt: attempt)]
                )

            case .installDistro(let distro, let attempt):
                let current = distros[distro] ?? .idle(server: .stopped)
                if case .installing = current {
                    return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])
                }
                if data.configured.contains(where: { $0.distro == distro }) {
                    return GUIStateTransition(state: state, effects: [.reject(attempt: attempt, failure: .alreadyAdded(distro: distro))])
                }
                guard case .idle = current else {
                    return GUIStateTransition(state: state, effects: [.reject(attempt: attempt, failure: .busy(distro: distro))])
                }
                distros[distro] = .installing(attempt: attempt)
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.installDistro(distro: distro, attempt: attempt)]
                )

            case .distroInstalled(let distro, let attempt, let installed, let online, let probe):
                guard case .installing(let currentAttempt) = distros[distro], currentAttempt == attempt else {
                    return GUIStateTransition(state: state)
                }
                data.installed = installed
                data.online = online
                data.distroProbes[distro] = probe
                distros[distro] = .idle(server: .stopped)
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.resolve(attempt: attempt)]
                )

            case .update(let distro, let attempt):
                let current = distros[distro] ?? .idle(server: .stopped)
                if case .updating = current {
                    return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])
                }
                if case .starting(let startingAttempt) = current {
                    distros[distro] = .updating(attempt: attempt)
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [
                            .resolve(attempt: startingAttempt),
                            .stop(distro: distro, attempt: attempt, server: startingAttempt),
                        ]
                    )
                }
                guard case .idle(let server) = current else {
                    return GUIStateTransition(state: state, effects: [.reject(attempt: attempt, failure: .busy(distro: distro))])
                }
                distros[distro] = .updating(attempt: attempt)
                if case .ready(let serverAttempt, _, _) = server {
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [.stop(distro: distro, attempt: attempt, server: serverAttempt)]
                    )
                }
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.installCLI(distro: distro, attempt: attempt)]
                )

            case .cliInstalled(let distro, let attempt, let check):
                guard case .updating(let currentAttempt) = distros[distro], currentAttempt == attempt else {
                    return GUIStateTransition(state: state)
                }
                data.opencodeChecks[distro] = check
                if !data.configured.contains(where: { $0.distro == distro }) {
                    distros[distro] = .idle(server: .stopped)
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [.resolve(attempt: attempt)]
                    )
                }
                distros[distro] = .starting(attempt: attempt)
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.spawn(distro: distro, attempt: attempt)]
                )

            case .jobFailed(let distro, let attempt, let message, let check):
                let current = distros[distro] ?? .idle(server: .stopped)
                let nextPhase: DistroPhase
                switch current {
                case .probing(let currentAttempt, let server) where currentAttempt == attempt:
                    nextPhase = .idle(server: server)
                case .installing(let currentAttempt) where currentAttempt == attempt:
                    nextPhase = .idle(server: .stopped)
                case .updating(let currentAttempt) where currentAttempt == attempt:
                    nextPhase = .idle(server: .stopped)
                default:
                    return GUIStateTransition(state: state)
                }
                if let check {
                    data.opencodeChecks[distro] = check
                }
                distros[distro] = nextPhase
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.reject(attempt: attempt, failure: .error(message: message))]
                )

            case .add(let config, let attempt):
                let distro = config.distro
                if data.configured.contains(where: { $0.id == config.id || $0.distro == distro }) {
                    return GUIStateTransition(
                        state: state,
                        effects: [.reject(attempt: attempt, failure: .alreadyAdded(distro: distro))]
                    )
                }
                let current = distros[distro] ?? .idle(server: .stopped)
                guard case .idle = current else {
                    return GUIStateTransition(
                        state: state,
                        effects: [.reject(attempt: attempt, failure: .busy(distro: distro))]
                    )
                }
                data.configured.append(config)
                distros[distro] = .starting(attempt: attempt)
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [
                        .persist(servers: data.configured),
                        .spawn(distro: distro, attempt: attempt),
                        .checkCLI(distro: distro),
                        .resolve(attempt: attempt),
                    ]
                )

            case .start(let id, let attempt):
                guard let distro = data.configured.first(where: { $0.id == id })?.distro else {
                    return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])
                }
                let current = distros[distro] ?? .idle(server: .stopped)
                switch current {
                case .starting, .updating:
                    return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])
                case .idle(let server):
                    distros[distro] = .starting(attempt: attempt)
                    if case .ready(let serverAttempt, _, _) = server {
                        return GUIStateTransition(
                            state: .open(data: data, host: host, distros: distros),
                            effects: [
                                .stop(distro: distro, attempt: attempt, server: serverAttempt),
                                .checkCLI(distro: distro),
                            ]
                        )
                    }
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [
                            .spawn(distro: distro, attempt: attempt),
                            .checkCLI(distro: distro),
                        ]
                    )
                default:
                    return GUIStateTransition(state: state, effects: [.reject(attempt: attempt, failure: .busy(distro: distro))])
                }

            case .remove(let id, let attempt):
                guard let distro = data.configured.first(where: { $0.id == id })?.distro else {
                    return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])
                }
                let current = distros[distro] ?? .idle(server: .stopped)
                if case .removing = current {
                    return GUIStateTransition(state: state, effects: [.resolve(attempt: attempt)])
                }
                if case .starting(let startingAttempt) = current {
                    distros[distro] = .removing(attempt: attempt)
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [
                            .resolve(attempt: startingAttempt),
                            .stop(distro: distro, attempt: attempt, server: startingAttempt),
                        ]
                    )
                }
                guard case .idle(let server) = current else {
                    return GUIStateTransition(state: state, effects: [.reject(attempt: attempt, failure: .busy(distro: distro))])
                }
                if case .ready(let serverAttempt, _, _) = server {
                    distros[distro] = .removing(attempt: attempt)
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [.stop(distro: distro, attempt: attempt, server: serverAttempt)]
                    )
                }
                removeDistroData(distro: distro, data: &data, distros: &distros)
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.persist(servers: data.configured), .resolve(attempt: attempt)]
                )

            case .serverStopped(let distro, let attempt):
                guard let current = distros[distro] else { return GUIStateTransition(state: state) }
                switch current {
                case .starting(let currentAttempt) where currentAttempt == attempt:
                    return GUIStateTransition(state: state, effects: [.spawn(distro: distro, attempt: attempt)])
                case .updating(let currentAttempt) where currentAttempt == attempt:
                    return GUIStateTransition(state: state, effects: [.installCLI(distro: distro, attempt: attempt)])
                case .removing(let currentAttempt) where currentAttempt == attempt:
                    removeDistroData(distro: distro, data: &data, distros: &distros)
                    return GUIStateTransition(
                        state: .open(data: data, host: host, distros: distros),
                        effects: [.persist(servers: data.configured), .resolve(attempt: attempt)]
                    )
                default:
                    return GUIStateTransition(state: state)
                }

            case .serverSpawned(let distro, let attempt, let url, let password):
                guard case .starting(let currentAttempt) = distros[distro], currentAttempt == attempt else {
                    return GUIStateTransition(state: state)
                }
                distros[distro] = .idle(server: .ready(attempt: attempt, url: url, password: password))
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [
                        .resolve(attempt: attempt),
                        .checkCLI(distro: distro),
                        .log(level: .info, message: "wsl sidecar ready", data: ["distro": distro, "url": url]),
                    ]
                )

            case .serverFailed(let distro, let attempt, let message):
                guard case .starting(let currentAttempt) = distros[distro], currentAttempt == attempt else {
                    return GUIStateTransition(state: state)
                }
                distros[distro] = .idle(server: .failed(message: message))
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [
                        .resolve(attempt: attempt),
                        .log(level: .error, message: "wsl sidecar failed to start", data: ["distro": distro, "message": message]),
                    ]
                )

            case .serverExited(let distro, let attempt, let code, let signal, let message):
                guard let current = distros[distro] else { return GUIStateTransition(state: state) }
                switch current {
                case .idle(.ready(let serverAttempt, _, _)) where serverAttempt == attempt:
                    distros[distro] = .idle(server: .failed(message: message))
                case .probing(let probeAttempt, .ready(let serverAttempt, _, _)) where serverAttempt == attempt:
                    distros[distro] = .probing(attempt: probeAttempt, server: .failed(message: message))
                default:
                    return GUIStateTransition(state: state)
                }
                var logData: [String: String] = ["distro": distro]
                if let code { logData["code"] = String(code) }
                if let signal { logData["signal"] = signal }
                return GUIStateTransition(
                    state: .open(data: data, host: host, distros: distros),
                    effects: [.log(level: .error, message: "wsl sidecar exited", data: logData)]
                )

            case .cliChecked(let distro, let check):
                let current = distros[distro] ?? .idle(server: .stopped)
                guard data.configured.contains(where: { $0.distro == distro }) else {
                    return GUIStateTransition(state: state)
                }
                if case .updating = current { return GUIStateTransition(state: state) }
                if case .removing = current { return GUIStateTransition(state: state) }
                data.opencodeChecks[distro] = check
                return GUIStateTransition(state: .open(data: data, host: host, distros: distros))
            }
        }
    }

    private static func runtime(for phase: DistroPhase) -> WSLServerRuntime {
        switch phase {
        case .starting:
            return .starting
        case .idle(let server), .probing(_, let server):
            switch server {
            case .ready(_, let url, let password):
                return .ready(url: url, password: password)
            case .failed(let message):
                return .failed(message: message)
            case .stopped:
                return .stopped
            }
        case .installing, .updating, .removing:
            return .stopped
        }
    }

    private static func needsCLICheck(data: DataSnapshot, distro: String) -> Bool {
        guard let probe = data.distroProbes[distro] else { return false }
        return probe.canExecute && probe.hasBash && probe.hasCurl && data.opencodeChecks[distro] == nil
    }

    private static func removeDistroData(distro: String, data: inout DataSnapshot, distros: inout [String: DistroPhase]) {
        data.configured.removeAll { $0.distro == distro }
        distros.removeValue(forKey: distro)
        data.distroProbes.removeValue(forKey: distro)
        data.opencodeChecks.removeValue(forKey: distro)
    }
}

// MARK: - WSL Probe Machine & View Models (`wsl/probe-machine.ts`, `wsl/model.ts`, `wsl/row-view.ts`)

public enum WSLAutoProbeAction: String, Equatable, Hashable, Sendable {
    case probeRuntime
    case refreshDistros
}

public enum WSLAddServerProbePlan: Equatable, Hashable, Sendable {
    case auto(key: String, action: WSLAutoProbeAction)
    case addable(key: String, distros: [String])

    public var key: String {
        switch self {
        case .auto(let key, _): return "auto:\(key)"
        case .addable(let key, _): return "addable:\(key)"
        }
    }

    public var isAddable: Bool {
        if case .addable = self { return true }
        return false
    }
}

public enum WSLProbeMachine: GUIStateMachine {
    public static let timeoutMs = 60_000

    public struct Input: Equatable, Sendable {
        public let plan: WSLAddServerProbePlan?
        public let busy: Bool
        public let available: Bool

        public init(plan: WSLAddServerProbePlan?, busy: Bool, available: Bool) {
            self.plan = plan
            self.busy = busy
            self.available = available
        }
    }

    public enum State: Equatable, Sendable {
        case idle(issued: Int, completed: String?, failed: Set<String>)
        case running(issued: Int, attempt: Int, command: WSLAddServerProbePlan, failed: Set<String>)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case synced(Input)
        case reset
        case probeSucceeded(attempt: Int, input: Input)
        case probeFailed(attempt: Int, cause: String?, input: Input)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case probeRun(attempt: Int, command: WSLAddServerProbePlan, timeoutMs: Int)
        case probeAbort(attempt: Int)
        case probeError(cause: String?)
    }

    public static func createState() -> State {
        .idle(issued: 0, completed: nil, failed: [])
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if state == .disposed {
            return GUIStateTransition(state: state)
        }
        if case .disposed = event {
            if case .running(_, let attempt, _, _) = state {
                return GUIStateTransition(state: .disposed, effects: [.probeAbort(attempt: attempt)])
            }
            return GUIStateTransition(state: .disposed)
        }
        if case .reset = event {
            switch state {
            case .idle(let issued, let completed, let failed) where !failed.isEmpty:
                return GUIStateTransition(state: .idle(issued: issued, completed: completed, failed: []))
            case .running(let issued, let attempt, let command, let failed) where !failed.isEmpty:
                return GUIStateTransition(state: .running(issued: issued, attempt: attempt, command: command, failed: []))
            default:
                return GUIStateTransition(state: state)
            }
        }

        switch state {
        case .idle(let issued, let completed, let failed):
            guard case .synced(let input) = event else { return GUIStateTransition(state: state) }
            return schedule(previous: (issued, completed, failed), issued: issued, completed: completed, failed: failed, input: input)

        case .running(let issued, let attempt, let command, let failed):
            if case .synced(let input) = event {
                if input.available { return GUIStateTransition(state: state) }
                return GUIStateTransition(
                    state: .idle(issued: issued, completed: nil, failed: []),
                    effects: [.probeAbort(attempt: attempt)]
                )
            }
            switch event {
            case .probeSucceeded(let eventAttempt, let input) where eventAttempt == attempt:
                let next = schedule(previous: nil, issued: issued, completed: command.key, failed: failed, input: input)
                return GUIStateTransition(state: next.state, effects: [.probeAbort(attempt: attempt)] + next.effects)
            case .probeFailed(let eventAttempt, let cause, let input) where eventAttempt == attempt:
                var nextFailed = failed
                nextFailed.insert(command.key)
                let next = schedule(previous: nil, issued: issued, completed: nil, failed: nextFailed, input: input)
                return GUIStateTransition(
                    state: next.state,
                    effects: [.probeAbort(attempt: attempt), .probeError(cause: cause)] + next.effects
                )
            default:
                return GUIStateTransition(state: state)
            }

        case .disposed:
            return GUIStateTransition(state: state)
        }
    }

    public static func selectProbingAddable(_ state: State) -> Bool {
        if case .running(_, _, let command, _) = state {
            return command.isAddable
        }
        return false
    }

    private static func schedule(
        previous: (issued: Int, completed: String?, failed: Set<String>)?,
        issued: Int,
        completed: String?,
        failed: Set<String>,
        input: Input
    ) -> GUIStateTransition<State, Effect> {
        if !input.available {
            if let previous, previous.completed == nil && previous.failed.isEmpty {
                return GUIStateTransition(state: .idle(issued: previous.issued, completed: nil, failed: []))
            }
            return GUIStateTransition(state: .idle(issued: issued, completed: nil, failed: []))
        }

        let held: String? = (completed != nil && (input.busy || input.plan?.key == completed)) ? completed : nil
        guard let plan = input.plan, plan.key != held, !failed.contains(plan.key) else {
            return GUIStateTransition(state: .idle(issued: issued, completed: held, failed: failed))
        }

        let attempt = issued + 1
        return GUIStateTransition(
            state: .running(issued: attempt, attempt: attempt, command: plan, failed: failed),
            effects: [.probeRun(attempt: attempt, command: plan, timeoutMs: timeoutMs)]
        )
    }
}

public struct WSLTextKey: Equatable, Hashable, Sendable {
    public let key: String
    public let params: [String: String]

    public init(key: String, params: [String: String] = [:]) {
        self.key = key
        self.params = params
    }
}

public enum WSLDistroStatusTone: String, Equatable, Hashable, Sendable {
    case success
    case warning
    case muted
}

public struct WSLDistroStatus: Equatable, Sendable {
    public let label: WSLTextKey
    public let tone: WSLDistroStatusTone

    public init(label: WSLTextKey, tone: WSLDistroStatusTone) {
        self.label = label
        self.tone = tone
    }
}

public enum WSLAddServerRuntimeState: String, Equatable, Hashable, Sendable {
    case loading
    case pendingRestart
    case checking
    case unavailable
    case ready
}

public struct WSLPrimaryButton: Equatable, Sendable {
    public enum Variant: String, Equatable, Hashable, Sendable {
        case neutral
        case contrast
    }

    public let variant: Variant
    public let label: WSLTextKey
    public let disabled: Bool
    public let action: WSLDialogMachine.PrimaryActionKind?
    public let loading: Bool
    public let width: String?

    public init(
        variant: Variant,
        label: WSLTextKey,
        disabled: Bool,
        action: WSLDialogMachine.PrimaryActionKind?,
        loading: Bool,
        width: String?
    ) {
        self.variant = variant
        self.label = label
        self.disabled = disabled
        self.action = action
        self.loading = loading
        self.width = width
    }
}

public struct WSLAddServerViewModel: Equatable, Sendable {
    public let view: WSLDialogMachine.ViewKind
    public let catalogSearch: String
    public let adding: Bool
    public let busy: Bool
    public let runtimeState: WSLAddServerRuntimeState
    public let visibleInstalledDistros: [WSLInstalledDistro]
    public let visibleOnlineDistros: [WSLOnlineDistro]
    public let addableInstalledDistros: [WSLInstalledDistro]
    public let selectedDistro: String?
    public let opencodeCheck: WSLOpenCodeCheck?
    public let wslReady: Bool
    public let distroStatuses: [String: WSLDistroStatus]
    public let primaryButton: WSLPrimaryButton
    public let installableDistros: [WSLOnlineDistro]
    public let filteredInstallableDistros: [WSLOnlineDistro]
    public let catalogTarget: String?
    public let installingCatalogDistro: Bool
}

public struct WSLRowView: Equatable, Sendable {
    public struct Button: Equatable, Sendable {
        public let label: String
        public let disabled: Bool

        public init(label: String, disabled: Bool) {
            self.label = label
            self.disabled = disabled
        }
    }

    public let version: String?
    public let button: Button?
    public let retry: Bool
    public let removable: Bool

    public init(version: String?, button: Button?, retry: Bool, removable: Bool) {
        self.version = version
        self.button = button
        self.retry = retry
        self.removable = removable
    }
}

public enum WSLViewModel {
    public static func isHiddenDistro(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "docker-desktop" || lower == "docker-desktop-data"
    }

    public static func buildAddServerViewModel(
        state: WSLServersState?,
        dialog: WSLDialogMachine.State,
        probingAddable: Bool
    ) -> WSLAddServerViewModel {
        let catalogSearch = WSLDialogMachine.selectCatalogSearch(dialog)
        let visibleInstalled = (state?.installed ?? []).filter { !isHiddenDistro($0.name) }
        let visibleOnline = (state?.online ?? []).filter { !isHiddenDistro($0.name) }
        let existingDistros = Set((state?.servers ?? []).map(\.config.distro))
        let addableInstalled = visibleInstalled.filter { !existingDistros.contains($0.name) }

        let selected = pickSelectedDistro(
            preferred: WSLDialogMachine.selectSelectedDistro(dialog),
            visibleInstalled: visibleInstalled,
            addableInstalled: addableInstalled
        )
        let opencodeCheck = selected.flatMap { state?.opencodeChecks[$0] }
        let installable = computeInstallable(installed: visibleInstalled, online: visibleOnline)
        let filteredInstallable = filterInstallable(installable, search: catalogSearch)
        let catalogTarget = pickCatalogTarget(preferred: WSLDialogMachine.selectCatalogTarget(dialog), distros: filteredInstallable)
        let working = (state.map(dialogJobRunning) ?? false) || WSLDialogMachine.selectBusy(dialog)

        var statuses: [String: WSLDistroStatus] = [:]
        for item in addableInstalled {
            if let status = distroStatus(state: state, name: item.name, probingAddable: probingAddable) {
                statuses[item.name] = status
            }
        }

        let runtimeState: WSLAddServerRuntimeState
        if let state {
            if state.pendingRestart {
                runtimeState = .pendingRestart
            } else if let rt = state.runtime {
                runtimeState = rt.available ? .ready : .unavailable
            } else {
                runtimeState = .checking
            }
        } else {
            runtimeState = .loading
        }

        let button = primaryButton(
            state: state,
            selectedDistro: selected,
            opencodeCheck: opencodeCheck,
            busy: working,
            installingOpencode: WSLDialogMachine.selectInstallingOpencode(dialog, distro: selected),
            adding: WSLDialogMachine.selectAdding(dialog),
            probingAddable: probingAddable
        )

        let installingCatalog = WSLDialogMachine.selectInstallingCatalog(dialog)
            || (state?.distroJobs.values.contains(.installing) ?? false)

        return WSLAddServerViewModel(
            view: WSLDialogMachine.selectView(dialog),
            catalogSearch: catalogSearch,
            adding: WSLDialogMachine.selectAdding(dialog),
            busy: working || probingAddable,
            runtimeState: runtimeState,
            visibleInstalledDistros: visibleInstalled,
            visibleOnlineDistros: visibleOnline,
            addableInstalledDistros: addableInstalled,
            selectedDistro: selected,
            opencodeCheck: opencodeCheck,
            wslReady: state?.runtime?.available == true && state?.pendingRestart == false,
            distroStatuses: statuses,
            primaryButton: button,
            installableDistros: installable,
            filteredInstallableDistros: filteredInstallable,
            catalogTarget: catalogTarget,
            installingCatalogDistro: installingCatalog
        )
    }

    public static func addServerProbePlan(
        state: WSLServersState?,
        view: WSLDialogMachine.ViewKind,
        busy: Bool,
        selectedDistro: String?,
        addableInstalledDistros: [WSLInstalledDistro]
    ) -> WSLAddServerProbePlan? {
        if let state, !busy, !state.pendingRestart {
            if state.runtime == nil {
                return .auto(key: "runtime", action: .probeRuntime)
            }
            if state.runtime?.available == true && state.installed.isEmpty && state.online.isEmpty {
                return .auto(key: "distros", action: .refreshDistros)
            }
        }

        guard let state,
              state.runtime?.available == true,
              !state.pendingRestart,
              view == .main,
              !busy,
              !dialogJobRunning(state)
        else {
            return nil
        }

        let ordered: [WSLInstalledDistro]
        if let selectedDistro {
            ordered = addableInstalledDistros.filter { $0.name == selectedDistro }
                + addableInstalledDistros.filter { $0.name != selectedDistro }
        } else {
            ordered = addableInstalledDistros
        }

        var pending: [String] = []
        for item in ordered {
            if item.version == 1 { continue }
            if state.distroProbes[item.name] == nil {
                pending.append("distro:\(item.name)")
            } else if distroReady(state: state, name: item.name) && state.opencodeChecks[item.name] == nil {
                pending.append("opencode:\(item.name)")
            }
        }
        guard !pending.isEmpty else { return nil }
        return .addable(
            key: pending.joined(separator: "|"),
            distros: ordered.filter { $0.version != 1 }.map(\.name)
        )
    }

    public static func rowView(state: WSLServersState?, distro: String) -> WSLRowView {
        let job = state?.distroJobs[distro]
        let check = state?.opencodeChecks[distro]
        let action: String?
        if let check {
            if check.resolvedPath == nil {
                action = "onboarding.installOpencode"
            } else if check.matchesDesktop == false {
                action = "onboarding.updateOpencode"
            } else {
                action = nil
            }
        } else {
            action = nil
        }
        let runtime = state?.servers.first(where: { $0.config.distro == distro })?.runtime
        let free = job == nil || job == .starting
        let canRetry: Bool
        if job == nil {
            switch runtime {
            case .failed, .stopped: canRetry = true
            default: canRetry = false
            }
        } else {
            canRetry = false
        }
        return WSLRowView(
            version: check?.version,
            button: action.map { WSLRowView.Button(label: job == .updating ? "server.updating" : $0, disabled: !free) },
            retry: canRetry,
            removable: free
        )
    }

    private static func dialogJobRunning(_ state: WSLServersState) -> Bool {
        if state.hostJob == .busy { return true }
        let added = Set(state.servers.map(\.config.distro))
        return state.distroJobs.keys.contains { !added.contains($0) }
    }

    private static func distroReady(state: WSLServersState?, name: String) -> Bool {
        guard let installed = state?.installed.first(where: { $0.name == name }),
              let probe = state?.distroProbes[name],
              installed.version != 1
        else { return false }
        return probe.canExecute && probe.hasBash && probe.hasCurl
    }

    private static func pickSelectedDistro(
        preferred: String?,
        visibleInstalled: [WSLInstalledDistro],
        addableInstalled: [WSLInstalledDistro]
    ) -> String? {
        if let preferred, addableInstalled.contains(where: { $0.name == preferred && $0.version != 1 }) {
            return preferred
        }
        if let def = visibleInstalled.first(where: { $0.isDefault }),
           def.version != 1,
           addableInstalled.contains(where: { $0.name == def.name })
        {
            return def.name
        }
        return addableInstalled.first(where: { $0.version != 1 })?.name
    }

    private static func distroStatus(
        state: WSLServersState?,
        name: String,
        probingAddable: Bool
    ) -> WSLDistroStatus? {
        let installed = state?.installed.first(where: { $0.name == name })
        if installed?.version == 1 {
            return WSLDistroStatus(label: WSLTextKey(key: "onboarding.distroStatus.unsupported"), tone: .muted)
        }
        let probing = probingAddable || state?.distroJobs[name] == .probing
        guard let probe = state?.distroProbes[name] else {
            return probing ? WSLDistroStatus(label: WSLTextKey(key: "onboarding.distroStatus.checking"), tone: .muted) : nil
        }
        if !probe.canExecute {
            let key = installed == nil ? "onboarding.distroNotInstalled" : "onboarding.openDistroOnce"
            return WSLDistroStatus(label: WSLTextKey(key: key, params: ["distro": name]), tone: .warning)
        }
        if !probe.hasBash || !probe.hasCurl {
            return WSLDistroStatus(label: WSLTextKey(key: "onboarding.distroStatus.missingTools"), tone: .warning)
        }
        guard let check = state?.opencodeChecks[name] else {
            return probing ? WSLDistroStatus(label: WSLTextKey(key: "onboarding.distroStatus.checking"), tone: .muted) : nil
        }
        if check.matchesDesktop == false {
            return WSLDistroStatus(label: WSLTextKey(key: "onboarding.updateOpencode"), tone: .warning)
        }
        if check.resolvedPath == nil {
            return WSLDistroStatus(label: WSLTextKey(key: "onboarding.distroStatus.opencodeMissing"), tone: .warning)
        }
        if check.error != nil {
            return WSLDistroStatus(label: WSLTextKey(key: "onboarding.installOpencode"), tone: .warning)
        }
        return WSLDistroStatus(label: WSLTextKey(key: "onboarding.distroStatus.ready"), tone: .success)
    }

    private static func primaryButton(
        state: WSLServersState?,
        selectedDistro: String?,
        opencodeCheck: WSLOpenCodeCheck?,
        busy: Bool,
        installingOpencode: Bool,
        adding: Bool,
        probingAddable: Bool
    ) -> WSLPrimaryButton {
        let ready = selectedDistro.map { distroReady(state: state, name: $0) } ?? false
        let settled = selectedDistroSettled(state: state, selectedDistro: selectedDistro)
        let probingSelected = probingAddable && !settled
        let job = selectedDistro.flatMap { state?.distroJobs[$0] }
        let probingOpencode = probingSelected || (ready && (opencodeCheck == nil || job == .probing))
        let isInstalling = job == .updating || installingOpencode

        if !ready || probingOpencode {
            return WSLPrimaryButton(
                variant: .contrast,
                label: WSLTextKey(key: probingSelected ? "onboarding.distroStatus.checking" : "server.add"),
                disabled: true,
                action: nil,
                loading: probingSelected,
                width: nil
            )
        }

        let opencodeReady = opencodeCheck?.resolvedPath != nil
            && opencodeCheck?.matchesDesktop != false
            && opencodeCheck?.error == nil

        if !opencodeReady {
            let isUpdate = opencodeCheck?.resolvedPath != nil && opencodeCheck?.matchesDesktop == false
            let labelKey = isInstalling
                ? "onboarding.updatingOpencode"
                : (isUpdate ? "onboarding.updateOpencode" : "onboarding.installOpencode")
            return WSLPrimaryButton(
                variant: .neutral,
                label: WSLTextKey(key: labelKey),
                disabled: busy,
                action: .installOpencode,
                loading: isInstalling,
                width: isUpdate ? "138px" : "129px"
            )
        }

        return WSLPrimaryButton(
            variant: .contrast,
            label: WSLTextKey(key: adding ? "onboarding.adding" : "server.add"),
            disabled: busy,
            action: .add,
            loading: adding,
            width: nil
        )
    }

    private static func selectedDistroSettled(state: WSLServersState?, selectedDistro: String?) -> Bool {
        guard let selectedDistro, let state else { return false }
        if state.installed.first(where: { $0.name == selectedDistro })?.version == 1 { return false }
        guard state.distroProbes[selectedDistro] != nil else { return false }
        if !distroReady(state: state, name: selectedDistro) { return true }
        return state.opencodeChecks[selectedDistro] != nil
    }

    private static func computeInstallable(
        installed: [WSLInstalledDistro],
        online: [WSLOnlineDistro]
    ) -> [WSLOnlineDistro] {
        let installedNames = Set(installed.map(\.name))
        let hasVersionedUbuntu = online.contains { item in
            item.name.hasPrefix("Ubuntu-") && item.name.dropFirst("Ubuntu-".count).first?.isNumber == true
        }
        return online.filter { item in
            !installedNames.contains(item.name) && (item.name != "Ubuntu" || !hasVersionedUbuntu)
        }
    }

    private static func filterInstallable(_ distros: [WSLOnlineDistro], search: String) -> [WSLOnlineDistro] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return distros }
        let scored: [(WSLOnlineDistro, Int)] = distros.compactMap { distro in
            let bestScore = min(
                subsequenceMatchScore(query: query, target: distro.label.lowercased()) ?? Int.max,
                subsequenceMatchScore(query: query, target: distro.name.lowercased()) ?? Int.max
            )
            return bestScore == Int.max ? nil : (distro, bestScore)
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private static func subsequenceMatchScore(query: String, target: String) -> Int? {
        if let range = target.range(of: query) {
            return target.distance(from: target.startIndex, to: range.lowerBound)
        }
        var targetIndex = target.startIndex
        var gaps = 0
        var lastMatch: String.Index?
        for ch in query {
            guard let found = target[targetIndex...].firstIndex(of: ch) else { return nil }
            if let last = lastMatch {
                gaps += target.distance(from: target.index(after: last), to: found)
            }
            lastMatch = found
            targetIndex = target.index(after: found)
        }
        return 1000 + gaps
    }

    private static func pickCatalogTarget(preferred: String?, distros: [WSLOnlineDistro]) -> String? {
        if let preferred, distros.contains(where: { $0.name == preferred }) {
            return preferred
        }
        return distros.first?.name
    }
}

// MARK: - Injectable WSL Controller

public protocol WSLBackendDriver: Sendable {
    func performHostJob(attempt: String, job: WSLMachine.HostJob) async
    func probeDistro(distro: String, attempt: String) async
    func inspectCLI(distro: String, attempt: String) async
    func installDistro(distro: String, attempt: String) async
    func installCLI(distro: String, attempt: String) async
    func stopServer(distro: String, attempt: String, server: String) async
    func spawnServer(distro: String, attempt: String) async
    func checkCLI(distro: String) async
    func persistServers(_ servers: [WSLServerConfig]) async
}

/// Actor orchestrating `WSLMachine` transitions and injectable host/distro driver operations.
public actor WSLController {
    private var machineState: WSLMachine.State
    private var nextAttempt = 0
    private var continuations: [String: CheckedContinuation<Void, any Error>] = [:]
    private let driver: any WSLBackendDriver

    public init(configured: [WSLServerConfig] = [], driver: any WSLBackendDriver) {
        self.machineState = WSLMachine.createState(configured: configured)
        self.driver = driver
    }

    public func serversState() -> WSLServersState {
        WSLMachine.toServersState(machineState)
    }

    public func probeRuntime() async throws {
        try await request { .host(attempt: $0, job: .probeRuntime) }
    }

    public func refreshDistros() async throws {
        try await request { .host(attempt: $0, job: .refreshDistros) }
    }

    public func addServer(_ config: WSLServerConfig) async throws {
        try await request { .add(config: config, attempt: $0) }
    }

    public func startServer(id: String) async throws {
        try await request { .start(id: id, attempt: $0) }
    }

    public func removeServer(id: String) async throws {
        try await request { .remove(id: id, attempt: $0) }
    }

    public func report(_ event: WSLMachine.Event) async {
        await dispatch(event)
    }

    public func close() async {
        await dispatch(.close)
    }

    private func request(_ makeEvent: @Sendable (String) -> WSLMachine.Event) async throws {
        nextAttempt += 1
        let attempt = "wsl-\(nextAttempt)"
        let event = makeEvent(attempt)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            continuations[attempt] = continuation
            Task {
                await self.dispatch(event)
            }
        }
    }

    private func dispatch(_ event: WSLMachine.Event) async {
        let transition = WSLMachine.reduce(state: machineState, event: event)
        machineState = transition.state
        for effect in transition.effects {
            await perform(effect)
        }
    }

    private func perform(_ effect: WSLMachine.Effect) async {
        switch effect {
        case .host(let attempt, let job):
            await driver.performHostJob(attempt: attempt, job: job)
        case .probeDistro(let distro, let attempt):
            await driver.probeDistro(distro: distro, attempt: attempt)
        case .inspectCLI(let distro, let attempt):
            await driver.inspectCLI(distro: distro, attempt: attempt)
        case .installDistro(let distro, let attempt):
            await driver.installDistro(distro: distro, attempt: attempt)
        case .installCLI(let distro, let attempt):
            await driver.installCLI(distro: distro, attempt: attempt)
        case .stop(let distro, let attempt, let server):
            await driver.stopServer(distro: distro, attempt: attempt, server: server)
        case .spawn(let distro, let attempt):
            await driver.spawnServer(distro: distro, attempt: attempt)
        case .checkCLI(let distro):
            await driver.checkCLI(distro: distro)
        case .persist(let servers):
            await driver.persistServers(servers)
        case .log:
            break
        case .resolve(let attempt):
            if let continuation = continuations.removeValue(forKey: attempt) {
                continuation.resume()
            }
        case .reject(let attempt, let failure):
            if let continuation = continuations.removeValue(forKey: attempt) {
                continuation.resume(throwing: WSLControllerError(failure: failure))
            }
        }
    }
}

public struct WSLControllerError: Error, Equatable, Sendable {
    public let failure: WSLMachine.Failure

    public init(failure: WSLMachine.Failure) {
        self.failure = failure
    }
}
