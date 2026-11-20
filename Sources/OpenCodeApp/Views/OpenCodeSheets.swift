#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import OpenCodeSchema
import OpenCodeUtil
import SwiftUI

// MARK: - 1. Command Palette Sheet (`Cmd+K` / `Cmd+P`)

public struct CommandPaletteSheet: View {
    private enum PaletteEntry: Identifiable {
        case builtIn(AppCommandItem)
        case refreshModels

        var id: String {
            switch self {
            case .builtIn(let item): return item.id.rawValue
            case .refreshModels: return "refreshLiveModels"
            }
        }

        var title: String {
            switch self {
            case .builtIn(let item): return item.title
            case .refreshModels: return "Refresh Models"
            }
        }

        var subtitle: String {
            switch self {
            case .builtIn(let item): return item.subtitle
            case .refreshModels: return "Reload ModelsDev, OpenCode Console, and connected provider catalogs"
            }
        }

        var systemImage: String {
            switch self {
            case .builtIn(let item): return item.systemImage
            case .refreshModels: return "arrow.triangle.2.circlepath"
            }
        }

        var slashAlias: String? {
            switch self {
            case .builtIn(let item): return item.slashAlias
            case .refreshModels: return "/refresh-models"
            }
        }

        var shortcutHint: String? {
            switch self {
            case .builtIn(let item): return item.shortcutHint
            case .refreshModels: return nil
            }
        }
    }

