import AppKit
import SwiftUI
import TownDockCore

struct DashboardView: View {
    @EnvironmentObject private var store: TownStore
    @State private var selection: DashboardSection = .worktrees
    @State private var isSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                sidebar
                    .frame(width: 224)

                Rectangle()
                    .fill(TownTheme.border)
                    .frame(width: 1)
            }

            detail
                .background(TownTheme.canvas.ignoresSafeArea())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar }
        .navigationTitle("Town Dock")
        .preferredColorScheme(.dark)
        .tint(TownTheme.accent)
        .sheet(item: $store.nukeWorktree) { worktree in
            NukeSheet(worktree: worktree)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.bulkNukePresented) {
            BulkNukeSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.orphanCleanupPresented) {
            OrphanCleanupSheet()
                .environmentObject(store)
        }
        .overlay(alignment: .top) {
            notificationOverlay
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                    PhosphorStackIcon()
                        .padding(6)
                }
                .frame(width: 30, height: 30)
                Text("Town Dock")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                StatusDot(
                    state: store.runningWorktreeCount > 0 ? .running : .stopped,
                    size: 7
                )
                .townTooltip("\(store.runningWorktreeCount) of \(store.snapshot.worktrees.count) worktrees running")
            }
            .padding(.horizontal, 13)
            .padding(.top, 13)
            .padding(.bottom, 20)

            sidebarSection("Town") {
                sidebarRow(.worktrees, count: store.snapshot.worktrees.count)
                sidebarRow(.orphans, count: store.snapshot.orphans.count)
            }

            sidebarSection("Machine") {
                sidebarRow(.infrastructure, count: store.snapshot.sharedServices.count)
                sidebarRow(.storage, count: store.snapshot.dormantStates.count)
            }

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text("Repository")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(TownTheme.muted)
                    .textCase(nil)
                Text(store.repositoryPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(TownTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .townTooltip("Town repository being monitored: \(store.repositoryPath)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .overlay(alignment: .top) {
                Rectangle().fill(TownTheme.border).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TownTheme.sidebar.ignoresSafeArea())
    }

    private func sidebarSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(TownTheme.muted)
                .textCase(nil)
                .padding(.horizontal, 15)
                .padding(.bottom, 4)
            content()
        }
        .padding(.bottom, 17)
    }

    private func sidebarRow(_ section: DashboardSection, count: Int) -> some View {
        Button {
            selection = section
        } label: {
            HStack {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 17)
                Text(section.title)
                    .font(.system(size: 13, weight: .regular))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(section == .orphans ? .orange : TownTheme.muted)
                }
            }
            .foregroundStyle(selection == section ? Color.primary : TownTheme.muted)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                selection == section ? TownTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .townTooltip(section.helpText(count: count))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .worktrees:
            WorktreesDashboard()
        case .orphans:
            OrphansDashboard()
        case .infrastructure:
            SharedInfrastructureDashboard()
        case .storage:
            DormantStorageDashboard()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                isSidebarVisible.toggle()
            } label: {
                Label(
                    isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                    systemImage: "sidebar.left"
                )
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Text("Updated \(store.snapshot.generatedAt.relativeLabel)")
                .font(.caption)
                .foregroundStyle(TownTheme.muted)
                .townTooltip("Last refreshed \(store.snapshot.generatedAt.formatted())")

            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")
        }
    }

    @ViewBuilder
    private var notificationOverlay: some View {
        if let error = store.lastError {
            NotificationBanner(text: error, style: .error) {
                store.dismissError()
            }
                .padding(.top, 10)
                .padding(.horizontal, 18)
        } else if let message = store.activityMessage {
            NotificationBanner(text: message, style: .success) {
                store.dismissActivity()
            }
            .padding(.top, 10)
            .padding(.horizontal, 18)
        }
    }
}

private enum DashboardSection: String, Hashable {
    case worktrees
    case orphans
    case infrastructure
    case storage

    var title: String {
        switch self {
        case .worktrees: "Worktrees"
        case .orphans: "Orphans"
        case .infrastructure: "Shared Services"
        case .storage: "Dormant Storage"
        }
    }

    var symbol: String {
        switch self {
        case .worktrees: "arrow.triangle.branch"
        case .orphans: "exclamationmark.triangle"
        case .infrastructure: "server.rack"
        case .storage: "externaldrive"
        }
    }

    func helpText(count: Int) -> String {
        switch self {
        case .worktrees: "Show all \(count) detected Town worktrees and their running services."
        case .orphans: "Show \(count) processes or resources that are not owned by a current worktree."
        case .infrastructure: "Show \(count) shared services used across Town instances."
        case .storage: "Show \(count) local state directories not used by a running stack."
        }
    }
}

