/// Operating systems supported by OpenCode GUI plugins (matching `@opencode/plugin/gui` `runsOn`).
public enum GUIPluginOS: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case macos
    case windows
    case linux

    /// The host operating system this binary was compiled for.
    public static var current: GUIPluginOS {
        #if os(Windows)
        return .windows
        #elseif os(Linux)
        return .linux
        #else
        return .macos
        #endif
    }
}

/// Server connection states exposed to native GUI surfaces (matching `@opencode/plugin/gui` `ServerState`).
public enum GUIServerState: String, Equatable, Hashable, Sendable, Codable {
    case starting
    case auth
    case ready
    case failed
    case incompatible
    case stopped
}

/// Canonical built-in GUI plugin identifiers matching `packages/gui-plugins/src/main.ts` and `renderer.ts`.
public enum GUIPluginID: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case context
    case btw
    case debug
    case terminal
    case file
    case review
    case details
    case browser
    case pairing
    case updater
    case ssh
    case wsl
    case microsoftOffice = "microsoft-office"
    case sources
    case goal
}

/// Metadata descriptor for a GUI plugin, capturing platform eligibility, entry points, and persisted store keys.
public struct GUIPluginDescriptor: Equatable, Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let summary: String
    /// Operating systems where this plugin runs; `nil` means all operating systems.
    public let supportedOS: Set<GUIPluginOS>?
    public let hasMainEntry: Bool
    public let hasWindowEntry: Bool
    public let storeKeys: [String]
    public let ipcIDs: [String]
    public let contractIDs: [String]

    public init(
        id: String,
        displayName: String,
        summary: String,
        supportedOS: Set<GUIPluginOS>? = nil,
        hasMainEntry: Bool = false,
        hasWindowEntry: Bool = true,
        storeKeys: [String] = [],
        ipcIDs: [String] = [],
        contractIDs: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.supportedOS = supportedOS
        self.hasMainEntry = hasMainEntry
        self.hasWindowEntry = hasWindowEntry
        self.storeKeys = storeKeys
        self.ipcIDs = ipcIDs
        self.contractIDs = contractIDs
    }

    /// Returns `true` when the plugin is eligible to run on `os` (matching upstream `runsOn`).
    public func runsOn(_ os: GUIPluginOS) -> Bool {
        guard let supportedOS else { return true }
        return supportedOS.contains(os)
    }
}

/// Registry of built-in and custom GUI plugins, mirroring `builtins` in `packages/gui-plugins/src/main.ts` and `renderer.ts`.
public struct GUIPluginRegistry: Equatable, Sendable {
    public private(set) var plugins: [GUIPluginDescriptor]
    private var indexByID: [String: Int]

