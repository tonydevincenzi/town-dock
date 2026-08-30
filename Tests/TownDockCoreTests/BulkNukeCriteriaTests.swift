import XCTest
@testable import TownDockCore

final class BulkNukeCriteriaTests: XCTestCase {
    func testSafeDefaultsSelectOnlyStoppedCleanNonPrimaryWorktrees() {
        let criteria = BulkNukeCriteria()

        XCTAssertTrue(criteria.matches(makeWorktree(path: "/tmp/clean-stopped")))
        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/primary", isPrimary: true)))
        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/dirty", dirty: true)))
        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/running", running: true)))
        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/locked", isLocked: true)))
    }

    func testCriteriaCanIncludeRunningDirtyIncompleteWorktrees() {
        let criteria = BulkNukeCriteria(
            includeRunning: true,
            includeStopped: false,
            includeClean: false,
            includeDirty: true,
            includeSetupComplete: false,
            includeSetupIncomplete: true
        )
        let matching = makeWorktree(
            path: "/tmp/matching",
            dirty: true,
            running: true,
            setupComplete: false
        )

        XCTAssertTrue(criteria.matches(matching))
        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/clean", running: true)))
        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/stopped", dirty: true)))
        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/complete", dirty: true, running: true)))
    }

    func testPrimaryCheckoutRemainsExcludedWhenEveryCriterionIsEnabled() {
        let criteria = BulkNukeCriteria(
            includeRunning: true,
            includeStopped: true,
            includeClean: true,
            includeDirty: true,
            includeSetupComplete: true,
            includeSetupIncomplete: true
        )

        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/primary", isPrimary: true)))
        XCTAssertFalse(criteria.matches(makeWorktree(path: "/tmp/locked", isLocked: true)))
    }

    private func makeWorktree(
        path: String,
        dirty: Bool = false,
        running: Bool = false,
        isPrimary: Bool = false,
        isLocked: Bool = false,
        setupComplete: Bool = true
    ) -> WorktreeSnapshot {
        let instance = running
            ? InstanceSnapshot(
                number: 2,
                confidence: .certain,
                evidence: [],
                services: [ServiceSnapshot(kind: .frontend, port: 3020, state: .running)]
            )
            : nil
        return WorktreeSnapshot(
            path: path,
            head: "0123456789abcdef",
            branch: "codex/test",
            isDetached: false,
            isPrimary: isPrimary,
            isLocked: isLocked,
            isPrunable: false,
            gitStatus: GitStatusSnapshot(modifiedCount: dirty ? 1 : 0),
            instance: instance,
            health: nil,
            setupComplete: setupComplete
        )
    }
}