private struct WorktreesDashboard: View {
    @EnvironmentObject private var store: TownStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    SectionHeader(
                        "Town worktrees",
                        subtitle: "Live services, Git state, and controls for every checkout",
                        symbol: "arrow.triangle.branch",
                        count: store.snapshot.worktrees.count
                    )

                    Button(role: .destructive) {
                        store.requestBulkNuke()
                    } label: {
                        Label("Bulk Nuke…", systemImage: "trash.slash")
                    }
                    .buttonStyle(LinearButtonStyle(destructive: true))
                    .disabled(store.snapshot.worktrees.allSatisfy(\.isPrimary))
                    .townTooltip("Select and permanently remove multiple non-primary worktrees.")
                }
                .padding(.bottom, 4)

                ForEach(sortedWorktrees) { worktree in
                    WorktreeCard(worktree: worktree)
                }

                if store.snapshot.worktrees.isEmpty, store.isRefreshing {
                    InsetCard {
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Discovering Town worktrees…")
                                    .font(.subheadline.weight(.semibold))
                                Text("Inspecting Git checkouts, listeners, process ownership, and local storage.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if store.snapshot.worktrees.isEmpty, !store.isRefreshing {
                    EmptySectionView(
                        title: "No worktrees found",
                        detail: "Town Dock searched \(store.repositoryPath). Set TOWN_REPOSITORY_PATH before launching to use another checkout.",
                        symbol: "arrow.triangle.branch"
                    )
                }

                if !store.snapshot.warnings.isEmpty {
                    warnings
                }
            }
            .padding(22)
        }
    }

    private var sortedWorktrees: [WorktreeSnapshot] {
        store.snapshot.worktrees.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            let lhsRunning = $0.instance?.isRunning == true
            let rhsRunning = $1.instance?.isRunning == true
            if lhsRunning != rhsRunning { return lhsRunning }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var warnings: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 9) {
                Label("Discovery warnings", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(store.snapshot.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct OrphansDashboard: View {
    @EnvironmentObject private var store: TownStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    SectionHeader(
                        "Orphaned Town resources",
                        subtitle: "Processes, ports, storage, and Docker resources not attached to a live worktree",
                        symbol: "exclamationmark.triangle",
                        count: store.snapshot.orphans.count
                    )
                    if !store.snapshot.orphans.isEmpty {
                        Button("Remove All…", systemImage: "trash") {
                            store.requestOrphanCleanup()
                        }
                        .buttonStyle(LinearButtonStyle(destructive: true))
                    }
                }
                .padding(.bottom, 4)

                ForEach(store.snapshot.orphans) { orphan in
                    OrphanCard(orphan: orphan)
                }

                if store.snapshot.orphans.isEmpty {
                    EmptySectionView(
                        title: "No orphans detected",
                        detail: "Every Town process is attributed to a current worktree.",
                        symbol: "checkmark.circle"
                    )
                }
            }
            .padding(22)
        }
    }
}

private struct OrphanCard: View {
    @EnvironmentObject private var store: TownStore
    @State private var confirmKill = false
    @State private var showProcesses = false

    let orphan: OrphanSnapshot

    private var canKill: Bool {
        !orphan.processes.isEmpty
            && orphan.confidence.rank >= AttributionConfidence.high.rank
    }

    var body: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(orphan.title)
                            .font(.headline)
                        HStack(spacing: 10) {
                            Text(orphan.kind.rawValue.splitCamelCase.capitalized)
                                .townTooltip(orphan.kind.helpText)
                            if let instance = orphan.instanceNumber {
                                Text("Instance \(instance)")
                                    .townTooltip("Town instance number inferred for this orphaned resource.")
                            }
                            Text(orphan.confidence.rawValue.capitalized)
                                .foregroundStyle(orphan.confidence.tint)
                                .townTooltip(orphan.confidence.helpText)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isOperating(on: orphan.id) {
                        ProgressView().controlSize(.small)
                    }
                    if !orphan.processes.isEmpty {
                        Button("Kill All", systemImage: "xmark.octagon", role: .destructive) {
                            confirmKill = true
                        }
                        .buttonStyle(LinearButtonStyle(destructive: true))
                        .controlSize(.small)
                        .disabled(store.isOperating(on: orphan.id) || !canKill)
                        .townTooltip(
                            canKill
                                ? "Kill the verified orphan process tree"
                                : "Town Dock will not kill processes with ambiguous ownership"
                        )
                    }
                }

