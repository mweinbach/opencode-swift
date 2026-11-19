#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import OpenCodeSchema
import OpenCodeUtil
import SwiftUI

// MARK: - 1. Command Palette Sheet (`Cmd+K` / `Cmd+P`)

public struct CommandPaletteSheet: View {
    @Bindable public var store: OpenCodeAppStore
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    private var results: [AppCommandItem] {
        AppCommandRegistry.filterCommands(query: query)
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
                            Task { await store.executeCommand(first.id) }
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
                                Task { await store.executeCommand(cmd.id) }
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
}

// MARK: - 2. Connect Provider Sheet

public struct ConnectProviderSheet: View {
    @Bindable public var store: OpenCodeAppStore
    @State private var selectedProviderID: String = "anthropic"
    @State private var apiKey: String = ""
    @State private var label: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    private var providerChoices: [AppProviderIntegration] {
        if !store.integrations.isEmpty {
            return store.integrations
        }
        return [
            AppProviderIntegration(id: "anthropic", name: "Anthropic"),
            AppProviderIntegration(id: "openai", name: "OpenAI"),
            AppProviderIntegration(id: "google", name: "Google Gemini"),
            AppProviderIntegration(id: "openrouter", name: "OpenRouter"),
            AppProviderIntegration(id: "opencode", name: "OpenCode Console"),
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.title3)
                    .foregroundStyle(palette.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Provider")
                        .font(.headline)
                        .foregroundStyle(palette.textPrimaryColor)
                    Text("Add an API key to enable models from your provider.")
                        .font(.caption)
                        .foregroundStyle(palette.textMutedColor)
                }
                Spacer()
                Button("Close") { store.isConnectProviderPresented = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Divider().overlay(palette.borderColor.opacity(0.4))

            VStack(alignment: .leading, spacing: 10) {
                Text("Provider")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)

                Picker("Provider", selection: $selectedProviderID) {
                    ForEach(providerChoices) { provider in
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

                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Text("Label (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)
                TextField("Work / Personal", text: $label)
                    .textFieldStyle(.roundedBorder)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(palette.errorColor)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    store.isConnectProviderPresented = false
                }
                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .background(palette.dialogBackgroundColor)
        .frame(minWidth: 440, minHeight: 320)
        .onAppear {
            if let first = providerChoices.first(where: { !$0.isConnected }) ?? providerChoices.first {
                selectedProviderID = first.id
            }
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        let target = selectedProviderID
        let key = apiKey
        let lbl = label
        Task {
            do {
                try await store.connectProviderAPIKey(integrationID: target, apiKey: key, label: lbl)
                apiKey = ""
                label = ""
                store.isConnectProviderPresented = false
            } catch {
                errorMessage = String(describing: error)
            }
            isSubmitting = false
        }
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
