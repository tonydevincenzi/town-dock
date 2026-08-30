import Foundation
import XCTest

@testable import TownDockCore

final class RegistryTests: XCTestCase {
    func testPersistsOnlyHighConfidenceObservedOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("registry.json")
        let state = StateDirectorySnapshot(
            path: "/tmp/state-2",
            instanceNumber: 2,
            sizeBytes: 42,
            modifiedAt: nil,
            isRunning: true,
            associatedWorktreePath: "/tmp/town-two",
            confidence: .high
        )
        let instance = InstanceSnapshot(
            number: 2,
            confidence: .high,
            evidence: ["services marker"],
            services: [
                ServiceSnapshot(
                    kind: .frontend,
                    port: 3020,
                    state: .running
                ),
            ],
            stateDirectory: state,
            actualBucketName: "town-local-2"
        )
        let worktree = fixtureWorktree(instance: instance)
        let snapshot = TownSnapshot(
            repositoryPath: "/tmp/town",
            worktrees: [worktree],
            orphans: [],
            sharedServices: [],
            dormantStates: []
        )

        let registry = TownRegistry(fileURL: fileURL)
        try await registry.record(snapshot: snapshot)

        let reloaded = TownRegistry(fileURL: fileURL)
        let reloadedRecords = await reloaded.records()
        let record = try XCTUnwrap(reloadedRecords.first)
        XCTAssertEqual(record.canonicalPath, "/tmp/town-two")
        XCTAssertEqual(record.instanceNumber, 2)
        XCTAssertEqual(record.stateDirectory, "/tmp/state-2")
        XCTAssertEqual(record.bucketName, "town-local-2")
        XCTAssertNotNil(record.lastSeenRunningAt)
    }

    func testAmbiguousObservationDoesNotOverwriteKnownInstance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("registry.json")
        let registry = TownRegistry(fileURL: fileURL)

        let high = fixtureWorktree(
            instance: InstanceSnapshot(
                number: 3,
                confidence: .certain,
                evidence: ["marker"],
                services: []
            )
        )
        try await registry.record(snapshot: TownSnapshot(
            repositoryPath: "/tmp/town",
            worktrees: [high],
            orphans: [],
            sharedServices: [],
            dormantStates: []
        ))

        let ambiguous = fixtureWorktree(
            instance: InstanceSnapshot(
                number: 8,
                confidence: .ambiguous,
                evidence: ["port arithmetic only"],
                services: []
            )
        )
        try await registry.record(snapshot: TownSnapshot(
            repositoryPath: "/tmp/town",
            worktrees: [ambiguous],
            orphans: [],
            sharedServices: [],
            dormantStates: []
        ))

        let records = await registry.records()
        XCTAssertEqual(records.first?.instanceNumber, 3)
    }

    private func fixtureWorktree(instance: InstanceSnapshot?) -> WorktreeSnapshot {
        WorktreeSnapshot(
            path: "/tmp/town-two",
            head: "abc123",
            branch: "feature/test",
            isDetached: false,
            isPrimary: false,
            isLocked: false,
            isPrunable: false,
            gitStatus: GitStatusSnapshot(),
            instance: instance,
            health: nil,
            setupComplete: true
        )
    }
}
