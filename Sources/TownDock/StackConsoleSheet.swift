import SwiftUI
import TownDockCore

struct StackConsoleSheet: View {
    @EnvironmentObject private var store: TownStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRestart = false

    let worktree: WorktreeSnapshot

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            console
            Divider()
            footer
        }
        .frame(minWidth: 840, idealWidth: 1_040, minHeight: 540, idealHeight: 700)
        .background(TownTheme.canvas)
        .preferredColorScheme(.dark)
        .transaction { $0.animation = nil }
        .task(id: worktree.id) {
            while !Task.isCancelled {
                await store.refreshConsole()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear {
            if store.consoleWorktree?.id == worktree.id { store.dismissConsole() }
        }
        .confirmationDialog(
            "Restart \(worktree.displayName) and begin capturing its console?",
            isPresented: $confirmRestart,
            titleVisibility: .visible
        ) {
            Button("Restart & Capture") { store.restart(worktree) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This briefly stops the current local stack, then relaunches the same instance through Town Dock’s recorder.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TownTheme.surfaceRaised)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(worktree.displayName) console")
                    .font(.system(size: 15, weight: .semibold))
                Text("Unified output from mise run local-stack")
                    .font(.caption)
                    .foregroundStyle(TownTheme.muted)
            }

            Spacer()

            if store.isRefreshingConsole {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Copy Latest", systemImage: "doc.on.doc") {
                store.copyLatestConsoleLines()
            }
            .buttonStyle(LinearButtonStyle())
            .disabled(!canCopy)
            .townTooltip("Copy the latest 200 redacted lines for sharing in an issue or with an LLM.")

            Button("Copy All", systemImage: "document.on.document") {
                store.copyConsole()
            }
            .buttonStyle(LinearButtonStyle())
            .disabled(!canCopy)

            Button("Done") { dismiss() }
                .buttonStyle(LinearButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var console: some View {
        if let error = store.consoleError {
            ContentUnavailableView(
                "Couldn’t read stack output",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let snapshot = store.stackConsole, snapshot.source == .unavailable {
            ContentUnavailableView {
                Label("No captured console yet", systemImage: "terminal")
            } description: {
                Text("Start or restart this worktree through Town Dock to capture its exact local-stack stream.")
            } actions: {
                Button(worktree.instance?.isRunning == true ? "Restart & Capture…" : "Start & Capture") {
                    if worktree.instance?.isRunning == true {
                        confirmRestart = true
                    } else {
                        store.start(worktree)
                    }
                }
                .buttonStyle(LinearButtonStyle(emphasized: true))
                .disabled(
                    store.isOperating(on: worktree.id)
                        || (worktree.instance?.isRunning != true && !worktree.setupComplete)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.035, green: 0.039, blue: 0.045))
        } else if let snapshot = store.stackConsole {
            ScrollView([.horizontal, .vertical]) {
                Text(snapshot.text.isEmpty ? "Waiting for local-stack output…" : snapshot.text)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(red: 0.83, green: 0.85, blue: 0.88))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color(red: 0.035, green: 0.039, blue: 0.045))
        } else {
            VStack {
                ProgressView()
                    .controlSize(.small)
                Text("Finding this stack’s unified output…")
                    .font(.caption)
                    .foregroundStyle(TownTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.035, green: 0.039, blue: 0.045))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sourceColor)
                .frame(width: 6, height: 6)
            Text(store.stackConsole?.source.displayName ?? "Locating source")
                .font(.caption.weight(.medium))

            if store.stackConsole?.isTruncated == true {
                Text("· showing recent output")
                    .foregroundStyle(TownTheme.muted)
            }
            if let modifiedAt = store.stackConsole?.modifiedAt {
                Text("· updated \(modifiedAt.relativeLabel)")
                    .foregroundStyle(TownTheme.muted)
            }

            Spacer()

            Label("Secrets are redacted before display and copy", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(TownTheme.muted)
                .townTooltip("Town Dock masks common tokens, credentials, admin keys, passwords, and private keys in this view.")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(TownTheme.surface)
    }

    private var sourceColor: Color {
        switch store.stackConsole?.source {
        case .managedCapture: .green
        case .terminalScrollback: TownTheme.accent
        case .unavailable, .none: TownTheme.muted
        }
    }

    private var canCopy: Bool {
        guard let snapshot = store.stackConsole else { return false }
        return snapshot.source != .unavailable && !snapshot.text.isEmpty
    }
}
