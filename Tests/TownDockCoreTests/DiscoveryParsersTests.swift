import Foundation
import XCTest

@testable import TownDockCore

final class DiscoveryParsersTests: XCTestCase {
    func testParsesWorktreePorcelainIncludingFlagsAndBranchNames() {
        let records = GitWorktreePorcelainParser.parse(
            """
            worktree /Users/example/Developer/town
            HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            branch refs/heads/main

            worktree /Users/example/.codex/worktrees/abc/town
            HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            detached
            locked user-requested
            prunable gitdir file points to non-existent location

            """
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].branch, "main")
        XCTAssertFalse(records[0].isDetached)
        XCTAssertEqual(records[1].path, "/Users/example/.codex/worktrees/abc/town")
        XCTAssertTrue(records[1].isDetached)
        XCTAssertTrue(records[1].isLocked)
        XCTAssertTrue(records[1].isPrunable)
    }

    func testParsesPorcelainV2StatusWithoutCountingIgnoredFiles() {
        let status = GitStatusPorcelainV2Parser.parse(
            """
            # branch.oid aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            # branch.head feature/demo
            # branch.upstream origin/feature/demo
            # branch.ab +3 -2
            1 .M N... 100644 100644 100644 aaaaaaa aaaaaaa Sources/A.swift
            1 M. N... 100644 100644 100644 bbbbbbb bbbbbbb Sources/B.swift
            2 MM N... 100644 100644 100644 ccccccc ddddddd R100 Sources/C.swift\tSources/Old.swift
            ? scratch.txt
            ! ignored.txt
            """
        )

        XCTAssertEqual(status.modifiedCount, 2)
        XCTAssertEqual(status.stagedCount, 2)
        XCTAssertEqual(status.untrackedCount, 1)
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 2)
        XCTAssertEqual(status.upstream, "origin/feature/demo")
    }

    func testParsesMachineAndColumnLSOFListenerOutput() {
        let machine = LSOFListenerParser.parse(
            """
            p101
            cnode
            n*:3010
            n127.0.0.1:3010
            p202
            cconvex-local-backend
            n127.0.0.1:3220
            """
        )
        XCTAssertEqual(machine.map(\.port), [3_010, 3_220])
        XCTAssertEqual(machine.map(\.pid), [101, 202])

        let columns = LSOFListenerParser.parse(
            """
            COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            node 303 tony 22u IPv6 0x0 0t0 TCP *:3080 (LISTEN)
            """
        )
        XCTAssertEqual(columns.first?.pid, 303)
        XCTAssertEqual(columns.first?.port, 3_080)
    }

    func testParsesPSMetadataAndRedactsCommandSecrets() throws {
        let records = PSMetadataParser.parse(
            "  42  1  42 Sat Aug 29 13:00:00 2026 12.5 1234 /usr/bin/node server.js --admin-key secret-value\n"
        )
        let process = try XCTUnwrap(records.first)
        XCTAssertEqual(process.pid, 42)
        XCTAssertEqual(process.parentPID, 1)
        XCTAssertEqual(process.processGroupID, 42)
        XCTAssertEqual(process.cpuPercent, 12.5)
        XCTAssertEqual(process.residentBytes, 1_263_616)
        XCTAssertFalse(process.command.contains("secret-value"))
        XCTAssertTrue(process.command.contains("[REDACTED]"))
    }

    func testParsesProcessFileEvidence() throws {
        let records = LSOFProcessFileParser.parse(
            """
            p42
            fcwd
            n/Users/example/Developer/town
            ftxt
            n/usr/bin/node
            f12
            n/Users/example/Developer/town/lib/server.ts
            p43
            fcwd
            n/Users/example/.codex/worktrees/gone/town (deleted)
            """
        )
        let first = try XCTUnwrap(records.first { $0.pid == 42 })
        XCTAssertEqual(first.workingDirectory, "/Users/example/Developer/town")
        XCTAssertEqual(first.executablePath, "/usr/bin/node")
        XCTAssertTrue(first.openPaths.contains("/Users/example/Developer/town/lib/server.ts"))
    }

    func testHealthParserUsesLastValidJSONLineAndRedactsSecrets() throws {
        let health = try XCTUnwrap(TownHealthJSONLParser.parse(
            """
            {not-json}
            {"ts":"2026-08-29T20:30:00.000Z","overall":"warn","probes":{"backend":{"ok":false,"severity":"error","detail":"failed --admin-key super-secret"}},"recommendations":["retry with ?token=also-secret"]}

            """
        ))
        XCTAssertEqual(health.overall, .degraded)
        XCTAssertEqual(health.probes.first?.name, "backend")
        XCTAssertFalse(health.probes.first?.detail.contains("super-secret") == true)
        XCTAssertFalse(health.recommendations.first?.contains("also-secret") == true)
        XCTAssertNotNil(health.measuredAt)
    }

    func testStateDirectoryAndDUParsersRejectCollidingInstanceNumbers() throws {
        let state = try XCTUnwrap(TownStateDirectoryParser.parse(
            path: "/Users/example/.convex/local-backend-instance-8-3290"
        ))
        XCTAssertEqual(state.instanceNumber, 8)
        XCTAssertEqual(state.backendPort, 3_290)
        XCTAssertNil(TownStateDirectoryParser.parse(
            path: "/Users/example/.convex/local-backend-instance-10-3310"
        ))

        let sizes = TownStateDirectoryParser.parseDUKilobytes(
            "2048\t/Users/example/.convex/local-backend-instance-8-3290\n"
        )
        XCTAssertEqual(sizes[state.path], 2_097_152)
    }

    func testDockerJSONLineParsersKeepOnlySafeInventoryFields() throws {
        let containers = DockerInventoryParser.parseContainers(
            #"{"ID":"abcdef123456","Names":"harness-electric-13","State":"exited","Status":"Exited (1)","Ports":"0.0.0.0:3140->5133/tcp","Mounts":"harness-electric-data-13,harness-cache-13"}"#
        )
        let container = try XCTUnwrap(containers.first)
        XCTAssertEqual(container.id, "abcdef123456")
        XCTAssertEqual(container.instanceNumber, 13)
        XCTAssertEqual(container.publishedPorts, [3_140])
        XCTAssertEqual(container.mountedVolumes, ["harness-electric-data-13", "harness-cache-13"])

        let withStats = DockerInventoryParser.addingStats(
            #"{"Name":"harness-electric-13","CPUPerc":"4.25%","MemUsage":"321.2MiB / 7.748GiB"}"#,
            to: containers
        )
        XCTAssertEqual(withStats.first?.cpuPercent, 4.25)
        XCTAssertEqual(withStats.first?.residentBytes, 336_802_611)

        let volumes = DockerInventoryParser.parseVolumes(
            #"{"Name":"harness-electric-data-8","Driver":"local","Labels":"TOKEN=must-not-be-retained"}"#
        )
        let volume = try XCTUnwrap(volumes.first)
        XCTAssertEqual(volume.instanceNumber, 8)
        XCTAssertEqual(volume.driver, "local")
    }

    func testSecretRedactorHandlesURLsFlagsEnvironmentAndJWTs() {
        let input = "postgres://user:pass@localhost/db --token abc TOKEN=def eyJaaaaaaaaaaa.bbbbbbbbbbb.ccccccccccc"
        let redacted = SecretRedactor.redact(input)
        XCTAssertFalse(redacted.contains("pass"))
        XCTAssertFalse(redacted.contains("abc"))
        XCTAssertFalse(redacted.contains("def"))
        XCTAssertFalse(redacted.contains("eyJ"))
    }
}
