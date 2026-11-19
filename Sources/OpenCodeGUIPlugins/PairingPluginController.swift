import Foundation

// MARK: - Pairing Remote Address Helper (`pairing/remote.ts`)

public enum PairingRemote {
    /// Returns the HTTPS origin (`https://host[:port]`) another device opens to reach this machine,
    /// or `nil` when no HTTPS tunnel URL is advertised.
    public static func remoteAddress(urls: [String]) -> String? {
        for raw in urls {
            guard let components = URLComponents(string: raw),
                  components.scheme?.lowercased() == "https",
                  let host = components.host, !host.isEmpty
            else { continue }
            let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            if let port = components.port, port != 443 {
                return "https://\(formattedHost.lowercased()):\(port)"
            }
            return "https://\(formattedHost.lowercased())"
        }
        return nil
    }

    /// Resolves `/auth/connect/<code>` against a tunnel origin, matching `URL.parse("/auth/connect/\(code)", tunnel)?.href`.
    public static func connectURL(tunnel: String, code: String) -> String? {
        guard let base = URL(string: tunnel),
              let scheme = base.scheme, !scheme.isEmpty,
              base.host != nil,
              let resolved = URL(string: "/auth/connect/\(code)", relativeTo: base)?.absoluteURL
        else {
            return nil
        }
        return resolved.absoluteString
    }

    /// Encodes the QR payload JSON `{"code":"...","urls":["..."]}` matching `opencode pair --remote`.
    public static func encodeQRPayload(code: String, tunnel: String) -> String {
        struct QRPayload: Encodable {
            let code: String
            let urls: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(QRPayload(code: code, urls: [tunnel])),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"code\":\"\",\"urls\":[]}"
        }
        return json
    }
}

// MARK: - Pairing Window Machine (`pairing/machine.ts`)

public enum PairingMachine: GUIStateMachine {
    public static let remoteReadTimeoutMs = 15_000
    public static let remoteReadRetries = 3
    public static let remoteChangeTimeoutMs = 180_000
    public static let tunnelRetries = 180
    public static let tunnelRetryDelayMs = 1_000
    public static let tunnelTimeoutMs = 10_000
    public static let codeTimeoutMs = 15_000
    public static let screenTimeoutMs = 15_000

    public static func remoteReadDelay(failures: Int) -> Int {
        guard failures >= 0 else { return 1_000 }
        let shift = min(failures, 15)
        return min(1_000 * (1 << shift), 30_000)
    }

    public enum MainStatus: Equatable, Hashable, Sendable {
        case active(generation: Int)
        case pending
        case inactive
    }

    public enum ReadStep: String, Equatable, Hashable, Sendable {
        case reading
        case waiting
    }

    public enum TunnelStep: String, Equatable, Hashable, Sendable {
        case polling
        case waiting
    }

    public enum WaitPhase: String, Equatable, Hashable, Sendable {
        case read
        case screen
        case tunnel
    }

    public enum DialogFailureReason: String, Equatable, Hashable, Sendable {
        case remote
        case tunnel
    }

    public enum RemoteState: Equatable, Sendable {
        case pending
        case inactive
        case loading(generation: Int, attempt: Int, step: ReadStep, failures: Int)
        case ready(generation: Int, enabled: Bool)
        case changing(generation: Int, attempt: Int, enabled: Bool, restart: Bool, previous: Bool?)
        case failed(generation: Int, previous: Bool?)
        case disposed

        public var generation: Int? {
            switch self {
            case .loading(let g, _, _, _), .ready(let g, _), .changing(let g, _, _, _, _), .failed(let g, _):
                return g
            case .pending, .inactive, .disposed:
                return nil
            }
        }
    }

    public enum ScreenState: Equatable, Sendable {
        case pending
        case inactive
        case loading(generation: Int, attempt: Int, step: ReadStep, failures: Int)
        case ready(generation: Int, enabled: Bool)
        case changing(generation: Int, attempt: Int, enabled: Bool, previous: Bool?)
        case failed(generation: Int, previous: Bool?)
        case disposed

        public var generation: Int? {
            switch self {
            case .loading(let g, _, _, _), .ready(let g, _), .changing(let g, _, _, _), .failed(let g, _):
                return g
            case .pending, .inactive, .disposed:
                return nil
            }
        }
    }

    public enum DialogState: Equatable, Sendable {
        case closed
        case unavailable
        case turningOn
        case tunnel(attempt: Int, step: TunnelStep, retries: Int)
        case code(attempt: Int, tunnel: String)
        case ready(
            tunnel: String,
            code: String,
            url: String,
            expiresIn: Int,
            loadedAt: Int,
            refreshing: Int?
        )
        case codeError(tunnel: String)
        case failed(reason: DialogFailureReason)
    }

    public struct State: Equatable, Sendable {
        public let issued: Int
        public let server: Bool
        public let remote: RemoteState
        public let screen: ScreenState
        public let dialog: DialogState

        public init(
            issued: Int = 0,
            server: Bool = false,
            remote: RemoteState = .pending,
            screen: ScreenState = .pending,
            dialog: DialogState = .closed
        ) {
            self.issued = issued
            self.server = server
            self.remote = remote
            self.screen = screen
            self.dialog = dialog
        }
    }

