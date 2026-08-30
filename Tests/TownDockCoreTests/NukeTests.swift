import Foundation
import XCTest
@testable import TownDockCore

private final class NukeCommandFixture: @unchecked Sendable {
    let repository: URL
    let worktree: URL
    let head = "0123456789abcdef"
    let prunable: Bool
    private let lock = NSLock()
    private var callCount = 0

    init(primaryOnly: Bool = false, prunable: Bool = false) throws {
        self.prunable = prunable
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TownDockNukeTests-\(UUID().uuidString)")
        repository = root.appendingPathComponent("town")
        worktree = primaryOnly ? repository : root.appendingPathComponent("town-feature")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        if !primaryOnly {
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        }
    }

    func run(
        tool: CommandTool,
        arguments: [String],
        workingDirectory: URL?,
        allowedExitCodes: Set<Int32>
    ) throws -> CommandResult {
        lock.lock()
        callCount += 1
        lock.unlock()
        XCTAssertEqual(tool, .git)
        XCTAssertNil(workingDirectory)
        XCTAssertTrue(allowedExitCodes.contains(0))

        let commandDirectory: String = {
            guard let index = arguments.firstIndex(of: "-C"), arguments.indices.contains(index + 1) else {
                return repository.path
            }
            return arguments[index + 1]
        }()
        let output: String
        if arguments.contains("--show-toplevel"),
           prunable,
           commandDirectory == worktree.path {
            return CommandResult(
                stdout: "",
                stderr: "fatal: not a git repository",
                terminationStatus: 128
            )
        } else if arguments.contains("--show-toplevel") {
            output = commandDirectory
        } else if arguments.contains("--git-common-dir") {
            output = repository.appendingPathComponent(".git").path
        } else if arguments.last == "HEAD" {
            output = head
        } else if arguments.contains("--porcelain") {
            output = """
            worktree \(repository.path)
            HEAD \(head)
            branch refs/heads/main

            \(worktree.path == repository.path ? "" : "worktree \(worktree.path)\nHEAD \(head)\n\(prunable ? "detached\nprunable gitdir file points to non-existent location" : "branch refs/heads/codex/test")\n")
            """
        } else {
            XCTFail("Unexpected command: \(arguments)")
            output = ""
        }
        return CommandResult(stdout: output + "\n", stderr: "", terminationStatus: 0)
    }

    func calls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
    }
}

final class NukeTests: XCTestCase {
    func testDockerMountParserAcceptsGoTemplateSpacing() {
        XCTAssertTrue(dockerMountOutput(
            "harness-electric-data-3 | /var/electric\n",
            containsName: "harness-electric-data-3",
            destination: "/var/electric"
        ))
        XCTAssertTrue(dockerMountOutput(
            "harness-electric-data-3|/var/electric\n",
            containsName: "harness-electric-data-3",
            destination: "/var/electric"
        ))
        XCTAssertFalse(dockerMountOutput(
            "harness-electric-data-8 | /var/electric\n",
            containsName: "harness-electric-data-3",
            destination: "/var/electric"
        ))
    }

    func testPrimaryCheckoutCanNeverProduceExecutableManifest() async throws {
        let fixture = try NukeCommandFixture(primaryOnly: true)
        defer { fixture.cleanup() }
        let engine = makeEngine(fixture)
        let snapshot = makeWorktree(path: fixture.repository.path, isPrimary: false)

        let manifest = try await engine.dryRun(
            worktree: snapshot,
            repositoryPath: fixture.repository.path
        )

        XCTAssertFalse(manifest.canExecute)
        XCTAssertTrue(manifest.warnings.contains { $0.contains("primary checkout") })
        XCTAssertEqual(
            manifest.targets.first(where: { $0.kind == .worktreeDirectory })?.actionable,
            false
        )
    }

    func testWrongConfirmationStopsBeforeAnyExecutionCommand() async throws {
        let fixture = try NukeCommandFixture()
        defer { fixture.cleanup() }
        let engine = makeEngine(fixture)
        let manifest = try await engine.dryRun(
            worktree: makeWorktree(path: fixture.worktree.path),
            repositoryPath: fixture.repository.path
        )
        XCTAssertTrue(manifest.canExecute)
        let callsAfterDryRun = fixture.calls()

        do {
            _ = try await engine.execute(
                manifest: manifest,
                repositoryPath: fixture.repository.path,
                confirmationText: "not the exact branch"
            )
            XCTFail("Expected confirmation failure.")
        } catch let error as TownDockError {
            guard case .unsafeOperation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fixture.calls(), callsAfterDryRun)
    }

    func testBranchCheckboxChangeRequiresFreshManifest() async throws {
        let fixture = try NukeCommandFixture()
        defer { fixture.cleanup() }
        let engine = makeEngine(fixture)
        let manifest = try await engine.dryRun(
            worktree: makeWorktree(path: fixture.worktree.path),
            repositoryPath: fixture.repository.path,
            deleteLocalBranch: false
        )
        let callsAfterDryRun = fixture.calls()

        do {
            _ = try await engine.execute(
                manifest: manifest,
                repositoryPath: fixture.repository.path,
                confirmationText: manifest.confirmationText,
                deleteLocalBranch: true
            )
            XCTFail("Expected stale-manifest failure.")
        } catch let error as TownDockError {
            guard case .staleSnapshot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fixture.calls(), callsAfterDryRun)
    }

