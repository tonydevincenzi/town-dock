import SwiftUI
import TownDockCore

struct OrphanCleanupSheet: View {
    @EnvironmentObject private var store: TownStore
    @Environment(\.dismiss) private var dismiss
    @State private var deletionAcknowledged = false

    private var manifest: OrphanCleanupManifest? { store.orphanCleanupManifest }
    private var actionableTargets: [DestructiveTarget] {
        manifest?.targets.filter { $0.actionable && $0.selectedByDefault } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.isPreparingOrphanCleanup {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Building a fresh orphan cleanup manifest…")
                                .foregroundStyle(TownTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(36)
                    } else if let manifest {
                        manifestContent(manifest)
                    } else if let error = store.orphanCleanupError {
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
        .interactiveDismissDisabled(store.isExecutingOrphanCleanup)
        .onDisappear {
            if !store.isExecutingOrphanCleanup { store.dismissOrphanCleanup() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.red.opacity(0.10))
                Image(systemName: "trash.fill")
                    .foregroundStyle(.red)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Remove All Orphans")
                    .font(.title3.weight(.semibold))
                Text("End verified processes and permanently remove attributable local resources")
                    .font(.caption)
                    .foregroundStyle(TownTheme.muted)
            }
            Spacer()
            Button {
                store.dismissOrphanCleanup()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(TownTheme.muted)
            }
            .buttonStyle(.plain)
            .disabled(store.isExecutingOrphanCleanup)
        }
        .padding(18)
    }

    @ViewBuilder
    private func manifestContent(_ manifest: OrphanCleanupManifest) -> some View {
        InsetCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(actionableTargets.count) verified targets")
                        .font(.headline)
                    Text("Town Dock will rediscover everything and require this exact target set before the first change.")
                        .font(.caption)
                        .foregroundStyle(TownTheme.muted)
                }
                Spacer()
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("Cleanup manifest")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(manifest.targets) { target in
                    OrphanCleanupTargetRow(target: target)
                    if target.id != manifest.targets.last?.id {
                        Rectangle().fill(TownTheme.border).frame(height: 1)
                    }
                }
            }
            .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(TownTheme.border, lineWidth: 1)
            }
        }

        if !manifest.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Safety boundaries", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline.weight(.semibold))
                ForEach(manifest.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(TownTheme.muted)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.orange.opacity(0.16), lineWidth: 1)
            }
        }

        Toggle(isOn: $deletionAcknowledged) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Permanently delete these verified orphan resources")
                    .font(.subheadline.weight(.semibold))
                Text("This removes the listed processes and local storage and cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(TownTheme.muted)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(store.isExecutingOrphanCleanup || !manifest.canExecute)
        .padding(14)
        .background(Color.red.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.red.opacity(0.16), lineWidth: 1)
        }

        if let error = store.orphanCleanupError {
            errorCard(error)
        }
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 5) {
                Text("Cannot clean up orphans")
                    .font(.subheadline.weight(.semibold))
                Text(error)
                    .font(.caption)
                    .foregroundStyle(TownTheme.muted)
                    .textSelection(.enabled)
                Button("Build Fresh Manifest") {
                    deletionAcknowledged = false
                    Task { await store.prepareOrphanCleanup() }
                }
                .buttonStyle(LinearButtonStyle())
                .padding(.top, 3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private var footer: some View {
        HStack {
            Text(footerStatus)
                .font(.caption)
                .foregroundStyle(TownTheme.muted)
                .lineLimit(1)
            Spacer()
            Button("Cancel") {
                store.dismissOrphanCleanup()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(store.isExecutingOrphanCleanup)

            Button(role: .destructive) {
                Task {
                    if await store.executeOrphanCleanup() {
                        dismiss()
                    }
                }
            } label: {
                if store.isExecutingOrphanCleanup {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        if let progress = store.orphanCleanupProgress {
                            Text("\(progress.completedTargets) of \(progress.totalTargets)")
                        } else {
                            Text("Revalidating…")
                        }
                    }
                } else {
                    Text("Remove \(actionableTargets.count) Targets")
                }
            }
            .keyboardShortcut(.defaultAction)
            .townTooltip("Permanently remove every verified target shown in this cleanup manifest.")
            .disabled(
                store.isExecutingOrphanCleanup
                    || !deletionAcknowledged
                    || manifest?.canExecute != true
            )
        }
        .padding(16)
    }

    private var footerStatus: String {
        guard store.isExecutingOrphanCleanup else {
            return "Permanent local deletion. No worktree or shared service is targeted."
        }
        guard let progress = store.orphanCleanupProgress else {
            return "Revalidating the reviewed orphan manifest…"
        }
        return "Removing \(progress.currentTargetLabel)"
    }
}

private struct OrphanCleanupTargetRow: View {
    let target: DestructiveTarget

    private var symbol: String {
        switch target.kind {
        case .processGroup: "cpu"
        case .dockerContainer: "shippingbox"
        case .dockerVolume: "externaldrive"
        case .postgresReplicationSlot: "point.3.connected.trianglepath.dotted"
        case .postgresDatabase: "cylinder"
        case .convexStateDirectory: "internaldrive"
        default: "questionmark.square.dashed"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: target.actionable ? symbol : "lock.fill")
                .foregroundStyle(target.actionable ? Color.secondary : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(target.label)
                    .font(.subheadline.weight(.medium))
                Text(target.identifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(TownTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let bytes = target.estimatedBytes, bytes > 0 {
                Text(bytes.byteCountLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TownTheme.muted)
            }
            Text(target.actionable ? "REMOVE" : "SKIP")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(target.actionable ? Color.red : TownTheme.muted)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .townTooltip(
            [
                target.actionable
                    ? "Verified target that will be permanently removed after confirmation."
                    : "Excluded because Town Dock cannot safely prove ownership.",
                target.note,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        )
    }
}