    public enum Event: Equatable, Sendable {
        case mainChanged(MainStatus)
        case serverChanged(available: Bool)
        case readSucceeded(attempt: Int, enabled: Bool)
        case readFailed(attempt: Int)
        case toggled(enabled: Bool)
        case changeSucceeded(attempt: Int)
        case changeFailed(attempt: Int)
        case screenReadSucceeded(attempt: Int, enabled: Bool)
        case screenReadFailed(attempt: Int)
        case screenToggled(enabled: Bool)
        case screenRetry
        case screenChangeSucceeded(attempt: Int)
        case screenChangeFailed(attempt: Int)
        case dialogOpened
        case dialogClosed
        case tunnelFound(attempt: Int, tunnel: String)
        case tunnelMissing(attempt: Int)
        case waitEnded(phase: WaitPhase, attempt: Int)
        case codeLoaded(attempt: Int, code: String, expiresIn: Int, now: Int)
        case codeFailed(attempt: Int)
        case codeRefresh
        case retry
        case tick(now: Int)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case readRemote(generation: Int, attempt: Int, timeoutMs: Int)
        case setRemote(generation: Int, attempt: Int, enabled: Bool, restart: Bool, timeoutMs: Int)
        case readScreen(generation: Int, attempt: Int, timeoutMs: Int)
        case setScreen(generation: Int, attempt: Int, enabled: Bool, timeoutMs: Int)
        case pollTunnel(attempt: Int, timeoutMs: Int)
        case wait(phase: WaitPhase, attempt: Int, delayMs: Int)
        case fetchCode(attempt: Int, timeoutMs: Int)
        case abort(attempt: Int)
        case openDialog
        case closeDialog
    }

    public struct PageView: Equatable, Sendable {
        public let mainActive: Bool
        public let pairDisabled: Bool
        public let remoteChecked: Bool
        public let remoteDisabled: Bool
        public let remoteError: Bool
        public let screenChecked: Bool
        public let screenDisabled: Bool
        public let screenError: Bool
        public let unavailable: Bool
    }

    public enum DialogView: Equatable, Sendable {
        case unavailable
        case loading(setup: Bool)
        case ready(url: String, qr: String, refreshing: Bool)
        case codeError
        case failed
    }

    public static func createState() -> State {
        State()
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state.remote {
            return GUIStateTransition(state: state)
        }

        switch event {
        case .disposed:
            let close: [Effect] = state.dialog == .closed ? [] : [.closeDialog]
            return GUIStateTransition(
                state: State(issued: state.issued, server: state.server, remote: .disposed, screen: .disposed, dialog: .closed),
                effects: abortRemote(state.remote) + abortScreen(state.screen) + abortDialog(state.dialog) + close
            )

        case .mainChanged(let main):
            switch main {
            case .pending, .inactive:
                let targetRemote: RemoteState = (main == .pending) ? .pending : .inactive
                let targetScreen: ScreenState = (main == .pending) ? .pending : .inactive
                if state.remote == targetRemote && state.screen == targetScreen {
                    return GUIStateTransition(state: state)
                }
                let nextState = State(
                    issued: state.issued,
                    server: state.server,
                    remote: targetRemote,
                    screen: targetScreen,
                    dialog: state.dialog
                )
                return settle(state: nextState, effects: abortRemote(state.remote) + abortScreen(state.screen))

            case .active(let generation):
                if state.remote.generation == generation && state.screen.generation == generation {
                    return GUIStateTransition(state: state)
                }
                let remoteAttempt = state.issued + 1
                let screenAttempt = remoteAttempt + 1
                let nextState = State(
                    issued: screenAttempt,
                    server: state.server,
                    remote: .loading(generation: generation, attempt: remoteAttempt, step: .reading, failures: 0),
                    screen: .loading(generation: generation, attempt: screenAttempt, step: .reading, failures: 0),
                    dialog: state.dialog
                )
                return settle(
                    state: nextState,
                    effects: abortRemote(state.remote)
                        + abortScreen(state.screen)
                        + [
                            .readRemote(generation: generation, attempt: remoteAttempt, timeoutMs: remoteReadTimeoutMs),
                            .readScreen(generation: generation, attempt: screenAttempt, timeoutMs: screenTimeoutMs),
                        ]
                )
            }

        case .screenReadSucceeded, .screenReadFailed, .screenToggled, .screenRetry, .screenChangeSucceeded, .screenChangeFailed:
            return reduceScreen(state: state, event: event)

        case .waitEnded(.screen, _):
            return reduceScreen(state: state, event: event)

        case .serverChanged(let available):
            if state.server == available { return GUIStateTransition(state: state) }
            let next = State(issued: state.issued, server: available, remote: state.remote, screen: state.screen, dialog: state.dialog)
            return settle(state: next, effects: [])

        case .readSucceeded(let attempt, let enabled):
            guard case .loading(let generation, let currentAttempt, .reading, _) = state.remote, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            let next = State(
                issued: state.issued,
                server: state.server,
                remote: .ready(generation: generation, enabled: enabled),
                screen: state.screen,
                dialog: state.dialog
            )
            return settle(state: next, effects: [.abort(attempt: attempt)])

        case .readFailed(let attempt):
            guard case .loading(let generation, let currentAttempt, .reading, let failures) = state.remote, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if failures >= remoteReadRetries {
                let next = State(
                    issued: state.issued,
                    server: state.server,
                    remote: .failed(generation: generation, previous: nil),
                    screen: state.screen,
                    dialog: state.dialog
                )
                return settle(state: next, effects: [.abort(attempt: attempt)])
            }
            let nextAttempt = state.issued + 1
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: .loading(generation: generation, attempt: nextAttempt, step: .waiting, failures: failures + 1),
                    screen: state.screen,
                    dialog: state.dialog
                ),
                effects: [.abort(attempt: attempt), .wait(phase: .read, attempt: nextAttempt, delayMs: remoteReadDelay(failures: failures))]
            )

