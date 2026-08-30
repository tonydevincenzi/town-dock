import SwiftUI
import TownDockCore

struct LogConsoleSheet: View {
    @EnvironmentObject private var store: TownStore
    @Environment(\.dismiss) private var dismiss

    let worktree: WorktreeSnapshot

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                logList
                    .frame(width: 210)
                Divider()
                logDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 840, idealWidth: 980, minHeight: 520, idealHeight: 640)
        .background(TownTheme.canvas)
        .preferredColorScheme(.dark)
        .transaction { $0.animation = nil }
        .task(id: worktree.id) {
            while !Task.isCancelled {
                await store.refreshLogs()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear {
            if store.logWorktree?.id == worktree.id { store.dismissLogs() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TownTheme.surfaceRaised)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TownTheme.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(worktree.displayName) logs")
                    .font(.system(size: 15, weight: .semibold))
                Text("Live, bounded tails from this worktree’s service logs")
                    .font(.caption)
                    .foregroundStyle(TownTheme.muted)
            }

            Spacer()

            if store.isRefreshingLogs {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Reveal Logs", systemImage: "folder") {
                store.revealLogs(for: worktree)
            }
            .buttonStyle(LinearButtonStyle())
            .townTooltip("Reveal this worktree’s logs folder in Finder.")

            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.refreshLogs() }
            }
            .buttonStyle(LinearButtonStyle())
            .disabled(store.isRefreshingLogs)

            Button("Done") { dismiss() }
                .buttonStyle(LinearButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var logList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SERVICE LOGS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TownTheme.muted)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if store.worktreeLogs.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(store.logError ?? "No logs yet")
                        .font(.caption.weight(.medium))
                    Text("Start the stack and Town’s service logs will appear here automatically.")
                        .font(.caption2)
                        .foregroundStyle(TownTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.worktreeLogs) { file in
                            Button {
                                store.selectedLogID = file.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(file.sizeBytes.byteCountLabel)
                                        if let modifiedAt = file.modifiedAt {
                                            Text("· \(modifiedAt.relativeLabel)")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(TownTheme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    store.selectedLogID == file.id ? TownTheme.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(TownTheme.sidebar)
    }

    @ViewBuilder
    private var logDetail: some View {
        if let file = store.selectedLog {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(file.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    if file.isTruncated {
                        Text("TAIL")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(TownTheme.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(TownTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                            .townTooltip("This large log is bounded to its most recent output to keep the app responsive.")
                    }
                    Spacer()
                    Text(file.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(TownTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(TownTheme.surface)

                Divider()

                ScrollView([.horizontal, .vertical]) {
                    Text(file.text.isEmpty ? "No output yet." : file.text)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.bottom)
            }
        } else {
            ContentUnavailableView(
                "No service logs",
                systemImage: "text.alignleft",
                description: Text("Town Dock will show bounded live output when this worktree creates logs/*.log.")
            )
        }
    }
}
