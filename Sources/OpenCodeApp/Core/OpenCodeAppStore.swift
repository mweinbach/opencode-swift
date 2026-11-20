import Foundation
import Observation
import OpenCodeClient
import OpenCodeCore
import OpenCodeGUIPlugins
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeSDK
import OpenCodeServer
import OpenCodeTUI
import OpenCodeUtil
import OpenTUICore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Errors thrown by `OpenCodeAppStore` operations.
public enum OpenCodeAppStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConnected
    case invalidServerURL(String)
    case emptyInput
    case missingActiveSession
    case noActiveOAuthAttempt

    public var description: String {
        switch self {
        case .notConnected:
            return "Not connected to an OpenCode server."
        case .invalidServerURL(let url):
            return "Invalid OpenCode server URL: \(url)"
        case .emptyInput:
            return "Input cannot be empty."
        case .missingActiveSession:
            return "No active session selected."
        case .noActiveOAuthAttempt:
            return "No active OAuth sign-in attempt."
        }
    }
}

/// Active interactive OAuth sign-in attempt tracked by `OpenCodeAppStore`.
public struct AppOAuthAttempt: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { attemptID }
    public let integrationID: String
    public let integrationName: String
    public let methodID: String
    public let attemptID: String
    public let url: String
    public let instructions: String
    public let mode: IntegrationSchema.Attempt.Mode
    public let supportsPaste: Bool
    public var statusMessage: String?
    public var isPolling: Bool
    public var errorMessage: String?

    public init(
        integrationID: String,
        integrationName: String,
        methodID: String,
        attemptID: String,
        url: String,
        instructions: String,
        mode: IntegrationSchema.Attempt.Mode,
        supportsPaste: Bool = false,
        statusMessage: String? = nil,
        isPolling: Bool = false,
        errorMessage: String? = nil
    ) {
        self.integrationID = integrationID
        self.integrationName = integrationName
        self.methodID = methodID
        self.attemptID = attemptID
        self.url = url
        self.instructions = instructions
        self.mode = mode
        self.supportsPaste = supportsPaste
        self.statusMessage = statusMessage
        self.isPolling = isPolling
        self.errorMessage = errorMessage
    }

    /// Extracts an optional device/user code (such as `WDJB-MJHT` or `ABCD-1234`) from `instructions`
    /// so the UI can highlight it and provide a one-click Copy Code action.
    public var extractedDeviceCode: String? {
        Self.extractDeviceCode(from: instructions)
    }

    public static func extractDeviceCode(from instructions: String) -> String? {
        // 1. Prefer explicit "Enter code: <CODE>" / "enter code: <CODE>" pattern used by
        //    OpenCode Console, GitHub Copilot, OpenAI Codex device auth, and xAI.
        let lowered = instructions.lowercased()
        if let markerRange = lowered.range(of: "enter code:") {
            let tail = instructions[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let token = tail
                .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." || $0 == "\"" || $0 == "'" || $0 == "`" })
                .first
                .map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: ":;()[]{}"))
            if let token, !token.isEmpty, token.count <= 32 {
                return token
            }
        }

        // 2. Fallback: scan for standard RFC 8628 dashed device codes (e.g. WDJB-MJHT, ABCD-12345).
        let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.\"'`()[]{}"))
        for rawToken in instructions.components(separatedBy: delimiters) {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ":;"))
            guard token.contains("-"), token.count >= 8, token.count <= 16 else { continue }
            guard !token.lowercased().hasPrefix("http") else { continue }
            let parts = token.split(separator: "-")
            guard parts.count == 2,
                  parts[0].count >= 4,
                  parts[1].count >= 4,
                  parts.allSatisfy({ part in
                      part.allSatisfy { ch in ch.isASCII && (ch.isUppercase || ch.isNumber) }
                  })
            else {
                continue
            }
            return token
        }
        return nil
    }
}

/// Side-effect flags emitted by the pure SSE event reducer `OpenCodeAppStore.applyServerEvent(_:)`.
public struct AppEventSideEffect: Equatable, Sendable {
    public var refreshSessions: Bool = false
    public var refreshMessagesForSession: String? = nil
    public var refreshAgents: Bool = false
    public var refreshModelsAndProviders: Bool = false
    public var refreshIntegrations: Bool = false
    public var refreshMCP: Bool = false
    public var refreshVCS: Bool = false
    public var refreshDiffs: Bool = false
    public var refreshCommands: Bool = false
    public var refreshPermissions: Bool = false
    public var refreshForms: Bool = false
    public var refreshUsageLimits: Bool = false

    public init() {}
}

/// Production-grade reactive application store powering the native SwiftUI OpenCode app
/// across macOS, iOS, iPadOS, and visionOS — and compiling cleanly on Linux/Windows without SwiftUI.
@MainActor
@Observable
public final class OpenCodeAppStore {
    // MARK: - Connection & Environment State

    public private(set) var connectionState: AppConnectionState = .disconnected
    public private(set) var connectionTarget: AppConnectionTarget = .embedded()
    public private(set) var serverURL: String = "http://opencode.local"
    public private(set) var serverVersion: String = ""
    public private(set) var sseConnected: Bool = false
    public private(set) var workspaceDirectory: String = FileManager.default.currentDirectoryPath
    public private(set) var activeDatabasePath: String? = nil
    public private(set) var gitBranch: String? = nil

    // MARK: - Sessions & Active Transcript

    public private(set) var sessions: [AppSessionSummary] = []
    public var sessionSearchQuery: String = ""
    public private(set) var activeSessionID: String? = nil
    public private(set) var messages: [AppTranscriptMessage] = []
    public private(set) var activeSessionCost: Double = 0
    public private(set) var activeSessionTokens: Int = 0

    // MARK: - Live Catalogs & Workspace Data

    /// Built-in GUI plugin descriptors & non-DOM state machines from `OpenCodeGUIPlugins`.
    public let guiPluginRegistry: GUIPluginRegistry = .default
    public var reviewComments: ReviewCommentStore = ReviewCommentStore()
    public var pairingCopyState: PairingCopyMachine.State = .idle(attempt: 0)
    public var windowUpdaterState: WindowUpdaterMachine.State = .idle(issued: 0)

    /// Built-in GUI plugins eligible for the current host OS.
    public var activeGUIPlugins: [GUIPluginDescriptor] {
        guiPluginRegistry.plugins.filter { $0.runsOn(.current) }
    }

    public private(set) var agents: [AppAgentItem] = AppAgentItem.defaults
    public private(set) var selectedAgentID: String = "build"
    public private(set) var models: [AppModelItem] = []
    public private(set) var providers: [String: String] = [:]
    public private(set) var selectedModel: AppModelItem? = nil
    public private(set) var selectedVariant: String? = nil
    public private(set) var integrations: [AppProviderIntegration] = []
    /// Full `IntegrationSchema.Info` records keyed by integration ID (including OAuth, API Key, External, Command, and Env auth methods).
    public private(set) var integrationCatalog: [String: IntegrationSchema.Info] = [:]
    public private(set) var serverCommands: [AppSlashCommandItem] = []
    public private(set) var mcpServers: [AppMCPServerItem] = []
    public private(set) var todos: [AppTodoItem] = []
    public private(set) var diffs: [AppFileDiffItem] = []
    public private(set) var usageLimits: [AppUsageLimitItem] = []
    public private(set) var usageWorkspaceName: String? = nil

    // MARK: - Permissions & Interactive Forms

    public private(set) var pendingPermissions: [AppPermissionItem] = []
    public private(set) var pendingForms: [AppFormItem] = []

    // MARK: - Composer & Autocomplete State

    public var composerText: String = ""
    public var isShellMode: Bool = false
    public var slashAutocompleteDismissed: Bool = false
    public var mentionAutocompleteDismissed: Bool = false
    public private(set) var mentionFilePaths: [String] = []
    public private(set) var isSending: Bool = false

    // MARK: - Appearance, Settings & Sheet State

    public var settings: AppSettings
    public private(set) var systemIsDark: Bool = true
    public var selectedInspectorTab: AppInspectorTab = .context

    public var isCommandPalettePresented: Bool = false
    public var isConnectProviderPresented: Bool = false
    public var isPairingQRPresented: Bool = false
    public var isSettingsPresented: Bool = false
    public var isDiffReviewPresented: Bool = false
    public var isRemoteConnectPresented: Bool = false
    public var activeFormSheet: AppFormItem? = nil
    public var renamingSession: AppSessionSummary? = nil
    public private(set) var pairingPayload: AppPairingPayload? = nil
    public private(set) var pairingError: String? = nil
    public private(set) var activeOAuthAttempt: AppOAuthAttempt? = nil
    public private(set) var isRefreshingModels: Bool = false
    public private(set) var toast: AppToastNotice? = nil

    // MARK: - Injectable Platform Hooks

    /// Opens an external URL (such as an OAuth authorization URL) in the system browser.
    /// Defaults to `OpenCodeAppStore.openURLInBrowser(_:)` (`NSWorkspace.shared.open` on macOS,
    /// `UIApplication.shared.open` on iOS/visionOS). Injectable for deterministic tests.
    @ObservationIgnored public var urlOpener: @MainActor (String) -> Bool

    // MARK: - Private Runtime Handles

    @ObservationIgnored private var client: OpenCodeClient? = nil
    @ObservationIgnored private var embeddedSDK: OpenCode.Interface? = nil
    @ObservationIgnored private var eventTask: Task<Void, Never>? = nil
    @ObservationIgnored private var mentionTask: Task<Void, Never>? = nil
    @ObservationIgnored private var oauthPollTask: Task<Void, Never>? = nil
    @ObservationIgnored private var oauthPollInterval: Duration
    @ObservationIgnored private var runningSessionIDs: Set<String> = []
    @ObservationIgnored private var retryingSessions: [String: String] = [:]
    @ObservationIgnored private var sseReconnectEnabled: Bool = true

    public init(
        settings: AppSettings = AppSettings(),
        systemIsDark: Bool = true,
        oauthPollInterval: Duration = .milliseconds(500),
        urlOpener: (@MainActor (String) -> Bool)? = nil
    ) {
        self.settings = settings
        self.systemIsDark = systemIsDark
        self.oauthPollInterval = oauthPollInterval
        self.urlOpener = urlOpener ?? Self.openURLInBrowser
    }

    // MARK: - Derived Properties

    public var activeClient: OpenCodeClient? { client }

    /// Resolved semantic theme palette bridged from `OpenCodeTUI.ThemeDefaults`.
    public var resolvedPalette: AppResolvedPalette {
        AppResolvedPalette(
            themeName: settings.themeName,
            preference: settings.themeMode,
            systemIsDark: systemIsDark
        )
    }

    public var effectiveThemeMode: Mode {
        settings.themeMode.resolvedMode(systemIsDark: systemIsDark)
    }

    public var activeSession: AppSessionSummary? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    public var activeAgent: AppAgentItem {
        agents.first { $0.id == selectedAgentID } ?? agents.first ?? AppAgentItem.defaults[0]
    }

    public var activeSessionStatus: AppSessionStatusBadge {
        guard let sid = activeSessionID else { return .idle }
        return badgeForSession(sid)
    }

    public var isActiveSessionWorking: Bool {
        activeSessionStatus.isWorking
    }