        case .waitEnded(.read, let attempt):
            guard case .loading(let generation, let currentAttempt, .waiting, let failures) = state.remote, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            let nextAttempt = state.issued + 1
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: .loading(generation: generation, attempt: nextAttempt, step: .reading, failures: failures),
                    screen: state.screen,
                    dialog: state.dialog
                ),
                effects: [
                    .abort(attempt: attempt),
                    .readRemote(generation: generation, attempt: nextAttempt, timeoutMs: remoteReadTimeoutMs),
                ]
            )

        case .toggled(let enabled):
            switch state.remote {
            case .ready(_, let current) where current != enabled:
                let (nextState, effects) = startRemoteChange(state: state, effects: [], enabled: enabled, restart: false)
                return settle(state: nextState, effects: effects)
            case .failed:
                let (nextState, effects) = startRemoteChange(state: state, effects: [], enabled: enabled, restart: false)
                return settle(state: nextState, effects: effects)
            default:
                return GUIStateTransition(state: state)
            }

        case .changeSucceeded(let attempt), .changeFailed(let attempt):
            guard case .changing(let generation, let currentAttempt, let enabled, _, let previous) = state.remote, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            let nextRemote: RemoteState
            if case .changeSucceeded = event {
                nextRemote = .ready(generation: generation, enabled: enabled)
            } else {
                nextRemote = .failed(generation: generation, previous: previous)
            }
            return settle(
                state: State(issued: state.issued, server: state.server, remote: nextRemote, screen: state.screen, dialog: state.dialog),
                effects: [.abort(attempt: attempt)]
            )

        case .dialogOpened:
            guard state.dialog == .closed else { return GUIStateTransition(state: state) }
            let opened = State(issued: state.issued, server: state.server, remote: state.remote, screen: state.screen, dialog: .turningOn)
            let effects: [Effect] = [.openDialog]
            if case .failed = state.remote {
                let (nextState, nextEffects) = startRemoteChange(state: opened, effects: effects, enabled: true, restart: false)
                return settle(state: nextState, effects: nextEffects)
            }
            return settle(state: opened, effects: effects)

        case .dialogClosed:
            return toDialog(state: state, effects: [], next: .closed)

        case .retry:
            guard case .failed(let reason) = state.dialog else { return GUIStateTransition(state: state) }
            let retrying = State(issued: state.issued, server: state.server, remote: state.remote, screen: state.screen, dialog: .turningOn)
            switch state.remote {
            case .ready, .failed:
                let (nextState, effects) = startRemoteChange(state: retrying, effects: [], enabled: true, restart: reason == .tunnel)
                return settle(state: nextState, effects: effects)
            default:
                return settle(state: retrying, effects: [])
            }

        case .tunnelFound, .tunnelMissing, .waitEnded(.tunnel, _), .codeLoaded, .codeFailed, .codeRefresh, .tick:
            return reduceCode(state: state, event: event)
        }
    }

    public static func effectFailed(_ effect: Effect) -> Event? {
        switch effect {
        case .readRemote(_, let attempt, _): return .readFailed(attempt: attempt)
        case .setRemote(_, let attempt, _, _, _): return .changeFailed(attempt: attempt)
        case .readScreen(_, let attempt, _): return .screenReadFailed(attempt: attempt)
        case .setScreen(_, let attempt, _, _): return .screenChangeFailed(attempt: attempt)
        case .pollTunnel(let attempt, _): return .tunnelMissing(attempt: attempt)
        case .wait(let phase, let attempt, _): return .waitEnded(phase: phase, attempt: attempt)
        case .fetchCode(let attempt, _): return .codeFailed(attempt: attempt)
        case .openDialog: return .dialogClosed
        case .abort, .closeDialog: return nil
        }
    }

    public static func viewPage(_ state: State) -> PageView {
        let mainActive: Bool
        switch state.remote {
        case .pending, .inactive, .disposed: mainActive = false
        default: mainActive = true
        }

        let disablingRemote: Bool
        if case .changing(_, _, false, _, _) = state.remote { disablingRemote = true } else { disablingRemote = false }

        let remoteChecked: Bool
        let remoteDisabled: Bool
        let remoteError: Bool
        switch state.remote {
        case .ready(_, let enabled):
            remoteChecked = enabled
            remoteDisabled = false
            remoteError = false
        case .changing(_, _, let enabled, _, _):
            remoteChecked = enabled
            remoteDisabled = true
            remoteError = false
        case .failed(_, let previous):
            remoteChecked = previous == true
            remoteDisabled = false
            remoteError = true
        default:
            remoteChecked = false
            remoteDisabled = true
            remoteError = false
        }

        let screenChecked: Bool
        let screenDisabled: Bool
        let screenError: Bool
        switch state.screen {
        case .ready(_, let enabled):
            screenChecked = enabled
            screenDisabled = false
            screenError = false
        case .changing(_, _, let enabled, _):
            screenChecked = enabled
            screenDisabled = true
            screenError = false
        case .failed(_, let previous):
            screenChecked = previous == true
            screenDisabled = false
            screenError = true
        default:
            screenChecked = false
            screenDisabled = true
            screenError = false
        }

        let unavailable = state.remote == .inactive || !state.server

        return PageView(
            mainActive: mainActive,
            pairDisabled: !mainActive || !state.server || disablingRemote,
            remoteChecked: remoteChecked,
            remoteDisabled: remoteDisabled,
            remoteError: remoteError,
            screenChecked: screenChecked,
            screenDisabled: screenDisabled,
            screenError: screenError,
            unavailable: unavailable
        )
    }

    public static func viewDialog(_ dialog: DialogState) -> DialogView {
        switch dialog {
        case .turningOn, .tunnel:
            return .loading(setup: true)
        case .code:
            return .loading(setup: false)
        case .ready(let tunnel, let code, let url, _, _, let refreshing):
            return .ready(
                url: url,
                qr: PairingRemote.encodeQRPayload(code: code, tunnel: tunnel),
                refreshing: refreshing != nil
            )
        case .codeError:
            return .codeError
        case .failed:
            return .failed
        case .closed, .unavailable:
            return .unavailable
        }
    }

    public static func dialogUrl(_ dialog: DialogState) -> String? {
        if case .ready(_, _, let url, _, _, _) = dialog { return url }
        return nil
    }

    public static func remainingSeconds(_ dialog: DialogState, now: Int) -> Int {
        guard case .ready(_, _, _, let expiresIn, let loadedAt, _) = dialog else { return 0 }
        let ageSeconds = max(0, now - loadedAt) / 1000
        return max(0, expiresIn - ageSeconds)
    }

    // MARK: Screen & Code Reducers

    private static func reduceScreen(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        let nextAttempt = state.issued + 1
        switch event {
        case .screenRetry:
            guard case .failed(let generation, _) = state.screen else { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: state.remote,
                    screen: .loading(generation: generation, attempt: nextAttempt, step: .reading, failures: 0),
                    dialog: state.dialog
                ),
                effects: [.readScreen(generation: generation, attempt: nextAttempt, timeoutMs: screenTimeoutMs)]
            )

        case .screenReadSucceeded(let attempt, let enabled):
            guard case .loading(let generation, let currentAttempt, .reading, _) = state.screen, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    issued: state.issued,
                    server: state.server,
                    remote: state.remote,
                    screen: .ready(generation: generation, enabled: enabled),
                    dialog: state.dialog
                ),
                effects: [.abort(attempt: attempt)]
            )

        case .screenReadFailed(let attempt):
            guard case .loading(let generation, let currentAttempt, .reading, let failures) = state.screen, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if failures >= remoteReadRetries {
                return GUIStateTransition(
                    state: State(
                        issued: state.issued,
                        server: state.server,
                        remote: state.remote,
                        screen: .failed(generation: generation, previous: nil),
                        dialog: state.dialog
                    ),
                    effects: [.abort(attempt: attempt)]
                )
            }
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: state.remote,
                    screen: .loading(generation: generation, attempt: nextAttempt, step: .waiting, failures: failures + 1),
                    dialog: state.dialog
                ),
                effects: [.abort(attempt: attempt), .wait(phase: .screen, attempt: nextAttempt, delayMs: remoteReadDelay(failures: failures))]
            )

        case .waitEnded(.screen, let attempt):
            guard case .loading(let generation, let currentAttempt, .waiting, let failures) = state.screen, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: state.remote,
                    screen: .loading(generation: generation, attempt: nextAttempt, step: .reading, failures: failures),
                    dialog: state.dialog
                ),
                effects: [
                    .abort(attempt: attempt),
                    .readScreen(generation: generation, attempt: nextAttempt, timeoutMs: screenTimeoutMs),
                ]
            )

        case .screenToggled(let enabled):
            let generation: Int
            let previous: Bool?
            switch state.screen {
            case .ready(let g, let current):
                if current == enabled { return GUIStateTransition(state: state) }
                generation = g
                previous = current
            case .failed(let g, let prev):
                generation = g
                previous = prev
            default:
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: state.remote,
                    screen: .changing(generation: generation, attempt: nextAttempt, enabled: enabled, previous: previous),
                    dialog: state.dialog
                ),
                effects: [.setScreen(generation: generation, attempt: nextAttempt, enabled: enabled, timeoutMs: screenTimeoutMs)]
            )

        case .screenChangeSucceeded(let attempt), .screenChangeFailed(let attempt):
            guard case .changing(let generation, let currentAttempt, let enabled, let previous) = state.screen, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            let nextScreen: ScreenState
            if case .screenChangeSucceeded = event {
                nextScreen = .ready(generation: generation, enabled: enabled)
            } else {
                nextScreen = .failed(generation: generation, previous: previous)
            }
            return GUIStateTransition(
                state: State(issued: state.issued, server: state.server, remote: state.remote, screen: nextScreen, dialog: state.dialog),
                effects: [.abort(attempt: attempt)]
            )

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func reduceCode(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        let nextAttempt = state.issued + 1
        switch event {
        case .tunnelFound(let attempt, let tunnel):
            guard case .tunnel(let currentAttempt, .polling, _) = state.dialog, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: state.remote,
                    screen: state.screen,
                    dialog: .code(attempt: nextAttempt, tunnel: tunnel)
                ),
                effects: [.abort(attempt: attempt), .fetchCode(attempt: nextAttempt, timeoutMs: codeTimeoutMs)]
            )

        case .tunnelMissing(let attempt):
            guard case .tunnel(let currentAttempt, .polling, let retries) = state.dialog, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            if retries >= tunnelRetries {
                return GUIStateTransition(
                    state: State(
                        issued: state.issued,
                        server: state.server,
                        remote: state.remote,
                        screen: state.screen,
                        dialog: .failed(reason: .tunnel)
                    ),
                    effects: abortDialog(state.dialog)
                )
            }
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: state.remote,
                    screen: state.screen,
                    dialog: .tunnel(attempt: nextAttempt, step: .waiting, retries: retries + 1)
                ),
                effects: [.abort(attempt: attempt), .wait(phase: .tunnel, attempt: nextAttempt, delayMs: tunnelRetryDelayMs)]
            )

        case .waitEnded(.tunnel, let attempt):
            guard case .tunnel(let currentAttempt, .waiting, let retries) = state.dialog, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: state.remote,
                    screen: state.screen,
                    dialog: .tunnel(attempt: nextAttempt, step: .polling, retries: retries)
                ),
                effects: [.abort(attempt: attempt), .pollTunnel(attempt: nextAttempt, timeoutMs: tunnelTimeoutMs)]
            )

        case .codeLoaded(let attempt, let code, let expiresIn, let now):
            guard let tunnel = matchingCodeTunnel(state.dialog, attempt: attempt) else {
                return GUIStateTransition(state: state)
            }
            let nextDialog: DialogState
            if let url = PairingRemote.connectURL(tunnel: tunnel, code: code) {
                nextDialog = .ready(
                    tunnel: tunnel,
                    code: code,
                    url: url,
                    expiresIn: expiresIn,
                    loadedAt: now,
                    refreshing: nil
                )
            } else {
                nextDialog = .codeError(tunnel: tunnel)
            }
            return GUIStateTransition(
                state: State(issued: state.issued, server: state.server, remote: state.remote, screen: state.screen, dialog: nextDialog),
                effects: [.abort(attempt: attempt)]
            )

        case .codeFailed(let attempt):
            guard let tunnel = matchingCodeTunnel(state.dialog, attempt: attempt) else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    issued: state.issued,
                    server: state.server,
                    remote: state.remote,
                    screen: state.screen,
                    dialog: .codeError(tunnel: tunnel)
                ),
                effects: [.abort(attempt: attempt)]
            )

        case .codeRefresh:
            switch state.dialog {
            case .codeError(let tunnel):
                return GUIStateTransition(
                    state: State(
                        issued: nextAttempt,
                        server: state.server,
                        remote: state.remote,
                        screen: state.screen,
                        dialog: .code(attempt: nextAttempt, tunnel: tunnel)
                    ),
                    effects: [.fetchCode(attempt: nextAttempt, timeoutMs: codeTimeoutMs)]
                )
            case .ready(let tunnel, let code, let url, let expiresIn, let loadedAt, nil):
                return GUIStateTransition(
                    state: State(
                        issued: nextAttempt,
                        server: state.server,
                        remote: state.remote,
                        screen: state.screen,
                        dialog: .ready(
                            tunnel: tunnel,
                            code: code,
                            url: url,
                            expiresIn: expiresIn,
                            loadedAt: loadedAt,
                            refreshing: nextAttempt
                        )
                    ),
                    effects: [.fetchCode(attempt: nextAttempt, timeoutMs: codeTimeoutMs)]
                )
            default:
                return GUIStateTransition(state: state)
            }

        case .tick(let now):
            guard case .ready(let tunnel, let code, let url, let expiresIn, let loadedAt, nil) = state.dialog,
                  remainingSeconds(state.dialog, now: now) <= 0
            else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    issued: nextAttempt,
                    server: state.server,
                    remote: state.remote,
                    screen: state.screen,
                    dialog: .ready(
                        tunnel: tunnel,
                        code: code,
                        url: url,
                        expiresIn: expiresIn,
                        loadedAt: loadedAt,
                        refreshing: nextAttempt
                    )
                ),
                effects: [.fetchCode(attempt: nextAttempt, timeoutMs: codeTimeoutMs)]
            )

        default:
            return GUIStateTransition(state: state)
        }
    }

    private static func matchingCodeTunnel(_ dialog: DialogState, attempt: Int) -> String? {
        switch dialog {
        case .code(let currentAttempt, let tunnel) where currentAttempt == attempt:
            return tunnel
        case .ready(let tunnel, _, _, _, _, let refreshing) where refreshing == attempt:
            return tunnel
        default:
            return nil
        }
    }

    private static func startRemoteChange(
        state: State,
        effects: [Effect],
        enabled: Bool,
        restart: Bool
    ) -> (State, [Effect]) {
        let generation: Int
        let previous: Bool?
        switch state.remote {
        case .ready(let g, let current):
            generation = g
            previous = current
        case .failed(let g, let prev):
            generation = g
            previous = prev
        default:
            return (state, effects)
        }
        let attempt = state.issued + 1
        let nextState = State(
            issued: attempt,
            server: state.server,
            remote: .changing(generation: generation, attempt: attempt, enabled: enabled, restart: restart, previous: previous),
            screen: state.screen,
            dialog: state.dialog
        )
        let nextEffects = effects + [
            .setRemote(generation: generation, attempt: attempt, enabled: enabled, restart: restart, timeoutMs: remoteChangeTimeoutMs),
        ]
        return (nextState, nextEffects)
    }

    private static func settle(state: State, effects: [Effect]) -> GUIStateTransition<State, Effect> {
        if state.dialog == .closed {
            return GUIStateTransition(state: state, effects: effects)
        }
        if !state.server {
            return toDialog(state: state, effects: effects, next: .unavailable)
        }

        switch state.dialog {
        case .tunnel, .code, .ready, .codeError:
            if case .failed = state.remote {
                return toDialog(state: state, effects: effects, next: .failed(reason: .remote))
            }
            let isChangingOrOff: Bool
            switch state.remote {
            case .changing: isChangingOrOff = true
            case .ready(_, false): isChangingOrOff = true
            default: isChangingOrOff = false
            }
            if !isChangingOrOff {
                return GUIStateTransition(state: state, effects: effects)
            }
            return setUpDialog(state: state, effects: effects)

        case .failed(let reason):
            switch state.remote {
            case .inactive:
                return toDialog(state: state, effects: effects, next: .unavailable)
            case .changing:
                return toDialog(state: state, effects: effects, next: .turningOn)
            case .failed:
                return toDialog(state: state, effects: effects, next: .failed(reason: .remote))
            case .ready(_, true) where reason == .remote:
                return startTunnel(state: state, effects: effects)
            default:
                return GUIStateTransition(state: state, effects: effects)
            }

        case .unavailable, .turningOn:
            return setUpDialog(state: state, effects: effects)

        case .closed:
            return GUIStateTransition(state: state, effects: effects)
        }
    }

    private static func setUpDialog(state: State, effects: [Effect]) -> GUIStateTransition<State, Effect> {
        switch state.remote {
        case .inactive:
            return toDialog(state: state, effects: effects, next: .unavailable)
        case .failed:
            return toDialog(state: state, effects: effects, next: .failed(reason: .remote))
        case .ready(_, true):
            return startTunnel(state: state, effects: effects)
        case .ready(_, false):
            let (changedState, changedEffects) = startRemoteChange(state: state, effects: effects, enabled: true, restart: false)
            return toDialog(state: changedState, effects: changedEffects, next: .turningOn)
        case .pending, .loading, .changing, .disposed:
            return toDialog(state: state, effects: effects, next: .turningOn)
        }
    }

    private static func startTunnel(state: State, effects: [Effect]) -> GUIStateTransition<State, Effect> {
        let attempt = state.issued + 1
        return GUIStateTransition(
            state: State(
                issued: attempt,
                server: state.server,
                remote: state.remote,
                screen: state.screen,
                dialog: .tunnel(attempt: attempt, step: .polling, retries: 0)
            ),
            effects: effects + abortDialog(state.dialog) + [.pollTunnel(attempt: attempt, timeoutMs: tunnelTimeoutMs)]
        )
    }

    private static func toDialog(state: State, effects: [Effect], next: DialogState) -> GUIStateTransition<State, Effect> {
        if state.dialog == next {
            return GUIStateTransition(state: state, effects: effects)
        }
        return GUIStateTransition(
            state: State(issued: state.issued, server: state.server, remote: state.remote, screen: state.screen, dialog: next),
            effects: effects + abortDialog(state.dialog)
        )
    }

    private static func abortRemote(_ remote: RemoteState) -> [Effect] {
        switch remote {
        case .loading(_, let attempt, _, _), .changing(_, let attempt, _, _, _):
            return [.abort(attempt: attempt)]
        default:
            return []
        }
    }

    private static func abortScreen(_ screen: ScreenState) -> [Effect] {
        switch screen {
        case .loading(_, let attempt, _, _), .changing(_, let attempt, _, _):
            return [.abort(attempt: attempt)]
        default:
            return []
        }
    }

    private static func abortDialog(_ dialog: DialogState) -> [Effect] {
        switch dialog {
        case .tunnel(let attempt, _, _), .code(let attempt, _):
            return [.abort(attempt: attempt)]
        case .ready(_, _, _, _, _, let refreshing?):
            return [.abort(attempt: refreshing)]
        default:
            return []
        }
    }
}

