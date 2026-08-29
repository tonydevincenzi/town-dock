import SwiftUI
import TownDockCore

struct WorktreeCard: View {
    @EnvironmentObject private var store: TownStore
    @State private var showHealth = false
    @State private var confirmForceKill = false

    let worktree: WorktreeSnapshot

    private var isRunning: Bool { worktree.instance?.isRunning == true }
    private var isOperating: Bool { store.isOperating(on: worktree.id) }
    private var overallState: ServiceState {
        worktree.health?.overall ?? (isRunning ? .running : .stopped)
    }

    var body: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let instance = worktree.instance {
                    instanceSummary(instance)
                    if !instance.services.isEmpty {
                        ServiceGrid(services: instance.services)
                    }
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "pause.circle")
                        Text(worktree.setupComplete ? "No Town services detected" : "Worktree setup is incomplete")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let health = worktree.health,
                   !health.probes.isEmpty || !health.recommendations.isEmpty {
                    healthDisclosure(health)
                }

                Divider()
                controls
            }
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    StatusDot(state: overallState, size: 9)
                    Text(worktree.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if worktree.isPrimary {
                        badge("PRIMARY", tint: .blue)
                    }
                    if worktree.gitStatus.isDirty {
                        badge("DIRTY", tint: .orange)
                            .help("This worktree has modified, staged, or untracked files. Nuke would permanently remove those local changes.")
                    }
                    if let frontend = worktree.instance?.services.first(where: { $0.kind == .frontend }) {
                        badge(
                            "LOCALHOST :\(frontend.port)",
                            tint: frontend.state == .running || frontend.state == .degraded ? .green : .secondary
                        )
                        .help(
                            frontend.state == .running || frontend.state == .degraded
                                ? "Frontend is available at http://localhost:\(frontend.port)"
                                : "Reserved frontend port; it is not currently listening"
                        )
                    }
                    if worktree.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Git worktree is locked")
                    }
                }

                Text(worktree.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(worktree.path)
            }

            Spacer()

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
                if !worktree.isPrimary {
                    Divider()
                    Button("Nuke Worktree…", role: .destructive) { store.requestNuke(worktree) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(TownTheme.muted)
            }
            .menuStyle(.borderlessButton)
            .tint(TownTheme.muted)
            .fixedSize()
        }
    }

    private func instanceSummary(_ instance: InstanceSnapshot) -> some View {
        HStack(spacing: 14) {
            Label("Instance \(instance.number)", systemImage: "number.circle")
            Label(instance.confidence.rawValue.capitalized, systemImage: "scope")
                .foregroundStyle(instance.confidence.tint)
            if !instance.processes.isEmpty {
                Label("\(instance.processes.count) stack processes", systemImage: "cpu")
            }
            let memory = instance.processes.reduce(UInt64(0)) { $0 + $1.residentBytes }
            if memory > 0 {
                Label(memory.byteCountLabel, systemImage: "memorychip")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(TownTheme.muted)
    }

    private func healthDisclosure(_ health: HealthSnapshot) -> some View {
        DisclosureGroup(isExpanded: $showHealth) {
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
                if let measuredAt = health.measuredAt {
                    Text("· \(measuredAt.relativeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if let url = worktree.frontendURL {
                Button {
                    store.openInChrome(url)
                } label: {
                    Label("Chrome", systemImage: "safari")
                }
                .buttonStyle(LinearButtonStyle())
            }

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

            if isOperating {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }

            if isRunning {
                Button("Stop", systemImage: "stop.fill") { store.stop(worktree) }
                    .buttonStyle(LinearButtonStyle())
                    .disabled(isOperating)
                Button("Restart", systemImage: "arrow.clockwise") { store.restart(worktree) }
                    .buttonStyle(LinearButtonStyle())
                    .disabled(isOperating)
                Button(role: .destructive) {
                    confirmForceKill = true
                } label: {
                    Label("Kill All", systemImage: "xmark.octagon")
                }
                .buttonStyle(LinearButtonStyle(destructive: true))
                .disabled(isOperating)
            } else {
                Button("Start", systemImage: "play.fill") { store.start(worktree) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isOperating || !worktree.setupComplete)
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(0.13), lineWidth: 1)
            }
    }
}
