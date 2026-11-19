#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI

/// Native Unified & Side-by-Side Split Diff Review sheet for workspace and session file diffs.
public struct DiffReviewView: View {
    @Bindable public var store: OpenCodeAppStore
    @State private var selectedFileID: String? = nil
    @State private var splitMode: Bool = false

    public init(store: OpenCodeAppStore) {
        self.store = store
    }

    private var palette: AppResolvedPalette { store.resolvedPalette }

    private var selectedFile: AppFileDiffItem? {
        if let id = selectedFileID, let match = store.diffs.first(where: { $0.id == id }) {
            return match
        }
        return store.diffs.first
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(palette.borderColor.opacity(0.45))

            if store.diffs.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    fileListPane
                        .frame(width: 240)
                    Divider().overlay(palette.borderColor.opacity(0.45))
                    if let file = selectedFile {
                        diffContentPane(for: file)
                    }
                }
            }
        }
        .background(palette.backgroundColor)
        .frame(minWidth: 780, minHeight: 520)
        .onAppear {
            splitMode = store.settings.splitDiffView
            selectedFileID = store.diffs.first?.id
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(palette.accentColor)
            Text("Diff Review")
                .font(.headline)
                .foregroundStyle(palette.textPrimaryColor)
            if !store.diffs.isEmpty {
                Text("\(store.diffs.count) file\(store.diffs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(palette.textMutedColor)
            }
            Spacer()
            Picker("Diff Layout", selection: $splitMode) {
                Text("Unified").tag(false)
                Text("Split").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)

            Button {
                Task { await store.refreshDiffs() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Done") {
                store.isDiffReviewPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.surfaceRaisedColor)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(palette.successColor)
            Text("Working Tree Clean")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.textPrimaryColor)
            Text("No modified files or session diffs detected in this workspace.")
                .font(.callout)
                .foregroundStyle(palette.textMutedColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileListPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(store.diffs) { file in
                    let isSelected = file.id == selectedFile?.id
                    Button {
                        selectedFileID = file.id
                    } label: {
                        HStack(spacing: 8) {
                            statusBadge(file.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(palette.textPrimaryColor)
                                    .lineLimit(1)
                                Text(file.path)
                                    .font(.caption2)
                                    .foregroundStyle(palette.textMutedColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            HStack(spacing: 4) {
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
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? palette.surfaceHighColor : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(palette.surfaceRaisedColor.opacity(0.5))
    }

    private func statusBadge(_ status: String) -> some View {
        let letter: String
        let color: Color
        switch status.lowercased() {
        case "added":
            letter = "A"
            color = palette.diffAddedTextColor
        case "deleted":
            letter = "D"
            color = palette.diffRemovedTextColor
        default:
            letter = "M"
            color = palette.warningColor
        }
        return Text(letter)
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
    }

    private func diffContentPane(for file: AppFileDiffItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(file.path)
                    .font(.callout.monospaced().weight(.medium))
                    .foregroundStyle(palette.textPrimaryColor)
                Spacer()
                Text("+\(file.additions)  -\(file.deletions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.textMutedColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(palette.surfaceRaisedColor)

            Divider().overlay(palette.borderColor.opacity(0.35))

            ScrollView([.vertical, .horizontal]) {
                if splitMode {
                    splitDiffTable(file.splitRows)
                } else {
                    unifiedDiffTable(file.unifiedLines)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func unifiedDiffTable(_ lines: [AppDiffLine]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(spacing: 8) {
                    Text(line.oldLineNumber.map(String.init) ?? "")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(palette.diffLineNumberColor)
                        .frame(width: 38, alignment: .trailing)
                    Text(line.newLineNumber.map(String.init) ?? "")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(palette.diffLineNumberColor)
                        .frame(width: 38, alignment: .trailing)
                    Text(prefixSymbol(for: line.kind))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(lineForeground(for: line.kind))
                        .frame(width: 12, alignment: .center)
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(lineForeground(for: line.kind))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(lineBackground(for: line.kind))
            }
        }
        .padding(.vertical, 6)
    }

    private func splitDiffTable(_ rows: [AppSplitDiffRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 0) {
                    splitCell(row.left, isLeft: true)
                    Divider().overlay(palette.borderColor.opacity(0.35))
                    splitCell(row.right, isLeft: false)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func splitCell(_ line: AppDiffLine?, isLeft: Bool) -> some View {
        let kind = line?.kind ?? .context
        let number = isLeft ? line?.oldLineNumber : line?.newLineNumber
        return HStack(spacing: 6) {
            Text(number.map(String.init) ?? "")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(palette.diffLineNumberColor)
                .frame(width: 34, alignment: .trailing)
            Text(line?.text ?? "")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(line != nil ? lineForeground(for: kind) : palette.textFaintColor)
                .textSelection(.enabled)
                .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(line != nil ? lineBackground(for: kind) : palette.surfaceRaisedColor.opacity(0.25))
    }

    private func prefixSymbol(for kind: AppDiffLineKind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .header: return "@"
        case .context: return " "
        }
    }

    private func lineForeground(for kind: AppDiffLineKind) -> Color {
        switch kind {
        case .added: return palette.diffAddedTextColor
        case .removed: return palette.diffRemovedTextColor
        case .header: return palette.diffHunkHeaderColor
        case .context: return palette.textPrimaryColor
        }
    }

    private func lineBackground(for kind: AppDiffLineKind) -> Color {
        switch kind {
        case .added: return palette.diffAddedBackgroundColor.opacity(0.65)
        case .removed: return palette.diffRemovedBackgroundColor.opacity(0.65)
        case .header: return palette.surfaceHighColor.opacity(0.5)
        case .context: return Color.clear
        }
    }
}
#endif
