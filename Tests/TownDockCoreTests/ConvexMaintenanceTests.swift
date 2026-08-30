import Foundation
import XCTest

@testable import TownDockCore

private final class MaintenanceCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocation: (URL, [String], URL, [String: String])?

    func record(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String]
    ) {
        lock.lock()
        invocation = (executable, arguments, directory, environment)
        lock.unlock()
    }

    func snapshot() -> (URL, [String], URL, [String: String])? {
        lock.lock()
        defer { lock.unlock() }
        return invocation
    }
}

final class ConvexMaintenanceTests: XCTestCase {
    func testClearDataRequiresRunningPinnedLocalBackend() async throws {
        let fixture = try makeFixture(running: true, confidence: .certain)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let engine = makeEngine(snapshot: fixture.snapshot)

        let allowed = await engine.dryRun(worktree: fixture.worktree, action: .clearData)
        XCTAssertTrue(allowed.canExecute)

        let stoppedFixture = try makeFixture(running: false, confidence: .certain)
        defer { try? FileManager.default.removeItem(at: stoppedFixture.directory) }
        let stopped = await engine.dryRun(
            worktree: stoppedFixture.worktree,
            action: .clearData
        )
        XCTAssertFalse(stopped.canExecute)
        XCTAssertTrue(stopped.warnings.contains { $0.contains("Start") })
    }

    func testFullResetAllowsStoppedOwnedInstanceButBlocksAmbiguousOwnership() async throws {
        let owned = try makeFixture(running: false, confidence: .high)
        defer { try? FileManager.default.removeItem(at: owned.directory) }
        let engine = makeEngine(snapshot: owned.snapshot)
        let reset = await engine.dryRun(worktree: owned.worktree, action: .resetInstance)
        XCTAssertTrue(reset.canExecute)

        let ambiguous = try makeFixture(running: false, confidence: .ambiguous)
        defer { try? FileManager.default.removeItem(at: ambiguous.directory) }
        let blocked = await engine.dryRun(
            worktree: ambiguous.worktree,
            action: .resetInstance
        )
        XCTAssertFalse(blocked.canExecute)
    }

    func testClearCommandIsPinnedToObservedInstance() async throws {
        let fixture = try makeFixture(running: true, confidence: .certain)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = MaintenanceCommandRecorder()
        let engine = ConvexMaintenanceEngine(
            controls: TownControlEngine(),
            runCommand: { executable, arguments, directory, environment in
                recorder.record(
                    executable: executable,
                    arguments: arguments,
                    directory: directory,
                    environment: environment
                )
                return 0
            },
            freshSnapshot: { _ in fixture.snapshot }
        )
        let plan = await engine.dryRun(worktree: fixture.worktree, action: .clearData)

        let result = try await engine.execute(plan: plan, repositoryPath: fixture.directory.path)

        XCTAssertEqual(result.action, .clearData)
        let invocation = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(invocation.0.path, fixture.directory.appendingPathComponent("mise").path)
        XCTAssertEqual(
            invocation.1,
            ["exec", "--locked", "--", "bun", "run", "db:clear"]
        )
        XCTAssertEqual(invocation.2.path, fixture.directory.path)
        XCTAssertEqual(invocation.3["TOWN_CX_N"], "3")
    }

    private func makeEngine(snapshot: TownSnapshot) -> ConvexMaintenanceEngine {
        ConvexMaintenanceEngine(
            controls: TownControlEngine(),
            runCommand: { _, _, _, _ in 0 },
            freshSnapshot: { _ in snapshot }
        )
    }

    private func makeFixture(
        running: Bool,
        confidence: AttributionConfidence
    ) throws -> (directory: URL, worktree: WorktreeSnapshot, snapshot: TownSnapshot) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mise = directory.appendingPathComponent("mise")
        XCTAssertTrue(FileManager.default.createFile(atPath: mise.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mise.path)

        let statePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".convex/local-backend-instance-3-3240", isDirectory: true)
            .path
        let marker = "*Instance: 3 | State: \(statePath)*\n"
        try Data(marker.utf8).write(
            to: directory.appendingPathComponent(".local-convex-services.md")
        )
        let state = StateDirectorySnapshot(
            path: statePath,
            instanceNumber: 3,
            sizeBytes: 42,
            modifiedAt: nil,
            isRunning: running,
            associatedWorktreePath: directory.path,
            confidence: confidence
        )
        let services = [ServiceSnapshot(
            kind: .convexBackend,
            port: 3_240,
            state: running ? .running : .stopped
        )]
        let instance = InstanceSnapshot(
            number: 3,
            confidence: confidence,
            evidence: ["test"],
            services: services,
            stateDirectory: state
        )
        let worktree = WorktreeSnapshot(
            path: directory.path,
            head: "abc123",
            branch: "feature/convex-reset",
            isDetached: false,
            isPrimary: false,
            isLocked: false,
            isPrunable: false,
            gitStatus: GitStatusSnapshot(),
            instance: instance,
            health: nil,
            setupComplete: true
        )
        let snapshot = TownSnapshot(
            repositoryPath: directory.path,
            worktrees: [worktree],
            orphans: [],
            sharedServices: [],
            dormantStates: []
        )
        return (directory, worktree, snapshot)
    }
}