    func testAmbiguousInstanceOwnershipBlocksNuke() async throws {
        let fixture = try NukeCommandFixture()
        defer { fixture.cleanup() }
        let engine = makeEngine(fixture)
        let instance = InstanceSnapshot(
            number: 2,
            confidence: .ambiguous,
            evidence: ["port formula only"],
            services: [],
            actualBucketName: nil
        )

        let manifest = try await engine.dryRun(
            worktree: makeWorktree(path: fixture.worktree.path, instance: instance),
            repositoryPath: fixture.repository.path
        )

        XCTAssertFalse(manifest.canExecute)
        XCTAssertTrue(manifest.targets.contains {
            $0.kind == .minioBucket && !$0.actionable
        })
        XCTAssertTrue(manifest.warnings.contains { $0.contains("ambiguous") })
    }

    func testProvisionedWorktreeWithoutInstanceRefusesIncompleteNuke() async throws {
        let fixture = try NukeCommandFixture()
        defer { fixture.cleanup() }
        let engine = makeEngine(fixture)
        let source = makeWorktree(path: fixture.worktree.path)
        let provisioned = WorktreeSnapshot(
            path: source.path,
            head: source.head,
            branch: source.branch,
            isDetached: source.isDetached,
            isPrimary: source.isPrimary,
            isLocked: source.isLocked,
            isPrunable: source.isPrunable,
            gitStatus: source.gitStatus,
            instance: nil,
            health: nil,
            setupComplete: true
        )

        let manifest = try await engine.dryRun(
            worktree: provisioned,
            repositoryPath: fixture.repository.path
        )

        XCTAssertFalse(manifest.canExecute)
        XCTAssertTrue(manifest.warnings.contains { $0.contains("checkout-only deletion") })
    }

    func testPrunableRegistrationWithMissingGitLinkCanBuildDeletionManifest() async throws {
        let fixture = try NukeCommandFixture(prunable: true)
        defer { fixture.cleanup() }
        let source = makeWorktree(path: fixture.worktree.path)
        let stranded = WorktreeSnapshot(
            path: source.path,
            head: source.head,
            branch: nil,
            isDetached: true,
            isPrimary: false,
            isLocked: false,
            isPrunable: true,
            gitStatus: source.gitStatus,
            instance: nil,
            health: nil,
            setupComplete: false
        )

        let manifest = try await makeEngine(fixture).dryRun(
            worktree: stranded,
            repositoryPath: fixture.repository.path
        )

        XCTAssertTrue(manifest.canExecute)
        XCTAssertTrue(manifest.targets.contains {
            $0.kind == .worktreeDirectory && $0.actionable
        })
        XCTAssertTrue(manifest.targets.contains {
            $0.kind == .gitRegistration && $0.actionable
        })
    }

    func testManifestIncludesOnlyPerInstanceDockerResourcesAndObservedBucket() async throws {
        let fixture = try NukeCommandFixture()
        defer { fixture.cleanup() }
        let engine = makeEngine(fixture)
        let services = [
            ServiceSnapshot(kind: .frontend, port: 3_040, state: .running),
            ServiceSnapshot(kind: .postgres, port: 5_433, state: .running, isShared: true),
        ]
        let instance = InstanceSnapshot(
            number: 4,
            confidence: .certain,
            evidence: ["marker and cwd"],
            services: services,
            actualBucketName: "custom-town-bucket-4"
        )

        let manifest = try await engine.dryRun(
            worktree: makeWorktree(path: fixture.worktree.path, instance: instance),
            repositoryPath: fixture.repository.path
        )

        XCTAssertTrue(manifest.canExecute)
        XCTAssertTrue(manifest.targets.contains {
            $0.kind == .dockerContainer && $0.identifier == "harness-electric-4"
        })
        XCTAssertTrue(manifest.targets.contains {
            $0.kind == .dockerVolume && $0.identifier == "harness-electric-data-4"
        })
        XCTAssertTrue(manifest.targets.contains {
            $0.kind == .minioBucket && $0.identifier == "custom-town-bucket-4"
        })
        XCTAssertFalse(manifest.targets.contains {
            $0.kind == .listener && $0.identifier == "5433"
        })
        XCTAssertFalse(manifest.targets.contains {
            $0.kind == .dockerContainer && ["harness-postgres", "harness-minio", "harness-temporal"].contains($0.identifier)
        })
    }