// MARK: - Pairing Main Process Machine (`pairing/main-machine.ts`)

public enum PairingMainMachine: GUIStateMachine {
    public static let serviceReadTimeoutMs = 20_000
    public static let serviceSetTimeoutMs = 180_000
    public static let serviceStartTimeoutMs = 60_000

    public enum BlockerState: Equatable, Sendable {
        case released
        case held(id: Int)
    }

    public enum ServiceRequest: Equatable, Hashable, Sendable {
        case getRemote
        case setRemote(enabled: Bool)
    }

    public enum SetRemoteStep: String, Equatable, Hashable, Sendable {
        case setting
        case starting
    }

    public enum ActiveJobKind: Equatable, Sendable {
        case getRemote
        case setRemote(enabled: Bool, step: SetRemoteStep)
    }

    public struct ActiveServiceJob: Equatable, Sendable {
        public let attempt: Int
        public let waiter: Int
        public let job: ActiveJobKind

        public init(attempt: Int, waiter: Int, job: ActiveJobKind) {
            self.attempt = attempt
            self.waiter = waiter
            self.job = job
        }
    }

    public struct PendingServiceJob: Equatable, Sendable {
        public let waiter: Int
        public let request: ServiceRequest

        public init(waiter: Int, request: ServiceRequest) {
            self.waiter = waiter
            self.request = request
        }
    }

