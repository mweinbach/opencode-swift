#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI

/// Right-hand workspace inspector presenting live Context/Usage, Session Todos, MCP Servers, and Diffs.
public struct WorkspaceInspectorView: View {
    @Bindable public var store: OpenCodeAppStore

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $store.selectedInspectorTab) {
                ForEach(AppInspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider().overlay(palette.borderColor.opacity(0.4))

            ScrollView {
                switch store.selectedInspectorTab {
                case .context:
                    contextTab
                case .todos:
                    todosTab
                case .mcp:
                    mcpTab
                case .diffs:
                    diffsTab
                }
            }
        }
        .background(palette.surfaceRaisedColor)
    }

    // MARK: - Context & Usage Tab

    private var contextTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            inspectorSection("Session Context") {
                VStack(alignment: .leading, spacing: 8) {
                    metricRow("Agent", store.activeAgent.name)
                    metricRow("Model", store.selectedModel?.name ?? "None")
                    if let variant = store.selectedVariant {
                        metricRow("Variant", variant)
                    }
                    metricRow("Tokens", formatTokens(store.activeSessionTokens))
                    if let limit = store.contextLimit {
                        metricRow("Window", formatTokens(limit))
                    }
                    metricRow("Cost", String(format: "$%.4f", store.activeSessionCost))

                    if let pct = store.contextPercent {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Context Fill")
                                    .font(.caption2)
                                    .foregroundStyle(palette.textMutedColor)
                                Spacer()
                                Text("\(pct)%")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(pct > 85 ? palette.warningColor : palette.textPrimaryColor)
                            }
                            ProgressView(value: Double(pct), total: 100)
                                .tint(pct > 85 ? palette.warningColor : palette.interactiveColor)
                        }
                        .padding(.top, 4)
                    }
                }
            }

            inspectorSection("Workspace") {
                VStack(alignment: .leading, spacing: 6) {
                    metricRow("Branch", store.gitBranch ?? "—")
                    metricRow("Connection", store.connectionState.shortLabel)
                    metricRow("SSE Stream", store.sseConnected ? "Live" : "Idle")
                }
            }

            inspectorSection("Usage Limits") {
                if store.usageLimits.isEmpty {
                    Text("No active workspace usage budgets reported.")
                        .font(.caption)
                        .foregroundStyle(palette.textMutedColor)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if let wsName = store.usageWorkspaceName {
                            Text(wsName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.textPrimaryColor)
                        }
                        ForEach(store.usageLimits) { limit in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(limit.title)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(palette.textPrimaryColor)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(limit.remainingPercent)% left")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(limit.isReached ? palette.errorColor : (limit.isLow ? palette.warningColor : palette.successColor))
                                }
                                ProgressView(value: Double(100 - limit.remainingPercent), total: 100)
                                    .tint(limit.isReached ? palette.errorColor : (limit.isLow ? palette.warningColor : palette.interactiveColor))
                                HStack {
                                    Text(String(format: "$%.2f / $%.2f", limit.spentDollars, limit.limitDollars))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(palette.textMutedColor)
                                    Spacer()
                                    Text(limit.resetsLabel)
                                        .font(.caption2)
                                        .foregroundStyle(palette.textFaintColor)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Todos Tab

    private var todosTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.todos.isEmpty {
                emptyInspectorPlaceholder(
                    icon: "checklist",
                    title: "No Active Todos",
                    subtitle: "Tasks tracked during agent execution appear here in real time."
                )
            } else {
                ForEach(store.todos) { todo in
                    HStack(alignment: .top, spacing: 8) {
                        todoIcon(todo.status)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(todo.content)
                                .font(.callout)
                                .strikethrough(todo.status == .completed || todo.status == .cancelled)
                                .foregroundStyle(todo.status == .completed ? palette.textMutedColor : palette.textPrimaryColor)
                            if let priority = todo.priority, !priority.isEmpty {
                                Text(priority.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(palette.textFaintColor)
                            }
                        }
                        Spacer()
                    }
                    .padding(9)
                    .background(palette.backgroundColor.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(12)
    }

    // MARK: - MCP Tab

    private var mcpTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MCP Servers (\(store.mcpServers.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)
                Spacer()
                Button {
                    Task { await store.refreshMCP() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textMutedColor)
            }

            if store.mcpServers.isEmpty {
                emptyInspectorPlaceholder(
                    icon: "puzzlepiece.extension",
                    title: "No MCP Servers",
                    subtitle: "Configured Model Context Protocol servers appear here with live status."
                )
            } else {
                ForEach(store.mcpServers) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle()
                                .fill(server.isConnected ? palette.successColor : (server.isFailed ? palette.errorColor : palette.warningColor))
                                .frame(width: 8, height: 8)
                            Text(server.title ?? server.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(palette.textPrimaryColor)
                                .lineLimit(1)
                            Spacer()
                            Text(server.statusLabel)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(server.isConnected ? palette.successColor : (server.isFailed ? palette.errorColor : palette.textMutedColor))
                        }
                        if let detail = server.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(palette.errorColor)
                                .lineLimit(3)
                        }
                    }
                    .padding(9)
                    .background(palette.backgroundColor.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(12)
    }

    // MARK: - Diffs Tab

    private var diffsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Changed Files (\(store.diffs.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMutedColor)
                Spacer()
                Button("Review All") {
                    store.isDiffReviewPresented = true
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(palette.interactiveColor)
            }

            if store.diffs.isEmpty {
                emptyInspectorPlaceholder(
                    icon: "doc.text.magnifyingglass",
                    title: "No Modified Files",
                    subtitle: "Git working tree and session diffs appear here automatically."
                )
            } else {
                ForEach(store.diffs) { file in
                    Button {
                        store.isDiffReviewPresented = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(file.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.textPrimaryColor)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if file.additions > 0 {
                                Text("+\(file.additions)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(palette.diffAddedTextColor)
                            }
                            if file.deletions > 0 {
                                Text("-\(file.deletions)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(palette.diffRemovedTextColor)
                            }
                        }
                        .padding(8)
                        .background(palette.backgroundColor.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.textMutedColor)
            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.backgroundColor.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(palette.textMutedColor)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(palette.textPrimaryColor)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func todoIcon(_ status: AppTodoStatus) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(palette.successColor)
        case .inProgress:
            Image(systemName: "circle.dotted.circle").font(.caption).foregroundStyle(palette.infoColor)
        case .cancelled:
            Image(systemName: "minus.circle").font(.caption).foregroundStyle(palette.textFaintColor)
        case .pending:
            Image(systemName: "circle").font(.caption).foregroundStyle(palette.textMutedColor)
        }
    }

    private func emptyInspectorPlaceholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(palette.textFaintColor)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(palette.textPrimaryColor)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(palette.textMutedColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}
#endif