    /// All 15 built-in GUI plugins shipped in upstream `packages/gui-plugins`.
    public static let builtInDescriptors: [GUIPluginDescriptor] = [
        GUIPluginDescriptor(
            id: GUIPluginID.context.rawValue,
            displayName: "Context",
            summary: "Session token usage, model catalog loader, scroll persistence, and JSON session export.",
            hasMainEntry: false,
            hasWindowEntry: true
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.btw.rawValue,
            displayName: "BTW",
            summary: "Side-channel quick question tabs scoped per session.",
            hasMainEntry: false,
            hasWindowEntry: true,
            storeKeys: ["chats"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.debug.rawValue,
            displayName: "Debug",
            summary: "Debug bar, force-focus toggle, heap snapshot queue, memory diagnostics, and Motion inspector.",
            hasMainEntry: true,
            hasWindowEntry: true,
            storeKeys: ["bar"],
            ipcIDs: ["debug.heap", "debug.memory"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.terminal.rawValue,
            displayName: "Terminal",
            summary: "Multi-terminal tab management, persistent PTY connection/replay protocol, focus, rename, and quoting.",
            hasMainEntry: false,
            hasWindowEntry: true
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.file.rawValue,
            displayName: "File",
            summary: "Workspace file tree, search, picker, link resolution, artifact viewer, and external app launcher.",
            hasMainEntry: false,
            hasWindowEntry: true,
            storeKeys: ["app"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.review.rawValue,
            displayName: "Review",
            summary: "Code review diff loader, untracked folder expansion, bounded detail patches, git init, and line comments.",
            hasMainEntry: false,
            hasWindowEntry: true,
            storeKeys: ["diff", "panel", "mobileDiff", "session"],
            contractIDs: ["review.details"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.details.rawValue,
            displayName: "Details",
            summary: "Session details drawer, workspace move, service loading, and MCP status controls.",
            hasMainEntry: false,
            hasWindowEntry: true
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.browser.rawValue,
            displayName: "Browser",
            summary: "Embedded browser pane, address history, diagnostics, and viewport controls.",
            hasMainEntry: true,
            hasWindowEntry: true,
            storeKeys: ["history"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.pairing.rawValue,
            displayName: "Pairing",
            summary: "Remote access enablement, display sleep blocker, pairing QR/code lifecycle, and copy feedback.",
            hasMainEntry: true,
            hasWindowEntry: true,
            ipcIDs: ["pairing"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.updater.rawValue,
            displayName: "Updater",
            summary: "Desktop and web update checks, staged/external installation, action resolution, and What's New dialog.",
            hasMainEntry: true,
            hasWindowEntry: true,
            storeKeys: ["releaseNotes", "seen"],
            ipcIDs: ["updater"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.ssh.rawValue,
            displayName: "SSH",
            summary: "SSH target parsing, askpass challenge-response protocol, remote CLI bootstrapping, and tunnel lifecycle.",
            hasMainEntry: true,
            hasWindowEntry: true,
            ipcIDs: ["ssh"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.wsl.rawValue,
            displayName: "WSL",
            summary: "Windows Subsystem for Linux runtime detection, distro installation/probing, and sidecar server lifecycle.",
            supportedOS: [.windows],
            hasMainEntry: true,
            hasWindowEntry: true,
            ipcIDs: ["wsl"]
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.microsoftOffice.rawValue,
            displayName: "Microsoft Office",
            summary: "Read-only previews of Word, Excel, and PowerPoint documents.",
            hasMainEntry: false,
            hasWindowEntry: true
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.sources.rawValue,
            displayName: "Sources",
            summary: "Session source attachments and citations view.",
            hasMainEntry: false,
            hasWindowEntry: true
        ),
        GUIPluginDescriptor(
            id: GUIPluginID.goal.rawValue,
            displayName: "Goal",
            summary: "Autonomous session goal pill, live subscription, and pause/resume/clear command orchestration.",
            hasMainEntry: false,
            hasWindowEntry: true
        ),
    ]

    /// The default registry populated with all built-in GUI plugins.
    public static let `default` = GUIPluginRegistry(plugins: builtInDescriptors)

    public static let reservedBuiltInIDs: Set<String> = Set(builtInDescriptors.map(\.id))

    public init(plugins: [GUIPluginDescriptor] = GUIPluginRegistry.builtInDescriptors) {
        self.plugins = []
        self.indexByID = [:]
        for plugin in plugins {
            self.register(plugin)
        }
    }

    /// Registers or replaces a plugin descriptor by `id`, preserving insertion order.
    public mutating func register(_ descriptor: GUIPluginDescriptor) {
        if let existingIndex = indexByID[descriptor.id] {
            plugins[existingIndex] = descriptor
        } else {
            indexByID[descriptor.id] = plugins.count
            plugins.append(descriptor)
        }
    }

    /// Looks up a plugin descriptor by its string identifier.
    public func plugin(id: String) -> GUIPluginDescriptor? {
        guard let index = indexByID[id] else { return nil }
        return plugins[index]
    }

    /// Looks up a built-in plugin descriptor by its typed `GUIPluginID`.
    public func plugin(_ id: GUIPluginID) -> GUIPluginDescriptor? {
        plugin(id: id.rawValue)
    }

    /// Returns whether `id` is reserved by a built-in plugin.
    public func isBuiltIn(_ id: String) -> Bool {
        Self.reservedBuiltInIDs.contains(id)
    }

    /// Returns all registered plugins eligible to run on `os`.
    public func available(on os: GUIPluginOS = .current) -> [GUIPluginDescriptor] {
        plugins.filter { $0.runsOn(os) }
    }

    /// Returns all plugins that provide a main-process controller on `os`.
    public func mainPlugins(on os: GUIPluginOS = .current) -> [GUIPluginDescriptor] {
        plugins.filter { $0.hasMainEntry && $0.runsOn(os) }
    }

    /// Returns all plugins that provide a window-side controller on `os`.
    public func windowPlugins(on os: GUIPluginOS = .current) -> [GUIPluginDescriptor] {
        plugins.filter { $0.hasWindowEntry && $0.runsOn(os) }
    }

    /// Resolves the plugin that owns a given IPC identifier (for example `"ssh"`, `"wsl"`, `"pairing"`, `"updater"`).
    public func plugin(forIPC ipcID: String) -> GUIPluginDescriptor? {
        plugins.first { $0.ipcIDs.contains(ipcID) }
    }

    /// Resolves the plugin that provides a given contract identifier (for example `"review.details"`).
    public func plugin(forContract contractID: String) -> GUIPluginDescriptor? {
        plugins.first { $0.contractIDs.contains(contractID) }
    }
}

// MARK: - Deterministic State Machine Core

/// Result of a pure deterministic state-machine transition: the next state and ordered side effects.
public struct GUIStateTransition<State: Sendable, Effect: Sendable>: Sendable {
    public let state: State
    public let effects: [Effect]

    public init(state: State, effects: [Effect] = []) {
        self.state = state
        self.effects = effects
    }
}

extension GUIStateTransition: Equatable where State: Equatable, Effect: Equatable {}

/// Common interface implemented by pure deterministic GUI plugin state machines.
public protocol GUIStateMachine: Sendable {
    associatedtype State: Sendable
    associatedtype Event: Sendable
    associatedtype Effect: Sendable

    static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect>
}

/// FIFO state-machine driver loop matching `terminal/dispatch.ts` and `pairing/dispatch.ts`.
///
/// Applies one event at a time. Effects may synchronously enqueue follow-up events, which wait
/// until the current transition finishes applying. When an effect throws, `failed(effect)` is
/// optionally translated into a failure event and queued so the machine never stalls.
public final class GUIStateMachineDispatcher<State: Equatable & Sendable, Event: Sendable, Effect: Sendable> {
    private var currentState: State
    private var queue: [Event] = []
    private var draining = false

    private let reducer: (State, Event) -> GUIStateTransition<State, Effect>
    private let onStateChange: (State) -> Void
    private let runEffect: (Effect) throws -> Void
    private let onEffectFailure: (Effect) -> Event?
    private let onUnhandledError: ((any Error) -> Void)?

    public init(
        initialState: State,
        reduce: @escaping (State, Event) -> GUIStateTransition<State, Effect>,
        onStateChange: @escaping (State) -> Void = { _ in },
        runEffect: @escaping (Effect) throws -> Void,
        onEffectFailure: @escaping (Effect) -> Event? = { _ in nil },
        onUnhandledError: ((any Error) -> Void)? = nil
    ) {
        self.currentState = initialState
        self.reducer = reduce
        self.onStateChange = onStateChange
        self.runEffect = runEffect
        self.onEffectFailure = onEffectFailure
        self.onUnhandledError = onUnhandledError
    }

    public var state: State {
        currentState
    }

    public func dispatch(_ event: Event) {
        queue.append(event)
        if draining { return }
        draining = true
        defer { draining = false }

        var index = 0
        while index < queue.count {
            let nextEvent = queue[index]
            index += 1
            apply(nextEvent)
        }
        queue.removeAll(keepingCapacity: true)
    }

    private func apply(_ event: Event) {
        let previous = currentState
        let transition = reducer(previous, event)
        if transition.state != previous {
            currentState = transition.state
            onStateChange(transition.state)
        }
        for effect in transition.effects {
            do {
                try runEffect(effect)
            } catch {
                if let failureEvent = onEffectFailure(effect) {
                    queue.append(failureEvent)
                } else {
                    onUnhandledError?(error)
                }
            }
        }
    }
}
