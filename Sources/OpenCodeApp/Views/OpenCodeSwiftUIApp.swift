import Foundation
import OpenCodePlatform

/// Launch configuration parsed from command-line arguments and environment variables.
public struct OpenCodeAppLaunchConfiguration: Equatable, Sendable {
    public let serverURL: String?
    public let credentials: AppServerCredentials
    public let workspaceDirectory: String?

    public init(
        serverURL: String? = nil,
        credentials: AppServerCredentials = .none,
        workspaceDirectory: String? = nil
    ) {
        self.serverURL = serverURL
        self.credentials = credentials
        self.workspaceDirectory = workspaceDirectory
    }

    /// Parses `--server <url>`, `--dir <path>`, `OPENCODE_SERVER_URL`, `OPENCODE_SERVER_USERNAME`,
    /// `OPENCODE_SERVER_PASSWORD`, and `OPENCODE_SERVER_TOKEN` from process arguments & environment.
    public static func fromProcess(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OpenCodeAppLaunchConfiguration {
        var serverURL = environment["OPENCODE_SERVER_URL"]
        var directory = environment["OPENCODE_WORKSPACE_DIR"]

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if (arg == "--server" || arg == "-s"), i + 1 < arguments.count {
                serverURL = arguments[i + 1]
                i += 2
                continue
            }
            if (arg == "--dir" || arg == "--directory" || arg == "-d"), i + 1 < arguments.count {
                directory = arguments[i + 1]
                i += 2
                continue
            }
            i += 1
        }

        let credentials: AppServerCredentials
        if let token = environment["OPENCODE_SERVER_TOKEN"], !token.isEmpty {
            credentials = .bearer(token: token)
        } else if let password = environment["OPENCODE_SERVER_PASSWORD"], !password.isEmpty {
            let username = environment["OPENCODE_SERVER_USERNAME"] ?? "opencode"
            credentials = .basic(username: username, password: password)
        } else {
            credentials = .none
        }

        return OpenCodeAppLaunchConfiguration(
            serverURL: serverURL,
            credentials: credentials,
            workspaceDirectory: directory
        )
    }
}

#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Native SwiftUI `App` hosting `OpenCodeRootView`, menu commands, and automatic SDK/remote bootstrap.
public struct OpenCodeSwiftUIApp: App {
    @State private var store = OpenCodeAppStore()
    private let launchConfig = OpenCodeAppLaunchConfiguration.fromProcess()

    public init() {
        #if canImport(AppKit) && os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        if let dockIcon = OpenCodeIdentityAssets.nsImage(size: .px512, lightMode: false) {
            NSApplication.shared.applicationIconImage = dockIcon
        }
        NSApplication.shared.activate()
        #endif
    }

    public var body: some Scene {
        WindowGroup("OpenCode") {
            OpenCodeRootView(store: store)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    guard store.connectionState == .disconnected else { return }
                    if let remote = launchConfig.serverURL, !remote.isEmpty {
                        try? await store.connectRemote(
                            url: remote,
                            credentials: launchConfig.credentials
                        )
                    } else {
                        try? await store.connectEmbedded(directory: launchConfig.workspaceDirectory)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    Task { _ = try? await store.createSession() }
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("OpenCode") {
                Button("Command Palette…") {
                    store.isCommandPalettePresented = true
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Quick Command Picker…") {
                    store.isCommandPalettePresented = true
                }
                .keyboardShortcut("p", modifiers: .command)

                Divider()

                Button("Connect Provider…") {
                    store.isConnectProviderPresented = true
                }

                Button("Review Diffs…") {
                    store.isDiffReviewPresented = true
                    Task { await store.refreshDiffs() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Pair Device (QR Code)…") {
                    store.isPairingQRPresented = true
                    Task { _ = try? await store.generatePairingQR() }
                }
                .keyboardShortcut("q", modifiers: [.command, .shift])

                Button("Server Connection…") {
                    store.isRemoteConnectPresented = true
                }

                Divider()

                Button("Abort Active Run") {
                    Task { try? await store.abortActiveSession() }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!store.isActiveSessionWorking)

                Button("Toggle Inspector") {
                    store.settings.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("Cycle Theme Mode") {
                    store.cycleThemeMode()
                }

                Button("Settings…") {
                    store.isSettingsPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
#endif