    public var activePermission: AppPermissionItem? {
        if let sid = activeSessionID,
           let match = pendingPermissions.first(where: { $0.sessionID == sid }) {
            return match
        }
        return pendingPermissions.first
    }

    public var activePendingForm: AppFormItem? {
        if let sid = activeSessionID,
           let match = pendingForms.first(where: { $0.sessionID == sid }) {
            return match
        }
        return pendingForms.first
    }

    public var filteredSessionGroups: [AppSessionGroup] {
        let needle = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [AppSessionSummary]
        if needle.isEmpty {
            filtered = sessions
        } else {
            filtered = sessions.filter {
                $0.title.lowercased().contains(needle)
                    || $0.id.lowercased().contains(needle)
                    || $0.directory.lowercased().contains(needle)
            }
        }
        return AppSessionGroup.group(filtered)
    }

    public var allSlashCommands: [AppSlashCommandItem] {
        AppCommandRegistry.mergedSlashCommands(serverCommands: serverCommands)
    }

    public var slashSuggestions: [AppSlashCommandItem] {
        guard !isShellMode, !slashAutocompleteDismissed else { return [] }
        return AppCommandRegistry.filterSlashCommands(allSlashCommands, input: composerText)
    }

    public var activeMentionTrigger: AppMentionTrigger? {
        guard !isShellMode, !mentionAutocompleteDismissed, slashSuggestions.isEmpty else { return nil }
        return AppCommandRegistry.detectMentionTrigger(in: composerText)
    }

    public var mentionSuggestions: [AppMentionItem] {
        guard let trigger = activeMentionTrigger else { return [] }
        return AppCommandRegistry.buildMentionSuggestions(
            query: trigger.query,
            files: mentionFilePaths,
            agents: agents
        )
    }

    public var contextLimit: Int? {
        selectedModel?.contextLimit
    }

    public var contextPercent: Int? {
        guard activeSessionTokens > 0, let limit = contextLimit, limit > 0 else { return nil }
        return min(100, max(0, Int((Double(activeSessionTokens) / Double(limit) * 100.0).rounded())))
    }

    public var isAnyProviderConnected: Bool {
        !models.isEmpty || integrations.contains(where: \.isConnected)
    }

    /// Returns all authentication methods advertised by the server for `integrationID`.
    public func authMethods(for integrationID: String) -> [IntegrationSchema.Method] {
        integrationCatalog[integrationID]?.methods ?? []
    }

