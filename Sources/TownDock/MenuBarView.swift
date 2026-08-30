import AppKit
import SwiftUI
import TownDockCore

struct MenuBarView: View {
    @EnvironmentObject private var store: TownStore
    let showDashboardAction: () -> Void
    let checkForUpdatesAction: () -> Void
    let updatesEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            Divider()

            if store.snapshot.worktrees.isEmpty {
                VStack(spacing: 8) {
                    if store.isRefreshing {
                        ProgressView()
                        Text("Scanning Town…")
                    } else {
                        PhosphorStackIcon(color: .secondary)
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.secondary)
                        Text("No worktrees found")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.snapshot.worktrees.prefix(7)) { worktree in
                            MenuBarWorktreeRow(worktree: worktree)
                            if worktree.id != store.snapshot.worktrees.prefix(7).last?.id {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            if !store.snapshot.orphans.isEmpty {
                Divider()
                Button {
                    showDashboard()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(store.snapshot.orphans.count) orphan\(store.snapshot.orphans.count == 1 ? "" : "s") need attention")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
            }

            Divider()
            footer
                .padding(10)
        }
        .frame(width: 370)
        .background(TownTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(TownTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                PhosphorStackIcon()
                    .padding(7)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Town Dock")
                    .font(.headline)
                Text("\(store.runningWorktreeCount) running · \(store.snapshot.worktrees.count) worktrees")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .townTooltip("Refresh")
            .disabled(store.isRefreshing)
        }
    }

    private var footer: some View {
        VStack(spacing: 9) {
            HStack {
                Button("Open Town Dock") { showDashboard() }
                    .keyboardShortcut("o")
                Spacer()
                Text("v\(appVersion)")
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Button(
                    updatesEnabled ? "Check for Updates…" : "Update status…",
                    action: checkForUpdatesAction
                )
                .townTooltip(updatesEnabled ? "Check for a newer Town Dock release" : "Show why updates are unavailable")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func showDashboard() {
        showDashboardAction()
    }
}

private struct MenuBarWorktreeRow: View {
    @EnvironmentObject private var store: TownStore
    let worktree: WorktreeSnapshot

    private var isRunning: Bool { worktree.instance?.isRunning == true }
    private var state: ServiceState {
        worktree.health?.overall ?? (isRunning ? .running : .stopped)
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: state, size: 8)
                .townTooltip(state.helpText)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(worktree.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let number = worktree.instance?.number {
                        Text("N=\(number)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .townTooltip("Town instance \(number), which determines this worktree's ports and local storage.")
                    }
                }
                Text(isRunning ? serviceSummary : "Stopped")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            if let url = worktree.frontendURL {
                Button { store.openInChrome(url) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .townTooltip("Open frontend in Chrome")
            }

            Menu {
                Button("Open in Finder") { store.revealInFinder(path: worktree.path) }
                Button("Open in Terminal") { store.openTerminal(at: worktree.path) }
                Divider()
                if isRunning {
                    Button("Stop") { store.stop(worktree) }
                    Button("Restart") { store.restart(worktree) }
                    Button("Kill All", role: .destructive) { store.forceKill(worktree) }
                } else {
                    Button("Start") { store.start(worktree) }
                        .disabled(!worktree.setupComplete)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .tint(TownTheme.muted)
            .fixedSize()
            .disabled(store.isOperating(on: worktree.id))
            .townTooltip("More actions for \(worktree.displayName)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var serviceSummary: String {
        let running = worktree.instance?.services.filter { $0.state == .running || $0.state == .degraded } ?? []
        guard !running.isEmpty else { return "No listeners" }
        return running.prefix(3).map { "\($0.kind.displayName) :\($0.port)" }.joined(separator: " · ")
    }
}
