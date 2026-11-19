#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI

/// Workspace & Session sidebar displaying the official OpenCode brand mark, new session CTA,
/// live search filter, time-grouped sessions with live status badges, and rename/fork/delete context menus.
public struct SessionSidebarView: View {
    @Bindable public var store: OpenCodeAppStore
    @State private var renameDraft: String = ""

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    public var body: some View {
        VStack(spacing: 0) {
            brandHeader
            searchBar
            Divider().overlay(palette.borderColor.opacity(0.35))
            sessionList
            Divider().overlay(palette.borderColor.opacity(0.35))
            workspaceFooter
        }
        .background(palette.surfaceRaisedColor)
        .sheet(item: $store.renamingSession) { session in
            renameSheet(for: session)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            OpenCodeBrandMarkView(size: 26, isLight: !palette.isDark, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenCode")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.textPrimaryColor)
                if !store.serverVersion.isEmpty {
                    Text("v\(store.serverVersion)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.textMutedColor)
                }
            }
            Spacer()
            Button {
                Task { _ = try? await store.createSession() }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .foregroundStyle(palette.textPrimaryColor)
                    .padding(6)
                    .background(palette.surfaceHighColor, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("New Session (⌘N)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(palette.textMutedColor)
            TextField("Filter sessions…", text: $store.sessionSearchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(palette.textPrimaryColor)
            if !store.sessionSearchQuery.isEmpty {
                Button {
                    store.sessionSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(palette.textMutedColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(palette.backgroundColor.opacity(0.75), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(palette.borderColor.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                let groups = store.filteredSessionGroups
                if groups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.title3)
                            .foregroundStyle(palette.textFaintColor)
                        Text(store.sessionSearchQuery.isEmpty ? "No sessions yet" : "No matching sessions")
                            .font(.callout)
                            .foregroundStyle(palette.textMutedColor)
                        if store.sessionSearchQuery.isEmpty {
                            Button("Start New Session") {
                                Task { _ = try? await store.createSession() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.textMutedColor)
                                .padding(.horizontal, 12)
                                .padding(.top, 4)

                            ForEach(group.sessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sessionRow(_ session: AppSessionSummary) -> some View {
        let isSelected = session.id == store.activeSessionID
        return Button {
            Task { await store.selectSession(session.id) }
        } label: {
            HStack(spacing: 8) {
                SessionStatusBadgeView(badge: session.badge, palette: palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? palette.textPrimaryColor : palette.textPrimaryColor.opacity(0.9))
                        .lineLimit(1)
                    if session.parentID != nil {
                        Label("Fork", systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(palette.textMutedColor)
                    }
                }
                Spacer(minLength: 4)
                if session.cost > 0 {
                    Text(String(format: "$%.2f", session.cost))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.textFaintColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? palette.surfaceHighColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? palette.interactiveColor.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameDraft = session.title
                store.renamingSession = session
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            Button {
                Task { _ = try? await store.forkSession(session.id) }
            } label: {
                Label("Fork Session", systemImage: "arrow.triangle.branch")
            }

            Divider()

            Button(role: .destructive) {
                Task { try? await store.deleteSession(session.id) }
            } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }

    private var workspaceFooter: some View {
        Button {
            store.isRemoteConnectPresented = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionIndicatorColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspaceDisplayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.textPrimaryColor)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(store.connectionState.shortLabel)
                            .font(.caption2)
                            .foregroundStyle(palette.textMutedColor)
                        if let branch = store.gitBranch, !branch.isEmpty {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.infoColor)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(palette.textMutedColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .help("Manage Embedded or Remote Server Connection")
    }

    private var workspaceDisplayName: String {
        let dir = store.workspaceDirectory
        if let last = dir.split(separator: "/").last {
            return String(last)
        }
        return dir.isEmpty ? "Workspace" : dir
    }

    private var connectionIndicatorColor: Color {
        switch store.connectionState {
        case .connected:
            return store.sseConnected ? palette.successColor : palette.infoColor
        case .connecting, .reconnecting:
            return palette.warningColor
        case .failed:
            return palette.errorColor
        case .disconnected:
            return palette.textFaintColor
        }
    }

    private func renameSheet(for session: AppSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Session")
                .font(.headline)
                .foregroundStyle(palette.textPrimaryColor)
            TextField("Session title", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .onAppear { renameDraft = session.title }
                .onSubmit {
                    submitRename(for: session)
                }
            HStack {
                Spacer()
                Button("Cancel") {
                    store.renamingSession = nil
                }
                Button("Rename") {
                    submitRename(for: session)
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(palette.dialogBackgroundColor)
    }

    private func submitRename(for session: AppSessionSummary) {
        let next = renameDraft
        store.renamingSession = nil
        Task { try? await store.renameSession(session.id, title: next) }
    }
}
#endif
