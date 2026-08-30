@preconcurrency import Foundation

public enum NukeTargetDisposition: String, Codable, Sendable {
    case removed
    case alreadyAbsent
    case skipped
}

public struct NukeTargetOutcome: Codable, Hashable, Sendable {
    public let targetID: String
    public let disposition: NukeTargetDisposition
    public let detail: String

    public init(
        targetID: String,
        disposition: NukeTargetDisposition,
        detail: String
    ) {
        self.targetID = targetID
        self.disposition = disposition
        self.detail = detail
    }
}

public struct NukeExecutionResult: Codable, Hashable, Sendable {
    public let worktreePath: String
    public let outcomes: [NukeTargetOutcome]
    public let deletedLocalBranch: Bool
    public let completedAt: Date

    public init(
        worktreePath: String,
        outcomes: [NukeTargetOutcome],
        deletedLocalBranch: Bool,
        completedAt: Date = Date()
    ) {
        self.worktreePath = worktreePath
        self.outcomes = outcomes
        self.deletedLocalBranch = deletedLocalBranch
        self.completedAt = completedAt
    }
}

typealias FreshSnapshotProvider = @Sendable (_ repositoryPath: String) async throws -> TownSnapshot

/// Docker's Go-template `println` inserts spaces between arguments. Parse the
/// fields instead of comparing its raw output so `name | destination` and
/// `name|destination` are treated identically without weakening either check.
func dockerMountOutput(
    _ output: String,
    containsName expectedName: String,
    destination expectedDestination: String
) -> Bool {
    output.split(whereSeparator: \.isNewline).contains { row in
        let fields = row.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count == 2 else { return false }
        return fields[0].trimmingCharacters(in: .whitespaces) == expectedName
            && fields[1].trimmingCharacters(in: .whitespaces) == expectedDestination
    }
}

/// `pg_replication_slots.database` is already a database name. Joining it to
/// `pg_database.oid` produces an `oid = name` error on supported PostgreSQL
/// versions, so read and verify the name directly from the slot record.
func replicationSlotLookupSQL(named slotName: String) -> String {
    "SELECT s.slot_name || '|' || s.database || '|' || s.active "
        + "FROM pg_replication_slots s WHERE s.slot_name='\(slotName)'"
}

