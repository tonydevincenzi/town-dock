import Foundation
import TownDockCore

@main
enum TownDockProbe {
    static func main() async {
        let repositoryPath = CommandLine.arguments.dropFirst().first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Developer/town", isDirectory: true).path
        let probeRegistryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TownDockProbe-\(UUID().uuidString).json")
        let registry = TownRegistry(fileURL: probeRegistryURL)

        do {
            let discovered = try await TownDiscoveryEngine(
                repositoryPath: repositoryPath
            ).snapshot()
            try await registry.record(snapshot: discovered)
            let snapshot = await registry.enrich(snapshot: discovered)

            print("Town Dock read-only probe")
            print("worktrees=\(snapshot.worktrees.count) orphans=\(snapshot.orphans.count) warnings=\(snapshot.warnings.count)")
            for worktree in snapshot.worktrees {
                let label = worktree.branch ?? URL(fileURLWithPath: worktree.path).lastPathComponent
                let instance = worktree.instance.map { String($0.number) } ?? "none"
                let runningPorts = worktree.instance?.services
                    .filter { $0.state == .running || $0.state == .degraded }
                    .map(\.port).sorted().map(String.init).joined(separator: ",") ?? ""
                let processCount = worktree.instance?.processes.count ?? 0
                print("worktree \(label) instance=\(instance) processes=\(processCount) running=[\(runningPorts)]")
            }
            for orphan in snapshot.orphans {
                let instance = orphan.instanceNumber.map(String.init) ?? "none"
                let ports = orphan.services.map(\.port).sorted().map(String.init).joined(separator: ",")
                print("orphan \(orphan.kind.rawValue) instance=\(instance) processes=\(orphan.processes.count) ports=[\(ports)]")
            }
            let shared = snapshot.sharedServices
                .filter { $0.state == .running || $0.state == .degraded }
                .map(\.port).sorted().map(String.init).joined(separator: ",")
            print("shared-running=[\(shared)]")
            print("dormant-states=\(snapshot.dormantStates.count)")
            for warning in snapshot.warnings {
                print("warning \(warning)")
            }

            let nuker = NukeEngine(registry: registry)
            let orphanCleanup = await nuker.orphanCleanupDryRun(snapshot: snapshot)
            print(
                "orphan-cleanup executable=\(orphanCleanup.canExecute) "
                    + "targets=\(orphanCleanup.targets.filter { $0.actionable && $0.selectedByDefault }.count) "
                    + "skipped=\(orphanCleanup.targets.filter { !$0.actionable }.count)"
            )
            for worktree in snapshot.worktrees where !worktree.isPrimary {
                let label = worktree.branch ?? URL(fileURLWithPath: worktree.path).lastPathComponent
                let manifest = try await nuker.dryRun(
                    worktree: worktree,
                    repositoryPath: snapshot.repositoryPath
                )
                print("nuke-preview \(label) executable=\(manifest.canExecute) targets=\(manifest.targets.count) warnings=\(manifest.warnings.count)")
            }
        } catch {
            FileHandle.standardError.write(Data("Town Dock probe failed: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}
