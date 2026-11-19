#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI

/// Primary native OpenCode SwiftUI workspace view using `NavigationSplitView`
/// (workspace/session sidebar, rich conversation + composer detail, and optional right inspector).
public struct OpenCodeRootView: View {
    @Bindable public var store: OpenCodeAppStore
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 265, max: 340)
        } detail: {
            VStack(spacing: 0) {
                SessionConversationView(store: store)
                Divider().overlay(palette.borderColor.opacity(0.45))
                ComposerView(store: store)
            }
            .background(palette.backgroundColor)
            .navigationTitle(store.activeSession?.title ?? "OpenCode")
            .toolbar {
                workspaceToolbar
            }
        }
        .inspector(isPresented: $store.settings.showInspector) {
            WorkspaceInspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .preferredColorScheme(AppResolvedPalette.preferredColorScheme(for: store.settings.themeMode))
        .onAppear {
            store.updateSystemAppearance(isDark: systemColorScheme == .dark)
        }
        .onChange(of: systemColorScheme) { _, next in
            store.updateSystemAppearance(isDark: next == .dark)
        }
        .sheet(isPresented: $store.isCommandPalettePresented) {
            CommandPaletteSheet(store: store)
        }
        .sheet(isPresented: $store.isConnectProviderPresented) {
            ConnectProviderSheet(store: store)
        }
        .sheet(isPresented: $store.isPairingQRPresented) {
            PairingQRSheet(store: store)
        }
        .sheet(isPresented: $store.isSettingsPresented) {
            SettingsSheet(store: store)
        }
        .sheet(isPresented: $store.isDiffReviewPresented) {
            DiffReviewView(store: store)
        }
        .sheet(isPresented: $store.isRemoteConnectPresented) {
            RemoteServerSheet(store: store)
        }
        .sheet(item: $store.activeFormSheet) { form in
            FormPromptSheet(store: store, form: form)
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                toastOverlay(toast)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if let branch = store.gitBranch, !branch.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                    Text(branch)
                        .font(.caption.monospaced())
                }
                .foregroundStyle(palette.infoColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.infoColor.opacity(0.12), in: Capsule())
            }

            Button {
                store.isDiffReviewPresented = true
                Task { await store.refreshDiffs() }
            } label: {
                Label("Diffs", systemImage: "doc.text.magnifyingglass")
            }
            .help("Review Diffs (⇧⌘D)")

            Button {
                store.isPairingQRPresented = true
                Task { _ = try? await store.generatePairingQR() }
            } label: {
                Label("Pair", systemImage: "qrcode")
            }
            .help("Pair Device with QR Code (⇧⌘Q)")

            Button {
                store.isCommandPalettePresented = true
            } label: {
                Label("Commands", systemImage: "command")
            }
            .help("Command Palette (⌘K)")

            Button {
                store.isSettingsPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")

            Button {
                store.settings.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle Workspace Inspector (⌥⌘I)")
        }
    }

    private func toastOverlay(_ toast: AppToastNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? palette.errorColor : palette.successColor)
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(palette.textPrimaryColor)
            Button {
                store.dismissToast()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(palette.textMutedColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.dialogBackgroundColor, in: Capsule())
        .overlay(Capsule().stroke(palette.borderColor.opacity(0.6), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
    }
}
#endif
