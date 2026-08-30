import SwiftUI
import TownDockCore

struct NukeSheet: View {
    @EnvironmentObject private var store: TownStore
    @Environment(\.dismiss) private var dismiss

    let worktree: WorktreeSnapshot

    @State private var deletionAcknowledged = false
    @State private var showingFinalConfirmation = false
    @State private var deleteLocalBranch = false

    private var manifest: NukeManifest? { store.nukeManifest }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identityCard

                    if store.isPreparingNuke {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Building a fresh deletion manifest…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(28)
                    } else if let manifest {
                        manifestContent(manifest)
                    } else if let error = store.nukeError {
                        errorCard(error)
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 680)
        .background(TownTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(TownTheme.accent)
        .interactiveDismissDisabled(store.isExecutingNuke)
        .onChange(of: deleteLocalBranch) { _, newValue in
            deletionAcknowledged = false
            Task { await store.prepareNuke(deleteLocalBranch: newValue) }
        }
        .alert("Nuke \(worktree.displayName)?", isPresented: $showingFinalConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Nuke Worktree", role: .destructive) {
                Task {
                    if await store.executeNuke(deleteLocalBranch: deleteLocalBranch) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("This permanently deletes the checkout, every untracked file beneath it, attributed processes, and verified local storage. This cannot be undone.")
        }
        .onDisappear {
            if !store.isExecutingNuke { store.dismissNuke() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.13))
                Image(systemName: "trash.slash.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Nuke Worktree")
                    .font(.title2.weight(.semibold))
                Text("Permanently remove its processes, services, and local storage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.dismissNuke()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.isExecutingNuke)
        }
        .padding(18)
    }

    private var identityCard: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(worktree.displayName)
                        .font(.headline)
                    if worktree.gitStatus.isDirty {
                        Label("Dirty working tree", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.gray)
                            .townTooltip("This worktree contains modified, staged, or untracked files that deletion would permanently remove.")
                    }
                    Spacer()
                    if let instance = worktree.instance?.number {
                        Text("Instance \(instance)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .townTooltip("Town instance number used to identify this worktree's ports and isolated storage.")
                    }
                }
                Text(worktree.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    Label("\(worktree.gitStatus.modifiedCount) modified", systemImage: "pencil")
                        .townTooltip("Tracked files whose contents differ from the latest commit.")
                    Label("\(worktree.gitStatus.untrackedCount) untracked", systemImage: "questionmark.diamond")
                        .townTooltip("Files Git has not been asked to track; they would also be permanently deleted.")
                    Label("\(worktree.gitStatus.ahead) ahead", systemImage: "arrow.up")
                        .townTooltip("Local commits that have not been pushed to the configured upstream branch.")
                    Label("\(worktree.gitStatus.behind) behind", systemImage: "arrow.down")
                        .townTooltip("Upstream commits that have not been incorporated into this local branch.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func manifestContent(_ manifest: NukeManifest) -> some View {
        if !manifest.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Review before deleting", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(manifest.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.orange.opacity(0.25), lineWidth: 1)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Deletion manifest")
                    .font(.headline)
                Spacer()
                Text("\(manifest.targets.filter { $0.actionable && $0.selectedByDefault }.count) actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(manifest.targets) { target in
                    DestructiveTargetRow(target: target)
                    if target.id != manifest.targets.last?.id { Divider() }
                }
            }
            .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(TownTheme.border, lineWidth: 1)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $deleteLocalBranch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also delete the local Git branch")
                        .font(.subheadline.weight(.medium))
                    Text(worktree.branch ?? "This checkout is detached; no local branch is available.")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(worktree.branch == nil || store.isExecutingNuke)

            Divider()

            Toggle(isOn: $deletionAcknowledged) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("I understand this deletion is permanent")
                        .font(.subheadline.weight(.medium))
                    Text("You will see one final confirmation before anything is deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
                .toggleStyle(.checkbox)
                .disabled(store.isExecutingNuke || !manifest.canExecute)
        }
        .padding(14)
        .background(.red.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.red.opacity(0.2), lineWidth: 1)
        }

        if let error = store.nukeError {
            errorCard(error)
        }
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cannot prepare deletion")
                    .font(.subheadline.weight(.semibold))
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Try Again") {
                    Task { await store.prepareNuke(deleteLocalBranch: deleteLocalBranch) }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack {
            Text("This cannot be undone.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
            Spacer()
            Button("Cancel") {
                store.dismissNuke()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(store.isExecutingNuke)

            Button(role: .destructive) {
                showingFinalConfirmation = true
            } label: {
                if store.isExecutingNuke {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Nuking…")
                    }
                } else {
                    Label("Nuke Worktree", systemImage: "trash.slash.fill")
                }
            }
            .townTooltip("Stop attributed processes and permanently delete the selected worktree resources.")
            .disabled(
                !deletionAcknowledged
                    || manifest?.canExecute != true
                    || store.isPreparingNuke
                    || store.isExecutingNuke
            )
        }
        .padding(16)
    }
}

private struct DestructiveTargetRow: View {
    let target: DestructiveTarget

    private var willDelete: Bool {
        target.actionable && target.selectedByDefault
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: willDelete ? target.kind.symbol : "questionmark.diamond")
                .foregroundStyle(willDelete ? .red : .orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(target.label)
                        .font(.subheadline.weight(.medium))
                    Text(target.confidence.rawValue.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(target.confidence.tint)
                        .townTooltip(target.confidence.helpText)
                }
                Text(target.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let note = target.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let bytes = target.estimatedBytes {
                Text(bytes.byteCountLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .townTooltip("Estimated disk space this deletion will reclaim")
            }
            Image(systemName: willDelete ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(willDelete ? .red : .secondary)
                .townTooltip(willDelete ? "Included in the deletion manifest" : "Excluded because ownership is not safe to establish")
        }
        .padding(11)
        .opacity(willDelete ? 1 : 0.72)
    }
}

private extension DestructiveTargetKind {
    var symbol: String {
        switch self {
        case .processGroup, .listener: "cpu"
        case .dockerContainer, .dockerVolume: "shippingbox"
        case .postgresDatabase, .postgresReplicationSlot: "cylinder"
        case .minioBucket: "archivebox"
        case .convexStateDirectory, .worktreeDirectory: "folder"
        case .tunnelMarker: "point.3.connected.trianglepath.dotted"
        case .gitRegistration, .localBranch: "arrow.triangle.branch"
        case .remoteSubscription: "envelope"
        case .temporalHistory: "clock.arrow.circlepath"
        }
    }
}