                if let missingPath = orphan.missingPath {
                    Text(missingPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .townTooltip("The worktree path this resource previously belonged to; it no longer exists.")
                }

                ForEach(orphan.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !orphan.services.isEmpty {
                    ServiceGrid(services: orphan.services)
                }

                if !orphan.processes.isEmpty {
                    SnapDisclosure(isExpanded: $showProcesses) {
                        VStack(spacing: 0) {
                            ForEach(orphan.processes) { process in
                                ProcessRow(process: process)
                                if process.id != orphan.processes.last?.id { Divider() }
                            }
                        }
                        .padding(.top, 7)
                    } label: {
                        Text("\(orphan.processes.count) attributed processes")
                    }
                    .font(.caption.weight(.medium))
                    .townTooltip("Processes Town Dock attributes to this orphan using working-directory and process-tree evidence.")
                }
            }
        }
        .confirmationDialog(
            "Kill all verified processes for this orphan?",
            isPresented: $confirmKill,
            titleVisibility: .visible
        ) {
            Button("Kill \(orphan.processes.count) Processes", role: .destructive) {
                store.kill(orphan)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes running processes only. Dormant storage remains available for separate review.")
        }
    }
}

struct ProcessRow: View {
    let process: ProcessIdentity

    private var processName: String {
        guard let executablePath = process.executablePath else { return "Town process" }
        return URL(fileURLWithPath: executablePath).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(process.pid)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .townTooltip("Process ID (PID)")
            VStack(alignment: .leading, spacing: 2) {
                Text(processName)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                if let workingDirectory = process.workingDirectory {
                    Text(workingDirectory)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let cpuPercent = process.cpuPercent {
                Text(cpuPercent.cpuPercentLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .townTooltip("CPU usage")
            }
            if process.residentBytes > 0 {
                Text(process.residentBytes.byteCountLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .townTooltip("Resident memory currently held by this process")
            }
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
    }
}

private struct SharedInfrastructureDashboard: View {
    @EnvironmentObject private var store: TownStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    "Shared infrastructure",
                    subtitle: "Services shared by every running Town instance",
                    symbol: "server.rack",
                    count: store.snapshot.sharedServices.count
                )

                if store.snapshot.sharedServices.isEmpty {
                    EmptySectionView(
                        title: "No shared services detected",
                        detail: "PostgreSQL, Temporal, MinIO, and tracing services will appear here when running.",
                        symbol: "server.rack"
                    )
                } else {
                    InsetCard {
                        ServiceGrid(services: store.snapshot.sharedServices)
                    }
                }

                Text("Shared PostgreSQL, Temporal, MinIO, and tracing services are always excluded from worktree-level Stop and Nuke actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DormantStorageDashboard: View {
    @EnvironmentObject private var store: TownStore

    private var totalBytes: UInt64 {
        store.snapshot.dormantStates.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    "Dormant storage",
                    subtitle: totalBytes > 0 ? "\(totalBytes.byteCountLabel) across state directories not used by a running stack" : "State directories not used by a running stack",
                    symbol: "externaldrive",
                    count: store.snapshot.dormantStates.count
                )
                .padding(.bottom, 4)

                ForEach(store.snapshot.dormantStates) { state in
                    DormantStateRow(state: state)
                }

                if store.snapshot.dormantStates.isEmpty {
                    EmptySectionView(
                        title: "No dormant storage",
                        detail: "All detected instance state belongs to a running worktree.",
                        symbol: "externaldrive.badge.checkmark"
                    )
                }
            }
            .padding(20)
        }
    }
}

private struct DormantStateRow: View {
    @EnvironmentObject private var store: TownStore
    let state: StateDirectorySnapshot

    var body: some View {
        InsetCard {
            HStack(spacing: 13) {
                Image(systemName: "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(state.instanceNumber.map { "Instance \($0)" } ?? "Unassigned state")
                            .font(.headline)
                        Text(state.confidence.rawValue.capitalized)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(state.confidence.tint)
                            .townTooltip(state.confidence.helpText)
                    }
                    Text(state.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let worktree = state.associatedWorktreePath {
                        Text("Previously associated with \(worktree)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(state.sizeBytes.byteCountLabel)
                        .font(.headline.monospacedDigit())
                        .townTooltip("Disk space used by this dormant state directory")
                    if let modifiedAt = state.modifiedAt {
                        Text(modifiedAt.relativeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .townTooltip("Last modified \(modifiedAt.formatted())")
                    }
                }
                Button {
                    store.revealInFinder(path: state.path)
                } label: {
                    Image(systemName: "folder")
                }
                .townTooltip("Reveal in Finder")
            }
        }
    }
}

private enum NotificationStyle {
    case success
    case error

    var tint: Color { self == .success ? .green : .red }
    var symbol: String { self == .success ? "checkmark.circle.fill" : "exclamationmark.octagon.fill" }
}

private struct NotificationBanner: View {
    let text: String
    let style: NotificationStyle
    var dismiss: (() -> Void)?

    init(text: String, style: NotificationStyle, dismiss: (() -> Void)? = nil) {
        self.text = text
        self.style = style
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .townTooltip("Dismiss notification")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(style.tint.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .frame(maxWidth: 620)
    }
}

private extension String {
    var splitCamelCase: String {
        replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}
