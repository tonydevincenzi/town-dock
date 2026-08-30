import Foundation
import XCTest
@testable import TownDockCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class ControlInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [(Int32, Int32)] = []
    private var launches: [(URL, [String], URL)] = []

    func recordSignal(_ pid: Int32, _ signal: Int32) {
        lock.lock()
        signals.append((pid, signal))
        lock.unlock()
    }

    func recordLaunch(_ executable: URL, _ arguments: [String], _ cwd: URL) {
        lock.lock()
        launches.append((executable, arguments, cwd))
        lock.unlock()
    }

    func signalSnapshot() -> [(Int32, Int32)] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }

    func launchSnapshot() -> [(URL, [String], URL)] {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }
}

final class ControlsTests: XCTestCase {
    func testDockerDesktopBackendIsAlwaysClassifiedAsSharedRuntimeHost() {
        XCTAssertTrue(TownProcessClassifier.isSharedRuntimeHost(
            "/Applications/Docker.app/Contents/MacOS/com.docker.backend services"
        ))
        XCTAssertTrue(TownProcessClassifier.isSharedRuntimeHost("com.docker.backend services"))
        XCTAssertFalse(TownProcessClassifier.isSharedRuntimeHost(
            "convex-local-backend --instance-name instance-5"
        ))
    }

    func testOwnershipAnchorsExcludeUnrelatedProcessInSameCheckout() {
        let launcher = ProcessIdentity(
            pid: 100,
            parentPID: 10,
            processGroupID: 100,
            startToken: "launcher",
            command: "./mise run local-stack",
            workingDirectory: "/tmp/town"
        )
        let child = ProcessIdentity(
            pid: 101,
            parentPID: 100,
            processGroupID: 101,
            startToken: "child",
            command: "node scripts/local-frontend-dev.ts",
            workingDirectory: "/tmp/town"
        )
        let listener = ProcessIdentity(
            pid: 102,
            parentPID: 101,
            processGroupID: 101,
            startToken: "listener",
            command: "next-server",
            workingDirectory: "/tmp/town"
        )
        let unrelated = ProcessIdentity(
            pid: 200,
            parentPID: 10,
            processGroupID: 200,
            startToken: "agent",
            command: "coding-agent",
            workingDirectory: "/tmp/town"
        )

        let anchored = TownProcessClassifier.anchoredProcessIDs(
            processes: [launcher, child, listener, unrelated],
            listenerPIDs: [listener.pid],
            ownsPath: { $0.workingDirectory == "/tmp/town" }
        )

        XCTAssertEqual(anchored, Set([launcher.pid, child.pid, listener.pid]))
        XCTAssertFalse(anchored.contains(unrelated.pid))
    }

