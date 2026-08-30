import Foundation
import XCTest

@testable import TownDockCore

final class ManagedRunsTests: XCTestCase {
    func testLaunchRecordPersistsAndReconcilesAcrossRegistryInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("managed-runs.json")
        let launchedAt = Date(timeIntervalSince1970: 1_780_000_000)

        let registry = ManagedRunRegistry(storageURL: fileURL)
        try await registry.recordLaunch(
            worktreePath: "/tmp/town-managed",
            instanceNumber: 4,
            launcherPID: 4321,
            launchedAt: launchedAt
        )

        let reloaded = ManagedRunRegistry(storageURL: fileURL)
        let pending = try await reloaded.reconcile(
            snapshot: fixtureSnapshot(running: false),
            now: launchedAt.addingTimeInterval(30)
        )
        XCTAssertEqual(pending.first?.launcherPID, 4321)
        XCTAssertEqual(pending.first?.instanceNumber, 4)

        let expired = try await reloaded.reconcile(
            snapshot: fixtureSnapshot(running: false),
            now: launchedAt.addingTimeInterval(121)
        )
        XCTAssertTrue(expired.isEmpty)
    }

    func testRunningWorktreeRefreshesManagedRecord() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("managed-runs.json")
        let launchedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let observedAt = launchedAt.addingTimeInterval(300)
        let registry = ManagedRunRegistry(storageURL: fileURL)

        try await registry.recordLaunch(
            worktreePath: "/tmp/town-managed",
            instanceNumber: 4,
            launcherPID: 4321,
            launchedAt: launchedAt
        )
        let records = try await registry.reconcile(
            snapshot: fixtureSnapshot(running: true),
            now: observedAt
        )

        XCTAssertEqual(records.first?.lastSeenRunningAt, observedAt)

        let stopped = try await registry.reconcile(
            snapshot: fixtureSnapshot(running: false),
            now: observedAt.addingTimeInterval(1)
        )
        XCTAssertTrue(stopped.isEmpty)
    }

    private func fixtureSnapshot(running: Bool) -> TownSnapshot {
        let services = running
            ? [ServiceSnapshot(kind: .frontend, port: 3040, state: .running)]
            : []
        let worktree = WorktreeSnapshot(
            path: "/tmp/town-managed",
            head: "abc123",
            branch: "feature/managed",
            isDetached: false,
            isPrimary: false,
            isLocked: false,
            isPrunable: false,
            gitStatus: GitStatusSnapshot(),
            instance: InstanceSnapshot(
                number: 4,
                confidence: .certain,
                evidence: ["test"],
                services: services
            ),
            health: nil,
            setupComplete: true
        )
        return TownSnapshot(
            repositoryPath: "/tmp/town",
            worktrees: [worktree],
            orphans: [],
            sharedServices: [],
            dormantStates: []
        )
    }
}

final class WorktreeLogReaderTests: XCTestCase {
    func testReadsAWholeSmallLogFromTheBeginning() async throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logs = worktree.appendingPathComponent("logs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("ready\n".utf8).write(to: logs.appendingPathComponent("frontend.log"))

        let files = try await WorktreeLogReader().read(worktreePath: worktree.path)

        XCTAssertEqual(files.first?.text, "ready\n")
        XCTAssertEqual(files.first?.isTruncated, false)
    }

    func testReadsOnlyBoundedLogTailsAndStripsANSI() async throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logs = worktree.appendingPathComponent("logs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("discard\n\u{001B}[31mkeep\u{001B}[0m\n".utf8)
            .write(to: logs.appendingPathComponent("frontend.log"))
        try Data("ignored".utf8).write(to: logs.appendingPathComponent("secret.env"))

        let reader = WorktreeLogReader()
        let files = try await reader.read(
            worktreePath: worktree.path,
            maximumBytesPerFile: 14
        )

        XCTAssertEqual(files.map(\.name), ["frontend.log"])
        XCTAssertTrue(files[0].isTruncated)
        XCTAssertEqual(files[0].text, "keep\n")
    }
}