    func testExecutionRefusesInstanceReusedByAnotherWorktree() async throws {
        let fixture = try NukeCommandFixture()
        defer { fixture.cleanup() }
        let instance = InstanceSnapshot(
            number: 6,
            confidence: .certain,
            evidence: ["marker and cwd"],
            services: [],
            actualBucketName: "town-observed-6"
        )
        let reviewed = makeWorktree(path: fixture.worktree.path, instance: instance)
        let competing = makeWorktree(path: "/tmp/another-town-worktree", instance: instance)
        let fresh = TownSnapshot(
            repositoryPath: fixture.repository.path,
            worktrees: [
                makeWorktree(path: fixture.repository.path, isPrimary: true),
                reviewed,
                competing,
            ],
            orphans: [],
            sharedServices: [],
            dormantStates: []
        )
        let engine = makeEngine(fixture, freshSnapshot: { _ in fresh })
        let manifest = try await engine.dryRun(
            worktree: reviewed,
            repositoryPath: fixture.repository.path
        )
        XCTAssertTrue(manifest.canExecute)

        do {
            _ = try await engine.execute(
                manifest: manifest,
                repositoryPath: fixture.repository.path,
                confirmationText: manifest.confirmationText
            )
            XCTFail("Expected reused-instance ownership to be rejected.")
        } catch let error as TownDockError {
            guard case .unsafeOperation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testOrphanCleanupManifestIncludesOnlyHighConfidenceOwnedResources() async throws {
        let fixture = try NukeCommandFixture()
        defer { fixture.cleanup() }
        let state = StateDirectorySnapshot(
            path: "/Users/example/.convex/local-backend-instance-2-3230",
            instanceNumber: 2,
            sizeBytes: 4_096,
            modifiedAt: nil,
            isRunning: false,
            associatedWorktreePath: nil,
            confidence: .ambiguous
        )
        let owned = OrphanSnapshot(
            id: "dormant-2",
            kind: .dormantState,
            title: "Dormant state for instance 2",
            missingPath: nil,
            instanceNumber: 2,
            confidence: .high,
            reasons: ["unclaimed"],
            stateDirectory: state
        )
        let ambiguous = OrphanSnapshot(
            id: "ambiguous-process",
            kind: .unclaimedInstance,
            title: "Ambiguous process",
            missingPath: nil,
            instanceNumber: 3,
            confidence: .ambiguous,
            reasons: ["port-only"],
            processes: [
                ProcessIdentity(
                    pid: 99,
                    parentPID: 1,
                    processGroupID: 99,
                    startToken: "token",
                    command: "node",
                    workingDirectory: "/tmp/unknown"
                ),
            ]
        )
        let snapshot = TownSnapshot(
            repositoryPath: fixture.repository.path,
            worktrees: [makeWorktree(path: fixture.repository.path, isPrimary: true)],
            orphans: [owned, ambiguous],
            sharedServices: [],
            dormantStates: [state]
        )
        let engine = makeEngine(fixture)

        let manifest = await engine.orphanCleanupDryRun(snapshot: snapshot)
        let selected = manifest.targets.filter { $0.actionable && $0.selectedByDefault }

        XCTAssertTrue(manifest.canExecute)
        XCTAssertEqual(selected.filter { $0.kind == .convexStateDirectory }.count, 1)
        XCTAssertEqual(selected.filter { $0.kind == .dockerContainer }.count, 1)
        XCTAssertEqual(selected.filter { $0.kind == .dockerVolume }.count, 1)
        XCTAssertEqual(selected.filter { $0.kind == .postgresReplicationSlot }.count, 1)
        XCTAssertEqual(selected.filter { $0.kind == .postgresDatabase }.count, 1)
        XCTAssertEqual(
            manifest.targets.first(where: { $0.identifier == ambiguous.id })?.actionable,
            false
        )
    }

    private func makeEngine(
        _ fixture: NukeCommandFixture,
        freshSnapshot: @escaping FreshSnapshotProvider = { _ in
            throw TownDockError.unsupported("Fresh discovery was not expected in this test.")
        }
    ) -> NukeEngine {
        let control = TownControlEngine(
            runCommand: { _, _, _, _ in
                XCTFail("No process controls should run in these manifest/gate tests.")
                return CommandResult(stdout: "", stderr: "", terminationStatus: 1)
            }
        )
        let registryURL = fixture.repository.deletingLastPathComponent()
            .appendingPathComponent("registry.json")
        return NukeEngine(
            runCommand: { tool, arguments, workingDirectory, allowedExitCodes in
                try fixture.run(
                    tool: tool,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    allowedExitCodes: allowedExitCodes
                )
            },
            controlEngine: control,
            registry: TownRegistry(fileURL: registryURL),
            freshSnapshot: freshSnapshot
        )
    }

    private func makeWorktree(
        path: String,
        isPrimary: Bool = false,
        instance: InstanceSnapshot? = nil
    ) -> WorktreeSnapshot {
        WorktreeSnapshot(
            path: path,
            head: "0123456789abcdef",
            branch: path.hasSuffix("/town") ? "main" : "codex/test",
            isDetached: false,
            isPrimary: isPrimary,
            isLocked: false,
            isPrunable: false,
            gitStatus: GitStatusSnapshot(),
            instance: instance,
            health: nil,
            setupComplete: false
        )
    }
}