    public enum State: Equatable, Sendable {
        case open(issued: Int, blocker: BlockerState, active: ActiveServiceJob?, pending: [PendingServiceJob])
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case screenSet(enabled: Bool, started: Bool)
        case blockerStarted(id: Int)
        case serviceRequested(waiter: Int, request: ServiceRequest)
        case waiterCancelled(waiter: Int)
        case serviceSucceeded(attempt: Int, stdout: String)
        case serviceFailed(attempt: Int, message: String)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case blockerStart
        case blockerStop(id: Int)
        case persistScreen(enabled: Bool)
        case serviceExec(attempt: Int, args: [String], timeoutMs: Int)
        case serviceAbort(attempt: Int)
        case waiterResolve(waiter: Int, value: Bool?)
        case waiterReject(waiter: Int, message: String)
    }

    private static let stoppedMessage = "Pairing stopped"

    public static func createState() -> State {
        .open(issued: 0, blocker: .released, active: nil, pending: [])
    }

    public static func selectBlocker(_ state: State) -> Int? {
        if case .open(_, .held(let id), _, _) = state { return id }
        return nil
    }

    public static func effectFailed(_ effect: Effect) -> Event? {
        if case .serviceExec(let attempt, _, _) = effect {
            return .serviceFailed(attempt: attempt, message: "Pairing service command failed")
        }
        return nil
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        switch state {
        case .disposed:
            switch event {
            case .serviceRequested(let waiter, _):
                return GUIStateTransition(state: state, effects: [.waiterReject(waiter: waiter, message: stoppedMessage)])
            case .blockerStarted(let id):
                return GUIStateTransition(state: state, effects: [.blockerStop(id: id)])
            default:
                return GUIStateTransition(state: state)
            }

        case .open(let issued, let blocker, let active, let pending):
            switch event {
            case .disposed:
                var effects: [Effect] = []
                if case .held(let id) = blocker {
                    effects.append(.blockerStop(id: id))
                }
                if let active {
                    effects.append(.serviceAbort(attempt: active.attempt))
                    effects.append(.waiterReject(waiter: active.waiter, message: stoppedMessage))
                }
                for item in pending {
                    effects.append(.waiterReject(waiter: item.waiter, message: stoppedMessage))
                }
                return GUIStateTransition(state: .disposed, effects: effects)

            case .screenSet(let enabled, let started):
                if enabled, case .held = blocker, started {
                    return GUIStateTransition(state: state, effects: [.persistScreen(enabled: true)])
                }
                var effects: [Effect] = []
                if enabled {
                    effects.append(.blockerStart)
                } else if case .held(let id) = blocker {
                    effects.append(.blockerStop(id: id))
                }
                effects.append(.persistScreen(enabled: enabled))
                return GUIStateTransition(
                    state: .open(issued: issued, blocker: .released, active: active, pending: pending),
                    effects: effects
                )

            case .blockerStarted(let id):
                return GUIStateTransition(
                    state: .open(issued: issued, blocker: .held(id: id), active: active, pending: pending)
                )

            case .serviceRequested(let waiter, let request):
                return advance(
                    issued: issued,
                    blocker: blocker,
                    active: active,
                    pending: pending + [PendingServiceJob(waiter: waiter, request: request)],
                    effects: []
                )

            case .waiterCancelled(let waiter):
                if pending.contains(where: { $0.waiter == waiter }) {
                    return GUIStateTransition(
                        state: .open(
                            issued: issued,
                            blocker: blocker,
                            active: active,
                            pending: pending.filter { $0.waiter != waiter }
                        ),
                        effects: [.waiterReject(waiter: waiter, message: "Aborted")]
                    )
                }
                guard let active, active.waiter == waiter, case .getRemote = active.job else {
                    return GUIStateTransition(state: state)
                }
                return advance(
                    issued: issued,
                    blocker: blocker,
                    active: nil,
                    pending: pending,
                    effects: [
                        .serviceAbort(attempt: active.attempt),
                        .waiterReject(waiter: waiter, message: "Aborted"),
                    ]
                )

            case .serviceFailed(let attempt, let message):
                guard let active, active.attempt == attempt else { return GUIStateTransition(state: state) }
                return advance(
                    issued: issued,
                    blocker: blocker,
                    active: nil,
                    pending: pending,
                    effects: [.waiterReject(waiter: active.waiter, message: message)]
                )

            case .serviceSucceeded(let attempt, let stdout):
                guard let active, active.attempt == attempt else { return GUIStateTransition(state: state) }
                switch active.job {
                case .getRemote:
                    return advance(
                        issued: issued,
                        blocker: blocker,
                        active: nil,
                        pending: pending,
                        effects: [.waiterResolve(waiter: active.waiter, value: stdout == "true")]
                    )
                case .setRemote(_, .starting):
                    return advance(
                        issued: issued,
                        blocker: blocker,
                        active: nil,
                        pending: pending,
                        effects: [.waiterResolve(waiter: active.waiter, value: nil)]
                    )
                case .setRemote(let enabled, .setting):
                    let nextAttempt = issued + 1
                    let nextActive = ActiveServiceJob(
                        attempt: nextAttempt,
                        waiter: active.waiter,
                        job: .setRemote(enabled: enabled, step: .starting)
                    )
                    return GUIStateTransition(
                        state: .open(issued: nextAttempt, blocker: blocker, active: nextActive, pending: pending),
                        effects: [.serviceExec(attempt: nextAttempt, args: ["start"], timeoutMs: serviceStartTimeoutMs)]
                    )
                }
            }
        }
    }