    func testStartUsesPTYCaptureAndPinnedMiseInstance() async throws {
        let directory = try makeWorktreeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ControlInvocationRecorder()
        let consoleRoot = directory.appendingPathComponent("captures")
        let worktree = makeWorktree(
            path: directory.path,
            instance: makeInstance(number: 3, processes: [], services: [])
        )
        let engine = TownControlEngine(
            runCommand: { tool, _, _, _ in
                XCTAssertEqual(tool, .git)
                return CommandResult(
                    stdout: directory.path + "\n",
                    stderr: "",
                    terminationStatus: 0
                )
            },
            launchProcess: { executable, arguments, cwd in
                recorder.recordLaunch(executable, arguments, cwd)
                return 9_001
            },
            consoleRoot: consoleRoot
        )

        let result = try await engine.start(worktree)

        XCTAssertEqual(result.action, .start)
        XCTAssertEqual(result.affectedProcessIDs, [9_001])
        let launch = try XCTUnwrap(recorder.launchSnapshot().first)
        XCTAssertEqual(launch.0.path, "/usr/bin/script")
        XCTAssertEqual(
            launch.1,
            [
                "-q", "-F", "-t", "0",
                StackConsoleCapture.captureURL(
                    for: directory.path,
                    rootDirectory: consoleRoot
                ).path,
                directory.appendingPathComponent("mise").path,
                "run", "local-stack", "--", "-n", "3",
            ]
        )
        XCTAssertEqual(launch.2.path, directory.path)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: StackConsoleCapture.captureURL(
                for: directory.path,
                rootDirectory: consoleRoot
            ).path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testForceKillRevalidatesIdentityAndStateDirectoryOwnership() async throws {
        let recorder = ControlInvocationRecorder()
        let worktreePath = "/tmp/town-owned-worktree"
        let statePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".convex/local-backend-test-3240").path
        let process = ProcessIdentity(
            pid: 4_242,
            parentPID: 1,
            processGroupID: 4_200,
            startToken: "Sat Aug 29 13:00:00 2026",
            command: "convex-local-backend",
            workingDirectory: statePath
        )
        let state = StateDirectorySnapshot(
            path: statePath,
            instanceNumber: 3,
            sizeBytes: 100,
            modifiedAt: nil,
            isRunning: true,
            associatedWorktreePath: worktreePath,
            confidence: .certain
        )
        let instance = InstanceSnapshot(
            number: 3,
            confidence: .certain,
            evidence: ["verified marker"],
            services: [
                ServiceSnapshot(
                    kind: .convexBackend,
                    port: 3_240,
                    state: .running,
                    processIDs: [4_242]
                ),
            ],
            processes: [process],
            stateDirectory: state,
            actualBucketName: "town-test-3"
        )
        let engine = TownControlEngine(
            runCommand: { tool, arguments, _, _ in
                if tool == .ps {
                    return CommandResult(
                        stdout: "Sat Aug 29 13:00:00 2026 4200\n",
                        stderr: "",
                        terminationStatus: 0
                    )
                }
                if arguments.contains("cwd") {
                    return CommandResult(
                        stdout: "p4242\nfcwd\nn\(statePath)\n",
                        stderr: "",
                        terminationStatus: 0
                    )
                }
                return CommandResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            sendSignal: { pid, signal in recorder.recordSignal(pid, signal) }
        )

        let result = try await engine.forceKill(
            makeWorktree(path: worktreePath, instance: instance)
        )

        XCTAssertEqual(result.affectedProcessIDs, [4_242])
        XCTAssertEqual(recorder.signalSnapshot().map(\.0), [4_242])
        XCTAssertEqual(recorder.signalSnapshot().map(\.1), [SIGKILL])
    }

    func testOrphanKillAcceptsDiscoveredUnderscoreStartToken() async throws {
        let recorder = ControlInvocationRecorder()
        let missingPath = "/tmp/deleted-town-worktree"
        let process = ProcessIdentity(
            pid: 4_242,
            parentPID: 1,
            processGroupID: 4_200,
            startToken: "Sat_Aug_29_13:00:00_2026",
            command: "convex-local-backend",
            workingDirectory: missingPath
        )
        let orphan = OrphanSnapshot(
            id: "deleted-worktree-3",
            kind: .deletedWorktree,
            title: "Deleted worktree instance 3",
            missingPath: missingPath,
            instanceNumber: 3,
            confidence: .certain,
            reasons: ["The worktree directory disappeared."],
            processes: [process]
        )
        let engine = TownControlEngine(
            runCommand: { tool, arguments, _, _ in
                if tool == .ps {
                    return CommandResult(
                        stdout: "Sat Aug 29 13:00:00 2026 4200\n",
                        stderr: "",
                        terminationStatus: 0
                    )
                }
                if arguments.contains("cwd") {
                    return CommandResult(
                        stdout: "p4242\nfcwd\nn\(missingPath) (deleted)\n",
                        stderr: "",
                        terminationStatus: 0
                    )
                }
                return CommandResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            sendSignal: { pid, signal in recorder.recordSignal(pid, signal) }
        )

        let result = try await engine.killOrphan(orphan)

        XCTAssertEqual(result.affectedProcessIDs, [4_242])
        XCTAssertEqual(recorder.signalSnapshot().map(\.0), [4_242, 4_242])
        XCTAssertEqual(recorder.signalSnapshot().map(\.1), [SIGTERM, SIGKILL])
    }

    func testAmbiguousOrphanIsRefusedWithoutSendingSignals() async throws {
        let recorder = ControlInvocationRecorder()
        let engine = TownControlEngine(
            runCommand: { _, _, _, _ in
                XCTFail("Ambiguous ownership must fail before process inspection.")
                return CommandResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            sendSignal: { pid, signal in recorder.recordSignal(pid, signal) }
        )
        let orphan = OrphanSnapshot(
            id: "ambiguous",
            kind: .unclaimedInstance,
            title: "Unknown process",
            missingPath: nil,
            instanceNumber: 2,
            confidence: .ambiguous,
            reasons: ["port-only match"],
            processes: [
                ProcessIdentity(
                    pid: 7_777,
                    parentPID: 1,
                    processGroupID: 7_777,
                    startToken: "token",
                    command: "node",
                    workingDirectory: "/tmp/unknown"
                ),
            ]
        )

        do {
            _ = try await engine.killOrphan(orphan)
            XCTFail("Expected ambiguous ownership to be rejected.")
        } catch let error as TownDockError {
            guard case .unsafeOperation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(recorder.signalSnapshot().isEmpty)
    }

    func testSharedServicePIDIsNeverEligible() async throws {
        let recorder = ControlInvocationRecorder()
        let process = ProcessIdentity(
            pid: 5_432,
            parentPID: 1,
            processGroupID: 5_432,
            startToken: "token",
            command: "postgres",
            workingDirectory: "/tmp/town"
        )
        let service = ServiceSnapshot(
            kind: .postgres,
            port: 5_433,
            state: .running,
            processIDs: [5_432],
            isShared: true
        )
        let engine = TownControlEngine(
            runCommand: { _, _, _, _ in
                XCTFail("A shared PID must not be inspected or signalled.")
                return CommandResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            sendSignal: { pid, signal in recorder.recordSignal(pid, signal) }
        )
        let instance = makeInstance(
            number: 1,
            processes: [process],
            services: [service]
        )

        let result = try await engine.forceKill(
            makeWorktree(path: "/tmp/town", instance: instance)
        )

        XCTAssertTrue(result.affectedProcessIDs.isEmpty)
        XCTAssertTrue(recorder.signalSnapshot().isEmpty)
    }

    private func makeWorktreeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TownDockControlsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mise = root.appendingPathComponent("mise")
        XCTAssertTrue(FileManager.default.createFile(atPath: mise.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mise.path)
        return root
    }

    private func makeInstance(
        number: Int,
        processes: [ProcessIdentity],
        services: [ServiceSnapshot]
    ) -> InstanceSnapshot {
        InstanceSnapshot(
            number: number,
            confidence: .certain,
            evidence: ["test"],
            services: services,
            processes: processes,
            actualBucketName: "town-test-\(number)"
        )
    }

    private func makeWorktree(
        path: String,
        instance: InstanceSnapshot?
    ) -> WorktreeSnapshot {
        WorktreeSnapshot(
            path: path,
            head: "abc123",
            branch: "codex/test",
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
