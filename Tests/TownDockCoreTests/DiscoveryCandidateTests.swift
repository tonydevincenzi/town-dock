import XCTest
@testable import TownDockCore

final class DiscoveryCandidateTests: XCTestCase {
    func testCandidateExpansionDoesNotPullInSiblingsThroughSharedAncestor() {
        let processes = [
            process(10, parent: 1, command: "/Applications/Terminal.app/Contents/MacOS/Terminal"),
            process(20, parent: 10, command: "zsh"),
            process(30, parent: 20, command: "/Users/example/Developer/town/./mise run local-stack"),
            process(31, parent: 30, command: "convex-local-backend"),
            process(40, parent: 10, command: "unrelated-build"),
            process(41, parent: 40, command: "unrelated-worker"),
        ]

        let candidates = Set(TownDiscoveryEngine.candidateProcessIDs(
            processes: processes,
            listeners: [],
            worktreePaths: ["/Users/example/Developer/town"]
        ))

        XCTAssertEqual(candidates, Set([10, 20, 30, 31]))
        XCTAssertFalse(candidates.contains(40))
        XCTAssertFalse(candidates.contains(41))
    }

    private func process(_ pid: Int32, parent: Int32, command: String) -> PSProcessRecord {
        PSProcessRecord(
            pid: pid,
            parentPID: parent,
            processGroupID: pid,
            startToken: "start-\(pid)",
            cpuPercent: 0,
            residentBytes: 0,
            command: command
        )
    }
}