    private static func advance(
        issued: Int,
        blocker: BlockerState,
        active: ActiveServiceJob?,
        pending: [PendingServiceJob],
        effects: [Effect]
    ) -> GUIStateTransition<State, Effect> {
        guard active == nil, let head = pending.first else {
            return GUIStateTransition(
                state: .open(issued: issued, blocker: blocker, active: active, pending: pending),
                effects: effects
            )
        }
        let nextAttempt = issued + 1
        let rest = Array(pending.dropFirst())
        switch head.request {
        case .getRemote:
            let job = ActiveServiceJob(attempt: nextAttempt, waiter: head.waiter, job: .getRemote)
            return GUIStateTransition(
                state: .open(issued: nextAttempt, blocker: blocker, active: job, pending: rest),
                effects: effects + [.serviceExec(attempt: nextAttempt, args: ["get", "remote"], timeoutMs: serviceReadTimeoutMs)]
            )
        case .setRemote(let enabled):
            let job = ActiveServiceJob(
                attempt: nextAttempt,
                waiter: head.waiter,
                job: .setRemote(enabled: enabled, step: .setting)
            )
            return GUIStateTransition(
                state: .open(issued: nextAttempt, blocker: blocker, active: job, pending: rest),
                effects: effects + [
                    .serviceExec(
                        attempt: nextAttempt,
                        args: ["set", "remote", enabled ? "true" : "false"],
                        timeoutMs: serviceSetTimeoutMs
                    ),
                ]
            )
        }
    }
}