/// Builds and executes a frozen, reviewable worktree deletion manifest.
///
/// `execute` is intentionally strict: the exact confirmation string, branch
/// checkbox state, Git identity, HEAD, common repository, worktree registration,
/// and per-resource ownership are all checked again immediately before mutation.
public actor NukeEngine {
    private let runCommand: ControlCommand
    private let controlEngine: TownControlEngine
    private let registry: TownRegistry
    private let freshSnapshot: FreshSnapshotProvider

    public init(
        commandRunner: CommandRunner = CommandRunner(),
        controlEngine: TownControlEngine? = nil,
        registry: TownRegistry = TownRegistry()
    ) {
        self.runCommand = { tool, arguments, workingDirectory, allowedExitCodes in
            try commandRunner.run(
                tool,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeout: 15,
                allowedExitCodes: allowedExitCodes
            )
        }
        self.controlEngine = controlEngine ?? TownControlEngine(commandRunner: commandRunner)
        self.registry = registry
        self.freshSnapshot = { repositoryPath in
            let discovered = try await TownDiscoveryEngine(
                repositoryPath: repositoryPath,
                runner: commandRunner
            ).snapshot()
            return await registry.enrich(snapshot: discovered)
        }
    }

    init(
        runCommand: @escaping ControlCommand,
        controlEngine: TownControlEngine,
        registry: TownRegistry,
        freshSnapshot: @escaping FreshSnapshotProvider = { _ in
            throw TownDockError.unsupported("No fresh-snapshot provider was configured for this test.")
        }
    ) {
        self.runCommand = runCommand
        self.controlEngine = controlEngine
        self.registry = registry
        self.freshSnapshot = freshSnapshot
    }

    public func dryRun(
        worktree: WorktreeSnapshot,
        repositoryPath: String,
        deleteLocalBranch: Bool = false
    ) async throws -> NukeManifest {
        let identity = try validateGitIdentity(
            worktree: worktree,
            repositoryPath: repositoryPath
        )
        let instance = worktree.instance
        let instanceIsOwned = instance.map {
            $0.confidence.rank >= AttributionConfidence.high.rank
        } ?? true
        var targets: [DestructiveTarget] = []
        var warnings: [String] = []
        var hasBlockingAmbiguity = !instanceIsOwned

        if instance == nil, worktree.setupComplete {
            hasBlockingAmbiguity = true
            warnings.append(
                "This provisioned worktree has no freshly attributable instance. Town Sheriff will not perform a checkout-only deletion that could strand its storage."
            )
        }

        if identity.isPrimary || worktree.isPrimary {
            warnings.append("The primary checkout can be reset, but it can never be deleted by Town Sheriff.")
        }
        if worktree.gitStatus.isDirty {
            warnings.append(
                "This worktree has uncommitted or untracked files. Deletion is permanent."
            )
        }
        if worktree.gitStatus.ahead > 0 {
            warnings.append(
                "This branch is ahead of its upstream by \(worktree.gitStatus.ahead) commit(s)."
            )
        }
        if worktree.isDetached {
            warnings.append("This worktree is detached; record its commit before deletion if needed.")
        }
        if !instanceIsOwned {
            warnings.append(
                "The instance association is ambiguous, so its processes and storage cannot be deleted safely."
            )
        }

        if let instance {
            let sharedPIDs = Set(instance.services.filter(\.isShared).flatMap(\.processIDs))
            let listenerPIDs = Set(instance.services.filter { !$0.isShared }.flatMap(\.processIDs))
            let ownershipRoots = safeOwnershipRoots(worktree: worktree)
            let groups = Dictionary(grouping: instance.processes) { $0.processGroupID }
            let ownsPath: (ProcessIdentity) -> Bool = { process in
                process.workingDirectory.map { cwd in
                    ownershipRoots.contains(where: { self.path(cwd, isInside: $0) })
                } == true
            }
            let anchoredPIDs = TownProcessClassifier.anchoredProcessIDs(
                processes: instance.processes,
                listenerPIDs: listenerPIDs,
                ownsPath: ownsPath
            )
            for (groupID, processes) in groups.sorted(by: { $0.key < $1.key })
                where groupID > 1
            {
                let groupIsOwned = instanceIsOwned
                    && processes.contains(where: { anchoredPIDs.contains($0.pid) })
                    && processes.allSatisfy { process in
                        !sharedPIDs.contains(process.pid)
                            && anchoredPIDs.contains(process.pid)
                            && ownsPath(process)
                    }
                if !groupIsOwned {
                    hasBlockingAmbiguity = true
                    warnings.append(
                        "Process group \(groupID) contains a process whose ownership is not provable."
                    )
                }
                targets.append(
                    DestructiveTarget(
                        id: "process-group:\(groupID)",
                        kind: .processGroup,
                        label: "Town process group \(groupID)",
                        identifier: String(groupID),
                        confidence: groupIsOwned ? .high : .ambiguous,
                        selectedByDefault: groupIsOwned,
                        actionable: groupIsOwned,
                        note: groupIsOwned ? "TERM first, then ownership-checked KILL sweep." : "Ownership is ambiguous."
                    )
                )
            }

            for service in instance.services.sorted(by: { $0.port < $1.port })
                where !service.isShared
            {
                targets.append(
                    DestructiveTarget(
                        id: "listener:\(service.port)",
                        kind: .listener,
                        label: "\(service.kind.displayName) listener",
                        identifier: String(service.port),
                        confidence: instanceIsOwned ? .high : .ambiguous,
                        selectedByDefault: instanceIsOwned,
                        actionable: instanceIsOwned,
                        note: "Only a listener whose current cwd belongs to this worktree or its state directory is eligible."
                    )
                )
            }

            let n = instance.number
            if (1...9).contains(n) {
                targets += perInstanceTargets(number: n, actionable: instanceIsOwned)
            } else {
                hasBlockingAmbiguity = true
                warnings.append("The recorded instance number is outside Town's supported 1...9 range.")
            }

            if let state = instance.stateDirectory {
                let stateIsOwned = instanceIsOwned && stateDirectoryIsOwned(state, by: worktree)
                if !stateIsOwned {
                    hasBlockingAmbiguity = true
                    warnings.append("The Convex state directory is not safely attributable to this worktree.")
                }
                targets.append(
                    DestructiveTarget(
                        id: "convex-state:\(state.path)",
                        kind: .convexStateDirectory,
                        label: "Convex state and uploads",
                        identifier: state.path,
                        estimatedBytes: state.sizeBytes,
                        confidence: stateIsOwned ? .high : .ambiguous,
                        selectedByDefault: stateIsOwned,
                        actionable: stateIsOwned,
                        note: stateIsOwned ? nil : "Path ownership must be resolved before deletion."
                    )
                )
            } else if worktree.setupComplete {
                hasBlockingAmbiguity = true
                warnings.append(
                    "Setup is recorded as complete, but no owned Convex state directory was found."
                )
            }

            if let bucket = instance.actualBucketName,
               validBucketName(bucket)
            {
                targets.append(
                    DestructiveTarget(
                        id: "minio-bucket:\(bucket)",
                        kind: .minioBucket,
                        label: "MinIO bucket",
                        identifier: bucket,
                        confidence: instanceIsOwned ? .high : .ambiguous,
                        selectedByDefault: instanceIsOwned,
                        actionable: instanceIsOwned
                    )
                )
            } else {
                hasBlockingAmbiguity = true
                let expected = "harness-storage-\(instance.number)"
                targets.append(
                    DestructiveTarget(
                        id: "minio-bucket:unresolved:\(instance.number)",
                        kind: .minioBucket,
                        label: "Unresolved MinIO bucket",
                        identifier: expected,
                        confidence: .ambiguous,
                        selectedByDefault: false,
                        actionable: false,
                        note: "Town permits an S3 bucket-prefix override; the observed bucket name is required."
                    )
                )
                warnings.append(
                    "The actual MinIO bucket was not observed; Town Sheriff will not guess from the instance number."
                )
            }

            let tunnelPath = "/tmp/town-tunnel-\(instance.number).json"
            if FileManager.default.fileExists(atPath: tunnelPath) {
                targets.append(
                    DestructiveTarget(
                        id: "tunnel-marker:\(instance.number)",
                        kind: .tunnelMarker,
                        label: "Tunnel marker",
                        identifier: tunnelPath,
                        confidence: instanceIsOwned ? .high : .ambiguous,
                        selectedByDefault: instanceIsOwned,
                        actionable: instanceIsOwned
                    )
                )
            }

            targets.append(
                DestructiveTarget(
                    id: "temporal-history:\(instance.number)",
                    kind: .temporalHistory,
                    label: "Potential Temporal workflow history",
                    identifier: "Town instance \(instance.number)",
                    confidence: .inferred,
                    selectedByDefault: false,
                    actionable: false,
                    note: "Only explicitly enumerated, provably owned workflows may be removed; none were supplied by discovery."
                )
            )
            targets.append(
                DestructiveTarget(
                    id: "remote-subscription:\(instance.number)",
                    kind: .remoteSubscription,
                    label: "Potential Gmail development subscription",
                    identifier: "gmail-push-dev-<developer>-\(instance.number)",
                    confidence: .inferred,
                    selectedByDefault: false,
                    actionable: false,
                    note: "Remote deletion requires an exact observed resource name and separate confirmation."
                )
            )
        }

        let worktreeActionable = !identity.isPrimary && !worktree.isPrimary
        targets.append(
            DestructiveTarget(
                id: "git-registration:\(identity.path)",
                kind: .gitRegistration,
                label: "Git worktree registration",
                identifier: identity.path,
                confidence: .certain,
                selectedByDefault: worktreeActionable,
                actionable: worktreeActionable
            )
        )
        targets.append(
            DestructiveTarget(
                id: "worktree-directory:\(identity.path)",
                kind: .worktreeDirectory,
                label: "Worktree directory and all ignored files",
                identifier: identity.path,
                confidence: .certain,
                selectedByDefault: worktreeActionable,
                actionable: worktreeActionable,
                note: "Includes node_modules, build products, caches, logs, and every untracked file beneath the checkout."
            )
        )

        if let branch = worktree.branch {
            targets.append(
                DestructiveTarget(
                    id: "local-branch:\(branch)",
                    kind: .localBranch,
                    label: "Local Git branch",
                    identifier: branch,
                    confidence: .certain,
                    selectedByDefault: deleteLocalBranch,
                    actionable: worktreeActionable,
                    note: "Controlled by the separate Delete local branch checkbox."
                )
            )
        }

        let label = worktree.branch ?? URL(fileURLWithPath: identity.path).lastPathComponent
        let canExecute = worktreeActionable
            && !hasBlockingAmbiguity
            && targets.filter(\.selectedByDefault).allSatisfy(\.actionable)

        return NukeManifest(
            worktree: worktree,
            targets: targets,
            warnings: warnings,
            confirmationText: label,
            canExecute: canExecute
        )
    }

    public func execute(
        manifest: NukeManifest,
        repositoryPath: String,
        confirmationText: String,
        deleteLocalBranch: Bool = false
    ) async throws -> NukeExecutionResult {
        guard manifest.canExecute else {
            throw TownDockError.unsafeOperation(
                "This manifest contains a blocking ownership or primary-checkout safety issue."
            )
        }
        guard confirmationText == manifest.confirmationText else {
            throw TownDockError.unsafeOperation("The confirmation text does not match exactly.")
        }
        let branchSelection = manifest.targets.first(where: { $0.kind == .localBranch })?
            .selectedByDefault ?? false
        guard branchSelection == deleteLocalBranch else {
            throw TownDockError.staleSnapshot(
                "The branch deletion checkbox changed. Generate and confirm a new manifest."
            )
        }

        let identity = try validateGitIdentity(
            worktree: manifest.worktree,
            repositoryPath: repositoryPath
        )
        guard !identity.isPrimary, !manifest.worktree.isPrimary else {
            throw TownDockError.unsafeOperation("The primary checkout can never be deleted.")
        }

        // Instance numbers are reusable. Never trust the reviewed snapshot at
        // execution time: rediscover all ownership and require every persistent
        // resource key to still match before the first mutation.
        let currentSnapshot = try await freshSnapshot(identity.repositoryPath)
        let currentWorktree = try revalidateFreshOwnership(
            manifest: manifest,
            snapshot: currentSnapshot,
            repositoryPath: identity.repositoryPath
        )
        try validateSelectedTargets(
            manifest.targets.filter(\.selectedByDefault),
            for: currentWorktree,
            identity: identity
        )
        if let record = await registry.record(forPath: currentWorktree.path) {
            guard record.head == currentWorktree.head,
                  record.instanceNumber == currentWorktree.instance?.number,
                  record.stateDirectory.map(canonicalPath)
                    == currentWorktree.instance?.stateDirectory.map({ canonicalPath($0.path) }),
                  record.bucketName == currentWorktree.instance?.actualBucketName
            else {
                throw TownDockError.staleSnapshot(
                    "The durable ownership registry conflicts with fresh discovery. Nothing was deleted."
                )
            }
        }
        try await registry.record(snapshot: currentSnapshot)

        if identity.isPrunable {
            try repairPrunableWorktree(identity, expectedHead: currentWorktree.head)
        }

        var outcomes: [NukeTargetOutcome] = []
        if currentWorktree.instance?.isRunning == true {
            _ = try await controlEngine.stop(currentWorktree)
        }
        let swept = try await controlEngine.sweepAfterGrace(currentWorktree)
        for target in manifest.targets where target.kind == .processGroup || target.kind == .listener {
            outcomes.append(
                NukeTargetOutcome(
                    targetID: target.id,
                    disposition: .removed,
                    detail: swept.isEmpty
                        ? "Graceful stop completed; no owned listener remained."
                        : "Graceful stop completed and the final owned listener sweep removed \(swept.count) process(es)."
                )
            )
        }

        for target in manifest.targets where target.selectedByDefault {
            switch target.kind {
            case .processGroup, .listener, .worktreeDirectory, .gitRegistration, .localBranch:
                continue
            case .dockerContainer:
                outcomes.append(try removeDockerContainer(target))
            case .dockerVolume:
                outcomes.append(try removeDockerVolume(target))
            case .postgresReplicationSlot:
                outcomes.append(try removeReplicationSlot(target))
            case .postgresDatabase:
                outcomes.append(try removePostgresDatabase(target))
            case .minioBucket:
                outcomes.append(try removeMinIOBucket(target))
            case .convexStateDirectory:
                outcomes.append(try removeStateDirectory(target, worktree: currentWorktree))
            case .tunnelMarker:
                outcomes.append(try removeTunnelMarker(target, worktree: currentWorktree))
            case .remoteSubscription, .temporalHistory:
                throw TownDockError.unsupported(
                    "A non-actionable remote resource was unexpectedly selected."
                )
            }
        }

        // Git performs the final checkout removal so its administrative state
        // and the directory disappear as one operation.
        _ = try runCommand(
            .git,
            ["-C", identity.repositoryPath, "worktree", "remove", "--force", identity.path],
            nil,
            [0]
        )
        outcomes.append(
            NukeTargetOutcome(
                targetID: "git-registration:\(identity.path)",
                disposition: .removed,
                detail: "Removed Git's worktree registration."
            )
        )
        outcomes.append(
            NukeTargetOutcome(
                targetID: "worktree-directory:\(identity.path)",
                disposition: .removed,
                detail: "Removed the checkout and all files beneath it."
            )
        )

        var branchWasDeleted = false
        if deleteLocalBranch, let branch = manifest.worktree.branch {
            guard !branch.isEmpty, !branch.hasPrefix("-") else {
                throw TownDockError.unsafeOperation("Refusing an unsafe branch name.")
            }
            _ = try runCommand(
                .git,
                ["-C", identity.repositoryPath, "branch", "-D", "--", branch],
                nil,
                [0]
            )
            branchWasDeleted = true
            outcomes.append(
                NukeTargetOutcome(
                    targetID: "local-branch:\(branch)",
                    disposition: .removed,
                    detail: "Deleted the local branch."
                )
            )
        }

        for target in manifest.targets where !target.selectedByDefault {
            outcomes.append(
                NukeTargetOutcome(
                    targetID: target.id,
                    disposition: .skipped,
                    detail: target.note ?? "Not selected."
                )
            )
        }
        try await registry.remove(canonicalPath: identity.path)

        return NukeExecutionResult(
            worktreePath: identity.path,
            outcomes: outcomes,
            deletedLocalBranch: branchWasDeleted
        )
    }

    /// Builds a reviewable manifest for every orphan resource that can be
    /// attributed without guessing. Shared infrastructure and ambiguous
    /// resources are deliberately excluded.
    public func orphanCleanupDryRun(snapshot: TownSnapshot) -> OrphanCleanupManifest {
        let claimedInstances = Set(snapshot.worktrees.compactMap { worktree -> Int? in
            guard let instance = worktree.instance,
                  instance.confidence.rank >= AttributionConfidence.high.rank
            else {
                return nil
            }
            return instance.number
        })
        var targetsByID: [String: DestructiveTarget] = [:]
        var warnings: [String] = [
            "Shared PostgreSQL, Temporal, MinIO, and tracing containers are never removed.",
            "Remote subscriptions, Temporal history, and unobserved object-storage buckets remain untouched.",
        ]

        for orphan in snapshot.orphans {
            let instanceIsUnclaimed = orphan.instanceNumber.map {
                !claimedInstances.contains($0)
            } ?? true
            let isOwned = orphan.confidence.rank >= AttributionConfidence.high.rank
                && instanceIsUnclaimed
            let killableProcesses = orphan.processes.filter {
                !TownProcessClassifier.isSharedRuntimeHost($0.command)
            }
            if !killableProcesses.isEmpty {
                let target = DestructiveTarget(
                    id: "orphan-processes:\(orphan.id)",
                    kind: .processGroup,
                    label: "\(killableProcesses.count) processes — \(orphan.title)",
                    identifier: orphan.id,
                    confidence: isOwned ? orphan.confidence : .ambiguous,
                    selectedByDefault: isOwned,
                    actionable: isOwned,
                    note: isOwned
                        ? "PID identity, process group, and working directory are revalidated before signalling."
                        : "Process ownership is ambiguous and will be skipped."
                )
                targetsByID[target.id] = target
            }

            if let number = orphan.instanceNumber,
               (1...9).contains(number),
               isOwned,
               !claimedInstances.contains(number)
            {
                for target in perInstanceTargets(number: number, actionable: true) {
                    targetsByID[target.id] = target
                }
            }

            if let state = orphan.stateDirectory {
                let descriptor = TownStateDirectoryParser.parse(path: state.path)
                let stateIsOwned = isOwned
                    && state.associatedWorktreePath == nil
                    && descriptor?.instanceNumber == orphan.instanceNumber
                    && orphan.instanceNumber.map { !claimedInstances.contains($0) } == true
                let target = DestructiveTarget(
                    id: "convex-state:\(canonicalPath(state.path))",
                    kind: .convexStateDirectory,
                    label: orphan.instanceNumber.map { "Convex state for instance \($0)" }
                        ?? "Orphan Convex state",
                    identifier: canonicalPath(state.path),
                    estimatedBytes: state.sizeBytes,
                    confidence: stateIsOwned ? .high : .ambiguous,
                    selectedByDefault: stateIsOwned,
                    actionable: stateIsOwned,
                    note: stateIsOwned
                        ? "Removed only after fresh discovery proves its backend is stopped and no worktree claims it."
                        : "State ownership is ambiguous and will be skipped."
                )
                targetsByID[target.id] = target
            }

            if !isOwned {
                warnings.append("\(orphan.title) is ambiguous and will not be changed.")
            }
        }

        let priority: [DestructiveTargetKind: Int] = [
            .processGroup: 0,
            .dockerContainer: 1,
            .dockerVolume: 2,
            .postgresReplicationSlot: 3,
            .postgresDatabase: 4,
            .convexStateDirectory: 5,
        ]
        let targets = targetsByID.values.sorted {
            let lhs = priority[$0.kind, default: 99]
            let rhs = priority[$1.kind, default: 99]
            guard lhs == rhs else { return lhs < rhs }
            let labelOrder = $0.label.localizedStandardCompare($1.label)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            return $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending
        }
        let actionable = targets.filter { $0.actionable && $0.selectedByDefault }
        return OrphanCleanupManifest(
            targets: targets,
            warnings: Array(Set(warnings)).sorted(),
            canExecute: !actionable.isEmpty
        )
    }

    /// Executes a frozen bulk-orphan manifest only after a second full
    /// discovery proves every reviewed target is still safely attributable.
    public func executeOrphanCleanup(
        manifest: OrphanCleanupManifest,
        repositoryPath: String,
        confirmationText: String,
        progress: (@Sendable (OrphanCleanupProgress) async -> Void)? = nil
    ) async throws -> OrphanCleanupResult {
        guard manifest.canExecute else {
            throw TownDockError.unsafeOperation("No safely attributable orphan resources are available.")
        }
        guard confirmationText == manifest.confirmationText else {
            throw TownDockError.unsafeOperation("The confirmation text does not match exactly.")
        }

        let fresh = try await freshSnapshot(canonicalPath(repositoryPath))
        let currentManifest = orphanCleanupDryRun(snapshot: fresh)
        let reviewedSignature = cleanupSignature(manifest.targets)
        let currentSignature = cleanupSignature(currentManifest.targets)
        guard reviewedSignature.isSubset(of: currentSignature) else {
            throw TownDockError.staleSnapshot(
                "A reviewed orphan is no longer safely attributable. Nothing was removed; generate a fresh manifest."
            )
        }

        // Discovery can find additional orphans while the review sheet is
        // open. They were never reviewed, so ignore them instead of either
        // failing the reviewed cleanup or silently expanding its scope.
        let selectedTargets = manifest.targets.filter { $0.actionable && $0.selectedByDefault }
        let totalTargets = selectedTargets.count
        var completedTargets = 0
        var outcomes: [NukeTargetOutcome] = []
        for target in selectedTargets where target.kind == .processGroup {
            await progress?(OrphanCleanupProgress(
                completedTargets: completedTargets,
                totalTargets: totalTargets,
                currentTargetLabel: target.label
            ))
            guard let orphan = fresh.orphans.first(where: { $0.id == target.identifier }) else {
                throw TownDockError.staleSnapshot("A reviewed orphan process tree disappeared.")
            }
            do {
                let result = try await controlEngine.killOrphan(orphan)
                outcomes.append(
                    NukeTargetOutcome(
                        targetID: target.id,
                        disposition: .removed,
                        detail: result.message
                    )
                )
                completedTargets += 1
            } catch {
                throw cleanupFailure(error, target: target, position: completedTargets + 1, total: totalTargets)
            }
        }

        // Rediscover after process termination. Persistent resources are not
        // touched until every targeted backend is observed stopped.
        let afterProcesses = try await freshSnapshot(canonicalPath(repositoryPath))
        for target in selectedTargets where target.kind != .processGroup {
            await progress?(OrphanCleanupProgress(
                completedTargets: completedTargets,
                totalTargets: totalTargets,
                currentTargetLabel: target.label
            ))
            do {
                let outcome: NukeTargetOutcome
                switch target.kind {
                case .dockerContainer:
                    outcome = try removeDockerContainer(target)
                case .dockerVolume:
                    outcome = try removeDockerVolume(target)
                case .postgresReplicationSlot:
                    outcome = try removeReplicationSlot(target)
                case .postgresDatabase:
                    outcome = try removePostgresDatabase(target)
                case .convexStateDirectory:
                    outcome = try removeOrphanStateDirectory(target, snapshot: afterProcesses)
                default:
                    throw TownDockError.unsupported("An unexpected orphan cleanup target was selected.")
                }
                outcomes.append(outcome)
                completedTargets += 1
            } catch {
                throw cleanupFailure(error, target: target, position: completedTargets + 1, total: totalTargets)
            }
        }
        await progress?(OrphanCleanupProgress(
            completedTargets: completedTargets,
            totalTargets: totalTargets,
            currentTargetLabel: "Cleanup complete"
        ))
        return OrphanCleanupResult(outcomes: outcomes)
    }

    private func cleanupFailure(
        _ error: Error,
        target: DestructiveTarget,
        position: Int,
        total: Int
    ) -> TownDockError {
        TownDockError.commandFailed(
            "Cleanup stopped at \(target.label) (\(position) of \(total)): \(error.localizedDescription)"
        )
    }

    private struct GitIdentity {
        let path: String
        let repositoryPath: String
        let isPrimary: Bool
        let isPrunable: Bool
    }

    private struct GitRegistration {
        let path: String
        let head: String
        let branch: String?
        let isPrunable: Bool
    }

    private func revalidateFreshOwnership(
        manifest: NukeManifest,
        snapshot: TownSnapshot,
        repositoryPath: String
    ) throws -> WorktreeSnapshot {
        guard canonicalPath(snapshot.repositoryPath) == canonicalPath(repositoryPath) else {
            throw TownDockError.staleSnapshot(
                "Fresh discovery returned a different Town repository."
            )
        }
        let expectedPath = canonicalPath(manifest.worktree.path)
        guard let current = snapshot.worktrees.first(where: {
            canonicalPath($0.path) == expectedPath
        }) else {
            throw TownDockError.staleSnapshot(
                "The worktree disappeared during deletion review. Refresh before continuing."
            )
        }
        guard !current.isPrimary,
              current.head == manifest.worktree.head,
              current.branch == manifest.worktree.branch,
              current.isPrunable == manifest.worktree.isPrunable,
              current.gitStatus == manifest.worktree.gitStatus,
              current.setupComplete == manifest.worktree.setupComplete
        else {
            throw TownDockError.staleSnapshot(
                "The worktree identity or Git status changed after the manifest was reviewed."
            )
        }

        switch (manifest.worktree.instance, current.instance) {
        case (nil, nil):
            return current
        case let (expected?, observed?):
            guard expected.number == observed.number,
                  observed.confidence.rank >= AttributionConfidence.high.rank,
                  expected.actualBucketName == observed.actualBucketName,
                  expected.stateDirectory.map({ canonicalPath($0.path) })
                    == observed.stateDirectory.map({ canonicalPath($0.path) })
            else {
                throw TownDockError.staleSnapshot(
                    "The instance, state directory, or observed bucket changed after review."
                )
            }
            if let state = observed.stateDirectory,
               !stateDirectoryIsOwned(state, by: current)
            {
                throw TownDockError.unsafeOperation(
                    "Fresh discovery cannot prove ownership of the Convex state directory."
                )
            }

            let competingWorktree = snapshot.worktrees.contains { other in
                canonicalPath(other.path) != expectedPath
                    && other.instance?.number == observed.number
                    && (other.instance?.confidence.rank ?? 0)
                        >= AttributionConfidence.high.rank
            }
            let competingOrphan = snapshot.orphans.contains { orphan in
                orphan.instanceNumber == observed.number
                    && orphan.confidence.rank >= AttributionConfidence.high.rank
            }
            guard !competingWorktree, !competingOrphan else {
                throw TownDockError.unsafeOperation(
                    "Another worktree or orphan now claims instance \(observed.number). Nothing was deleted."
                )
            }

            let requiredIdentifiers = Set(
                manifest.targets.filter(\.selectedByDefault).map(\.identifier)
            )
            let n = observed.number
            guard requiredIdentifiers.contains("harness-electric-\(n)"),
                  requiredIdentifiers.contains("harness-electric-data-\(n)"),
                  requiredIdentifiers.contains("electric_slot_instance\(n)"),
                  requiredIdentifiers.contains("harness_\(n)"),
                  observed.actualBucketName.map(requiredIdentifiers.contains) == true
            else {
                throw TownDockError.staleSnapshot(
                    "The reviewed resource manifest no longer matches the fresh instance."
                )
            }
            if let state = observed.stateDirectory {
                guard requiredIdentifiers.contains(state.path) else {
                    throw TownDockError.staleSnapshot(
                        "The reviewed manifest does not contain the fresh state directory."
                    )
                }
            }
            return current
        default:
            throw TownDockError.staleSnapshot(
                "The worktree's instance association changed after review."
            )
        }
    }

    private func validateSelectedTargets(
        _ targets: [DestructiveTarget],
        for worktree: WorktreeSnapshot,
        identity: GitIdentity
    ) throws {
        let singletonKinds: [DestructiveTargetKind] = [
            .dockerContainer, .dockerVolume, .postgresDatabase,
            .postgresReplicationSlot, .minioBucket, .convexStateDirectory,
            .tunnelMarker, .worktreeDirectory, .gitRegistration, .localBranch,
        ]
        let grouped = Dictionary(grouping: targets, by: { $0.kind.rawValue })
        guard singletonKinds.allSatisfy({ grouped[$0.rawValue, default: []].count <= 1 }) else {
            throw TownDockError.unsafeOperation(
                "The manifest contains duplicate destructive resource targets."
            )
        }

        for target in targets {
            let expected: String?
            switch target.kind {
            case .processGroup, .listener:
                continue
            case .dockerContainer:
                expected = worktree.instance.map { "harness-electric-\($0.number)" }
            case .dockerVolume:
                expected = worktree.instance.map { "harness-electric-data-\($0.number)" }
            case .postgresDatabase:
                expected = worktree.instance.map { "harness_\($0.number)" }
            case .postgresReplicationSlot:
                expected = worktree.instance.map { "electric_slot_instance\($0.number)" }
            case .minioBucket:
                expected = worktree.instance?.actualBucketName
            case .convexStateDirectory:
                expected = worktree.instance?.stateDirectory?.path
            case .tunnelMarker:
                expected = worktree.instance.map { "/tmp/town-tunnel-\($0.number).json" }
            case .worktreeDirectory, .gitRegistration:
                expected = identity.path
            case .localBranch:
                expected = worktree.branch
            case .remoteSubscription, .temporalHistory:
                expected = nil
            }
            guard let expected,
                  target.actionable,
                  target.confidence.rank >= AttributionConfidence.high.rank,
                  (target.kind == .convexStateDirectory
                    || target.kind == .worktreeDirectory
                    || target.kind == .gitRegistration
                    ? canonicalPath(target.identifier) == canonicalPath(expected)
                    : target.identifier == expected)
            else {
                throw TownDockError.unsafeOperation(
                    "A selected target does not exactly match fresh ownership. Nothing was deleted."
                )
            }
        }
    }

    private func validateGitIdentity(
        worktree: WorktreeSnapshot,
        repositoryPath: String
    ) throws -> GitIdentity {
        let path = canonicalPath(worktree.path)
        let repository = canonicalPath(repositoryPath)
        guard path != "/", repository != "/", path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw TownDockError.unsafeOperation("Refusing a broad or protected worktree path.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw TownDockError.repositoryNotFound("The worktree directory no longer exists.")
        }

        let repositoryTop = try gitOutput(["-C", repository, "rev-parse", "--show-toplevel"])
        guard canonicalPath(repositoryTop) == repository else {
            throw TownDockError.repositoryNotFound("The configured Town repository is invalid.")
        }
        let repositoryCommon = try gitOutput([
            "-C", repository, "rev-parse", "--path-format=absolute", "--git-common-dir",
        ])

        let list = try gitOutput(["-C", repository, "worktree", "list", "--porcelain"])
        let records = parseWorktreeRecords(list)
        guard let record = records.first(where: { canonicalPath($0.path) == path }) else {
            throw TownDockError.staleSnapshot("Git no longer registers this worktree.")
        }
        guard let first = records.first else {
            throw TownDockError.repositoryNotFound("Git reported no primary worktree.")
        }
        let primaryPath = canonicalPath(first.path)

        if let branch = worktree.branch {
            guard record.branch == branch || record.branch == "refs/heads/\(branch)"
            else {
                throw TownDockError.staleSnapshot(
                    "The worktree branch changed after discovery. Refresh the deletion manifest."
                )
            }
        }

        let topLevelResult = try runCommand(
            .git,
            ["-C", path, "rev-parse", "--show-toplevel"],
            nil,
            [0, 128]
        )
        if topLevelResult.terminationStatus == 0 {
            guard canonicalPath(topLevelResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == path else {
                throw TownDockError.staleSnapshot("The target path is no longer this Git worktree.")
            }
            let common = try gitOutput([
                "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir",
            ])
            guard canonicalPath(common) == canonicalPath(repositoryCommon) else {
                throw TownDockError.unsafeOperation(
                    "The selected worktree belongs to a different Git repository."
                )
            }
            let head = try gitOutput(["-C", path, "rev-parse", "HEAD"])
            guard head == worktree.head else {
                throw TownDockError.staleSnapshot(
                    "The worktree HEAD changed after discovery. Refresh the deletion manifest."
                )
            }
            return GitIdentity(
                path: path,
                repositoryPath: repository,
                isPrimary: path == primaryPath,
                isPrunable: false
            )
        }

        // Git can retain an exact, prunable registration after a checkout's
        // `.git` link is accidentally removed. The repository registration is
        // still authoritative enough to review deletion, provided its path and
        // HEAD exactly match discovery. Execution repairs and revalidates that
        // link before any resource is mutated.
        let dotGit = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(".git", isDirectory: false)
        guard worktree.isPrunable,
              record.isPrunable,
              record.head == worktree.head,
              !FileManager.default.fileExists(atPath: dotGit.path)
        else {
            throw TownDockError.staleSnapshot(
                "The target is no longer a valid or safely repairable Git worktree."
            )
        }
        let values = try URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw TownDockError.unsafeOperation("Refusing a non-directory or symbolic-link worktree path.")
        }

        return GitIdentity(
            path: path,
            repositoryPath: repository,
            isPrimary: path == primaryPath,
            isPrunable: true
        )
    }

    private func gitOutput(_ arguments: [String]) throws -> String {
        try runCommand(.git, arguments, nil, [0]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repairPrunableWorktree(
        _ identity: GitIdentity,
        expectedHead: String
    ) throws {
        let dotGit = URL(fileURLWithPath: identity.path, isDirectory: true)
            .appendingPathComponent(".git", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: dotGit.path) else {
            throw TownDockError.staleSnapshot(
                "The broken worktree's .git link changed after review. Nothing was deleted."
            )
        }

        // Git 2.5x may return status 1 while still repairing a missing link, so
        // the verified postconditions below—not the exit code—decide success.
        _ = try runCommand(
            .git,
            ["-C", identity.repositoryPath, "worktree", "repair", identity.path],
            nil,
            [0, 1]
        )

        let values = try dotGit.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TownDockError.commandFailed(
                "Git could not restore the broken worktree link. Nothing was deleted."
            )
        }
        let topLevel = try gitOutput(["-C", identity.path, "rev-parse", "--show-toplevel"])
        let common = try gitOutput([
            "-C", identity.path, "rev-parse", "--path-format=absolute", "--git-common-dir",
        ])
        let repositoryCommon = try gitOutput([
            "-C", identity.repositoryPath, "rev-parse", "--path-format=absolute", "--git-common-dir",
        ])
        let head = try gitOutput(["-C", identity.path, "rev-parse", "HEAD"])
        guard canonicalPath(topLevel) == identity.path,
              canonicalPath(common) == canonicalPath(repositoryCommon),
              head == expectedHead
        else {
            throw TownDockError.unsafeOperation(
                "The repaired worktree does not match the reviewed repository and HEAD. Nothing was deleted."
            )
        }
    }

    private func parseWorktreeRecords(_ output: String) -> [GitRegistration] {
        output.components(separatedBy: "\n\n").compactMap { block in
            var path: String?
            var head = ""
            var branch: String?
            var isPrunable = false
            for line in block.split(whereSeparator: \.isNewline).map(String.init) {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst("branch ".count))
                } else if line == "prunable" || line.hasPrefix("prunable ") {
                    isPrunable = true
                }
            }
            return path.map {
                GitRegistration(path: $0, head: head, branch: branch, isPrunable: isPrunable)
            }
        }
    }

    private func perInstanceTargets(number: Int, actionable: Bool) -> [DestructiveTarget] {
        let confidence: AttributionConfidence = actionable ? .high : .ambiguous
        return [
            DestructiveTarget(
                id: "docker-container:harness-electric-\(number)",
                kind: .dockerContainer,
                label: "Electric container",
                identifier: "harness-electric-\(number)",
                confidence: confidence,
                selectedByDefault: actionable,
                actionable: actionable,
                note: "The shared Postgres, Temporal, MinIO, and tracing containers are never selected."
            ),
            DestructiveTarget(
                id: "docker-volume:harness-electric-data-\(number)",
                kind: .dockerVolume,
                label: "Electric data volume",
                identifier: "harness-electric-data-\(number)",
                confidence: confidence,
                selectedByDefault: actionable,
                actionable: actionable
            ),
            DestructiveTarget(
                id: "postgres-slot:electric_slot_instance\(number)",
                kind: .postgresReplicationSlot,
                label: "Electric replication slot",
                identifier: "electric_slot_instance\(number)",
                confidence: confidence,
                selectedByDefault: actionable,
                actionable: actionable
            ),
            DestructiveTarget(
                id: "postgres-database:harness_\(number)",
                kind: .postgresDatabase,
                label: "Harness PostgreSQL database",
                identifier: "harness_\(number)",
                confidence: confidence,
                selectedByDefault: actionable,
                actionable: actionable
            ),
        ]
    }

    private func removeDockerContainer(_ target: DestructiveTarget) throws -> NukeTargetOutcome {
        try requireIdentifier(target.identifier, prefix: "harness-electric-", suffixRange: 1...9)
        let number = try numericSuffix(target.identifier, prefix: "harness-electric-")
        let exists = try runCommand(
            .docker, ["container", "inspect", target.identifier], nil, [0, 1]
        ).terminationStatus == 0
        guard exists else { return absent(target) }

        let environment = try runCommand(
            .docker,
            ["container", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", target.identifier],
            nil,
            [0]
        ).stdout.split(whereSeparator: \.isNewline).map(String.init)
        let expectedDatabase = "harness_\(number)"
        let databaseMatches = environment.contains { line in
            guard line.hasPrefix("DATABASE_URL=") else { return false }
            let value = String(line.dropFirst("DATABASE_URL=".count))
            return value.contains("/\(expectedDatabase)?") || value.hasSuffix("/\(expectedDatabase)")
        }
        guard databaseMatches,
              environment.contains("ELECTRIC_REPLICATION_STREAM_ID=instance\(number)")
        else {
            throw TownDockError.unsafeOperation(
                "The Electric container name matches, but its database or stream identity does not."
            )
        }

        let mounts = try runCommand(
            .docker,
            ["container", "inspect", "-f", "{{range .Mounts}}{{println .Name \"|\" .Destination}}{{end}}", target.identifier],
            nil,
            [0]
        ).stdout
        guard dockerMountOutput(
            mounts,
            containsName: "harness-electric-data-\(number)",
            destination: "/var/electric"
        ) else {
            throw TownDockError.unsafeOperation(
                "The Electric container does not mount the expected per-instance volume."
            )
        }

        _ = try runCommand(.docker, ["rm", "-f", target.identifier], nil, [0])
        let remains = try runCommand(
            .docker, ["container", "inspect", target.identifier], nil, [0, 1]
        ).terminationStatus == 0
        guard !remains else {
            throw TownDockError.commandFailed("The Electric container still exists after removal.")
        }
        return removed(target, detail: "Removed the per-instance Electric container.")
    }

    private func cleanupSignature(_ targets: [DestructiveTarget]) -> Set<String> {
        Set(targets.filter { $0.actionable && $0.selectedByDefault }.map {
            "\($0.kind.rawValue)|\($0.id)|\($0.identifier)"
        })
    }

    private func removeOrphanStateDirectory(
        _ target: DestructiveTarget,
        snapshot: TownSnapshot
    ) throws -> NukeTargetOutcome {
        let expectedPath = canonicalPath(target.identifier)
        guard let descriptor = TownStateDirectoryParser.parse(path: expectedPath) else {
            throw TownDockError.unsafeOperation("The orphan state path is not a recognized Town state directory.")
        }
        let observedStates = snapshot.dormantStates + snapshot.orphans.compactMap(\.stateDirectory)
        guard let state = observedStates.first(where: {
            canonicalPath($0.path) == expectedPath
        }),
              !state.isRunning,
              state.associatedWorktreePath == nil,
              state.instanceNumber == descriptor.instanceNumber,
              !snapshot.worktrees.contains(where: {
                  $0.instance?.number == descriptor.instanceNumber
                    && ($0.instance?.confidence.rank ?? 0) >= AttributionConfidence.high.rank
              })
        else {
            throw TownDockError.unsafeOperation(
                "Fresh discovery cannot prove the orphan state is stopped and unclaimed."
            )
        }

        let convexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".convex", isDirectory: true)
            .standardizedFileURL.path
        guard expectedPath.hasPrefix(convexRoot + "/local-backend-"), expectedPath != convexRoot else {
            throw TownDockError.unsafeOperation("Refusing a broad or unexpected state-directory path.")
        }
        let url = URL(fileURLWithPath: expectedPath, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return absent(target) }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw TownDockError.unsafeOperation("Refusing to recursively remove a symlink or non-directory.")
        }
        try makeTreeOwnerWritable(at: url)
        try FileManager.default.removeItem(at: url)
        return removed(target, detail: "Removed orphan Convex SQLite, uploads, keys, and temporary state.")
    }

    private func removeDockerVolume(_ target: DestructiveTarget) throws -> NukeTargetOutcome {
        try requireIdentifier(target.identifier, prefix: "harness-electric-data-", suffixRange: 1...9)
        let exists = try runCommand(
            .docker, ["volume", "inspect", target.identifier], nil, [0, 1]
        ).terminationStatus == 0
        guard exists else { return absent(target) }
        _ = try runCommand(.docker, ["volume", "rm", "-f", target.identifier], nil, [0])
        let remains = try runCommand(
            .docker, ["volume", "inspect", target.identifier], nil, [0, 1]
        ).terminationStatus == 0
        guard !remains else {
            throw TownDockError.commandFailed("The Electric volume still exists after removal.")
        }
        return removed(target, detail: "Removed the per-instance Electric data volume.")
    }

    private func removeReplicationSlot(_ target: DestructiveTarget) throws -> NukeTargetOutcome {
        try requireIdentifier(target.identifier, prefix: "electric_slot_instance", suffixRange: 1...9)
        let number = try numericSuffix(target.identifier, prefix: "electric_slot_instance")
        let expectedDatabase = "harness_\(number)"
        let query = replicationSlotLookupSQL(named: target.identifier)
        let record = try dockerPostgres(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.isEmpty else { return absent(target) }
        guard record == "\(target.identifier)|\(expectedDatabase)|false" else {
            throw TownDockError.unsafeOperation(
                "The replication slot is active or bound to a different database."
            )
        }
        let drop = "SELECT pg_drop_replication_slot('\(target.identifier)')"
        _ = try dockerPostgres(drop)
        let remains = try dockerPostgres(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard remains.isEmpty else {
            throw TownDockError.commandFailed("The replication slot still exists after removal.")
        }
        return removed(target, detail: "Removed the per-instance inactive replication slot.")
    }

    private func removePostgresDatabase(_ target: DestructiveTarget) throws -> NukeTargetOutcome {
        try requireIdentifier(target.identifier, prefix: "harness_", suffixRange: 1...9)
        let query = "SELECT 1 FROM pg_database WHERE datname='\(target.identifier)'"
        let exists = try dockerPostgres(query).split(whereSeparator: \.isNewline).contains("1")
        guard exists else { return absent(target) }
        _ = try dockerPostgres("DROP DATABASE IF EXISTS \(target.identifier) WITH (FORCE)")
        let remains = try dockerPostgres(query).split(whereSeparator: \.isNewline).contains("1")
        guard !remains else {
            throw TownDockError.commandFailed("The harness database still exists after removal.")
        }
        return removed(target, detail: "Removed the per-instance harness database.")
    }

    private func dockerPostgres(_ sql: String) throws -> String {
        try runCommand(
            .docker,
            ["exec", "harness-postgres", "psql", "-U", "postgres", "-d", "postgres", "-Atc", sql],
            nil,
            [0]
        ).stdout
    }

    private func removeMinIOBucket(_ target: DestructiveTarget) throws -> NukeTargetOutcome {
        guard validBucketName(target.identifier) else {
            throw TownDockError.unsafeOperation("Refusing an invalid MinIO bucket name.")
        }
        let running = try runCommand(
            .docker,
            ["container", "inspect", "-f", "{{.State.Running}}", "harness-minio"],
            nil,
            [0]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard running == "true" else {
            throw TownDockError.commandFailed(
                "MinIO must be running so the observed bucket can be deleted safely."
            )
        }
        let exists = try runCommand(
            .docker,
            ["exec", "harness-minio", "mc", "stat", "local/\(target.identifier)"],
            nil,
            [0, 1]
        ).terminationStatus == 0
        guard exists else { return absent(target) }
        _ = try runCommand(
            .docker,
            ["exec", "harness-minio", "mc", "rb", "--force", "local/\(target.identifier)"],
            nil,
            [0]
        )
        let remains = try runCommand(
            .docker,
            ["exec", "harness-minio", "mc", "stat", "local/\(target.identifier)"],
            nil,
            [0, 1]
        ).terminationStatus == 0
        guard !remains else {
            throw TownDockError.commandFailed("The MinIO bucket still exists after removal.")
        }
        return removed(target, detail: "Removed the observed per-instance MinIO bucket.")
    }

    private func removeStateDirectory(
        _ target: DestructiveTarget,
        worktree: WorktreeSnapshot
    ) throws -> NukeTargetOutcome {
        guard let state = worktree.instance?.stateDirectory,
              canonicalPath(state.path) == canonicalPath(target.identifier),
              stateDirectoryIsOwned(state, by: worktree)
        else {
            throw TownDockError.unsafeOperation(
                "The Convex state directory no longer has provable ownership."
            )
        }
        let url = URL(fileURLWithPath: target.identifier, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return absent(target) }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw TownDockError.unsafeOperation("Refusing to recursively remove a symlink or non-directory.")
        }
        try makeTreeOwnerWritable(at: url)
        try FileManager.default.removeItem(at: url)
        return removed(target, detail: "Removed Convex SQLite, uploads, keys, and temporary state.")
    }

    private func removeTunnelMarker(
        _ target: DestructiveTarget,
        worktree: WorktreeSnapshot
    ) throws -> NukeTargetOutcome {
        guard let number = worktree.instance?.number,
              target.identifier == "/tmp/town-tunnel-\(number).json"
        else {
            throw TownDockError.unsafeOperation("The tunnel marker no longer matches the instance.")
        }
        let url = URL(fileURLWithPath: target.identifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return absent(target) }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TownDockError.unsafeOperation("Refusing an unexpected tunnel marker file type.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 64 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["frontendPort"] as? Int == 3_000 + number * 10
        else {
            throw TownDockError.unsafeOperation("The tunnel marker contents do not match the instance.")
        }
        try FileManager.default.removeItem(at: url)
        return removed(target, detail: "Removed the verified tunnel marker.")
    }

    private func stateDirectoryIsOwned(
        _ state: StateDirectorySnapshot,
        by worktree: WorktreeSnapshot
    ) -> Bool {
        let path = canonicalPath(state.path)
        let convexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".convex", isDirectory: true).standardizedFileURL.path
        return state.confidence.rank >= AttributionConfidence.high.rank
            && state.associatedWorktreePath.map(canonicalPath) == canonicalPath(worktree.path)
            && path.hasPrefix(convexRoot + "/local-backend-")
            && path != convexRoot
    }

    private func safeOwnershipRoots(worktree: WorktreeSnapshot) -> [String] {
        var roots = [worktree.path]
        if let state = worktree.instance?.stateDirectory,
           stateDirectoryIsOwned(state, by: worktree)
        {
            roots.append(state.path)
        }
        return roots
    }

    private func validBucketName(_ value: String) -> Bool {
        guard (3...63).contains(value.count),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true
        else {
            return false
        }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." || $0 == "-" }
            && !value.contains("..")
    }

    private func requireIdentifier(
        _ value: String,
        prefix: String,
        suffixRange: ClosedRange<Int>
    ) throws {
        guard value.hasPrefix(prefix),
              let suffix = Int(value.dropFirst(prefix.count)),
              suffixRange.contains(suffix)
        else {
            throw TownDockError.unsafeOperation("Refusing an unexpected per-instance identifier.")
        }
    }

    private func numericSuffix(_ value: String, prefix: String) throws -> Int {
        guard value.hasPrefix(prefix),
              let result = Int(value.dropFirst(prefix.count)),
              (1...9).contains(result)
        else {
            throw TownDockError.unsafeOperation("Refusing an unexpected per-instance identifier.")
        }
        return result
    }

    private func removed(_ target: DestructiveTarget, detail: String) -> NukeTargetOutcome {
        NukeTargetOutcome(targetID: target.id, disposition: .removed, detail: detail)
    }

    private func absent(_ target: DestructiveTarget) -> NukeTargetOutcome {
        NukeTargetOutcome(
            targetID: target.id,
            disposition: .alreadyAbsent,
            detail: "The resource was already absent."
        )
    }

    private func path(_ candidate: String, isInside root: String) -> Bool {
        let child = canonicalPath(candidate)
        let parent = canonicalPath(root)
        guard parent != "/" else { return false }
        return child == parent || child.hasPrefix(parent + "/")
    }

    private func canonicalPath(_ rawPath: String) -> String {
        URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Convex creates immutable-by-convention cache artifacts and read-only
/// directories. Once a state root has passed the destructive ownership gates,
/// add only the current owner's write/search bits so Foundation can remove the
/// reviewed tree. Symlinks are never followed or modified.
func makeTreeOwnerWritable(
    at root: URL,
    fileManager: FileManager = .default
) throws {
    func updatePermissions(at url: URL, isDirectory: Bool) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else { return }
        let current = number.intValue
        let required = isDirectory ? 0o300 : 0o200
        let updated = current | required
        guard updated != current else { return }
        try fileManager.setAttributes([.posixPermissions: updated], ofItemAtPath: url.path)
    }

    let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
        throw TownDockError.unsafeOperation("Refusing to change permissions outside a real directory tree.")
    }
    try updatePermissions(at: root, isDirectory: true)

    var traversalError: Error?
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [],
        errorHandler: { _, error in
            traversalError = error
            return false
        }
    ) else {
        throw TownDockError.commandFailed("Could not inspect the verified state directory before removal.")
    }
    for case let child as URL in enumerator {
        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            enumerator.skipDescendants()
            continue
        }
        try updatePermissions(at: child, isDirectory: values.isDirectory == true)
    }
    if let traversalError { throw traversalError }
}
