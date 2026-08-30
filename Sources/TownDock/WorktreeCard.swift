import SwiftUI
import TownDockCore

struct WorktreeCard: View {
    @EnvironmentObject private var store: TownStore
    @State private var isExpanded = false
    @State private var showHealth = false
    @State private var showProcesses = false
    @State private var confirmForceKill = false

    let worktree: WorktreeSnapshot

    private var isRunning: Bool { worktree.instance?.isRunning == true }
    private var isOperating: Bool { store.isOperating(on: worktree.id) }
    private var overallState: ServiceState {
        worktree.health?.overall ?? (isRunning ? .running : .stopped)
    }

    private var orderedServices: [ServiceSnapshot] {
        guard let services = worktree.instance?.services else { return [] }
        return services.sorted {
            let leftRunning = $0.state == .running || $0.state == .degraded
            let rightRunning = $1.state == .running || $1.state == .degraded
            if leftRunning != rightRunning { return leftRunning }
            return servicePriority($0.kind) < servicePriority($1.kind)
        }
    }

    private var visibleServices: [ServiceSnapshot] {
        Array(orderedServices.filter { $0.state == .running || $0.state == .degraded }.prefix(4))
    }

    private var hiddenServiceCount: Int {
        max(0, orderedServices.count - visibleServices.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary

            if isExpanded {
                details
                    .padding(.top, 14)
            }
        }
        .padding(16)
        .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TownTheme.border, lineWidth: 1)
        }
        .confirmationDialog(
            "Force-kill every verified process for \(worktree.displayName)?",
            isPresented: $confirmForceKill,
            titleVisibility: .visible
        ) {
            Button("Force Kill All", role: .destructive) {
                store.forceKill(worktree)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Town Dock will terminate the attributed process tree. Files and local storage are not removed.")
        }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 11) {
            StatusDot(state: overallState, size: 8)
                .townTooltip(overallState.helpText)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(worktree.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)

                    if worktree.gitStatus.isDirty {
                        badge("DIRTY", tint: .gray)
                    }
                    if worktree.health?.overall == .degraded {
                        badge("DEGRADED", tint: .orange)
                    }
                    if !worktree.setupComplete {
                        badge("INCOMPLETE", tint: .orange)
                    }
                    if worktree.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(TownTheme.muted)
                            .townTooltip("Git worktree is locked")
                    }
                }

                portSummary
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isOperating {
                ProgressView()
                    .controlSize(.small)
            }

            primaryAction
            overflowMenu

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TownTheme.muted)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide worktree details" : "Show worktree details")
        }
    }

    @ViewBuilder
    private var portSummary: some View {
        if !visibleServices.isEmpty {
            HStack(spacing: 6) {
                ForEach(visibleServices) { service in
                    CompactPortChip(service: service)
                }
                if hiddenServiceCount > 0 {
                    Text("+\(hiddenServiceCount)")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(TownTheme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .townTooltip(hiddenServicesHelp)
                }
            }
        } else {
            Label(
                worktree.setupComplete ? "No services running" : "Setup incomplete",
                systemImage: worktree.setupComplete ? "pause.circle" : "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(TownTheme.muted)
            .townTooltip(
                worktree.setupComplete
                    ? "No Town service is currently listening for this worktree."
                    : "Run the worktree setup script before starting its services."
            )
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if isRunning, let url = worktree.frontendURL {
            Button {
                store.openInChrome(url)
            } label: {
                Label("Open", systemImage: "arrow.up.right")
            }
            .buttonStyle(LinearButtonStyle())
            .disabled(isOperating)
        } else if !isRunning {
            Button {
                store.start(worktree)
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(LinearButtonStyle(emphasized: true))
            .disabled(isOperating || !worktree.setupComplete)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Open Folder in Finder") { store.revealInFinder(path: worktree.path) }
            Button("Open in Terminal") { store.openTerminal(at: worktree.path) }
            Button("Copy Path") { store.copy(worktree.path) }
            Button("Copy Commit") { store.copy(worktree.head) }

            if let url = worktree.frontendURL {
                Divider()
                Button("Open Frontend in Chrome") { store.openInChrome(url) }
                Button("Copy Frontend URL") { store.copy(url.absoluteString) }
            }

            if isRunning {
                Divider()
                Button("Force Kill All…", role: .destructive) { confirmForceKill = true }
                    .disabled(isOperating)
            }

            if !worktree.isPrimary {
                Divider()
                Button("Nuke Worktree…", role: .destructive) { store.requestNuke(worktree) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TownTheme.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .tint(TownTheme.muted)
        .fixedSize()
        .townTooltip("More actions")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 13) {
            Divider()

            Text(worktree.path)
                .font(.caption.monospaced())
                .foregroundStyle(TownTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .townTooltip(worktree.path)

            if let instance = worktree.instance {
                instanceSummary(instance)
                if !instance.services.isEmpty {
                    ServiceGrid(services: instance.services)
                }
                if !instance.processes.isEmpty {
                    processDisclosure(instance.processes)
                }
            }

            if let health = worktree.health,
               !health.probes.isEmpty || !health.recommendations.isEmpty {
                healthDisclosure(health)
            }

            Divider()
            secondaryControls
        }
    }

    private func instanceSummary(_ instance: InstanceSnapshot) -> some View {
        HStack(spacing: 14) {
            Label("Instance \(instance.number)", systemImage: "number.circle")
                .townTooltip("Town assigns this number to derive the worktree's ports and isolated local storage.")
            if instance.confidence != .certain {
                Label(instance.confidence.rawValue.capitalized, systemImage: "scope")
                    .foregroundStyle(instance.confidence.tint)
                    .townTooltip(instance.confidence.helpText)
            }
            if !instance.processes.isEmpty {
                Label("\(instance.processes.count) processes", systemImage: "cpu")
                    .townTooltip("All live processes attributed to this worktree, including child processes.")
            }
            let cpuPercent = instance.processes.compactMap(\.cpuPercent).reduce(0, +)
            if !instance.processes.isEmpty {
                Label("\(cpuPercent.cpuPercentLabel) CPU", systemImage: "gauge.with.dots.needle.33percent")
                    .townTooltip("Combined current CPU usage of the attributed process tree.")
            }
            let memory = instance.processes.reduce(UInt64(0)) { $0 + $1.residentBytes }
            if memory > 0 {
                Label(memory.byteCountLabel, systemImage: "memorychip")
                    .townTooltip("Combined resident memory used by the attributed process tree.")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(TownTheme.muted)
    }

    private func processDisclosure(_ processes: [ProcessIdentity]) -> some View {
        SnapDisclosure(isExpanded: $showProcesses) {
            VStack(spacing: 0) {
                ForEach(processes) { process in
                    ProcessRow(process: process)
                    if process.id != processes.last?.id { Divider() }
                }
            }
            .padding(.top, 7)
        } label: {
            Text("\(processes.count) live process\(processes.count == 1 ? "" : "es")")
                .font(.caption.weight(.semibold))
        }
    }

    private func healthDisclosure(_ health: HealthSnapshot) -> some View {
        SnapDisclosure(isExpanded: $showHealth) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(health.probes) { probe in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatusDot(state: probe.state, size: 7)
                        Text(probe.name)
                            .font(.caption.weight(.semibold))
                        Text(probe.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }

                ForEach(health.recommendations, id: \.self) { recommendation in
                    Label(recommendation, systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 9)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: health.overall == .degraded ? "exclamationmark.triangle.fill" : "heart.text.square")
                    .foregroundStyle(health.overall.tint)
                Text("Health: \(health.overall.displayName)")
                    .font(.caption.weight(.semibold))
                    .townTooltip(health.overall.helpText)
                if let measuredAt = health.measuredAt {
                    Text("· \(measuredAt.relativeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 8) {
            Button {
                store.revealInFinder(path: worktree.path)
            } label: {
                Label("Finder", systemImage: "folder")
            }
            .buttonStyle(LinearButtonStyle())

            Button {
                store.openTerminal(at: worktree.path)
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .buttonStyle(LinearButtonStyle())

            Spacer()

            if isRunning {
                Button("Stop", systemImage: "stop.fill") { store.stop(worktree) }
                    .buttonStyle(LinearButtonStyle())
                    .disabled(isOperating)
                Button("Restart", systemImage: "arrow.clockwise") { store.restart(worktree) }
                    .buttonStyle(LinearButtonStyle())
                    .disabled(isOperating)
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .townTooltip(badgeHelpText(text))
    }

    private func badgeHelpText(_ text: String) -> String {
        switch text {
        case "DIRTY": "This worktree has modified, staged, or untracked files that have not been committed."
        case "DEGRADED": "The stack is running, but one or more service health checks are failing or incomplete."
        case "INCOMPLETE": "Required worktree setup has not completed, so some controls or service data may be unavailable."
        case "PRIMARY": "This is the repository's main checkout rather than a linked Git worktree."
        default: text
        }
    }

    private func servicePriority(_ kind: ServiceKind) -> Int {
        switch kind {
        case .frontend: 0
        case .electric: 1
        case .convexBackend: 2
        case .convexSiteProxy: 3
        case .harness: 4
        case .drizzleStudio: 5
        case .convexDashboard: 6
        default: 20
        }
    }

    private var hiddenServicesHelp: String {
        let hidden = orderedServices.dropFirst(visibleServices.count)
        let labels = hidden.map { "\($0.kind.displayName) :\($0.port)" }
        return "More configured services: " + labels.joined(separator: ", ")
    }
}

private struct CompactPortChip: View {
    @EnvironmentObject private var store: TownStore

    let service: ServiceSnapshot

    var body: some View {
        Group {
            if service.kind.isBrowserTarget, let url = service.url {
                Button {
                    store.openInChrome(url)
                } label: {
                    chipLabel
                }
                .buttonStyle(.plain)
            } else {
                chipLabel
            }
        }
        .townTooltip(service.kind.isBrowserTarget && service.url != nil
              ? "\(service.state.displayName): Open \(service.kind.displayName) on localhost:\(service.port). \(service.state.helpText)"
              : "\(service.state.displayName): \(service.kind.displayName) on localhost:\(service.port). \(service.state.helpText)")
        .contextMenu {
            if let url = service.url {
                Button("Open in Chrome") { store.openInChrome(url) }
                Button("Copy URL") { store.copy(url.absoluteString) }
            }
            Button("Copy Port") { store.copy(String(service.port)) }
        }
    }

    private var chipLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                StatusDot(state: service.state, size: 6)
                Text(service.kind.displayName)
                    .lineLimit(1)
                Text(":\(service.port)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let resourceSummary = service.compactResourceSummary {
                Text(resourceSummary)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TownTheme.muted)
                    .lineLimit(1)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(TownTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(TownTheme.border, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}