// MARK: - Pairing Copy Feedback Machine (`pairing/copy-machine.ts`)

public enum PairingCopyMachine: GUIStateMachine {
    public static let feedbackMs = 2_000
    public static let timeoutMs = 5_000

    public enum State: Equatable, Sendable {
        case idle(attempt: Int)
        case copying(attempt: Int, url: String)
        case copied(attempt: Int, url: String)
        case failed(attempt: Int, url: String)
        case disposed
    }

    public enum Event: Equatable, Sendable {
        case copyRequested(url: String)
        case copySucceeded(attempt: Int)
        case copyFailed(attempt: Int)
        case feedbackEnded(attempt: Int)
        case reset
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case write(attempt: Int, url: String, timeoutMs: Int)
        case scheduleFeedback(attempt: Int, delayMs: Int)
        case cancelTimer
    }

    public enum Icon: String, Equatable, Hashable, Sendable {
        case check
        case copy
    }

    public enum Label: String, Equatable, Hashable, Sendable {
        case copied = "common.copied"
        case copyLink
    }

    public struct CopyView: Equatable, Sendable {
        public let icon: Icon
        public let label: Label
        public let disabled: Bool
        public let error: Bool

        public init(icon: Icon, label: Label, disabled: Bool, error: Bool) {
            self.icon = icon
            self.label = label
            self.disabled = disabled
            self.error = error
        }
    }

