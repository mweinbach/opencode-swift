#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI

/// Multiline composer with `/` slash command autocomplete popover, `@` file/agent mention picker,
/// `!` shell mode toggle, model/agent/variant selector chips, and Send/Abort control.
public struct ComposerView: View {
    @Bindable public var store: OpenCodeAppStore

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.slashSuggestions.isEmpty {
                slashAutocompletePopover
            } else if !store.mentionSuggestions.isEmpty {
                mentionAutocompletePopover
            }

            VStack(alignment: .leading, spacing: 8) {
                if store.isShellMode {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.caption2)
                            .foregroundStyle(palette.warningColor)
                        Text("Shell Mode — runs command directly in \(store.workspaceDirectory)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(palette.warningColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Exit") {
                            store.isShellMode = false
                        }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.textMutedColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.warningColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField(
                        store.isShellMode
                            ? "Enter shell command…"
                            : "Ask OpenCode… (type / for commands, @ for files/agents, ! for shell)",
                        text: $store.composerText,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(store.isShellMode ? .system(.body, design: .monospaced) : .body)
                    .foregroundStyle(palette.textPrimaryColor)
                    .lineLimit(1...8)
                    .onChange(of: store.composerText) { _, _ in
                        store.handleComposerTextChanged()
                    }
                    .onSubmit {
                        submitCurrentInput()
                    }

                    actionButton
                }

                selectorChipsBar
            }
            .padding(12)
            .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        store.isShellMode ? palette.warningColor.opacity(0.65) : palette.borderColor.opacity(0.5),
                        lineWidth: 1
                    )
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
        .background(palette.backgroundColor)
    }

    // MARK: - Slash Autocomplete Popover

    private var slashAutocompletePopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Slash Commands")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)
                Spacer()
                Button("Dismiss") {
                    store.slashAutocompleteDismissed = true
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(palette.textFaintColor)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.slashSuggestions.prefix(8)) { cmd in
                        Button {
                            store.applySlashSuggestion(cmd)
                        } label: {
                            HStack(spacing: 10) {
                                Text(cmd.name)
                                    .font(.callout.monospaced().weight(.semibold))
                                    .foregroundStyle(palette.interactiveColor)
                                Text(cmd.description)
                                    .font(.caption)
                                    .foregroundStyle(palette.textMutedColor)
                                    .lineLimit(1)
                                Spacer()
                                if cmd.isServerCommand {
                                    Text("Server")
                                        .font(.caption2)
                                        .foregroundStyle(palette.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(.bottom, 6)
        .background(palette.dialogBackgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.borderColor.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 8, y: 2)
    }

    // MARK: - Mention Picker Popover

    private var mentionAutocompletePopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Mentions (@file / @agent)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)
                Spacer()
                Button("Dismiss") {
                    store.mentionAutocompleteDismissed = true
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(palette.textFaintColor)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.mentionSuggestions.prefix(8)) { item in
                        Button {
                            store.applyMentionSuggestion(item)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.kind == .agent ? "sparkles" : "doc.text")
                                    .font(.caption)
                                    .foregroundStyle(item.kind == .agent ? palette.accentColor : palette.infoColor)
                                Text(item.displayTitle)
                                    .font(.callout.monospaced().weight(.medium))
                                    .foregroundStyle(palette.textPrimaryColor)
                                    .lineLimit(1)
                                if let sub = item.subtitle, !sub.isEmpty {
                                    Text(sub)
                                        .font(.caption2)
                                        .foregroundStyle(palette.textMutedColor)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(.bottom, 6)
        .background(palette.dialogBackgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.borderColor.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 8, y: 2)
    }

    // MARK: - Selector Chips Bar

    private var selectorChipsBar: some View {
        HStack(spacing: 8) {
            agentPickerChip
            modelPickerChip
            if let variants = store.selectedModel?.variants, !variants.isEmpty {
                variantPickerChip(variants)
            }

            Spacer()

            Button {
                store.isShellMode.toggle()
            } label: {
                Label("!", systemImage: "terminal")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(store.isShellMode ? palette.warningColor : palette.textMutedColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (store.isShellMode ? palette.warningColor.opacity(0.18) : palette.surfaceHighColor),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle Shell Command Mode (!)")
        }
    }

    private var agentPickerChip: some View {
        let idx = store.agents.firstIndex(where: { $0.id == store.activeAgent.id }) ?? 0
        let tint = palette.agentColor(colorHex: store.activeAgent.colorHex, index: idx)
        return Menu {
            ForEach(store.agents) { agent in
                Button {
                    Task { try? await store.selectAgent(agent) }
                } label: {
                    HStack {
                        Text(agent.name)
                        if agent.id == store.selectedAgentID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(store.activeAgent.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.textMutedColor)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(palette.surfaceHighColor, in: Capsule())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
    }

    private var modelPickerChip: some View {
        Menu {
            if store.models.isEmpty {
                Button("Connect a Provider…") {
                    store.isConnectProviderPresented = true
                }
            } else {
                ForEach(store.models) { model in
                    Button {
                        Task { try? await store.selectModel(model) }
                    } label: {
                        HStack {
                            Text("\(model.name) — \(model.providerName)")
                            if store.selectedModel?.id == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button("Connect Provider…") {
                    store.isConnectProviderPresented = true
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(palette.interactiveColor)
                Text(store.selectedModel?.name ?? "Select Model")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.textPrimaryColor)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.textMutedColor)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(palette.surfaceHighColor, in: Capsule())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
    }

    private func variantPickerChip(_ variants: [String]) -> some View {
        Menu {
            Button("Default") {
                Task { try? await store.selectVariant(nil) }
            }
            Divider()
            ForEach(variants, id: \.self) { variant in
                Button {
                    Task { try? await store.selectVariant(variant) }
                } label: {
                    HStack {
                        Text(variant)
                        if store.selectedVariant == variant {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(palette.accentColor)
                Text(store.selectedVariant ?? "default")
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.textPrimaryColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.surfaceHighColor, in: Capsule())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
    }

    // MARK: - Send / Abort Button

    @ViewBuilder
    private var actionButton: some View {
        if store.isActiveSessionWorking {
            Button {
                Task { try? await store.abortActiveSession() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(palette.errorColor, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Abort Run (⌘.)")
        } else {
            let canSend = !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isSending
            Button {
                submitCurrentInput()
            } label: {
                Image(systemName: store.isShellMode ? "play.fill" : "arrow.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        (canSend ? (store.isShellMode ? palette.warningColor : palette.interactiveColor) : palette.textFaintColor.opacity(0.4)),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(store.isShellMode ? "Run Shell Command" : "Send Prompt")
        }
    }

    private func submitCurrentInput() {
        Task { try? await store.submitComposer() }
    }
}
#endif