    @Bindable public var store: OpenCodeAppStore
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    private var results: [PaletteEntry] {
        var entries = AppCommandRegistry.filterCommands(query: query).map(PaletteEntry.builtIn)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let refreshKeywords = ["refresh", "models", "model", "catalog", "modelsdev", "console", "provider", "providers", "reload", "sync", "/refresh-models"]
        let matchesRefresh = needle.isEmpty
            || "refresh models".contains(needle)
            || refreshKeywords.contains(where: { $0.contains(needle) || needle.contains($0) })
        if matchesRefresh {
            if needle.contains("model") || needle == "refresh models" || needle == "/refresh-models" {
                entries.insert(.refreshModels, at: 0)
            } else if let idx = entries.firstIndex(where: {
                if case .builtIn(let cmd) = $0 { return cmd.id == .connectProvider }
                return false
            }) {
                entries.insert(.refreshModels, at: idx + 1)
            } else {
                entries.append(.refreshModels)
            }
        }
        return entries
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.textMutedColor)
                TextField("Type a command or search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(palette.textPrimaryColor)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = results.first {
                            run(first)
                        }
                    }
                Button("Esc") {
                    store.isCommandPalettePresented = false
                }
                .font(.caption.monospaced())
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(14)
            .background(palette.surfaceRaisedColor)

            Divider().overlay(palette.borderColor.opacity(0.45))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if results.isEmpty {
                        Text("No matching commands for \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(palette.textMutedColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        ForEach(results) { cmd in
                            Button {
                                run(cmd)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: cmd.systemImage)
                                        .font(.callout)
                                        .foregroundStyle(palette.accentColor)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cmd.title)
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(palette.textPrimaryColor)
                                        Text(cmd.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(palette.textMutedColor)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if let alias = cmd.slashAlias {
                                        Text(alias)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(palette.textFaintColor)
                                    }
                                    if let shortcut = cmd.shortcutHint {
                                        Text(shortcut)
                                            .font(.caption2.monospaced().weight(.semibold))
                                            .foregroundStyle(palette.textMutedColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(palette.surfaceHighColor, in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(palette.dialogBackgroundColor)
        .frame(minWidth: 520, minHeight: 380)
        .onAppear { searchFocused = true }
    }

    private func run(_ entry: PaletteEntry) {
        switch entry {
        case .builtIn(let cmd):
            Task { await store.executeCommand(cmd.id) }
        case .refreshModels:
            store.isCommandPalettePresented = false
            Task { await store.refreshLiveModels() }
        }
    }
}

// MARK: - 2. Connect Provider Sheet

public struct ConnectProviderSheet: View {
    @Bindable public var store: OpenCodeAppStore
    @State private var selectedProviderID: String = "opencode"
    @State private var providerSearch: String = ""
    @State private var apiKey: String = ""
    @State private var label: String = ""
    @State private var manualOAuthCode: String = ""
    @State private var isSubmitting = false
    @State private var activeActionMethodID: String? = nil
    @State private var isCompletingOAuth = false
    @State private var copiedOAuthCode = false
    @State private var copiedOAuthLink = false
    @State private var errorMessage: String? = nil

    // Per-method inline FormSchema.Fields draft state keyed by "<provider>::<method>::<fieldKey>"
    @State private var methodStringValues: [String: String] = [:]
    @State private var methodMultiValues: [String: Set<String>] = [:]
    @State private var methodBoolValues: [String: Bool] = [:]
    @State private var methodCustomValues: [String: String] = [:]

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    private var allProviderChoices: [AppProviderIntegration] {
        if !store.integrations.isEmpty {
            return store.integrations
        }
        return [
            AppProviderIntegration(id: "opencode", name: "OpenCode Console"),
            AppProviderIntegration(id: "anthropic", name: "Anthropic"),
            AppProviderIntegration(id: "openai", name: "OpenAI"),
            AppProviderIntegration(id: "google", name: "Google Gemini"),
            AppProviderIntegration(id: "github-copilot", name: "GitHub Copilot"),
            AppProviderIntegration(id: "openrouter", name: "OpenRouter"),
            AppProviderIntegration(id: "xai", name: "xAI"),
            AppProviderIntegration(id: "poe", name: "Poe"),
            AppProviderIntegration(id: "digitalocean", name: "DigitalOcean"),
            AppProviderIntegration(id: "gitlab", name: "GitLab Duo"),
        ]
    }

    private var filteredProviderChoices: [AppProviderIntegration] {
        let needle = providerSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return allProviderChoices }
        let matched = allProviderChoices.filter {
            $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
        }
        if matched.isEmpty, let selected = allProviderChoices.first(where: { $0.id == selectedProviderID }) {
            return [selected]
        }
        return matched
    }

    private var selectedProvider: AppProviderIntegration? {
        allProviderChoices.first(where: { $0.id == selectedProviderID }) ?? allProviderChoices.first
    }

    private var selectedMethods: [IntegrationSchema.Method] {
        store.authMethods(for: selectedProviderID)
    }

    private var oauthMethods: [IntegrationSchema.OAuthMethod] {
        selectedMethods.compactMap { method in
            if case .oauth(let oauth) = method { return oauth }
            return nil
        }
    }

    private var keyMethods: [IntegrationSchema.KeyMethod] {
        let explicit = selectedMethods.compactMap { method -> IntegrationSchema.KeyMethod? in
            if case .key(let keyMethod) = method { return keyMethod }
            return nil
        }
        if !explicit.isEmpty { return explicit }
        if selectedMethods.isEmpty && (selectedProvider?.supportsAPIKey ?? true) {
            return [IntegrationSchema.KeyMethod(label: "API Key")]
        }
        return []
    }

    private var externalMethods: [IntegrationSchema.ExternalMethod] {
        selectedMethods.compactMap { method in
            if case .external(let ext) = method { return ext }
            return nil
        }
    }

    private var envVarNames: [String] {
        var names: [String] = []
        for method in selectedMethods {
            if case .env(let envMethod) = method {
                for name in envMethod.names where !names.contains(name) {
                    names.append(name)
                }
            }
        }
        for name in selectedProvider?.envVars ?? [] where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private var selectedProviderModelCount: Int {
        store.models.filter { $0.providerID == selectedProviderID }.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().overlay(palette.borderColor.opacity(0.4))

            if let attempt = store.activeOAuthAttempt {
                oauthProgressView(attempt)
            } else {
                providerMethodsView
            }
        }
        .background(palette.dialogBackgroundColor)
        .frame(minWidth: 540, minHeight: 480)
        .onAppear {
            if let first = allProviderChoices.first(where: { !$0.isConnected }) ?? allProviderChoices.first {
                selectedProviderID = first.id
            }
            seedDefaultsForSelectedProvider()
            Task {
                if store.integrations.isEmpty {
                    await store.refreshIntegrations()
                    if let first = allProviderChoices.first(where: { !$0.isConnected }) ?? allProviderChoices.first {
                        selectedProviderID = first.id
                    }
                    seedDefaultsForSelectedProvider()
                }
            }
        }
        .onChange(of: selectedProviderID) { _, _ in
            errorMessage = nil
            apiKey = ""
            seedDefaultsForSelectedProvider()
        }
        .onChange(of: store.activeOAuthAttempt?.attemptID) { _, next in
            if next == nil {
                manualOAuthCode = ""
                isCompletingOAuth = false
                copiedOAuthCode = false
                copiedOAuthLink = false
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: store.activeOAuthAttempt != nil ? "person.badge.key.fill" : "key.fill")
                .font(.title3)
                .foregroundStyle(palette.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.activeOAuthAttempt != nil ? "OAuth Sign-In" : "Connect Provider")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimaryColor)
                Text(
                    store.activeOAuthAttempt != nil
                        ? "Complete sign-in in your browser or paste the authorization code."
                        : "Sign in with OAuth, enter an API key, or link external credentials."
                )
                .font(.caption)
                .foregroundStyle(palette.textMutedColor)
            }
            Spacer()
            Button {
                Task { await store.refreshLiveModels() }
            } label: {
                if store.isRefreshingModels {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Refreshing…")
                    }
                } else {
                    Label("Refresh Models", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isRefreshingModels)

            Button("Close") {
                if store.activeOAuthAttempt != nil {
                    Task {
                        await store.cancelOAuth()
                        store.isConnectProviderPresented = false
                    }
                } else {
                    store.isConnectProviderPresented = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .background(palette.surfaceRaisedColor)
    }

    // MARK: - Active OAuth Progress View

    private func oauthProgressView(_ attempt: AppOAuthAttempt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signing in to \(attempt.integrationName)")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(palette.textPrimaryColor)
                            Text("Method: \(attempt.methodID)")
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.textMutedColor)
                        }
                        Spacer()
                        if attempt.isPolling {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for browser…")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(palette.infoColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(palette.infoColor.opacity(0.12), in: Capsule())
                        }
                    }

                    // Instructions & Device Code Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("INSTRUCTIONS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.textMutedColor)

                        Text(attempt.instructions)
                            .font(.callout)
                            .foregroundStyle(palette.textPrimaryColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        if let deviceCode = attempt.extractedDeviceCode {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("DEVICE CODE")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(palette.textMutedColor)
                                    Text(deviceCode)
                                        .font(.title2.monospaced().weight(.bold))
                                        .foregroundStyle(palette.accentColor)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button {
                                    copyDeviceCode(deviceCode)
                                } label: {
                                    Label(
                                        copiedOAuthCode ? "Copied Code" : "Copy Code",
                                        systemImage: copiedOAuthCode ? "checkmark" : "doc.on.doc"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(12)
                            .background(palette.backgroundColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(palette.accentColor.opacity(0.45), lineWidth: 1)
                            )
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("AUTHORIZATION URL")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.textFaintColor)
                            Text(attempt.url)
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.textMutedColor)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }

                        HStack(spacing: 10) {
                            if let deviceCode = attempt.extractedDeviceCode {
                                Button {
                                    copyDeviceCode(deviceCode)
                                    store.openExternalURL(attempt.url)
                                } label: {
                                    Label("Copy Code & Open Browser", systemImage: "safari")
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button {
                                    store.openExternalURL(attempt.url)
                                } label: {
                                    Label("Open Browser", systemImage: "safari")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            Button {
                                copyOAuthLink(attempt.url)
                            } label: {
                                Label(
                                    copiedOAuthLink ? "Copied URL" : "Copy URL",
                                    systemImage: copiedOAuthLink ? "checkmark" : "link"
                                )
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.borderColor.opacity(0.4), lineWidth: 1)
                    )

                    // Manual Code / Redirect URL Paste Fallback
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            attempt.mode == .code
                                ? "AUTHORIZATION CODE"
                                : "MANUAL CODE / REDIRECT URL (OPTIONAL FALLBACK)"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.textMutedColor)

                        Text(
                            attempt.mode == .code
                                ? "Paste the authorization code or callback redirect URL from your browser to complete sign-in."
                                : "If automatic browser redirect does not complete, paste the callback URL or authorization code here."
                        )
                        .font(.caption)
                        .foregroundStyle(palette.textMutedColor)

                        HStack(spacing: 8) {
                            TextField("Paste authorization code or redirect URL…", text: $manualOAuthCode)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    submitManualOAuthCode()
                                }

                            Button {
                                submitManualOAuthCode()
                            } label: {
                                if isCompletingOAuth {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Complete")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                manualOAuthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || isCompletingOAuth
                            )
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.borderColor.opacity(0.35), lineWidth: 1)
                    )

                    if let status = attempt.statusMessage, !status.isEmpty {
                        HStack(spacing: 8) {
                            if attempt.isPolling {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: attempt.errorMessage != nil ? "exclamationmark.triangle.fill" : "info.circle")
                                    .foregroundStyle(attempt.errorMessage != nil ? palette.errorColor : palette.infoColor)
                            }
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(palette.textMutedColor)
                        }
                    }

                    if let err = attempt.errorMessage, !err.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundStyle(palette.errorColor)
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(palette.errorColor)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.errorColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(18)
            }

            Divider().overlay(palette.borderColor.opacity(0.4))

            HStack {
                if attempt.isPolling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Polling for completion…")
                            .font(.caption)
                            .foregroundStyle(palette.textMutedColor)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    Task {
                        await store.cancelOAuth()
                        manualOAuthCode = ""
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
            .background(palette.surfaceRaisedColor)
        }
    }

    // MARK: - Provider & Auth Methods Selection View

    private var providerMethodsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Provider Selector Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("PROVIDER")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.textMutedColor)
                            Spacer()
                            if let selected = selectedProvider {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(selected.isConnected ? palette.successColor : palette.textFaintColor)
                                        .frame(width: 7, height: 7)
                                    Text(
                                        selected.isConnected
                                            ? (selected.connectionSummary.isEmpty ? "Connected" : "Connected (\(selected.connectionSummary))")
                                            : "Not connected"
                                    )
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(selected.isConnected ? palette.successColor : palette.textMutedColor)
                                }
                            }
                        }

                        if allProviderChoices.count > 8 {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption)
                                    .foregroundStyle(palette.textMutedColor)
                                TextField("Filter \(allProviderChoices.count) providers…", text: $providerSearch)
                                    .textFieldStyle(.plain)
                                    .font(.callout)
                                    .onChange(of: providerSearch) { _, _ in
                                        if !filteredProviderChoices.contains(where: { $0.id == selectedProviderID }),
                                           let first = filteredProviderChoices.first {
                                            selectedProviderID = first.id
                                        }
                                    }
                                if !providerSearch.isEmpty {
                                    Button {
                                        providerSearch = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(palette.textMutedColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(palette.backgroundColor, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(palette.borderColor.opacity(0.4), lineWidth: 1)
                            )
                        }

                        Picker("Provider", selection: $selectedProviderID) {
                            ForEach(filteredProviderChoices) { provider in
                                HStack {
                                    Text(provider.name)
                                    if provider.isConnected {
                                        Text("• Connected")
                                    }
                                }
                                .tag(provider.id)
                            }
                        }
                        .labelsHidden()

                        HStack(spacing: 12) {
                            Text("ID: \(selectedProviderID)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.textFaintColor)
                            if selectedProviderModelCount > 0 {
                                Text("\(selectedProviderModelCount) live models")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(palette.infoColor)
                            }
                            Spacer()
                            if !oauthMethods.isEmpty {
                                Label("OAuth Supported", systemImage: "checkmark.shield.fill")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(palette.accentColor)
                            }
                        }
                    }
                    .padding(14)
                    .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.borderColor.opacity(0.35), lineWidth: 1)
                    )

                    // 1. OAuth Sign-In Methods
                    if !oauthMethods.isEmpty {
                        methodSection("OAuth Sign-In") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(oauthMethods, id: \.id.rawValue) { method in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "person.badge.key.fill")
                                                .foregroundStyle(palette.accentColor)
                                            Text(method.label)
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(palette.textPrimaryColor)
                                            Spacer()
                                        }

                                        if let fields = method.form?.elements, !fields.isEmpty {
                                            inlineFormFieldsView(methodKey: "oauth::\(method.id.rawValue)", fields: fields)
                                        }

                                        HStack {
                                            Spacer()
                                            Button {
                                                startOAuth(method)
                                            } label: {
                                                if isSubmitting && activeActionMethodID == "oauth::\(method.id.rawValue)" {
                                                    HStack(spacing: 6) {
                                                        ProgressView().controlSize(.small)
                                                        Text("Starting…")
                                                    }
                                                } else {
                                                    Label(method.label, systemImage: "arrow.up.right.square")
                                                }
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(isSubmitting)
                                        }
                                    }
                                    if method.id != oauthMethods.last?.id {
                                        Divider().overlay(palette.borderColor.opacity(0.3))
                                    }
                                }
                            }
                        }
                    }

                    // 2. API Key Methods
                    if !keyMethods.isEmpty {
                        methodSection("API Key") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(keyMethods.enumerated()), id: \.offset) { idx, keyMethod in
                                    let methodKey = "key::\(idx)"
                                    if let methodLabel = keyMethod.label, !methodLabel.isEmpty {
                                        Text(methodLabel)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(palette.textMutedColor)
                                    }
                                    SecureField("sk-…", text: $apiKey)
                                        .textFieldStyle(.roundedBorder)

                                    Text("Label (optional)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(palette.textMutedColor)
                                    TextField("Work / Personal", text: $label)
                                        .textFieldStyle(.roundedBorder)

                                    if let fields = keyMethod.form?.elements, !fields.isEmpty {
                                        inlineFormFieldsView(methodKey: methodKey, fields: fields)
                                    }

                                    HStack {
                                        Spacer()
                                        Button {
                                            submitAPIKey(methodKey: methodKey, form: keyMethod.form)
                                        } label: {
                                            if isSubmitting && activeActionMethodID == methodKey {
                                                ProgressView().controlSize(.small)
                                            } else {
                                                Text("Connect with API Key")
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(
                                            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                || isSubmitting
                                        )
                                    }
                                }
                            }
                        }
                    }

                    // 3. External Credential Methods
                    if !externalMethods.isEmpty {
                        methodSection("External Credentials") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(externalMethods, id: \.id.rawValue) { extMethod in
                                    let methodKey = "external::\(extMethod.id.rawValue)"
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "link.badge.plus")
                                                .foregroundStyle(palette.infoColor)
                                            Text(extMethod.label)
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(palette.textPrimaryColor)
                                            Spacer()
                                        }

                                        if let fields = extMethod.form?.elements, !fields.isEmpty {
                                            inlineFormFieldsView(methodKey: methodKey, fields: fields)
                                        }

                                        HStack {
                                            Spacer()
                                            Button {
                                                submitExternal(extMethod, methodKey: methodKey)
                                            } label: {
                                                if isSubmitting && activeActionMethodID == methodKey {
                                                    ProgressView().controlSize(.small)
                                                } else {
                                                    Label("Connect \(extMethod.label)", systemImage: "checkmark.circle")
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(isSubmitting)
                                        }
                                    }
                                    if extMethod.id != externalMethods.last?.id {
                                        Divider().overlay(palette.borderColor.opacity(0.3))
                                    }
                                }
                            }
                        }
                    }

                    // 4. Environment Variable Hint
                    if !envVarNames.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.caption2)
                                .foregroundStyle(palette.textMutedColor)
                            Text("Environment: \(envVarNames.joined(separator: ", "))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.textMutedColor)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 4)
                    }

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(palette.errorColor)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(palette.errorColor)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.errorColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(18)
            }

            Divider().overlay(palette.borderColor.opacity(0.4))

            HStack {
                Text("\(store.models.count) models across \(store.providers.count) active providers")
                    .font(.caption)
                    .foregroundStyle(palette.textMutedColor)
                Spacer()
                Button("Done") {
                    store.isConnectProviderPresented = false
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
            .background(palette.surfaceRaisedColor)
        }
    }

    // MARK: - Inline Form Field Renderer for OAuth / Key / External Methods

    private func methodSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.textMutedColor)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(palette.borderColor.opacity(0.35), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func inlineFormFieldsView(methodKey: String, fields: [FormSchema.Field]) -> some View {
        let appFields = fields.map(AppFormField.init(from:))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(appFields) { field in
                let storageKey = fieldStorageKey(methodKey: methodKey, fieldKey: field.key)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(field.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.textPrimaryColor)
                        if field.required {
                            Text("*").foregroundStyle(palette.errorColor)
                        }
                    }
                    if let desc = field.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(palette.textMutedColor)
                    }
                    switch field.kind {
                    case let .text(placeholder, _):
                        TextField(placeholder ?? "", text: methodStringBinding(for: storageKey))
                            .textFieldStyle(.roundedBorder)

                    case let .singleSelect(options, allowCustom, _):
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(options) { option in
                                let selected = methodStringValues[storageKey] == option.value
                                Button {
                                    methodStringValues[storageKey] = option.value
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(selected ? palette.interactiveColor : palette.textMutedColor)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(option.label)
                                                .font(.caption)
                                                .foregroundStyle(palette.textPrimaryColor)
                                            if let d = option.description, !d.isEmpty {
                                                Text(d)
                                                    .font(.caption2)
                                                    .foregroundStyle(palette.textMutedColor)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(7)
                                    .background(
                                        (selected ? palette.interactiveColor.opacity(0.12) : palette.backgroundColor),
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            if allowCustom {
                                TextField("Custom value…", text: methodCustomBinding(for: storageKey))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                    case let .multiSelect(options, allowCustom, _):
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(options) { option in
                                let checked = methodMultiValues[storageKey]?.contains(option.value) ?? false
                                Button {
                                    var set = methodMultiValues[storageKey] ?? []
                                    if checked { set.remove(option.value) } else { set.insert(option.value) }
                                    methodMultiValues[storageKey] = set
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(checked ? palette.interactiveColor : palette.textMutedColor)
                                        Text(option.label)
                                            .font(.caption)
                                            .foregroundStyle(palette.textPrimaryColor)
                                        Spacer()
                                    }
                                    .padding(7)
                                    .background(palette.backgroundColor, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                            if allowCustom {
                                TextField("Add custom option…", text: methodCustomBinding(for: storageKey))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                    case .boolean:
                        Toggle(field.title, isOn: methodBoolBinding(for: storageKey))
                            .labelsHidden()

                    case let .number(isInteger, _, _, _):
                        TextField(isInteger ? "0" : "0.0", text: methodStringBinding(for: storageKey))
                            .textFieldStyle(.roundedBorder)

                    case let .external(url):
                        Button {
                            store.openExternalURL(url)
                        } label: {
                            Label("Open \(url)", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Actions & Form Draft Helpers

    private func fieldStorageKey(methodKey: String, fieldKey: String) -> String {
        "\(selectedProviderID)::\(methodKey)::\(fieldKey)"
    }

    private func seedDefaultsForSelectedProvider() {
        for method in oauthMethods {
            if let fields = method.form?.elements {
                seedDefaults(methodKey: "oauth::\(method.id.rawValue)", fields: fields)
            }
        }
        for (idx, keyMethod) in keyMethods.enumerated() {
            if let fields = keyMethod.form?.elements {
                seedDefaults(methodKey: "key::\(idx)", fields: fields)
            }
        }
        for extMethod in externalMethods {
            if let fields = extMethod.form?.elements {
                seedDefaults(methodKey: "external::\(extMethod.id.rawValue)", fields: fields)
            }
        }
    }

    private func seedDefaults(methodKey: String, fields: [FormSchema.Field]) {
        for rawField in fields {
            let field = AppFormField(from: rawField)
            let key = fieldStorageKey(methodKey: methodKey, fieldKey: field.key)
            switch field.kind {
            case .text(_, let def):
                if methodStringValues[key] == nil {
                    methodStringValues[key] = def ?? ""
                }
            case .singleSelect(let opts, _, let def):
                if methodStringValues[key] == nil {
                    methodStringValues[key] = def ?? opts.first?.value ?? ""
                }
            case .multiSelect(_, _, let defs):
                if methodMultiValues[key] == nil {
                    methodMultiValues[key] = Set(defs)
                }
            case .boolean(let def):
                if methodBoolValues[key] == nil {
                    methodBoolValues[key] = def
                }
            case .number(_, _, _, let def):
                if methodStringValues[key] == nil {
                    methodStringValues[key] = def.map { String($0) } ?? ""
                }
            case .external:
                break
            }
        }
    }

    private func buildAnswer(methodKey: String, form: FormSchema.Fields?) -> FormSchema.Answer? {
        guard let fields = form?.elements, !fields.isEmpty else { return nil }
        var answer: FormSchema.Answer = [:]
        for rawField in fields {
            let field = AppFormField(from: rawField)
            let key = fieldStorageKey(methodKey: methodKey, fieldKey: field.key)
            switch field.kind {
            case .text(_, let def):
                answer[field.key] = .string(methodStringValues[key] ?? def ?? "")
            case .singleSelect(let opts, _, let def):
                let custom = (methodCustomValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let selected = methodStringValues[key] ?? def ?? opts.first?.value ?? ""
                answer[field.key] = .string(custom.isEmpty ? selected : custom)
            case .multiSelect(_, _, let defs):
                var list = Array(methodMultiValues[key] ?? Set(defs)).sorted()
                let custom = (methodCustomValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !custom.isEmpty { list.append(custom) }
                answer[field.key] = .strings(list)
            case .boolean(let def):
                answer[field.key] = .bool(methodBoolValues[key] ?? def)
            case .number(_, _, _, let def):
                if let raw = methodStringValues[key], let num = Double(raw) {
                    answer[field.key] = .number(num)
                } else if let def {
                    answer[field.key] = .number(def)
                }
            case .external:
                break
            }
        }
        return answer.isEmpty ? nil : answer
    }

    private func startOAuth(_ method: IntegrationSchema.OAuthMethod) {
        let methodKey = "oauth::\(method.id.rawValue)"
        let answer = buildAnswer(methodKey: methodKey, form: method.form)
        let target = selectedProviderID
        let lbl = label.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        activeActionMethodID = methodKey
        errorMessage = nil
        Task {
            do {
                _ = try await store.startOAuth(
                    integrationID: target,
                    methodID: method.id.rawValue,
                    answer: answer,
                    label: lbl.isEmpty ? nil : lbl
                )
            } catch {
                errorMessage = String(describing: error)
            }
            isSubmitting = false
            activeActionMethodID = nil
        }
    }

    private func submitAPIKey(methodKey: String, form: FormSchema.Fields?) {
        let answer = buildAnswer(methodKey: methodKey, form: form)
        let target = selectedProviderID
        let key = apiKey
        let lbl = label
        isSubmitting = true
        activeActionMethodID = methodKey
        errorMessage = nil
        Task {
            do {
                try await store.connectProviderAPIKey(
                    integrationID: target,
                    apiKey: key,
                    answer: answer,
                    label: lbl
                )
                apiKey = ""
                label = ""
                store.isConnectProviderPresented = false
            } catch {
                errorMessage = String(describing: error)
            }
            isSubmitting = false
            activeActionMethodID = nil
        }
    }

    private func submitExternal(_ method: IntegrationSchema.ExternalMethod, methodKey: String) {
        let answer = buildAnswer(methodKey: methodKey, form: method.form)
        let target = selectedProviderID
        let lbl = label.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        activeActionMethodID = methodKey
        errorMessage = nil
        Task {
            do {
                try await store.connectProviderExternal(
                    integrationID: target,
                    methodID: method.id.rawValue,
                    answer: answer,
                    label: lbl.isEmpty ? nil : lbl
                )
                label = ""
                store.isConnectProviderPresented = false
            } catch {
                errorMessage = String(describing: error)
            }
            isSubmitting = false
            activeActionMethodID = nil
        }
    }

    private func submitManualOAuthCode() {
        let code = manualOAuthCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        isCompletingOAuth = true
        Task {
            do {
                try await store.completeOAuth(code: code)
                manualOAuthCode = ""
            } catch {
                // Store updates activeOAuthAttempt.errorMessage & toast.
            }
            isCompletingOAuth = false
        }
    }

    private func copyDeviceCode(_ code: String) {
        OpenCodeAppClipboard.copy(code)
        copiedOAuthCode = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedOAuthCode = false
        }
    }

    private func copyOAuthLink(_ url: String) {
        OpenCodeAppClipboard.copy(url)
        copiedOAuthLink = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedOAuthLink = false
        }
    }

    private func methodStringBinding(for key: String) -> Binding<String> {
        Binding(
            get: { methodStringValues[key] ?? "" },
            set: { methodStringValues[key] = $0 }
        )
    }

    private func methodCustomBinding(for key: String) -> Binding<String> {
        Binding(
            get: { methodCustomValues[key] ?? "" },
            set: { methodCustomValues[key] = $0 }
        )
    }

    private func methodBoolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { methodBoolValues[key] ?? false },
            set: { methodBoolValues[key] = $0 }
        )
    }
}

// MARK: - 3. Pairing QR Sheet (Native SwiftUI Canvas from `OpenCodeUtil.QR.encode`)

public struct PairingQRSheet: View {
    @Bindable public var store: OpenCodeAppStore
    @State private var copiedLink = false

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "qrcode")
                    .font(.title3)
                    .foregroundStyle(palette.accentColor)
                Text("Pair Device")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimaryColor)
                Spacer()
                Button("Done") { store.isPairingQRPresented = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Divider().overlay(palette.borderColor.opacity(0.4))

            if let payload = store.pairingPayload {
                QRMatrixCanvasView(matrix: payload.qrMatrix)
                    .frame(width: 220, height: 220)
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)

                VStack(spacing: 6) {
                    Text(payload.code)
                        .font(.title3.monospaced().weight(.bold))
                        .foregroundStyle(palette.textPrimaryColor)
                        .textSelection(.enabled)

                    Text(payload.primaryLink)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.textMutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text("Expires in ~\(payload.expiresInMinutes) min")
                        .font(.caption2)
                        .foregroundStyle(palette.textFaintColor)
                }

                if payload.isLoopbackOnly {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(palette.warningColor)
                        Text("Server is bound to loopback; scan from the same host or expose via tunnel.")
                            .font(.caption2)
                            .foregroundStyle(palette.warningColor)
                    }
                    .padding(8)
                    .background(palette.warningColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 10) {
                    Button {
                        OpenCodeAppClipboard.copy(payload.primaryLink)
                        copiedLink = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedLink = false
                        }
                    } label: {
                        Label(copiedLink ? "Copied Link" : "Copy Link", systemImage: copiedLink ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { _ = try? await store.generatePairingQR() }
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            } else if let err = store.pairingError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(palette.errorColor)
                    Text("Unable to generate pairing code")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.textPrimaryColor)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(palette.textMutedColor)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { _ = try? await store.generatePairingQR() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 24)
            } else {
                ProgressView("Generating pairing QR code…")
                    .padding(.vertical, 44)
            }
        }
        .padding(20)
        .background(palette.dialogBackgroundColor)
        .frame(minWidth: 400, minHeight: 440)
        .task {
            if store.pairingPayload == nil {
                _ = try? await store.generatePairingQR()
            }
        }
    }
}

/// Crisp vector-crisp native SwiftUI `Canvas` rendering a boolean QR module matrix from `OpenCodeUtil.QR.encode`.
public struct QRMatrixCanvasView: View {
    public let matrix: [[Bool]]
    public let quietZoneModules: Int

    public init(matrix: [[Bool]], quietZoneModules: Int = 2) {
        self.matrix = matrix
        self.quietZoneModules = max(0, quietZoneModules)
    }

    public var body: some View {
        Canvas { context, size in
            let count = matrix.count
            guard count > 0 else { return }
            let total = count + quietZoneModules * 2
            let cell = min(size.width, size.height) / CGFloat(total)
            let originX = (size.width - cell * CGFloat(total)) / 2.0
            let originY = (size.height - cell * CGFloat(total)) / 2.0

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var darkPath = Path()
            for y in 0..<count {
                let row = matrix[y]
                for x in 0..<row.count where row[x] {
                    let rect = CGRect(
                        x: originX + CGFloat(x + quietZoneModules) * cell,
                        y: originY + CGFloat(y + quietZoneModules) * cell,
                        width: cell + 0.2,
                        height: cell + 0.2
                    )
                    darkPath.addRect(rect)
                }
            }
            context.fill(darkPath, with: .color(.black))
        }
    }
}

// MARK: - 4. Settings Sheet (Theme Mode, Theme Picker, Conceal Markdown, MCP Status)

public struct SettingsSheet: View {
    @Bindable public var store: OpenCodeAppStore

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OpenCodeBrandMarkView(size: 22, isLight: !palette.isDark, cornerRadius: 5)
                Text("Settings")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimaryColor)
                Spacer()
                Button("Done") { store.isSettingsPresented = false }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(16)
            .background(palette.surfaceRaisedColor)

            Divider().overlay(palette.borderColor.opacity(0.4))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsGroup("Appearance") {
                        HStack {
                            Text("Color Mode")
                                .foregroundStyle(palette.textPrimaryColor)
                            Spacer()
                            Picker("Mode", selection: $store.settings.themeMode) {
                                ForEach(AppThemeMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }

                        HStack {
                            Text("Theme")
                                .foregroundStyle(palette.textPrimaryColor)
                            Spacer()
                            Picker("Theme", selection: $store.settings.themeName) {
                                ForEach(AppResolvedPalette.availableThemeNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }

                        HStack(spacing: 8) {
                            Text("Resolved Palette")
                                .font(.caption)
                                .foregroundStyle(palette.textMutedColor)
                            Spacer()
                            swatch(palette.backgroundColor, label: "Bg")
                            swatch(palette.surfaceRaisedColor, label: "Panel")
                            swatch(palette.interactiveColor, label: "Action")
                            swatch(palette.accentColor, label: "Accent")
                            swatch(palette.successColor, label: "OK")
                            swatch(palette.errorColor, label: "Err")
                        }
                    }

                    settingsGroup("Conversation & Diffs") {
                        Toggle("Conceal Markdown Syntax (Rich Formatting)", isOn: $store.settings.concealMarkdown)
                            .foregroundStyle(palette.textPrimaryColor)
                        Toggle("Expand Reasoning Traces by Default", isOn: $store.settings.expandReasoningByDefault)
                            .foregroundStyle(palette.textPrimaryColor)
                        Toggle("Default to Split Side-by-Side Diff View", isOn: $store.settings.splitDiffView)
                            .foregroundStyle(palette.textPrimaryColor)
                    }

                    settingsGroup("Providers & Models") {
                        HStack {
                            Text("Connected Providers")
                                .foregroundStyle(palette.textPrimaryColor)
                            Spacer()
                            Text("\(store.integrations.filter(\.isConnected).count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(palette.textMutedColor)
                        }
                        HStack {
                            Text("Live Models")
                                .foregroundStyle(palette.textPrimaryColor)
                            Spacer()
                            Text("\(store.models.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(palette.textMutedColor)
                        }
                        if let dbPath = store.activeDatabasePath, !dbPath.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Text("Database")
                                    .foregroundStyle(palette.textPrimaryColor)
                                Spacer()
                                Text(dbPath)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(palette.textMutedColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        HStack {
                            Button("Connect Provider…") {
                                store.isSettingsPresented = false
                                store.isConnectProviderPresented = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                            Button {
                                Task { await store.refreshLiveModels() }
                            } label: {
                                if store.isRefreshingModels {
                                    HStack(spacing: 5) {
                                        ProgressView().controlSize(.mini)
                                        Text("Refreshing…")
                                    }
                                } else {
                                    Label("Refresh Models", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(store.isRefreshingModels)
                        }
                    }

                    settingsGroup("MCP Servers (\(store.mcpServers.count))") {
                        if store.mcpServers.isEmpty {
                            Text("No MCP servers configured for \(store.workspaceDirectory).")
                                .font(.caption)
                                .foregroundStyle(palette.textMutedColor)
                        } else {
                            ForEach(store.mcpServers) { server in
                                HStack {
                                    Circle()
                                        .fill(server.isConnected ? palette.successColor : (server.isFailed ? palette.errorColor : palette.warningColor))
                                        .frame(width: 8, height: 8)
                                    Text(server.title ?? server.name)
                                        .font(.callout)
                                        .foregroundStyle(palette.textPrimaryColor)
                                    Spacer()
                                    Text(server.statusLabel)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(palette.textMutedColor)
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Refresh MCP Status") {
                                Task { await store.refreshMCP() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(18)
            }
        }
        .background(palette.dialogBackgroundColor)
        .frame(minWidth: 500, minHeight: 460)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.textMutedColor)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(palette.borderColor.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private func swatch(_ color: Color, label: String) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 22, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.borderColor.opacity(0.5), lineWidth: 0.75))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(palette.textFaintColor)
        }
    }
}

// MARK: - 5. Interactive Form / Question Sheet

public struct FormPromptSheet: View {
    @Bindable public var store: OpenCodeAppStore
    public let form: AppFormItem

    @State private var stringValues: [String: String] = [:]
    @State private var multiValues: [String: Set<String>] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var customText: [String: String] = [:]
    @State private var isSubmitting = false

    public init(store: OpenCodeAppStore, form: AppFormItem) {
        self.store = store
        self.form = form
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.clipboard")
                    .foregroundStyle(palette.infoColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(form.title)
                        .font(.headline)
                        .foregroundStyle(palette.textPrimaryColor)
                    if let message = form.message, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(palette.textMutedColor)
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(palette.surfaceRaisedColor)

            Divider().overlay(palette.borderColor.opacity(0.4))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(form.fields) { field in
                        fieldView(field)
                    }
                }
                .padding(18)
            }

            Divider().overlay(palette.borderColor.opacity(0.4))

            HStack {
                Button("Cancel", role: .cancel) {
                    Task { try? await store.cancelForm(form) }
                }
                Spacer()
                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Submit Answers")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
            }
            .padding(14)
            .background(palette.surfaceRaisedColor)
        }
        .background(palette.dialogBackgroundColor)
        .frame(minWidth: 460, minHeight: 360)
        .onAppear(perform: seedDefaults)
    }

    @ViewBuilder
    private func fieldView(_ field: AppFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(field.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.textPrimaryColor)
                if field.required {
                    Text("*")
                        .foregroundStyle(palette.errorColor)
                }
            }
            if let desc = field.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(palette.textMutedColor)
            }

            switch field.kind {
            case let .text(placeholder, _):
                TextField(placeholder ?? "", text: stringBinding(for: field.key))
                    .textFieldStyle(.roundedBorder)

            case let .singleSelect(options, allowCustom, _):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options) { option in
                        let selected = stringValues[field.key] == option.value
                        Button {
                            stringValues[field.key] = option.value
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected ? palette.interactiveColor : palette.textMutedColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                        .font(.callout)
                                        .foregroundStyle(palette.textPrimaryColor)
                                    if let d = option.description, !d.isEmpty {
                                        Text(d)
                                            .font(.caption2)
                                            .foregroundStyle(palette.textMutedColor)
                                    }
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(
                                (selected ? palette.interactiveColor.opacity(0.12) : palette.surfaceRaisedColor),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if allowCustom {
                        TextField("Or enter custom value…", text: customBinding(for: field.key))
                            .textFieldStyle(.roundedBorder)
                    }
                }

            case let .multiSelect(options, allowCustom, _):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options) { option in
                        let checked = multiValues[field.key]?.contains(option.value) ?? false
                        Button {
                            var set = multiValues[field.key] ?? []
                            if checked { set.remove(option.value) } else { set.insert(option.value) }
                            multiValues[field.key] = set
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? palette.interactiveColor : palette.textMutedColor)
                                Text(option.label)
                                    .font(.callout)
                                    .foregroundStyle(palette.textPrimaryColor)
                                Spacer()
                            }
                            .padding(8)
                            .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                    if allowCustom {
                        TextField("Add custom option…", text: customBinding(for: field.key))
                            .textFieldStyle(.roundedBorder)
                    }
                }

            case .boolean:
                Toggle(field.title, isOn: boolBinding(for: field.key))
                    .labelsHidden()

            case let .number(isInteger, _, _, _):
                TextField(isInteger ? "0" : "0.0", text: stringBinding(for: field.key))
                    .textFieldStyle(.roundedBorder)

            case let .external(url):
                if let parsed = URL(string: url) {
                    Link(destination: parsed) {
                        Label("Open \(url)", systemImage: "arrow.up.right.square")
                    }
                } else {
                    Text(url).font(.caption.monospaced())
                }
            }
        }
    }

    private func seedDefaults() {
        for field in form.fields {
            switch field.kind {
            case .text(_, let def):
                stringValues[field.key] = def ?? ""
            case .singleSelect(let opts, _, let def):
                stringValues[field.key] = def ?? opts.first?.value ?? ""
            case .multiSelect(_, _, let defs):
                multiValues[field.key] = Set(defs)
            case .boolean(let def):
                boolValues[field.key] = def
            case .number(_, _, _, let def):
                stringValues[field.key] = def.map { String($0) } ?? ""
            case .external:
                break
            }
        }
    }

    private func submit() {
        isSubmitting = true
        var answer: FormSchema.Answer = [:]
        for field in form.fields {
            switch field.kind {
            case .text:
                answer[field.key] = .string(stringValues[field.key] ?? "")
            case .singleSelect:
                let custom = (customText[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                answer[field.key] = .string(custom.isEmpty ? (stringValues[field.key] ?? "") : custom)
            case .multiSelect:
                var list = Array(multiValues[field.key] ?? []).sorted()
                let custom = (customText[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !custom.isEmpty { list.append(custom) }
                answer[field.key] = .strings(list)
            case .boolean:
                answer[field.key] = .bool(boolValues[field.key] ?? false)
            case .number:
                if let num = Double(stringValues[field.key] ?? "") {
                    answer[field.key] = .number(num)
                }
            case .external:
                break
            }
        }

        Task {
            try? await store.replyForm(form, answer: answer)
            isSubmitting = false
        }
    }

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: { stringValues[key] ?? "" },
            set: { stringValues[key] = $0 }
        )
    }

    private func customBinding(for key: String) -> Binding<String> {
        Binding(
            get: { customText[key] ?? "" },
            set: { customText[key] = $0 }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { boolValues[key] ?? false },
            set: { boolValues[key] = $0 }
        )
    }
}

// MARK: - 6. Remote / Embedded Server Connection Sheet

public struct RemoteServerSheet: View {
    private enum ModeChoice: String, CaseIterable, Identifiable {
        case embedded = "Embedded SDK"
        case remote = "Remote Server"
        case pairing = "Pairing Code"
        var id: String { rawValue }
    }

    private enum AuthChoice: String, CaseIterable, Identifiable {
        case none = "None"
        case basic = "Basic Auth"
        case bearer = "Bearer Token"
        var id: String { rawValue }
    }

    @Bindable public var store: OpenCodeAppStore
    @State private var mode: ModeChoice = .embedded
    @State private var workspaceDir: String = ""
    @State private var remoteURL: String = "http://127.0.0.1:4096"
    @State private var authChoice: AuthChoice = .none
    @State private var username: String = "opencode"
    @State private var password: String = ""
    @State private var bearerToken: String = ""
    @State private var pairingCode: String = ""
    @State private var isConnecting = false
    @State private var errorMessage: String? = nil

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(palette.accentColor)
                Text("Server Connection")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimaryColor)
                Spacer()
                Button("Close") { store.isRemoteConnectPresented = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Picker("Mode", selection: $mode) {
                ForEach(ModeChoice.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .embedded:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Workspace Directory")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textMutedColor)
                    TextField("/path/to/workspace", text: $workspaceDir)
                        .textFieldStyle(.roundedBorder)
                    Text("Runs an in-process OpenCodeSDK host with live SQLite storage and SSE events.")
                        .font(.caption)
                        .foregroundStyle(palette.textMutedColor)
                    Text("Database: \(OpenCodeAppStore.resolveDefaultDatabasePath())")
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.textFaintColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

            case .remote:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textMutedColor)
                    TextField("http://127.0.0.1:4096", text: $remoteURL)
                        .textFieldStyle(.roundedBorder)

                    Picker("Authentication", selection: $authChoice) {
                        ForEach(AuthChoice.allCases) { a in
                            Text(a.rawValue).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)

                    if authChoice == .basic {
                        TextField("Username", text: $username).textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    } else if authChoice == .bearer {
                        SecureField("Bearer Token", text: $bearerToken).textFieldStyle(.roundedBorder)
                    }
                }

            case .pairing:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textMutedColor)
                    TextField("http://127.0.0.1:4096", text: $remoteURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Pairing Code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textMutedColor)
                    TextField("Enter pairing code…", text: $pairingCode)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(palette.errorColor)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { store.isRemoteConnectPresented = false }
                Button {
                    connect()
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)
            }
        }
        .padding(20)
        .background(palette.dialogBackgroundColor)
        .frame(minWidth: 460, minHeight: 340)
        .onAppear {
            workspaceDir = store.workspaceDirectory
            if case let .remote(url, _) = store.connectionTarget {
                mode = .remote
                remoteURL = url
            }
        }
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                switch mode {
                case .embedded:
                    let dir = workspaceDir.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await store.connectEmbedded(directory: dir.isEmpty ? nil : dir)
                case .remote:
                    let creds: AppServerCredentials
                    switch authChoice {
                    case .none: creds = .none
                    case .basic: creds = .basic(username: username, password: password)
                    case .bearer: creds = .bearer(token: bearerToken)
                    }
                    try await store.connectRemote(url: remoteURL, credentials: creds)
                case .pairing:
                    try await store.pairAndConnect(serverURL: remoteURL, code: pairingCode)
                }
                store.isRemoteConnectPresented = false
            } catch {
                errorMessage = String(describing: error)
            }
            isConnecting = false
        }
    }
}
#endif