    public static func createState() -> State {
        .idle(attempt: 0)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if case .disposed = state { return GUIStateTransition(state: state) }

        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed, effects: [.cancelTimer])

        case .copyRequested(let url):
            if case .copying(_, let currentURL) = state, currentURL == url {
                return GUIStateTransition(state: state)
            }
            let nextAttempt = attemptOf(state) + 1
            return GUIStateTransition(
                state: .copying(attempt: nextAttempt, url: url),
                effects: [.cancelTimer, .write(attempt: nextAttempt, url: url, timeoutMs: timeoutMs)]
            )

        case .copySucceeded(let attempt):
            guard case .copying(let currentAttempt, let url) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .copied(attempt: currentAttempt, url: url),
                effects: [.cancelTimer, .scheduleFeedback(attempt: currentAttempt, delayMs: feedbackMs)]
            )

        case .copyFailed(let attempt):
            guard case .copying(let currentAttempt, let url) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .failed(attempt: currentAttempt, url: url), effects: [.cancelTimer])

        case .feedbackEnded(let attempt):
            guard case .copied(let currentAttempt, _) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(state: .idle(attempt: currentAttempt))

        case .reset:
            if case .idle = state { return GUIStateTransition(state: state) }
            return GUIStateTransition(state: .idle(attempt: attemptOf(state)), effects: [.cancelTimer])
        }
    }

    public static func effectFailed(_ effect: Effect) -> Event? {
        if case .write(let attempt, _, _) = effect {
            return .copyFailed(attempt: attempt)
        }
        return nil
    }

    public static func view(_ state: State, url: String?) -> CopyView {
        switch state {
        case .copied(_, let copiedURL) where copiedURL == url:
            return CopyView(icon: .check, label: .copied, disabled: false, error: false)
        case .copying(_, let copyingURL) where copyingURL == url:
            return CopyView(icon: .copy, label: .copyLink, disabled: true, error: false)
        case .failed(_, let failedURL) where failedURL == url:
            return CopyView(icon: .copy, label: .copyLink, disabled: false, error: true)
        default:
            return CopyView(icon: .copy, label: .copyLink, disabled: false, error: false)
        }
    }

    private static func attemptOf(_ state: State) -> Int {
        switch state {
        case .idle(let a), .copying(let a, _), .copied(let a, _), .failed(let a, _): return a
        case .disposed: return 0
        }
    }
}

// MARK: - Pairing Controller Actor

public protocol PairingMainDriver: Sendable {
    func startBlocker() async -> Int
    func stopBlocker(id: Int) async
    func isBlockerStarted(id: Int) async -> Bool
    func persistScreenActive(_ enabled: Bool) async
    func execService(attempt: Int, args: [String], timeoutMs: Int) async -> Result<String, PairingServiceError>
    func abortService(attempt: Int) async
}

public struct PairingServiceError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Actor owning `PairingMainMachine` and coordinating serialized service commands and display sleep blocking.
public actor PairingController {
    private var mainState: PairingMainMachine.State = PairingMainMachine.createState()
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Bool?, any Error>] = [:]
    private let driver: any PairingMainDriver

    public init(driver: any PairingMainDriver) {
        self.driver = driver
    }

    public func remoteEnabled() async throws -> Bool {
        let value = try await enqueue(.getRemote)
        return value ?? false
    }

    public func setRemoteEnabled(_ enabled: Bool) async throws {
        _ = try await enqueue(.setRemote(enabled: enabled))
    }

    public func setScreenActive(_ enabled: Bool) async {
        let started: Bool
        if let id = PairingMainMachine.selectBlocker(mainState) {
            started = await driver.isBlockerStarted(id: id)
        } else {
            started = false
        }
        await dispatch(.screenSet(enabled: enabled, started: started))
    }

    public func blockerID() -> Int? {
        PairingMainMachine.selectBlocker(mainState)
    }

    public func dispose() async {
        await dispatch(.disposed)
    }

    private func enqueue(_ request: PairingMainMachine.ServiceRequest) async throws -> Bool? {
        nextWaiterID += 1
        let waiterID = nextWaiterID
        return try await withCheckedThrowingContinuation { continuation in
            waiters[waiterID] = continuation
            Task {
                await self.dispatch(.serviceRequested(waiter: waiterID, request: request))
            }
        }
    }

    private func dispatch(_ event: PairingMainMachine.Event) async {
        let transition = PairingMainMachine.reduce(state: mainState, event: event)
        mainState = transition.state
        for effect in transition.effects {
            await perform(effect)
        }
    }

    private func perform(_ effect: PairingMainMachine.Effect) async {
        switch effect {
        case .blockerStart:
            let id = await driver.startBlocker()
            await dispatch(.blockerStarted(id: id))
        case .blockerStop(let id):
            await driver.stopBlocker(id: id)
        case .persistScreen(let enabled):
            await driver.persistScreenActive(enabled)
        case .serviceExec(let attempt, let args, let timeoutMs):
            let result = await driver.execService(attempt: attempt, args: args, timeoutMs: timeoutMs)
            switch result {
            case .success(let stdout):
                await dispatch(.serviceSucceeded(attempt: attempt, stdout: stdout))
            case .failure(let error):
                await dispatch(.serviceFailed(attempt: attempt, message: error.message))
            }
        case .serviceAbort(let attempt):
            await driver.abortService(attempt: attempt)
        case .waiterResolve(let waiter, let value):
            if let continuation = waiters.removeValue(forKey: waiter) {
                continuation.resume(returning: value)
            }
        case .waiterReject(let waiter, let message):
            if let continuation = waiters.removeValue(forKey: waiter) {
                continuation.resume(throwing: PairingServiceError(message: message))
            }
        }
    }
}
