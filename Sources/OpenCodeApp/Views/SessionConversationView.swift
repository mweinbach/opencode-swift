#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import OpenCodeSchema
import SwiftUI

/// Rich conversation detail view displaying Markdown, code blocks, Merman Mermaid diagrams,
/// LaTeX math previews, collapsible reasoning & tool cards, and inline permission/form banners.
public struct SessionConversationView: View {
    @Bindable public var store: OpenCodeAppStore

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        VStack(spacing: 0) {
            if store.messages.isEmpty {
                welcomeEmptyState
            } else {
                transcriptScrollView
            }

            if let permission = store.activePermission {
                Divider().overlay(palette.borderColor.opacity(0.45))
                PermissionApprovalBannerView(permission: permission, palette: palette) { decision, feedback in
                    Task { try? await store.replyPermission(permission, decision: decision, message: feedback) }
                }
            }

            if let form = store.activePendingForm {
                Divider().overlay(palette.borderColor.opacity(0.45))
                PendingFormBannerView(form: form, palette: palette) {
                    store.activeFormSheet = form
                } onCancel: {
                    Task { try? await store.cancelForm(form) }
                }
            }
        }
        .background(palette.backgroundColor)
    }

    // MARK: - Welcome State

    private var welcomeEmptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 44)
                OpenCodeBrandMarkView(size: 64, isLight: !palette.isDark, cornerRadius: 16)
                    .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)

                VStack(spacing: 6) {
                    Text("OpenCode")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(palette.textPrimaryColor)
                    Text(store.workspaceDirectory)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.textMutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !store.isAnyProviderConnected {
                    Button {
                        store.isConnectProviderPresented = true
                    } label: {
                        Label("Connect an AI Provider", systemImage: "key.fill")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.interactiveColor)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Try asking:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textMutedColor)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                        starterPromptCard("Summarize the architecture of this workspace", icon: "map")
                        starterPromptCard("Find and fix failing tests", icon: "checkmark.shield")
                        starterPromptCard("Explain recent git changes and open diffs", icon: "doc.text.magnifyingglass")
                        starterPromptCard("Draw a Mermaid diagram of the core modules", icon: "point.3.connected.trianglepath.dotted")
                    }
                }
                .frame(maxWidth: 640)
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func starterPromptCard(_ prompt: String, icon: String) -> some View {
        Button {
            store.composerText = prompt
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(palette.accentColor)
                    .frame(width: 20)
                Text(prompt)
                    .font(.callout)
                    .foregroundStyle(palette.textPrimaryColor)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(palette.borderColor.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message List

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(store.messages) { message in
                        messageView(message)
                            .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("__conversation_bottom__")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("__conversation_bottom__", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: AppTranscriptMessage) -> some View {
        switch message {
        case let .user(_, text, _, mentions, isOptimistic):
            UserMessageCard(text: text, mentions: mentions, isOptimistic: isOptimistic, palette: palette)

        case let .assistant(_, agent, model, parts, completed, error, cost, tokens, _):
            AssistantMessageCard(
                agent: agent,
                model: model,
                parts: parts,
                completed: completed,
                error: error,
                cost: cost,
                tokens: tokens,
                palette: palette,
                concealMarkdown: store.settings.concealMarkdown,
                expandReasoningByDefault: store.settings.expandReasoningByDefault
            )

        case let .shell(_, _, command, status, output, exitCode, _):
            ShellMessageCard(
                command: command,
                status: status,
                output: output,
                exitCode: exitCode,
                palette: palette
            )

        case let .system(_, text, isError, _):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(isError ? palette.errorColor : palette.infoColor)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(isError ? palette.errorColor : palette.textMutedColor)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isError ? palette.errorColor : palette.infoColor).opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }
}

// MARK: - User Message Card

private struct UserMessageCard: View {
    let text: String
    let mentions: [String]
    let isOptimistic: Bool
    let palette: AppResolvedPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.interactiveColor)
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)
                if isOptimistic {
                    Text("Sending…")
                        .font(.caption2)
                        .foregroundStyle(palette.textFaintColor)
                }
                Spacer()
            }

            Text(text)
                .font(.body)
                .foregroundStyle(palette.textPrimaryColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !mentions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(mentions, id: \.self) { mention in
                        Text(mention)
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(palette.accentColor.opacity(0.14), in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.interactiveColor.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Assistant Message Card

private struct AssistantMessageCard: View {
    let agent: String
    let model: String
    let parts: [AppMessagePart]
    let completed: Bool
    let error: String?
    let cost: Double?
    let tokens: Int?
    let palette: AppResolvedPalette
    let concealMarkdown: Bool
    let expandReasoningByDefault: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OpenCodeBrandMarkView(size: 18, isLight: !palette.isDark, cornerRadius: 4)
                Text(agent.isEmpty ? "Assistant" : agent)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accentColor)
                if !model.isEmpty {
                    Text(model)
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.textMutedColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.surfaceHighColor, in: Capsule())
                }
                if !completed {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                if let tokens, tokens > 0 {
                    Text("\(tokens) tok")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.textFaintColor)
                }
                if let cost, cost > 0 {
                    Text(String(format: "$%.4f", cost))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.textFaintColor)
                }
            }

            ForEach(parts) { part in
                switch part {
                case let .reasoning(_, text, partCompleted):
                    ReasoningDisclosureCard(
                        text: text,
                        completed: partCompleted,
                        defaultExpanded: expandReasoningByDefault,
                        palette: palette
                    )

                case let .tool(_, name, status, summary, inputJSON, output, toolError):
                    ToolCallDisclosureCard(
                        name: name,
                        status: status,
                        summary: summary,
                        inputJSON: inputJSON,
                        output: output,
                        error: toolError,
                        palette: palette
                    )

                case let .text(_, text):
                    OpenCodeMarkdownView(
                        markdown: text,
                        palette: palette,
                        concealMarkdown: concealMarkdown,
                        streaming: !completed
                    )
                }
            }

            if let error, !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(palette.errorColor)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(palette.errorColor)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(palette.errorColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Collapsible Reasoning Card

private struct ReasoningDisclosureCard: View {
    let text: String
    let completed: Bool
    let defaultExpanded: Bool
    let palette: AppResolvedPalette
    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(palette.textMutedColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(palette.accentColor)
                Text(completed ? "Reasoning" : "Thinking…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)
                if !completed {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .padding(10)
        .background(palette.surfaceRaisedColor.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.borderColor.opacity(0.35), lineWidth: 1)
        )
        .onAppear {
            isExpanded = defaultExpanded
        }
    }
}

// MARK: - Collapsible Tool Call Card

private struct ToolCallDisclosureCard: View {
    let name: String
    let status: AppToolStatus
    let summary: String
    let inputJSON: String?
    let output: String?
    let error: String?
    let palette: AppResolvedPalette
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let inputJSON, !inputJSON.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("INPUT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.textFaintColor)
                        Text(inputJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(palette.textMutedColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let output, !output.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OUTPUT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.textFaintColor)
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(palette.textPrimaryColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(palette.errorColor)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                statusIcon
                Text(name)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(palette.textPrimaryColor)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.textMutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(status.displayLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.14), in: Capsule())
            }
        }
        .padding(10)
        .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(status == .error ? palette.errorColor.opacity(0.5) : palette.borderColor.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .streaming, .running:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(palette.successColor)
        case .error:
            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(palette.errorColor)
        }
    }

    private var statusColor: Color {
        switch status {
        case .streaming, .running: return palette.infoColor
        case .completed: return palette.successColor
        case .error: return palette.errorColor
        }
    }
}

// MARK: - Shell Output Card

private struct ShellMessageCard: View {
    let command: String
    let status: AppToolStatus
    let output: String?
    let exitCode: Int?
    let palette: AppResolvedPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(palette.warningColor)
                Text("$ \(command)")
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(palette.textPrimaryColor)
                    .textSelection(.enabled)
                Spacer()
                if let exitCode {
                    Text("exit \(exitCode)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(exitCode == 0 ? palette.successColor : palette.errorColor)
                } else if status == .running {
                    ProgressView().controlSize(.mini)
                }
            }
            if let output, !output.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(palette.textMutedColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(palette.surfaceRaisedColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.warningColor.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Inline Permission Approval Banner

public struct PermissionApprovalBannerView: View {
    public let permission: AppPermissionItem
    public let palette: AppResolvedPalette
    public let onReply: (PermissionSchema.Reply, String?) -> Void

    @State private var showRejectFeedback = false
    @State private var feedbackText = ""

    public init(
        permission: AppPermissionItem,
        palette: AppResolvedPalette,
        onReply: @escaping (PermissionSchema.Reply, String?) -> Void
    ) {
        self.permission = permission
        self.palette = palette
        self.onReply = onReply
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(palette.warningColor)
                Text("Permission Requested: \(permission.action)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.textPrimaryColor)
                Spacer()
                Text(permission.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.textFaintColor)
            }

            if let cmd = permission.commandPreview, !cmd.isEmpty {
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(palette.textPrimaryColor)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.backgroundColor, in: RoundedRectangle(cornerRadius: 6))
            } else if !permission.resources.isEmpty {
                Text(permission.resources.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.textMutedColor)
                    .lineLimit(2)
            }

            if showRejectFeedback {
                HStack(spacing: 8) {
                    TextField("Optional feedback for the agent…", text: $feedbackText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            onReply(.reject, feedbackText)
                            showRejectFeedback = false
                            feedbackText = ""
                        }
                    Button("Send Rejection") {
                        onReply(.reject, feedbackText)
                        showRejectFeedback = false
                        feedbackText = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.errorColor)
                    .controlSize(.small)
                    Button("Cancel") {
                        showRejectFeedback = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        onReply(.once, nil)
                    } label: {
                        Label("Allow Once", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.successColor)
                    .controlSize(.small)

                    Button {
                        onReply(.always, nil)
                    } label: {
                        Label("Allow Always", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        showRejectFeedback = true
                    } label: {
                        Label("Reject…", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(palette.warningColor.opacity(0.09))
    }
}

// MARK: - Inline Pending Form Banner

private struct PendingFormBannerView: View {
    let form: AppFormItem
    let palette: AppResolvedPalette
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.clipboard")
                .foregroundStyle(palette.infoColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(form.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.textPrimaryColor)
                Text("\(form.fields.count) question\(form.fields.count == 1 ? "" : "s") awaiting your input")
                    .font(.caption)
                    .foregroundStyle(palette.textMutedColor)
            }
            Spacer()
            Button("Dismiss", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Answer…", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(palette.infoColor.opacity(0.1))
    }
}
#endif