    /// Opens `urlString` via the configured `urlOpener` closure (defaulting to the platform browser).
    @discardableResult
    public func openExternalURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return urlOpener(trimmed)
    }

    /// Opens `urlString` in the host OS default browser (`NSWorkspace` on macOS, `UIApplication` on iOS/visionOS).
    @MainActor
    @discardableResult
    public static func openURLInBrowser(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        #if canImport(AppKit) && os(macOS)
        return NSWorkspace.shared.open(url)
        #elseif canImport(UIKit) && !os(watchOS)
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
        #else
        _ = url
        return false
        #endif
    }

    /// Resolves the default on-disk SQLite database path under `Global.make().data`.
    ///
    /// Resolution order:
    /// 1. `OPENCODE_DB` environment variable (if set and non-empty; `":memory:"` returned verbatim,
    ///    relative paths resolved against `dataDirectory`, absolute paths used directly).
    /// 2. Release / standard channels (`latest`, `dev`, `beta`, `next`, `prod`, `release`) or
    ///    `OPENCODE_DISABLE_CHANNEL_DB=1|true` -> `opencode.db`.
    /// 3. Local / custom channel (`OPENCODE_CHANNEL`, defaulting to `"local"`) ->
    ///    `opencode-<sanitizedChannel>.db` (e.g. `opencode-local.db`), falling back to `opencode.db`
    ///    when `opencode.db` already exists on disk and `opencode-<sanitizedChannel>.db` does not.
    public nonisolated static func resolveDefaultDatabasePath(
        dataDirectory: String? = nil,
        channel: String? = nil,
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let dataDir = dataDirectory ?? Global.make(environment: environment).data

        func resolveUnderDataDir(_ filename: String) -> String {
            if filename == ":memory:" {
                return filename
            }
            if isAbsolutePath(filename) {
                return URL(fileURLWithPath: filename).standardizedFileURL.path
            }
            return URL(fileURLWithPath: dataDir, isDirectory: true)
                .appendingPathComponent(filename)
                .standardizedFileURL
                .path
        }

        if let explicit = environment.variable("OPENCODE_DB")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return resolveUnderDataDir(explicit)
        }

        let rawChannel = channel ?? environment.variable("OPENCODE_CHANNEL")
        let trimmedChannel = rawChannel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveChannel = (trimmedChannel?.isEmpty == false ? trimmedChannel! : "local")

        let standardChannels: Set<String> = ["latest", "dev", "beta", "next", "prod", "release"]
        let disableChannelDB = environment.variable("OPENCODE_DISABLE_CHANNEL_DB")
        if standardChannels.contains(effectiveChannel.lowercased())
            || disableChannelDB == "1"
            || disableChannelDB == "true" {
            return resolveUnderDataDir("opencode.db")
        }

        let sanitized = sanitizeDatabaseChannelSegment(effectiveChannel)
        let channelPath = resolveUnderDataDir("opencode-\(sanitized).db")
        let defaultPath = resolveUnderDataDir("opencode.db")
        if !fileExists(channelPath) && fileExists(defaultPath) {
            return defaultPath
        }
        return channelPath
    }

    private nonisolated static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\") {
            return true
        }
        let units = Array(path.utf16)
        if units.count >= 3,
           ((units[0] >= 0x41 && units[0] <= 0x5A) || (units[0] >= 0x61 && units[0] <= 0x7A)),
           units[1] == 0x3A,
           (units[2] == 0x2F || units[2] == 0x5C) {
            return true
        }
        return false
    }

    private nonisolated static func sanitizeDatabaseChannelSegment(_ channel: String) -> String {
        var out = ""
        out.reserveCapacity(channel.utf16.count)
        for unit in channel.utf16 {
            let allowed = (unit >= 0x30 && unit <= 0x39)
                || (unit >= 0x41 && unit <= 0x5A)
                || (unit >= 0x61 && unit <= 0x7A)
                || unit == 0x2E || unit == 0x5F || unit == 0x2D
            if allowed, let scalar = UnicodeScalar(unit) {
                out.append(Character(scalar))
            } else {
                out.append("-")
            }
        }
        return out.isEmpty ? "local" : out
    }

    private var locationQuery: LocationQuery.LocationField? {
        guard !workspaceDirectory.isEmpty else { return nil }
        return LocationQuery.LocationField(directory: workspaceDirectory)
    }

    // MARK: - Connection Management

    /// Boots a live embedded `OpenCodeSDK` (`OpenCode.create`) host in-process and connects the store.
    ///
    /// When `databasePath` is explicitly provided (such as `":memory:"` or a temporary path in tests),
    /// it is used directly. When `nil` in real app launches, opens the user's real on-disk OpenCode
    /// SQLite database resolved via `resolveDefaultDatabasePath()`.
    public func connectEmbedded(
        directory: String? = nil,
        databasePath: String? = nil,
        configContent: String? = nil,
        options: OpenCode.CreateOptions? = nil,
        subscribeEvents: Bool = true
    ) async throws {
        await disconnect()
        let resolvedDir = directory ?? workspaceDirectory
        connectionTarget = .embedded(directory: resolvedDir, configContent: configContent)
        connectionState = .connecting

        do {
            let createOptions: OpenCode.CreateOptions
            let resolvedDatabasePath: String
            if var options {
                if let explicitDB = databasePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !explicitDB.isEmpty {
                    options.server.database = CoreDatabaseStore.Options(path: explicitDB)
                    resolvedDatabasePath = explicitDB
                } else if let existingPath = options.server.database?.path, !existingPath.isEmpty {
                    resolvedDatabasePath = existingPath
                } else {
                    let defaultPath = Self.resolveDefaultDatabasePath()
                    options.server.database = CoreDatabaseStore.Options(path: defaultPath)
                    resolvedDatabasePath = defaultPath
                }
                createOptions = options
            } else {
                let explicitDB = databasePath?.trimmingCharacters(in: .whitespacesAndNewlines)
                let dbPath = (explicitDB?.isEmpty == false ? explicitDB! : Self.resolveDefaultDatabasePath())
                resolvedDatabasePath = dbPath
                let channelEnv = SystemEnvironment.shared.variable("OPENCODE_CHANNEL")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let channel = (channelEnv?.isEmpty == false) ? channelEnv : nil
                createOptions = OpenCode.CreateOptions(
                    app: .init(
                        name: "opencode",
                        version: OpenCodeAppModule.version,
                        channel: channel
                    ),
                    database: CoreDatabaseStore.Options(path: dbPath),
                    config: .init(
                        directory: resolvedDir,
                        project: configContent == nil,
                        content: configContent
                    )
                )
            }

            if resolvedDatabasePath != ":memory:" && !resolvedDatabasePath.isEmpty {
                let parentDir = URL(fileURLWithPath: resolvedDatabasePath)
                    .deletingLastPathComponent()
                    .path
                if !parentDir.isEmpty {
                    try? FileManager.default.createDirectory(
                        atPath: parentDir,
                        withIntermediateDirectories: true
                    )
                }
            }

            let sdk = try await OpenCode.create(createOptions)
            self.embeddedSDK = sdk
            self.activeDatabasePath = resolvedDatabasePath
            self.workspaceDirectory = resolvedDir
            try await connect(
                using: sdk.client,
                serverURL: "http://opencode.local",
                modeLabel: "Embedded",
                directory: resolvedDir,
                subscribeEvents: subscribeEvents
            )
        } catch {
            activeDatabasePath = nil
            connectionState = .failed(String(describing: error))
            showToast("Failed to boot embedded server: \(error)", isError: true)
            throw error
        }
    }

    /// Connects to a remote OpenCode HTTP/SSE server using optional Basic or Bearer credentials.
    public func connectRemote(
        url: String,
        credentials: AppServerCredentials = .none,
        transport: (any HTTPTransport)? = nil,
        subscribeEvents: Bool = true
    ) async throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") else {
            let err = OpenCodeAppStoreError.invalidServerURL(url)
            connectionState = .failed(err.description)
            throw err
        }

        await disconnect()
        connectionTarget = .remote(url: trimmed, credentials: credentials)
        connectionState = .connecting

        let clientOptions = ClientOptions(
            baseUrl: trimmed,
            transport: transport ?? URLSessionHTTPTransport.shared,
            headers: credentials.headers
        )
        let remoteClient = OpenCode.make(clientOptions)
        do {
            try await connect(
                using: remoteClient,
                serverURL: trimmed,
                modeLabel: "Remote",
                directory: nil,
                subscribeEvents: subscribeEvents
            )
        } catch {
            connectionState = .failed(String(describing: error))
            showToast("Failed to connect to \(trimmed): \(error)", isError: true)
            throw error
        }
    }

    /// Exchanges a pairing code (`GET /auth/connect/:code`) for a Bearer token and connects to the server.
    public func pairAndConnect(
        serverURL: String,
        code: String,
        transport: (any HTTPTransport)? = nil,
        subscribeEvents: Bool = true
    ) async throws {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.lowercased().hasPrefix("http://") || trimmedURL.lowercased().hasPrefix("https://") else {
            throw OpenCodeAppStoreError.invalidServerURL(serverURL)
        }
        guard !trimmedCode.isEmpty else {
            throw OpenCodeAppStoreError.emptyInput
        }

        let resolvedTransport = transport ?? URLSessionHTTPTransport.shared
        let unauthenticated = OpenCode.make(ClientOptions(baseUrl: trimmedURL, transport: resolvedTransport))
        let pairingSession = try await unauthenticated.server.connect(ServerConnectInput(code: trimmedCode))
        connectionTarget = .paired(url: trimmedURL, code: trimmedCode)
        try await connectRemote(
            url: trimmedURL,
            credentials: .bearer(token: pairingSession.token),
            transport: resolvedTransport,
            subscribeEvents: subscribeEvents
        )
    }

    /// Connects directly to an already-constructed `OpenCodeClient` (ideal for tests or custom embedded routers).
    public func connect(
        using client: OpenCodeClient,
        serverURL: String = "http://opencode.local",
        modeLabel: String = "Connected",
        directory: String? = nil,
        subscribeEvents: Bool = true
    ) async throws {
        eventTask?.cancel()
        eventTask = nil

        self.client = client
        self.serverURL = serverURL
        if let directory, !directory.isEmpty {
            self.workspaceDirectory = directory
        }

        let info = try await client.server.info()
        self.serverVersion = info.version
        if let loc = try? await client.location.get(LocationGetInput(location: locationQuery)) {
            self.workspaceDirectory = loc.directory.rawValue
        }

        self.connectionState = .connected(serverVersion: info.version, modeLabel: modeLabel)
        await refreshWorkspace()

        if subscribeEvents {
            startEventSubscription()
        }
    }

    /// Cleanly tears down the live SSE stream and closes any owned embedded SDK host.
    public func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        mentionTask?.cancel()
        mentionTask = nil
        oauthPollTask?.cancel()
        oauthPollTask = nil
        activeOAuthAttempt = nil

        if let sdk = embeddedSDK {
            embeddedSDK = nil
            await sdk.close()
        }
        client = nil
        activeDatabasePath = nil
        sseConnected = false
        integrationCatalog.removeAll()
        runningSessionIDs.removeAll()
        retryingSessions.removeAll()
        connectionState = .disconnected
    }

    // MARK: - Live SSE Subscription

    public func startEventSubscription() {
        eventTask?.cancel()
        guard let activeClient = client else { return }
        sseReconnectEnabled = true

        eventTask = Task { @MainActor [weak self] in
            var backoffMs: UInt64 = 250
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.client != nil else { return }
                let stream = activeClient.event.subscribe()
                do {
                    for try await event in stream {
                        if Task.isCancelled { return }
                        backoffMs = 250
                        attempt = 0
                        self.sseConnected = true
                        self.processServerEvent(event)
                    }
                } catch {
                    if Task.isCancelled { return }
                }

                guard !Task.isCancelled, self.sseReconnectEnabled, self.client != nil else { return }
                self.sseConnected = false
                attempt += 1
                self.connectionState = .reconnecting(attempt: attempt)
                try? await Task.sleep(for: .milliseconds(backoffMs))
                backoffMs = min(backoffMs * 2, 2_000)
            }
        }
    }

    /// Applies an incoming SSE `OpenCodeEvent` immediately and dispatches any required refreshes.
    public func processServerEvent(_ event: OpenCodeEvent) {
        let effect = applyServerEvent(event)
        dispatch(sideEffect: effect)
    }

    /// Pure deterministic SSE event reducer updating store state synchronously (directly unit-testable!).
    @discardableResult
    public func applyServerEvent(_ event: OpenCodeEvent) -> AppEventSideEffect {
        var effect = AppEventSideEffect()
        let obj = Self.jsonObject(event.data)
        let eventSessionID = Self.stringField(obj, "sessionID")
        let isForActive = eventSessionID != nil && eventSessionID == activeSessionID
        let nowMs = Int64(event.created ?? Double(Flock.currentEpochMs()))

        switch event.type {
        case "server.connected":
            sseConnected = true
            if case .reconnecting = connectionState {
                connectionState = .connected(
                    serverVersion: serverVersion,
                    modeLabel: embeddedSDK != nil ? "Embedded" : "Remote"
                )
            }

        case "session.created":
            effect.refreshSessions = true

        case "session.deleted":
            if let sid = eventSessionID {
                sessions.removeAll { $0.id == sid }
                pendingPermissions.removeAll { $0.sessionID == sid }
                pendingForms.removeAll { $0.sessionID == sid }
                runningSessionIDs.remove(sid)
                retryingSessions.removeValue(forKey: sid)
                if activeSessionID == sid {
                    activeSessionID = sessions.first?.id
                    messages = []
                }
            }
            effect.refreshSessions = true

        case "session.renamed":
            if let sid = eventSessionID, let title = Self.stringField(obj, "title"), !title.isEmpty {
                if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                    sessions[idx].title = title
                }
            }

        case "session.archived":
            if let sid = eventSessionID, let idx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[idx].archived = true
            }

        case "session.unarchived":
            if let sid = eventSessionID, let idx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[idx].archived = false
            }

        case "session.status":
            if let sid = eventSessionID {
                let statusObj = Self.jsonObject(obj["status"])
                let kind = Self.stringField(statusObj, "type") ?? Self.stringField(obj, "status") ?? ""
                switch kind {
                case "busy", "running":
                    runningSessionIDs.insert(sid)
                    retryingSessions.removeValue(forKey: sid)
                case "retry":
                    runningSessionIDs.insert(sid)
                    retryingSessions[sid] = Self.stringField(statusObj, "message") ?? "Retrying…"
                case "idle":
                    runningSessionIDs.remove(sid)
                    retryingSessions.removeValue(forKey: sid)
                    if isForActive {
                        markActiveAssistantCompleted()
                        effect.refreshMessagesForSession = sid
                    }
                default:
                    break
                }
                syncSessionBadges()
            }

        case "session.execution.started":
            if let sid = eventSessionID {
                runningSessionIDs.insert(sid)
                retryingSessions.removeValue(forKey: sid)
                syncSessionBadges()
            }

        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.idle":
            if let sid = eventSessionID {
                runningSessionIDs.remove(sid)
                retryingSessions.removeValue(forKey: sid)
                syncSessionBadges()
                if isForActive {
                    markActiveAssistantCompleted()
                    if event.type == "session.execution.failed",
                       let errMsg = Self.stringField(Self.jsonObject(obj["error"]), "message"),
                       !errMsg.isEmpty {
                        messages.append(.system(
                            id: event.id,
                            text: errMsg,
                            isError: true,
                            timestampMs: nowMs
                        ))
                    }
                    effect.refreshMessagesForSession = sid
                }
            }

        case "session.step.started":
            if let sid = eventSessionID {
                runningSessionIDs.insert(sid)
                syncSessionBadges()
                if isForActive {
                    let msgID = Self.stringField(obj, "assistantMessageID") ?? event.id
                    let agent = Self.stringField(obj, "agent").map(TUIUtil.titlecase) ?? activeAgent.name
                    let modelID = Self.stringField(Self.jsonObject(obj["model"]), "id") ?? (selectedModel?.name ?? "")
                    ensureAssistantMessage(id: msgID, agent: agent, model: modelID, timestampMs: nowMs)
                }
            }

        case "session.step.ended":
            if isForActive {
                let msgID = Self.stringField(obj, "assistantMessageID")
                let cost = Self.doubleField(obj, "cost")
                let tokens = Self.extractTotalTokens(Self.jsonObject(obj["tokens"]))
                finalizeAssistantMessage(id: msgID, cost: cost, tokens: tokens)
                if let sid = activeSessionID {
                    effect.refreshMessagesForSession = sid
                }
            }

        case "session.step.failed":
            if let sid = eventSessionID {
                runningSessionIDs.remove(sid)
                retryingSessions.removeValue(forKey: sid)
                syncSessionBadges()
                if isForActive {
                    let msgID = Self.stringField(obj, "assistantMessageID")
                    finalizeAssistantMessage(id: msgID, cost: nil, tokens: nil)
                    if let errMsg = Self.stringField(Self.jsonObject(obj["error"]), "message") ?? Self.stringField(obj, "error") {
                        messages.append(.system(
                            id: "err-\(event.id)",
                            text: errMsg,
                            isError: true,
                            timestampMs: nowMs
                        ))
                    }
                    effect.refreshMessagesForSession = sid
                }
            }

        case "session.retry.scheduled":
            if let sid = eventSessionID {
                let msg = Self.stringField(obj, "message") ?? Self.stringField(Self.jsonObject(obj["error"]), "message") ?? "Retrying…"
                retryingSessions[sid] = msg
                runningSessionIDs.insert(sid)
                syncSessionBadges()
            }

        case "session.shell.started":
            if let sid = eventSessionID {
                runningSessionIDs.insert(sid)
                syncSessionBadges()
                if isForActive {
                    effect.refreshMessagesForSession = sid
                }
            }

        case "session.shell.ended":
            if let sid = eventSessionID {
                runningSessionIDs.remove(sid)
                syncSessionBadges()
                if isForActive {
                    effect.refreshMessagesForSession = sid
                }
            }

        case "session.text.started":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let ordinal = Self.intField(obj, "ordinal") ?? 0
            let partID = "\(msgID)-text-\(ordinal)"
            upsertAssistantPart(messageID: msgID, partID: partID, timestampMs: nowMs) { existing in
                existing ?? .text(id: partID, text: "")
            }

        case "session.text.delta":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let ordinal = Self.intField(obj, "ordinal") ?? 0
            let delta = Self.stringField(obj, "delta") ?? Self.stringField(obj, "text") ?? ""
            guard !delta.isEmpty else { break }
            let partID = "\(msgID)-text-\(ordinal)"
            upsertAssistantPart(messageID: msgID, partID: partID, timestampMs: nowMs) { existing in
                if case .text(let id, let prev) = existing {
                    return .text(id: id, text: prev + delta)
                }
                return .text(id: partID, text: delta)
            }

        case "session.text.ended":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let ordinal = Self.intField(obj, "ordinal") ?? 0
            let partID = "\(msgID)-text-\(ordinal)"
            if let finalText = Self.stringField(obj, "text") {
                upsertAssistantPart(messageID: msgID, partID: partID, timestampMs: nowMs) { _ in
                    .text(id: partID, text: finalText)
                }
            }

        case "session.reasoning.started":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let ordinal = Self.intField(obj, "ordinal") ?? 0
            let partID = "\(msgID)-reasoning-\(ordinal)"
            upsertAssistantPart(messageID: msgID, partID: partID, timestampMs: nowMs) { existing in
                existing ?? .reasoning(id: partID, text: "", completed: false)
            }

        case "session.reasoning.delta":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let ordinal = Self.intField(obj, "ordinal") ?? 0
            let delta = Self.stringField(obj, "delta") ?? Self.stringField(obj, "text") ?? ""
            guard !delta.isEmpty else { break }
            let partID = "\(msgID)-reasoning-\(ordinal)"
            upsertAssistantPart(messageID: msgID, partID: partID, timestampMs: nowMs) { existing in
                if case .reasoning(let id, let prev, let done) = existing {
                    return .reasoning(id: id, text: prev + delta, completed: done)
                }
                return .reasoning(id: partID, text: delta, completed: false)
            }

        case "session.reasoning.ended":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let ordinal = Self.intField(obj, "ordinal") ?? 0
            let partID = "\(msgID)-reasoning-\(ordinal)"
            let finalText = Self.stringField(obj, "text")
            upsertAssistantPart(messageID: msgID, partID: partID, timestampMs: nowMs) { existing in
                let prevText: String
                if case .reasoning(_, let text, _) = existing { prevText = text } else { prevText = "" }
                return .reasoning(id: partID, text: finalText ?? prevText, completed: true)
            }

        case "session.tool.input.started":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let toolID = Self.stringField(obj, "id") ?? "tool"
            let name = Self.stringField(obj, "name") ?? "tool"
            upsertAssistantPart(messageID: msgID, partID: toolID, timestampMs: nowMs) { _ in
                .tool(id: toolID, name: name, status: .streaming, summary: "", inputJSON: nil, output: nil, error: nil)
            }

        case "session.tool.called":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let toolID = Self.stringField(obj, "id") ?? "tool"
            let name = Self.stringField(obj, "name")
            let inputDict = Self.jsonObject(obj["input"])
            let summary = TUIInteractiveClient.summarizeToolInput(inputDict)
            let inputJSON = inputDict.isEmpty ? nil : (try? ClientCodec.encodeString(JSONValue.object(inputDict)))
            upsertAssistantPart(messageID: msgID, partID: toolID, timestampMs: nowMs) { existing in
                let resolvedName: String
                if let name, !name.isEmpty {
                    resolvedName = name
                } else if case .tool(_, let prevName, _, _, _, _, _) = existing {
                    resolvedName = prevName
                } else {
                    resolvedName = "tool"
                }
                return .tool(id: toolID, name: resolvedName, status: .running, summary: summary, inputJSON: inputJSON, output: nil, error: nil)
            }

        case "session.tool.progress":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let toolID = Self.stringField(obj, "id") ?? "tool"
            let meta = Self.jsonObject(obj["metadata"])
            let output = Self.stringField(meta, "output") ?? Self.stringField(meta, "title")
            upsertAssistantPart(messageID: msgID, partID: toolID, timestampMs: nowMs) { existing in
                if case .tool(let id, let name, _, let summary, let input, let prevOut, let err) = existing {
                    return .tool(id: id, name: name, status: .running, summary: summary, inputJSON: input, output: output ?? prevOut, error: err)
                }
                return .tool(id: toolID, name: "tool", status: .running, summary: "", inputJSON: nil, output: output, error: nil)
            }

        case "session.tool.success":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let toolID = Self.stringField(obj, "id") ?? "tool"
            let outputText = Self.extractToolOutputText(obj["content"])
            upsertAssistantPart(messageID: msgID, partID: toolID, timestampMs: nowMs) { existing in
                if case .tool(let id, let name, _, let summary, let input, _, _) = existing {
                    return .tool(id: id, name: name, status: .completed, summary: summary, inputJSON: input, output: outputText, error: nil)
                }
                return .tool(id: toolID, name: Self.stringField(obj, "name") ?? "tool", status: .completed, summary: "", inputJSON: nil, output: outputText, error: nil)
            }

        case "session.tool.failed":
            guard isForActive else { break }
            let msgID = Self.stringField(obj, "assistantMessageID") ?? Self.stringField(obj, "messageID") ?? "stream"
            let toolID = Self.stringField(obj, "id") ?? "tool"
            let errObj = Self.jsonObject(obj["error"])
            let errMsg = Self.stringField(errObj, "message") ?? Self.stringField(obj, "error") ?? "Tool failed"
            upsertAssistantPart(messageID: msgID, partID: toolID, timestampMs: nowMs) { existing in
                if case .tool(let id, let name, _, let summary, let input, let prevOut, _) = existing {
                    return .tool(id: id, name: name, status: .error, summary: summary, inputJSON: input, output: prevOut, error: errMsg)
                }
                return .tool(id: toolID, name: Self.stringField(obj, "name") ?? "tool", status: .error, summary: "", inputJSON: nil, output: nil, error: errMsg)
            }

        case "session.usage.updated", "session.usage.recorded":
            if let sid = eventSessionID {
                let cost = Self.doubleField(obj, "cost")
                let totalTokens = Self.extractTotalTokens(Self.jsonObject(obj["tokens"] ?? obj["usage"]))
                if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                    if let cost { sessions[idx].cost = max(sessions[idx].cost, cost) }
                    if let totalTokens { sessions[idx].tokensTotal = max(sessions[idx].tokensTotal, totalTokens) }
                }
                if isForActive {
                    if let cost { activeSessionCost = max(activeSessionCost, cost) }
                    if let totalTokens { activeSessionTokens = totalTokens }
                }
            }
            effect.refreshUsageLimits = true

        case "session.agent.selected":
            if isForActive, let agentID = Self.stringField(obj, "agent"), !agentID.isEmpty {
                selectedAgentID = agentID
            }

        case "session.model.selected":
            if isForActive {
                let modelObj = Self.jsonObject(obj["model"])
                if let modelID = Self.stringField(modelObj, "id"),
                   let providerID = Self.stringField(modelObj, "providerID"),
                   let matched = models.first(where: { $0.modelID == modelID && $0.providerID == providerID }) {
                    selectedModel = matched
                    selectedVariant = Self.stringField(modelObj, "variant")
                }
            }

        case "session.message.created", "session.message.content.updated", "session.inbox.delivered":
            if isForActive, let sid = activeSessionID {
                effect.refreshMessagesForSession = sid
            }

        case "permission.asked":
            if let decoded = try? ClientCodec.fromJSONValue(PermissionSchema.Request.self, value: event.data) {
                let item = AppPermissionItem(from: decoded)
                pendingPermissions.removeAll { $0.id == item.id }
                pendingPermissions.append(item)
                syncSessionBadges()
            } else if let reqID = Self.stringField(obj, "id"),
                      let sid = Self.stringField(obj, "sessionID") ?? activeSessionID,
                      let action = Self.stringField(obj, "action") ?? Self.stringField(obj, "permission") {
                let resources = Self.stringArrayField(obj, "resources") ?? Self.stringArrayField(obj, "patterns") ?? []
                let save = Self.stringArrayField(obj, "save") ?? resources
                let meta = Self.jsonObject(obj["metadata"])
                let item = AppPermissionItem(
                    id: reqID,
                    sessionID: sid,
                    action: action,
                    resources: resources,
                    savePatterns: save,
                    commandPreview: Self.stringField(meta, "command"),
                    filePath: Self.stringField(meta, "filepath") ?? Self.stringField(meta, "filePath") ?? Self.stringField(meta, "path"),
                    diffPatch: Self.stringField(meta, "diff") ?? Self.stringField(meta, "patch"),
                    message: Self.stringField(obj, "message")
                )
                pendingPermissions.removeAll { $0.id == reqID }
                pendingPermissions.append(item)
                syncSessionBadges()
            } else {
                effect.refreshPermissions = true
            }

        case "permission.replied":
            if let reqID = Self.stringField(obj, "requestID") ?? Self.stringField(obj, "id") {
                pendingPermissions.removeAll { $0.id == reqID }
                syncSessionBadges()
            } else {
                effect.refreshPermissions = true
            }

        case "form.asked", "form.created":
            let formPayload = obj["form"] ?? event.data
            if let info = try? ClientCodec.fromJSONValue(FormSchema.Info.self, value: formPayload) {
                let item = AppFormItem(from: info)
                pendingForms.removeAll { $0.id == item.id }
                pendingForms.append(item)
                syncSessionBadges()
                if activeFormSheet == nil && (item.sessionID == activeSessionID || item.sessionID == "global") {
                    activeFormSheet = item
                }
            } else {
                effect.refreshForms = true
            }

        case "form.replied", "form.cancelled", "form.settled":
            if let formID = Self.stringField(obj, "formID") ?? Self.stringField(obj, "id") {
                pendingForms.removeAll { $0.id == formID }
                if activeFormSheet?.id == formID {
                    activeFormSheet = pendingForms.first
                }
                syncSessionBadges()
            } else {
                effect.refreshForms = true
            }

        case "vcs.branch.updated", "vcs.updated":
            if let branch = Self.stringField(obj, "branch"), !branch.isEmpty {
                gitBranch = branch
            }
            effect.refreshVCS = true
            effect.refreshDiffs = true

        case "mcp.status.changed", "mcp.updated":
            effect.refreshMCP = true

        case "todo.updated", "session.todo.updated":
            if eventSessionID == nil || isForActive {
                if case .array(let arr) = obj["todos"] ?? obj["items"] {
                    todos = arr.compactMap { entry in
                        let dict = Self.jsonObject(entry)
                        guard let content = Self.stringField(dict, "content") ?? Self.stringField(dict, "text") else {
                            return nil
                        }
                        let id = Self.stringField(dict, "id") ?? content
                        let rawStatus = Self.stringField(dict, "status") ?? "pending"
                        let status = AppTodoStatus(rawValue: rawStatus) ?? .pending
                        return AppTodoItem(id: id, content: content, status: status, priority: Self.stringField(dict, "priority"))
                    }
                }
            }

        case "agent.updated":
            effect.refreshAgents = true

        case "model.updated", "provider.updated":
            effect.refreshModelsAndProviders = true
            effect.refreshIntegrations = true

        case "integration.updated":
            effect.refreshIntegrations = true
            effect.refreshModelsAndProviders = true

        case "command.updated":
            effect.refreshCommands = true

        case "tui.toast.show":
            if let msg = Self.stringField(obj, "message"), !msg.isEmpty {
                showToast(msg, isError: Self.stringField(obj, "variant") == "error")
            }

        default:
            break
        }

        return effect
    }

    private func dispatch(sideEffect: AppEventSideEffect) {
        if sideEffect.refreshSessions {
            Task { await self.refreshSessions() }
        }
        if let sid = sideEffect.refreshMessagesForSession {
            Task { await self.refreshMessages(for: sid) }
        }
        if sideEffect.refreshAgents {
            Task { await self.refreshAgents() }
        }
        if sideEffect.refreshModelsAndProviders {
            Task { await self.refreshModelsAndProviders() }
        }
        if sideEffect.refreshIntegrations {
            Task { await self.refreshIntegrations() }
        }
        if sideEffect.refreshMCP {
            Task { await self.refreshMCP() }
        }
        if sideEffect.refreshVCS {
            Task { await self.refreshVCS() }
        }
        if sideEffect.refreshDiffs {
            Task { await self.refreshDiffs() }
        }
        if sideEffect.refreshCommands {
            Task { await self.refreshCommands() }
        }
        if sideEffect.refreshPermissions || sideEffect.refreshForms {
            Task { await self.refreshPermissionsAndForms() }
        }
        if sideEffect.refreshUsageLimits {
            Task { await self.refreshUsageLimits() }
        }
    }

    // MARK: - Workspace Sync

    public func refreshWorkspace() async {
        guard client != nil else { return }
        await refreshAgents()
        await refreshModelsAndProviders()
        await refreshIntegrations()
        await refreshSessions()
        await refreshMCP()
        await refreshVCS()
        await refreshDiffs()
        await refreshCommands()
        await refreshPermissionsAndForms()
        await refreshUsageLimits()
        if let sid = activeSessionID {
            await refreshMessages(for: sid)
        }
    }

    public func refreshSessions() async {
        guard let client else { return }
        if let activeMap = try? await client.session.active() {
            runningSessionIDs = Set(activeMap.keys)
        }
        guard let list = try? await client.session.list(
            SessionListInput(limit: 100, order: .desc, parentID: "null", archived: false)
        ) else { return }
        sessions = list.data.map { info in
            AppSessionSummary(from: info, badge: badgeForSession(info.id.rawValue))
        }
        if activeSessionID == nil, let first = sessions.first(where: { !$0.archived }) {
            activeSessionID = first.id
        }
        syncSessionBadges()
    }

    public func refreshAgents() async {
        guard let client else { return }
        guard let resp = try? await client.agent.list(AgentListInput(location: locationQuery)) else { return }
        let visible = resp.data.filter { !$0.hidden }.map(AppAgentItem.init(from:))
        if !visible.isEmpty {
            agents = visible
            if !agents.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = agents.first(where: \.isPrimary)?.id ?? agents[0].id
            }
        }
    }

    public func refreshModelsAndProviders() async {
        guard let client else { return }
        async let providersTask = try? client.provider.list(ProviderListInput(location: locationQuery))
        async let modelsTask = try? client.model.list(ModelListInput(location: locationQuery))
        async let defaultTask = try? client.model.default(ModelDefaultInput(location: locationQuery))

        let provResp = await providersTask
        let modelResp = await modelsTask
        let defaultResp = await defaultTask

        if let provData = provResp?.data {
            providers = Dictionary(uniqueKeysWithValues: provData.map { ($0.id.rawValue, $0.name) })
        }

        if let modelData = modelResp?.data {
            let mapped = modelData.map { info -> AppModelItem in
                let pid = info.providerID.rawValue
                let pName = providers[pid] ?? TUIUtil.titlecase(pid)
                return AppModelItem(
                    modelID: info.id.rawValue,
                    providerID: pid,
                    name: info.name.isEmpty ? info.id.rawValue : info.name,
                    providerName: pName,
                    variants: info.variants.map(\.id.rawValue),
                    contextLimit: info.limit.context
                )
            }
            models = mapped

            if let current = selectedModel,
               let updated = mapped.first(where: { $0.id == current.id }) {
                selectedModel = updated
            } else if let def = defaultResp?.data,
                      let matched = mapped.first(where: {
                          $0.modelID == def.id.rawValue && $0.providerID == def.providerID.rawValue
                      }) {
                selectedModel = matched
                selectedVariant = nil
            } else if selectedModel == nil {
                selectedModel = mapped.first
            }
        }
    }

    public func refreshIntegrations() async {
        guard let client else { return }
        guard let resp = try? await client.integration.list(IntegrationListInput(location: locationQuery)) else {
            return
        }
        let filtered = resp.data.filter { item in
            if case .string(let src) = item.metadata?["source"], src == "mcp" {
                return false
            }
            return true
        }
        integrationCatalog = Dictionary(
            filtered.map { ($0.id.rawValue, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        integrations = filtered
            .map(AppProviderIntegration.init(from:))
            .sorted { lhs, rhs in
                if lhs.sortPriority != rhs.sortPriority { return lhs.sortPriority < rhs.sortPriority }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Calls `POST /api/location/reload` to reload ModelsDev, OpenCode Console, and provider catalogs
    /// on the server, then refreshes integrations, providers, models, agents, and usage limits.
    public func refreshLiveModels() async {
        await refreshLiveModels(showToastNotice: true)
    }

    private func refreshLiveModels(showToastNotice: Bool) async {
        guard let client else { return }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        try? await client.location.reload()
        await refreshIntegrations()
        await refreshModelsAndProviders()
        await refreshAgents()
        await refreshUsageLimits()
        if showToastNotice {
            let modelCount = models.count
            let providerCount = providers.count
            if modelCount > 0 {
                showToast("Refreshed \(modelCount) models across \(providerCount) providers")
            } else {
                showToast("Model catalog refreshed")
            }
        }
    }

    public func refreshMCP() async {
        guard let client else { return }
        guard let resp = try? await client.mcp.list(McpListInput(location: locationQuery)) else { return }
        mcpServers = resp.data
            .map(AppMCPServerItem.init(from:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func refreshVCS() async {
        guard let client else { return }
        if let info = try? await client.vcs.get(VcsGetInput(location: locationQuery)) {
            if let branch = info.data.branch.current, !branch.isEmpty {
                gitBranch = branch
            } else {
                gitBranch = nil
            }
        }
    }

    public func refreshDiffs() async {
        guard let client else { return }
        if let vcsDiff = try? await client.vcs.diff(VcsDiffInput(location: locationQuery, mode: .working)),
           !vcsDiff.data.isEmpty {
            diffs = vcsDiff.data.map { entry in
                AppFileDiffItem(
                    path: entry.file,
                    status: entry.status.rawValue,
                    additions: entry.additions.rawValue,
                    deletions: entry.deletions.rawValue,
                    patch: entry.patch
                )
            }
            return
        }
        if let sid = activeSessionID,
           let sessionDiff = try? await client.session.diff(SessionDiffInput(sessionID: sid)) {
            diffs = sessionDiff.map { entry in
                AppFileDiffItem(
                    path: entry.file,
                    status: entry.status.rawValue,
                    additions: entry.additions.rawValue,
                    deletions: entry.deletions.rawValue,
                    patch: entry.patch
                )
            }
        } else {
            diffs = []
        }
    }

    public func refreshCommands() async {
        guard let client else { return }
        guard let resp = try? await client.command.list(CommandListInput(location: locationQuery)) else { return }
        serverCommands = resp.data.map { cmd in
            AppSlashCommandItem(
                name: cmd.name,
                description: cmd.description ?? "Server command",
                isServerCommand: true
            )
        }
    }

    public func refreshPermissionsAndForms() async {
        guard let client else { return }
        if let permResp = try? await client.permission.request.list(PermissionRequestListInput(location: locationQuery)) {
            pendingPermissions = permResp.data.map(AppPermissionItem.init(from:))
        } else if let sid = activeSessionID,
                  let sessionPerms = try? await client.permission.list(PermissionListInput(sessionID: sid)) {
            pendingPermissions = sessionPerms.map(AppPermissionItem.init(from:))
        }

        if let formResp = try? await client.form.list(FormListInput(location: locationQuery)) {
            pendingForms = formResp.data.map(AppFormItem.init(from:))
        } else if let sid = activeSessionID,
                  let sessionForms = try? await client.session.form.list(SessionFormListInput(sessionID: sid)) {
            pendingForms = sessionForms.map(AppFormItem.init(from:))
        }
        syncSessionBadges()
    }

    public func refreshUsageLimits() async {
        guard let client else { return }
        guard let resp = try? await client.experimental.usage.limits(
            ExperimentalUsageLimitsInput(location: locationQuery)
        ), let info = resp.data else {
            usageLimits = []
            usageWorkspaceName = nil
            return
        }
        let nowMs = Double(Flock.currentEpochMs())
        usageWorkspaceName = info.workspace.name
        usageLimits = info.budgets.map { budget in
            let limitVal = budget.limit.rawValue
            let spentVal = budget.spent.rawValue
            let remaining = max(0, limitVal - spentVal)
            let pct = limitVal > 0 ? max(0, min(100, Int(((remaining / limitVal) * 100.0).rounded()))) : 0
            let resetSec = max(0, Int((budget.resetsAt - nowMs) / 1000.0))
            let resetLabel: String
            if resetSec >= 3600 {
                resetLabel = "Resets in \(resetSec / 3600)h"
            } else if resetSec >= 60 {
                resetLabel = "Resets in \(resetSec / 60)m"
            } else {
                resetLabel = "Resets soon"
            }
            let title = budget.models.first?.name ?? (budget.coverage == .all ? "All models" : "Workspace budget")
            let prov = budget.models.first.map {
                providers[$0.providerID.rawValue] ?? TUIUtil.titlecase($0.providerID.rawValue)
            } ?? "OpenCode"
            return AppUsageLimitItem(
                id: budget.id,
                title: title,
                provider: prov,
                scope: budget.scope.rawValue,
                spentDollars: spentVal,
                limitDollars: limitVal,
                remainingPercent: pct,
                resetsLabel: resetLabel,
                isLow: pct <= 15,
                isReached: remaining <= 0.0001
            )
        }
    }

    public func refreshMessages(for sessionID: String) async {
        guard let client else { return }
        async let msgTask = try? client.message.list(MessageListInput(sessionID: sessionID, limit: 200, order: .desc))
        async let infoTask = try? client.session.get(SessionGetInput(sessionID: sessionID))
        async let activeTask = try? client.session.active()
        let msgResp = await msgTask
        let sessionInfo = await infoTask
        let activeMap = await activeTask

        guard activeSessionID == sessionID else { return }

        if let activeMap {
            runningSessionIDs = Set(activeMap.keys)
            if !runningSessionIDs.contains(sessionID) {
                retryingSessions.removeValue(forKey: sessionID)
            }
            syncSessionBadges()
        }

        if let info = sessionInfo {
            let summary = AppSessionSummary(from: info, badge: badgeForSession(sessionID))
            if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[idx] = summary
            } else {
                sessions.insert(summary, at: 0)
            }
            if let agent = info.agent, agents.contains(where: { $0.id == agent }) {
                selectedAgentID = agent
            }
            if let m = info.model,
               let matched = models.first(where: { $0.modelID == m.id && $0.providerID == m.providerID }) {
                selectedModel = matched
                selectedVariant = m.variant
            }
            activeSessionCost = info.cost
        }

        guard let rawMessagesDesc = msgResp?.data else { return }
        // `GET /api/session/:id/message` returns newest-first (`order=desc`); reverse into chronological oldest→newest order.
        let rawMessages = Array(rawMessagesDesc.reversed())

        var totalCost = 0.0
        var latestTokens = 0
        var mapped: [AppTranscriptMessage] = []

        if let latestUsageMsg = lastAssistantWithUsage(rawMessages),
           let usage = latestUsageMsg.tokens {
            latestTokens = Int(usage.total.rounded())
        }

        for msg in rawMessages {
            switch msg {
            case .user(let u):
                let mentionLabels = (u.agents ?? []).map { "@\($0.name)" }
                    + (u.files ?? []).compactMap { $0.name.map { "@\($0)" } }
                mapped.append(.user(
                    id: u.id.rawValue,
                    text: u.text,
                    timestampMs: u.time.created,
                    mentions: mentionLabels,
                    isOptimistic: false
                ))

            case .assistant(let a):
                if let cost = a.cost { totalCost += cost }
                let msgTokens = a.tokens.map { Int($0.total.rounded()) }
                if latestTokens == 0, let msgTokens {
                    latestTokens = msgTokens
                }
                let parts: [AppMessagePart] = a.content.enumerated().compactMap { idx, content in
                    switch content {
                    case .text(let t):
                        guard !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        return .text(id: "\(a.id.rawValue)-text-\(idx)", text: t.text)
                    case .reasoning(let r):
                        let cleaned = r.text
                            .replacingOccurrences(of: "[REDACTED]", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleaned.isEmpty else { return nil }
                        return .reasoning(
                            id: "\(a.id.rawValue)-reasoning-\(idx)",
                            text: cleaned,
                            completed: r.time?.completed != nil || a.time.completed != nil
                        )
                    case .tool(let tl):
                        return Self.mapAssistantTool(tl)
                    }
                }
                if !parts.isEmpty || a.error != nil {
                    mapped.append(.assistant(
                        id: a.id.rawValue,
                        agent: TUIUtil.titlecase(a.agent),
                        model: a.model.id,
                        parts: parts,
                        completed: a.time.completed != nil,
                        error: a.error?.message,
                        cost: a.cost,
                        tokens: msgTokens,
                        timestampMs: a.time.created
                    ))
                }

            case .shell(let sh):
                let status: AppToolStatus
                switch sh.status {
                case .running: status = .running
                case .exited: status = (sh.exit ?? 0) == 0 ? .completed : .error
                case .timeout, .killed: status = .error
                }
                mapped.append(.shell(
                    id: sh.id.rawValue,
                    shellID: sh.shellID,
                    command: sh.command,
                    status: status,
                    output: sh.output?.output,
                    exitCode: sh.exit.map(Int.init),
                    timestampMs: sh.time.created
                ))

            case .synthetic(let s):
                mapped.append(.system(id: s.id.rawValue, text: s.text, isError: false, timestampMs: s.time.created))

            case .system(let s):
                mapped.append(.system(id: s.id.rawValue, text: s.text, isError: false, timestampMs: s.time.created))

            case .idle(let idle):
                if let err = idle.error {
                    mapped.append(.system(id: idle.id.rawValue, text: err.message, isError: true, timestampMs: idle.time.created))
                }

            default:
                break
            }
        }

        // Preserve any optimistic user messages or in-flight streaming assistant frames not yet flushed by server
        let serverUserTexts = Set(mapped.compactMap { item -> String? in
            if case .user(_, let text, _, _, _) = item { return text }
            return nil
        })
        let keptOptimistic = messages.filter { item in
            if case .user(_, let text, _, _, let opt) = item, opt {
                return !serverUserTexts.contains(text)
            }
            return false
        }
        let serverIDs = Set(mapped.map(\.id))
        let keptStreaming = messages.filter { item in
            if case .assistant(let id, _, _, let parts, let completed, _, _, _, _) = item,
               !completed, !parts.isEmpty, !serverIDs.contains(id) {
                return true
            }
            return false
        }

        messages = mapped + keptOptimistic + keptStreaming
        if totalCost > 0 { activeSessionCost = max(activeSessionCost, totalCost) }
        if latestTokens > 0 { activeSessionTokens = latestTokens }
    }

    // MARK: - Session Actions

    @discardableResult
    public func createSession(title: String? = nil) async throws -> AppSessionSummary {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        let loc = LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: workspaceDirectory))
        let created = try await client.session.create(SessionCreateInput(
            title: title,
            agent: selectedAgentID,
            model: selectedModel?.ref(variant: selectedVariant),
            location: loc
        ))
        let summary = AppSessionSummary(from: created, badge: .idle)
        sessions.removeAll { $0.id == summary.id }
        sessions.insert(summary, at: 0)
        activeSessionID = summary.id
        messages = []
        activeSessionCost = 0
        activeSessionTokens = 0
        return summary
    }

    public func selectSession(_ sessionID: String) async {
        guard activeSessionID != sessionID || messages.isEmpty else { return }
        activeSessionID = sessionID
        messages = []
        await refreshMessages(for: sessionID)
        await refreshPermissionsAndForms()
        await refreshDiffs()
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenCodeAppStoreError.emptyInput }
        try await client.session.update(SessionUpdateInput(sessionID: sessionID, title: trimmed))
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].title = trimmed
        }
        showToast("Renamed session to \"\(trimmed)\"")
    }

    @discardableResult
    public func forkSession(_ sessionID: String, beforeMessageID: String? = nil) async throws -> AppSessionSummary {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        let forked = try await client.session.fork(SessionForkInput(sessionID: sessionID, before: beforeMessageID))
        let summary = AppSessionSummary(from: forked, badge: .idle)
        sessions.removeAll { $0.id == summary.id }
        sessions.insert(summary, at: 0)
        activeSessionID = summary.id
        await refreshMessages(for: summary.id)
        showToast("Forked session \"\(summary.title)\"")
        return summary
    }

    public func deleteSession(_ sessionID: String) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        try await client.session.remove(SessionRemoveInput(sessionID: sessionID))
        sessions.removeAll { $0.id == sessionID }
        pendingPermissions.removeAll { $0.sessionID == sessionID }
        pendingForms.removeAll { $0.sessionID == sessionID }
        runningSessionIDs.remove(sessionID)
        retryingSessions.removeValue(forKey: sessionID)
        if activeSessionID == sessionID {
            if let next = sessions.first(where: { !$0.archived }) {
                await selectSession(next.id)
            } else {
                activeSessionID = nil
                messages = []
            }
        }
        showToast("Deleted session")
    }

    public func abortActiveSession() async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        guard let sid = activeSessionID else { throw OpenCodeAppStoreError.missingActiveSession }
        _ = try await client.session.interrupt(SessionInterruptInput(sessionID: sid))
        runningSessionIDs.remove(sid)
        retryingSessions.removeValue(forKey: sid)
        syncSessionBadges()
        markActiveAssistantCompleted()
        showToast("Aborted active run")
    }

    public func compactActiveSession() async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        guard let sid = activeSessionID else { throw OpenCodeAppStoreError.missingActiveSession }
        _ = try await client.session.compact(SessionCompactInput(sessionID: sid))
        showToast("Compaction requested")
    }

    // MARK: - Composer, Prompts, Shell (`!`), Slash Commands (`/`) & Mentions (`@`)

    public func submitComposer(_ overrideText: String? = nil) async throws {
        let raw = overrideText ?? composerText
        let parsed = AppCommandRegistry.parseComposerInput(
            raw,
            shellMode: isShellMode,
            knownAgentIDs: Set(agents.map(\.id))
        )

        switch parsed {
        case .empty:
            return

        case .shell(let command):
            composerText = ""
            isShellMode = false
            slashAutocompleteDismissed = false
            mentionAutocompleteDismissed = false
            try await runShellCommand(command)

        case let .slash(name, arguments):
            composerText = ""
            slashAutocompleteDismissed = false
            mentionAutocompleteDismissed = false
            try await executeSlashCommand(name: name, arguments: arguments)

        case let .prompt(text, fileMentions, agentMentions, _):
            composerText = ""
            slashAutocompleteDismissed = false
            mentionAutocompleteDismissed = false
            let fileAttachments: [PromptInputSchema.FileAttachment]? = fileMentions.isEmpty ? nil : fileMentions.map { path in
                let absolute = path.hasPrefix("/") ? path : "\(workspaceDirectory)/\(path)"
                return PromptInputSchema.FileAttachment(uri: "file://\(absolute)", name: path)
            }
            let agentAttachments: [PromptSchema.AgentAttachment]? = agentMentions.isEmpty ? nil : agentMentions.map { name in
                PromptSchema.AgentAttachment(name: name)
            }
            try await sendPrompt(text, files: fileAttachments, agents: agentAttachments)
        }
    }

    public func sendPrompt(
        _ text: String,
        files: [PromptInputSchema.FileAttachment]? = nil,
        agents agentAttachments: [PromptSchema.AgentAttachment]? = nil,
        resume: Bool? = nil
    ) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenCodeAppStoreError.emptyInput }

        isSending = true
        defer { isSending = false }

        let targetID: String
        if let existing = activeSessionID {
            targetID = existing
        } else {
            let created = try await createSession(title: String(trimmed.prefix(48)))
            targetID = created.id
        }

        let msgID = SessionMessageSchema.ID.create().rawValue
        let mentionTags = (agentAttachments ?? []).map { "@\($0.name)" }
            + (files ?? []).compactMap { $0.name.map { "@\($0)" } }
        messages.append(.user(
            id: msgID,
            text: trimmed,
            timestampMs: Flock.currentEpochMs(),
            mentions: mentionTags,
            isOptimistic: true
        ))
        runningSessionIDs.insert(targetID)
        syncSessionBadges()

        do {
            _ = try await client.session.prompt(SessionPromptInput(
                sessionID: targetID,
                id: msgID,
                text: trimmed,
                files: files,
                agents: agentAttachments,
                resume: resume
            ))
        } catch {
            runningSessionIDs.remove(targetID)
            syncSessionBadges()
            showToast("Prompt failed: \(error)", isError: true)
            throw error
        }
    }

    public func runShellCommand(_ command: String) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenCodeAppStoreError.emptyInput }

        let targetID: String
        if let existing = activeSessionID {
            targetID = existing
        } else {
            let created = try await createSession(title: "$ \(String(trimmed.prefix(40)))")
            targetID = created.id
        }

        runningSessionIDs.insert(targetID)
        syncSessionBadges()
        defer {
            runningSessionIDs.remove(targetID)
            syncSessionBadges()
        }

        try await client.session.shell(SessionShellInput(sessionID: targetID, command: trimmed))
        await refreshMessages(for: targetID)
    }

    public func executeSlashCommand(name: String, arguments: String) async throws {
        let normalized = name.lowercased()
        switch normalized {
        case "new":
            _ = try await createSession(title: arguments.isEmpty ? nil : arguments)
        case "fork":
            guard let sid = activeSessionID else { throw OpenCodeAppStoreError.missingActiveSession }
            _ = try await forkSession(sid)
        case "rename":
            guard let sid = activeSessionID else { throw OpenCodeAppStoreError.missingActiveSession }
            if arguments.isEmpty {
                renamingSession = activeSession
            } else {
                try await renameSession(sid, title: arguments)
            }
        case "compact":
            try await compactActiveSession()
        case "abort", "stop":
            try await abortActiveSession()
        case "connect":
            isConnectProviderPresented = true
            await refreshIntegrations()
        case "pair":
            isPairingQRPresented = true
            _ = try? await generatePairingQR()
        case "diff":
            isDiffReviewPresented = true
            await refreshDiffs()
        case "theme":
            if arguments.lowercased() == "light" {
                setThemeMode(.light)
            } else if arguments.lowercased() == "dark" {
                setThemeMode(.dark)
            } else if arguments.lowercased() == "system" {
                setThemeMode(.system)
            } else {
                cycleThemeMode()
            }
        case "settings":
            isSettingsPresented = true
        case "mcp":
            settings.showInspector = true
            selectedInspectorTab = .mcp
            await refreshMCP()
        case "usage":
            settings.showInspector = true
            selectedInspectorTab = .context
            await refreshUsageLimits()
        case "inspector":
            settings.showInspector.toggle()
        case "reload":
            await refreshLiveModels(showToastNotice: false)
            await refreshWorkspace()
            showToast("Workspace refreshed")
        case "refresh-models", "models":
            await refreshLiveModels()
        default:
            guard let client else { throw OpenCodeAppStoreError.notConnected }
            let targetID: String
            if let existing = activeSessionID {
                targetID = existing
            } else {
                let created = try await createSession(title: "/\(name)")
                targetID = created.id
            }
            try await client.session.command(SessionCommandInput(
                sessionID: targetID,
                name: name,
                text: arguments
            ))
            await refreshMessages(for: targetID)
        }
    }

    public func queryMentionFiles(_ query: String) async {
        guard let client else { return }
        guard let resp = try? await client.file.find(FileFindInput(
            location: locationQuery,
            query: query,
            limit: 30
        )) else {
            return
        }
        mentionFilePaths = resp.data.map(\.path.rawValue)
    }

    public func handleComposerTextChanged() {
        slashAutocompleteDismissed = false
        mentionAutocompleteDismissed = false
        if composerText == "!" && !isShellMode {
            isShellMode = true
            composerText = ""
            return
        }
        if let trigger = activeMentionTrigger {
            let query = trigger.query
            mentionTask?.cancel()
            mentionTask = Task { @MainActor [weak self] in
                await self?.queryMentionFiles(query)
            }
        }
    }

    public func applySlashSuggestion(_ item: AppSlashCommandItem) {
        composerText = "\(item.name) "
        slashAutocompleteDismissed = true
    }

    public func applyMentionSuggestion(_ item: AppMentionItem) {
        guard let trigger = activeMentionTrigger else { return }
        composerText = AppCommandRegistry.applyMention(item, to: composerText, trigger: trigger)
        mentionAutocompleteDismissed = true
    }

    // MARK: - Model, Agent, Variant & Provider Actions

    public func selectModel(_ model: AppModelItem, variant: String? = nil) async throws {
        selectedModel = model
        let resolvedVariant = variant ?? (model.variants.contains(selectedVariant ?? "") ? selectedVariant : nil)
        selectedVariant = resolvedVariant
        if let client, let sid = activeSessionID {
            try await client.session.switchModel(SessionSwitchModelInput(
                sessionID: sid,
                model: model.ref(variant: resolvedVariant)
            ))
        }
    }

    public func selectAgent(_ agent: AppAgentItem) async throws {
        selectedAgentID = agent.id
        if let client, let sid = activeSessionID {
            try await client.session.switchAgent(SessionSwitchAgentInput(
                sessionID: sid,
                agent: agent.id
            ))
        }
    }

    public func selectVariant(_ variant: String?) async throws {
        selectedVariant = variant
        if let model = selectedModel {
            try await selectModel(model, variant: variant)
        }
    }

    public func connectProviderAPIKey(
        integrationID: String,
        apiKey: String,
        answer: FormSchema.Answer? = nil,
        label: String? = nil
    ) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenCodeAppStoreError.emptyInput }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.integration.connect.key(IntegrationConnectKeyInput(
            integrationID: integrationID,
            location: locationQuery,
            key: trimmedKey,
            answer: answer,
            label: (trimmedLabel?.isEmpty == true) ? nil : trimmedLabel
        ))
        await refreshIntegrations()
        await refreshModelsAndProviders()
        showToast("Connected \(integrationID)")
    }

    public func connectProviderExternal(
        integrationID: String,
        methodID: String,
        answer: FormSchema.Answer? = nil,
        label: String? = nil
    ) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.integration.connect.external(IntegrationConnectExternalInput(
            integrationID: integrationID,
            location: locationQuery,
            methodID: methodID,
            answer: answer,
            label: (trimmedLabel?.isEmpty == true) ? nil : trimmedLabel
        ))
        await refreshLiveModels(showToastNotice: false)
        let displayName = integrationCatalog[integrationID]?.name
            ?? integrations.first(where: { $0.id == integrationID })?.name
            ?? integrationID
        showToast("Connected \(displayName)")
    }

    // MARK: - Interactive OAuth Sign-In

    /// Starts an interactive OAuth sign-in flow (`POST /api/integration/:id/connect/oauth`),
    /// automatically opens the authorization URL via `urlOpener`, and polls
    /// `GET /api/integration/:id/connect/oauth/:attemptID` in a cancellable background `Task`.
    @discardableResult
    public func startOAuth(
        integrationID: String,
        methodID: String,
        answer: FormSchema.Answer? = nil,
        label: String? = nil
    ) async throws -> AppOAuthAttempt {
        guard let client else { throw OpenCodeAppStoreError.notConnected }

        if activeOAuthAttempt != nil {
            await cancelOAuth(notifyServer: true)
        }

        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await client.integration.oauth.connect(IntegrationOauthConnectInput(
            integrationID: integrationID,
            location: locationQuery,
            methodID: methodID,
            answer: answer,
            label: (trimmedLabel?.isEmpty == true) ? nil : trimmedLabel
        ))
        let attempt = response.data
        let integrationName = integrationCatalog[integrationID]?.name
            ?? integrations.first(where: { $0.id == integrationID })?.name
            ?? TUIUtil.titlecase(integrationID)

        let opened = openExternalURL(attempt.url)
        let initialStatus: String
        if attempt.mode == .code {
            initialStatus = opened
                ? "Browser opened. Complete sign-in and paste the authorization code below."
                : "Open the authorization URL in your browser and paste the authorization code below."
        } else {
            initialStatus = opened
                ? "Waiting for authorization in your browser…"
                : "Open the authorization URL in your browser to finish signing in…"
        }

        let active = AppOAuthAttempt(
            integrationID: integrationID,
            integrationName: integrationName,
            methodID: methodID,
            attemptID: attempt.attemptID.rawValue,
            url: attempt.url,
            instructions: attempt.instructions,
            mode: attempt.mode,
            supportsPaste: attempt.paste == true,
            statusMessage: initialStatus,
            isPolling: true,
            errorMessage: nil
        )
        activeOAuthAttempt = active
        startOAuthPolling(for: active)
        return active
    }

    /// Submits a manually pasted OAuth authorization code or redirect URL for the active OAuth attempt
    /// (`POST /api/integration/:id/connect/oauth/:attemptID/complete`).
    public func completeOAuth(code: String) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        guard let current = activeOAuthAttempt else {
            throw OpenCodeAppStoreError.noActiveOAuthAttempt
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenCodeAppStoreError.emptyInput }

        let attemptID = current.attemptID
        let integrationID = current.integrationID
        let integrationName = current.integrationName

        activeOAuthAttempt?.errorMessage = nil
        activeOAuthAttempt?.statusMessage = "Completing sign-in…"

        do {
            try await client.integration.oauth.complete(IntegrationOauthCompleteInput(
                integrationID: integrationID,
                attemptID: attemptID,
                location: locationQuery,
                code: trimmed
            ))
            await handleOAuthCompleted(
                integrationID: integrationID,
                integrationName: integrationName,
                attemptID: attemptID
            )
        } catch {
            if activeOAuthAttempt?.attemptID == attemptID {
                activeOAuthAttempt?.errorMessage = String(describing: error)
                activeOAuthAttempt?.statusMessage = "Unable to complete sign-in with that code."
            }
            showToast("OAuth completion failed: \(error)", isError: true)
            throw error
        }
    }

    /// Cancels the active OAuth attempt, stops background polling, and notifies the server
    /// (`DELETE /api/integration/:id/connect/oauth/:attemptID`).
    public func cancelOAuth() async {
        await cancelOAuth(notifyServer: true)
    }

    private func cancelOAuth(notifyServer: Bool) async {
        oauthPollTask?.cancel()
        oauthPollTask = nil
        let previous = activeOAuthAttempt
        activeOAuthAttempt = nil

        if notifyServer, let client, let previous {
            try? await client.integration.oauth.cancel(IntegrationOauthCancelInput(
                integrationID: previous.integrationID,
                attemptID: previous.attemptID,
                location: locationQuery
            ))
        }
    }

    private func startOAuthPolling(for attempt: AppOAuthAttempt) {
        oauthPollTask?.cancel()
        let attemptID = attempt.attemptID
        let integrationID = attempt.integrationID
        let integrationName = attempt.integrationName
        let pollInterval = oauthPollInterval

        oauthPollTask = Task { @MainActor [weak self] in
            var consecutiveErrors = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
                guard let self,
                      let client = self.client,
                      let current = self.activeOAuthAttempt,
                      current.attemptID == attemptID
                else {
                    return
                }

                do {
                    let response = try await client.integration.oauth.status(IntegrationOauthStatusInput(
                        integrationID: integrationID,
                        attemptID: attemptID,
                        location: self.locationQuery
                    ))
                    consecutiveErrors = 0
                    guard !Task.isCancelled,
                          self.activeOAuthAttempt?.attemptID == attemptID
                    else {
                        return
                    }

                    switch response.data {
                    case .pending:
                        continue

                    case .complete:
                        await self.handleOAuthCompleted(
                            integrationID: integrationID,
                            integrationName: integrationName,
                            attemptID: attemptID
                        )
                        return

                    case .failed(let message, _):
                        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalError = detail.isEmpty ? "Authorization failed." : detail
                        self.activeOAuthAttempt?.isPolling = false
                        self.activeOAuthAttempt?.errorMessage = finalError
                        self.activeOAuthAttempt?.statusMessage = "Authorization failed."
                        self.showToast("Sign-in failed for \(integrationName): \(finalError)", isError: true)
                        return

                    case .expired:
                        let expiredMessage = "Authorization expired. Please start sign-in again."
                        self.activeOAuthAttempt?.isPolling = false
                        self.activeOAuthAttempt?.errorMessage = expiredMessage
                        self.activeOAuthAttempt?.statusMessage = "Authorization expired."
                        self.showToast("Sign-in expired for \(integrationName)", isError: true)
                        return
                    }
                } catch {
                    if Task.isCancelled { return }
                    if isIntegrationAttemptNotFoundError(error) {
                        self.activeOAuthAttempt?.isPolling = false
                        self.activeOAuthAttempt?.errorMessage = "Authorization session expired or was closed."
                        self.activeOAuthAttempt?.statusMessage = "Authorization closed."
                        return
                    }
                    consecutiveErrors += 1
                    if consecutiveErrors >= 5 {
                        let errText = String(describing: error)
                        self.activeOAuthAttempt?.isPolling = false
                        self.activeOAuthAttempt?.errorMessage = errText
                        self.activeOAuthAttempt?.statusMessage = "Unable to check authorization status."
                        self.showToast("OAuth polling failed: \(errText)", isError: true)
                        return
                    }
                }
            }
        }
    }

    private func handleOAuthCompleted(
        integrationID: String,
        integrationName: String,
        attemptID: String
    ) async {
        oauthPollTask?.cancel()
        oauthPollTask = nil
        if activeOAuthAttempt?.attemptID == attemptID {
            activeOAuthAttempt?.isPolling = false
            activeOAuthAttempt?.errorMessage = nil
            activeOAuthAttempt?.statusMessage = "Connected to \(integrationName)! Refreshing models…"
        }
        await refreshLiveModels(showToastNotice: false)
        if activeOAuthAttempt?.attemptID == attemptID {
            activeOAuthAttempt = nil
        }
        showToast("Connected \(integrationName)")
    }

    // MARK: - Permissions & Forms

    public func replyPermission(
        _ request: AppPermissionItem,
        decision: PermissionSchema.Reply,
        message: String? = nil
    ) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        let trimmedFeedback = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let feedback = (trimmedFeedback?.isEmpty == false) ? trimmedFeedback : nil
        do {
            try await client.permission.reply(PermissionReplyInput(
                sessionID: request.sessionID,
                requestID: request.id,
                decision: decision,
                message: feedback
            ))
        } catch {
            if !isPermissionNotFoundError(error) {
                showToast("Permission reply failed: \(error)", isError: true)
                throw error
            }
        }
        pendingPermissions.removeAll { $0.id == request.id }
        syncSessionBadges()
    }

    public func replyForm(_ form: AppFormItem, answer: FormSchema.Answer) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        do {
            try await client.session.form.reply(SessionFormReplyInput(
                sessionID: form.sessionID,
                formID: form.id,
                answer: answer
            ))
        } catch {
            if extractFormNotFoundError(error) == nil && extractFormAlreadySettledError(error) == nil {
                showToast("Form submission failed: \(error)", isError: true)
                throw error
            }
        }
        pendingForms.removeAll { $0.id == form.id }
        if activeFormSheet?.id == form.id {
            activeFormSheet = pendingForms.first
        }
        syncSessionBadges()
    }

    public func cancelForm(_ form: AppFormItem, message: String? = nil) async throws {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        do {
            try await client.session.form.cancel(SessionFormCancelInput(
                sessionID: form.sessionID,
                formID: form.id,
                message: message
            ))
        } catch {
            if extractFormNotFoundError(error) == nil && extractFormAlreadySettledError(error) == nil {
                showToast("Form cancel failed: \(error)", isError: true)
                throw error
            }
        }
        pendingForms.removeAll { $0.id == form.id }
        if activeFormSheet?.id == form.id {
            activeFormSheet = pendingForms.first
        }
        syncSessionBadges()
    }

    // MARK: - Pairing QR Generation

    @discardableResult
    public func generatePairingQR() async throws -> AppPairingPayload {
        guard let client else { throw OpenCodeAppStoreError.notConnected }
        pairingError = nil
        do {
            async let infoTask = client.server.info()
            async let pairTask = client.server.pair()
            let serverInfo = try await infoTask
            let pairCode = try await pairTask
            let urls = serverInfo.urls.isEmpty ? [serverURL] : serverInfo.urls
            let payload = try AppPairingPayload.make(
                code: pairCode.code,
                baseURLs: urls,
                expiresInSeconds: pairCode.expiresIn
            )
            pairingPayload = payload
            return payload
        } catch {
            pairingError = String(describing: error)
            throw error
        }
    }

    // MARK: - Theme & Settings

    public func setThemeMode(_ mode: AppThemeMode) {
        settings.themeMode = mode
    }

    public func cycleThemeMode() {
        settings.themeMode = settings.themeMode.nextMode
    }

    public func setThemeName(_ name: String) {
        settings.themeName = name
    }

    public func toggleConcealMarkdown() {
        settings.concealMarkdown.toggle()
    }

    public func updateSystemAppearance(isDark: Bool) {
        if systemIsDark != isDark {
            systemIsDark = isDark
        }
    }

    // MARK: - Command Palette Dispatch

    public func executeCommand(_ commandID: AppCommandID) async {
        isCommandPalettePresented = false
        switch commandID {
        case .newSession:
            _ = try? await createSession()
        case .renameSession:
            renamingSession = activeSession
        case .forkSession:
            if let sid = activeSessionID {
                _ = try? await forkSession(sid)
            }
        case .deleteSession:
            if let sid = activeSessionID {
                try? await deleteSession(sid)
            }
        case .abortSession:
            try? await abortActiveSession()
        case .compactSession:
            try? await compactActiveSession()
        case .connectProvider:
            isConnectProviderPresented = true
            await refreshIntegrations()
        case .pairDevice:
            isPairingQRPresented = true
            _ = try? await generatePairingQR()
        case .openSettings:
            isSettingsPresented = true
            await refreshMCP()
        case .openDiffReview:
            isDiffReviewPresented = true
            await refreshDiffs()
        case .toggleThemeMode:
            cycleThemeMode()
            showToast("Theme mode: \(settings.themeMode.displayName)")
        case .toggleInspector:
            settings.showInspector.toggle()
        case .toggleShellMode:
            isShellMode.toggle()
        case .showContextInspector:
            settings.showInspector = true
            selectedInspectorTab = .context
            await refreshUsageLimits()
        case .showTodosInspector:
            settings.showInspector = true
            selectedInspectorTab = .todos
        case .showMCPInspector:
            settings.showInspector = true
            selectedInspectorTab = .mcp
            await refreshMCP()
        case .showDiffsInspector:
            settings.showInspector = true
            selectedInspectorTab = .diffs
            await refreshDiffs()
        case .refreshWorkspace:
            await refreshWorkspace()
            showToast("Workspace refreshed")
        case .connectRemoteServer:
            isRemoteConnectPresented = true
        }
    }

    public func showToast(_ message: String, isError: Bool = false) {
        toast = AppToastNotice(message: message, isError: isError)
    }

    public func dismissToast() {
        toast = nil
    }

    // MARK: - Internal Helpers

    private func badgeForSession(_ sessionID: String) -> AppSessionStatusBadge {
        let permCount = pendingPermissions.filter { $0.sessionID == sessionID }.count
        let formCount = pendingForms.filter { $0.sessionID == sessionID }.count
        if permCount > 0 || formCount > 0 {
            return .blocked(permissions: permCount, forms: formCount)
        }
        if let retryMsg = retryingSessions[sessionID] {
            return .retrying(retryMsg)
        }
        if runningSessionIDs.contains(sessionID) {
            return .working
        }
        return .idle
    }

    private func syncSessionBadges() {
        for idx in sessions.indices {
            sessions[idx].badge = badgeForSession(sessions[idx].id)
        }
    }

    private func ensureAssistantMessage(id: String, agent: String, model: String, timestampMs: Int64) {
        if messages.contains(where: { $0.id == id }) { return }
        messages.append(.assistant(
            id: id,
            agent: agent,
            model: model,
            parts: [],
            completed: false,
            error: nil,
            cost: nil,
            tokens: nil,
            timestampMs: timestampMs
        ))
    }

    private func upsertAssistantPart(
        messageID: String,
        partID: String,
        timestampMs: Int64,
        transform: (AppMessagePart?) -> AppMessagePart
    ) {
        if let idx = messages.lastIndex(where: {
            if case .assistant(let id, _, _, _, _, _, _, _, _) = $0 { return id == messageID }
            return false
        }) {
            if case let .assistant(id, agent, model, oldParts, completed, err, cost, tokens, ts) = messages[idx] {
                var parts = oldParts
                if let pIdx = parts.firstIndex(where: { $0.id == partID }) {
                    parts[pIdx] = transform(parts[pIdx])
                } else {
                    parts.append(transform(nil))
                }
                messages[idx] = .assistant(
                    id: id,
                    agent: agent,
                    model: model,
                    parts: parts,
                    completed: completed,
                    error: err,
                    cost: cost,
                    tokens: tokens,
                    timestampMs: ts
                )
            }
        } else {
            let part = transform(nil)
            messages.append(.assistant(
                id: messageID,
                agent: activeAgent.name,
                model: selectedModel?.name ?? selectedModel?.modelID ?? "",
                parts: [part],
                completed: false,
                error: nil,
                cost: nil,
                tokens: nil,
                timestampMs: timestampMs
            ))
        }
    }

    private func finalizeAssistantMessage(id: String?, cost: Double?, tokens: Int?) {
        let targetIdx: Int?
        if let id {
            targetIdx = messages.lastIndex { $0.id == id }
        } else {
            targetIdx = messages.lastIndex {
                if case .assistant(_, _, _, _, let completed, _, _, _, _) = $0 { return !completed }
                return false
            }
        }
        guard let idx = targetIdx,
              case let .assistant(aid, agent, model, parts, _, err, prevCost, prevTokens, ts) = messages[idx]
        else { return }
        let finalizedParts = parts.map { part -> AppMessagePart in
            if case .reasoning(let pid, let text, _) = part {
                return .reasoning(id: pid, text: text, completed: true)
            }
            return part
        }
        messages[idx] = .assistant(
            id: aid,
            agent: agent,
            model: model,
            parts: finalizedParts,
            completed: true,
            error: err,
            cost: cost ?? prevCost,
            tokens: tokens ?? prevTokens,
            timestampMs: ts
        )
    }

    private func markActiveAssistantCompleted() {
        finalizeAssistantMessage(id: nil, cost: nil, tokens: nil)
    }

    private static func mapAssistantTool(_ tool: SessionMessageSchema.AssistantTool) -> AppMessagePart {
        switch tool.state {
        case .streaming(let s):
            return .tool(
                id: tool.id,
                name: tool.name,
                status: .streaming,
                summary: String(s.input.prefix(80)),
                inputJSON: s.input.isEmpty ? nil : s.input,
                output: nil,
                error: nil
            )
        case .running(let r):
            let inputStr = r.input.isEmpty ? nil : (try? ClientCodec.encodeString(JSONValue.object(r.input)))
            return .tool(
                id: tool.id,
                name: tool.name,
                status: .running,
                summary: TUIInteractiveClient.summarizeToolInput(r.input),
                inputJSON: inputStr,
                output: nil,
                error: nil
            )
        case .completed(let c):
            let inputStr = c.input.isEmpty ? nil : (try? ClientCodec.encodeString(JSONValue.object(c.input)))
            let textOut = c.content.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            return .tool(
                id: tool.id,
                name: tool.name,
                status: .completed,
                summary: TUIInteractiveClient.summarizeToolInput(c.input),
                inputJSON: inputStr,
                output: textOut.isEmpty ? nil : textOut,
                error: nil
            )
        case .error(let e):
            let inputStr = e.input.isEmpty ? nil : (try? ClientCodec.encodeString(JSONValue.object(e.input)))
            return .tool(
                id: tool.id,
                name: tool.name,
                status: .error,
                summary: TUIInteractiveClient.summarizeToolInput(e.input),
                inputJSON: inputStr,
                output: nil,
                error: e.error.message
            )
        }
    }

    // MARK: - JSON Extraction Helpers

    private static func jsonObject(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let dict) = value else { return [:] }
        return dict
    }

    private static func stringField(_ dict: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s) = dict[key] { return s }
        return nil
    }

    private static func intField(_ dict: [String: JSONValue], _ key: String) -> Int? {
        switch dict[key] {
        case .int(let i): return Int(i)
        case .double(let d) where d.isFinite: return Int(d)
        default: return nil
        }
    }

    private static func doubleField(_ dict: [String: JSONValue], _ key: String) -> Double? {
        switch dict[key] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    private static func stringArrayField(_ dict: [String: JSONValue], _ key: String) -> [String]? {
        guard case .array(let arr) = dict[key] else { return nil }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    private static func extractToolOutputText(_ value: JSONValue?) -> String? {
        guard case .array(let items) = value else { return nil }
        let texts = items.compactMap { item -> String? in
            stringField(jsonObject(item), "text")
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func extractTotalTokens(_ dict: [String: JSONValue]) -> Int? {
        let input = intField(dict, "input") ?? 0
        let output = intField(dict, "output") ?? 0
        let reasoning = intField(dict, "reasoning") ?? 0
        let cacheObj = jsonObject(dict["cache"])
        let cacheRead = intField(cacheObj, "read") ?? 0
        let cacheWrite = intField(cacheObj, "write") ?? 0
        let total = input + output + reasoning + cacheRead + cacheWrite
        return total > 0 ? total : nil
    }
}
