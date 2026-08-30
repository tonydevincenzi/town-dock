import XCTest

@testable import TownDockCore

final class ResourceUsageTests: XCTestCase {
    func testWorktreeUsageDeduplicatesProcessesAndDockerServices() {
        let process = ProcessIdentity(
            pid: 42,
            parentPID: 1,
            processGroupID: 42,
            startToken: "started",
            command: "node server.js",
            residentBytes: 100,
            cpuPercent: 2.5
        )
        let backend = ServiceSnapshot(
            kind: .convexBackend,
            port: 3_220,
            state: .running,
            cpuPercent: 4.5,
            residentBytes: 500,
            metricsIdentity: "docker:convex"
        )
        let proxy = ServiceSnapshot(
            kind: .convexSiteProxy,
            port: 3_221,
            state: .running,
            cpuPercent: 4.5,
            residentBytes: 500,
            metricsIdentity: "docker:convex"
        )
        let first = worktree(path: "/tmp/town-one", process: process, services: [backend, proxy])
        let second = worktree(path: "/tmp/town-two", process: process, services: [])
        let snapshot = TownSnapshot(
            repositoryPath: "/tmp/town",
            worktrees: [first, second],
            orphans: [],
            sharedServices: [
                ServiceSnapshot(
                    kind: .postgres,
                    port: 5_432,
                    state: .running,
                    isShared: true,
                    cpuPercent: 20,
                    residentBytes: 2_000,
                    metricsIdentity: "docker:postgres"
                ),
            ],
            dormantStates: []
        )

        XCTAssertEqual(snapshot.worktreeResourceUsage.cpuPercent, 7)
        XCTAssertEqual(snapshot.worktreeResourceUsage.residentBytes, 600)
        XCTAssertEqual(snapshot.worktreeResourceUsage.processCount, 1)
        XCTAssertEqual(snapshot.worktreeResourceUsage.containerCount, 1)
    }

    private func worktree(
        path: String,
        process: ProcessIdentity,
        services: [ServiceSnapshot]
    ) -> WorktreeSnapshot {
        WorktreeSnapshot(
            path: path,
            head: "abc123",
            branch: "feature/test",
            isDetached: false,
            isPrimary: false,
            isLocked: false,
            isPrunable: false,
            gitStatus: GitStatusSnapshot(),
            instance: InstanceSnapshot(
                number: 1,
                confidence: .certain,
                evidence: [],
                services: services,
                processes: [process]
            ),
            health: nil,
            setupComplete: true
        )
    }
}
