import SwiftUI
import TownDockCore

struct ConvexMaintenanceSheet: View {
    @EnvironmentObject private var store: TownStore
    @Environment(\.dismiss) private var dismiss

    let worktree: WorktreeSnapshot

    @State private var action: ConvexMaintenanceAction = .clearData
    @State private var acknowledged = false
    @State private var showingFinalConfirmation = false

    private var plan: ConvexMaintenancePlan? { store.convexMaintenancePlan }
    private var dashboardService: ServiceSnapshot? {
        worktree.instance?.services.first { $0.kind == .convexDashboard }
    }
    private var convexDashboardURL: URL? {
        guard let instance = worktree.instance,
              let dashboardURL = dashboardService?.url,
              let backend = instance.services.first(where: { $0.kind == .convexBackend }),
              var components = URLComponents(url: dashboardURL, resolvingAgainstBaseURL: false)
        else { return nil }

        components.queryItems = [
            URLQueryItem(name: "d", value: "instance-\(instance.number)"),
            URLQueryItem(
                name: "deploymentUrl",
                value: "http://127.0.0.1:\(backend.port)"
            ),
        ]
        return components.url
    }
    private var isDashboardRunning: Bool {
        guard let state = dashboardService?.state else { return false }
        return state == .running || state == .degraded
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    identityCard
                    actionPicker

                    if store.isPreparingConvexMaintenance {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Verifying local Convex ownership…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(28)
                    } else if let plan {
                        planContent(plan)
                    }

                    if let error = store.convexMaintenanceError {
                        errorCard(error)
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 680, height: 650)
        .background(TownTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(TownTheme.accent)
        .interactiveDismissDisabled(store.isExecutingConvexMaintenance)
        .transaction { $0.animation = nil }
        .onChange(of: action) { _, newAction in
            acknowledged = false
            Task { await store.prepareConvexMaintenance(action: newAction) }
        }
        .alert(finalTitle, isPresented: $showingFinalConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(finalButtonTitle, role: .destructive) {
                Task {
                    if await store.executeConvexMaintenance() { dismiss() }
                }
            }
        } message: {
            Text(finalMessage)
        }
        .onDisappear {
            if !store.isExecutingConvexMaintenance { store.dismissConvexMaintenance() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.orange.opacity(0.12))
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Manage Local Convex")
                    .font(.title2.weight(.semibold))
                Text("Clear data or rebuild this worktree’s isolated instance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if let convexDashboardURL {
                Button {
                    store.openInChrome(convexDashboardURL)
                } label: {
                    Label("Open Dashboard", systemImage: "arrow.up.right")
                }
                .buttonStyle(LinearButtonStyle())
                .disabled(!isDashboardRunning || store.isExecutingConvexMaintenance)
            }

            Button {
                store.dismissConvexMaintenance()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.isExecutingConvexMaintenance)
        }
        .padding(18)
    }

    private var identityCard: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(worktree.displayName)
                        .font(.headline)
                    Spacer()
                    if let number = plan?.instanceNumber ?? worktree.instance?.number {
                        Text("Instance \(number)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(worktree.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let state = plan?.stateDirectory {
                    HStack(spacing: 7) {
                        Image(systemName: "internaldrive")
                        Text(state.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(state.sizeBytes.byteCountLabel)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .townTooltip("Verified per-instance Convex state directory: \(state.path)")
                }
            }
        }
    }

    private var actionPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Operation")
                .font(.headline)
            Picker("Operation", selection: $action) {
                ForEach(ConvexMaintenanceAction.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(store.isExecutingConvexMaintenance)
        }
    }

    private func planContent(_ plan: ConvexMaintenancePlan) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            if !plan.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Cannot run this operation", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(plan.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.orange.opacity(0.22), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(action == .clearData ? "What will be cleared" : "What the reset will do")
                    .font(.headline)
                ForEach(Array(plan.impacts.enumerated()), id: \.offset) { _, impact in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TownTheme.muted)
                            .frame(width: 14, height: 16)
                        Text(impact)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(TownTheme.border, lineWidth: 1)
            }

            Toggle(isOn: $acknowledged) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(acknowledgementTitle)
                        .font(.subheadline.weight(.medium))
                    Text("You will see one final confirmation before anything is changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!plan.canExecute || store.isExecutingConvexMaintenance)
            .padding(14)
            .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.red.opacity(0.18), lineWidth: 1)
            }
        }
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Convex maintenance stopped safely")
                    .font(.subheadline.weight(.semibold))
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Verify Again") {
                    Task { await store.prepareConvexMaintenance(action: action) }
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
            Text(action == .clearData
                 ? "Local Convex only — cloud deployments are never eligible."
                 : "The worktree and shared infrastructure are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                store.dismissConvexMaintenance()
                dismiss()
            }
            .disabled(store.isExecutingConvexMaintenance)
            Button {
                showingFinalConfirmation = true
            } label: {
                if store.isExecutingConvexMaintenance {
                    ProgressView().controlSize(.small)
                } else {
                    Text(action == .clearData ? "Clear Convex Data…" : "Reset Convex Instance…")
                }
            }
            .buttonStyle(LinearButtonStyle(destructive: true))
            .disabled(!(plan?.canExecute == true && acknowledged) || store.isExecutingConvexMaintenance)
        }
        .padding(16)
    }

    private var acknowledgementTitle: String {
        action == .clearData
            ? "I understand all local Convex table data will be permanently cleared"
            : "I understand the local Convex database, uploads, keys, and configuration will be permanently reset"
    }

    private var finalTitle: String {
        action == .clearData ? "Clear local Convex data?" : "Fully reset this Convex instance?"
    }

    private var finalButtonTitle: String {
        action == .clearData ? "Clear Data" : "Reset Instance"
    }

    private var finalMessage: String {
        action == .clearData
            ? "Every application and Agent component table in this worktree’s pinned local Convex instance will be emptied. This cannot be undone."
            : "Town Sheriff will stop this worktree’s stack, delete its verified Convex state, and launch a fresh instance on the same ports. This cannot be undone."
    }
}
