@preconcurrency import Foundation

public enum ConvexMaintenanceAction: String, Codable, CaseIterable, Sendable {
    case clearData
    case resetInstance

    public var displayName: String {
        switch self {
        case .clearData: "Clear data"
        case .resetInstance: "Full reset"
        }
    }
}

public struct ConvexMaintenancePlan: Codable, Hashable, Sendable {
    public let action: ConvexMaintenanceAction
    public let worktree: WorktreeSnapshot
    public let instanceNumber: Int?
    public let stateDirectory: StateDirectorySnapshot?
    public let impacts: [String]
    public let warnings: [String]
    public let canExecute: Bool

    public init(
        action: ConvexMaintenanceAction,
        worktree: WorktreeSnapshot,
        instanceNumber: Int?,
        stateDirectory: StateDirectorySnapshot?,
        impacts: [String],
        warnings: [String],
        canExecute: Bool
    ) {
        self.action = action
        self.worktree = worktree
        self.instanceNumber = instanceNumber
        self.stateDirectory = stateDirectory
        self.impacts = impacts
        self.warnings = warnings
        self.canExecute = canExecute
    }
}

public struct ConvexMaintenanceResult: Codable, Hashable, Sendable {
    public let action: ConvexMaintenanceAction
    public let launcherPID: Int32?
    public let message: String

    public init(action: ConvexMaintenanceAction, launcherPID: Int32?, message: String) {
        self.action = action
        self.launcherPID = launcherPID
        self.message = message
    }
}

typealias ConvexMaintenanceCommand = @Sendable (
    _ executable: URL,
    _ arguments: [String],
    _ workingDirectory: URL,
    _ environment: [String: String]
) throws -> Int32

typealias ConvexSnapshotProvider = @Sendable (_ repositoryPath: String) async throws -> TownSnapshot

/// Executes only Town's sanctioned local Convex maintenance operations. Every
/// destructive reset re-discovers ownership before stopping or deleting, and
/// the table clear is pinned to the observed local instance so it can never
/// fall through to a cloud deployment.
public actor ConvexMaintenanceEngine {
    private let controls: TownControlEngine
    private let runCommand: ConvexMaintenanceCommand
    private let freshSnapshot: ConvexSnapshotProvider
    private let fileManager: FileManager

    public init() {
        controls = TownControlEngine()
        runCommand = Self.defaultCommand
        freshSnapshot = { repositoryPath in
            try await TownDiscoveryEngine(repositoryPath: repositoryPath).snapshot()
        }
        fileManager = .default
    }

    init(
        controls: TownControlEngine,
        runCommand: @escaping ConvexMaintenanceCommand,
        freshSnapshot: @escaping ConvexSnapshotProvider,
        fileManager: FileManager = .default
    ) {
        self.controls = controls
        self.runCommand = runCommand
        self.freshSnapshot = freshSnapshot
        self.fileManager = fileManager
    }

    public func dryRun(
        worktree: WorktreeSnapshot,
        action: ConvexMaintenanceAction
    ) -> ConvexMaintenancePlan {
        guard let instance = worktree.instance else {
            return blockedPlan(
                worktree: worktree,
                action: action,
                warning: "Town Sheriff could not attribute a Convex instance to this worktree."
            )
        }
        guard (1...9).contains(instance.number),
              instance.confidence.rank >= AttributionConfidence.high.rank
        else {
            return blockedPlan(
                worktree: worktree,
                action: action,
                warning: "The instance number or worktree ownership is ambiguous."
            )
        }
        guard let state = instance.stateDirectory,
              stateDirectoryIsOwned(state, by: worktree, instanceNumber: instance.number)
        else {
            return blockedPlan(
                worktree: worktree,
                action: action,
                warning: "The Convex state directory is not safely attributable to this worktree."
            )
        }

        switch action {
        case .clearData:
            let backendRunning = instance.services.contains {
                $0.kind == .convexBackend && ($0.state == .running || $0.state == .degraded)
            }
            var warnings: [String] = []
            if !backendRunning {
                warnings.append("Start this worktree’s Convex backend before clearing its data.")
            }
            return ConvexMaintenancePlan(
                action: action,
                worktree: worktree,
                instanceNumber: instance.number,
                stateDirectory: state,
                impacts: [
                    "Clear every application table in this local Convex deployment.",
                    "Clear every Agent component table.",
                    "Keep local keys, environment variables, uploads, and the running stack.",
                ],
                warnings: warnings,
                canExecute: backendRunning
            )

        case .resetInstance:
            return ConvexMaintenancePlan(
                action: action,
                worktree: worktree,
                instanceNumber: instance.number,
                stateDirectory: state,
                impacts: [
                    "Stop this worktree’s complete local stack.",
                    "Delete its verified Convex database, uploads, keys, and temporary state.",
                    "Generate a fresh Convex instance and relaunch the stack on the same ports.",
                    "Keep the Git worktree and non-Convex shared infrastructure.",
                ],
                warnings: [],
                canExecute: true
            )
        }
    }

    public func execute(
        plan: ConvexMaintenancePlan,
        repositoryPath: String
    ) async throws -> ConvexMaintenanceResult {
        guard plan.canExecute,
              let expectedNumber = plan.instanceNumber,
              let expectedState = plan.stateDirectory
        else {
            throw TownDockError.unsafeOperation(
                "This Convex maintenance plan has a blocking ownership or availability issue."
            )
        }

        let snapshot = try await freshSnapshot(repositoryPath)
        guard let current = snapshot.worktrees.first(where: {
            canonicalPath($0.path) == canonicalPath(plan.worktree.path)
        }),
              current.head == plan.worktree.head,
              let instance = current.instance,
              instance.number == expectedNumber,
              instance.confidence.rank >= AttributionConfidence.high.rank,
              let state = instance.stateDirectory,
              canonicalPath(state.path) == canonicalPath(expectedState.path),
              stateDirectoryIsOwned(state, by: current, instanceNumber: expectedNumber)
        else {
            throw TownDockError.staleSnapshot(
                "Fresh discovery no longer matches the reviewed Convex instance. Nothing was changed."
            )
        }

        switch plan.action {
        case .clearData:
            guard instance.services.contains(where: {
                $0.kind == .convexBackend && ($0.state == .running || $0.state == .degraded)
            })
            else {
                throw TownDockError.staleSnapshot(
                    "The pinned local Convex backend is no longer running. Nothing was cleared."
                )
            }
            try clearData(in: current, instanceNumber: expectedNumber)
            return ConvexMaintenanceResult(
                action: .clearData,
                launcherPID: nil,
                message: "Cleared the local Convex application and Agent tables."
            )

        case .resetInstance:
            if instance.isRunning {
                _ = try await controls.stop(current)
            }
            try removeServicesMarkerIfOwned(
                worktreePath: current.path,
                instanceNumber: expectedNumber,
                statePath: state.path
            )
            try removeStateDirectory(state, ownedBy: current, instanceNumber: expectedNumber)
            let launched = try await controls.startAfterMaintenance(current)
            return ConvexMaintenanceResult(
                action: .resetInstance,
                launcherPID: launched.affectedProcessIDs.first,
                message: "Reset Convex and started a fresh local instance on the same ports."
            )
        }
    }

    private func clearData(in worktree: WorktreeSnapshot, instanceNumber: Int) throws {
        let directory = URL(fileURLWithPath: worktree.path, isDirectory: true).standardizedFileURL
        let mise = directory.appendingPathComponent("mise", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: mise.path) else {
            throw TownDockError.repositoryNotFound(
                "The worktree does not contain an executable ./mise launcher."
            )
        }
        var environment = Self.safeEnvironment()
        environment["TOWN_CX_N"] = String(instanceNumber)
        let status = try runCommand(
            mise,
            ["exec", "--locked", "--", "bun", "run", "db:clear"],
            directory,
            environment
        )
        guard status == 0 else {
            throw TownDockError.commandFailed(
                "Town’s local Convex clear command failed. The target remained pinned to this worktree’s local instance."
            )
        }
    }

    private func removeStateDirectory(
        _ state: StateDirectorySnapshot,
        ownedBy worktree: WorktreeSnapshot,
        instanceNumber: Int
    ) throws {
        guard stateDirectoryIsOwned(state, by: worktree, instanceNumber: instanceNumber) else {
            throw TownDockError.unsafeOperation(
                "The Convex state directory no longer has provable worktree ownership."
            )
        }
        let url = URL(fileURLWithPath: state.path, isDirectory: true).standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw TownDockError.unsafeOperation(
                "Refusing to reset a symlink or non-directory Convex state path."
            )
        }
        try fileManager.removeItem(at: url)
    }

    private func removeServicesMarkerIfOwned(
        worktreePath: String,
        instanceNumber: Int,
        statePath: String
    ) throws {
        let marker = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".local-convex-services.md", isDirectory: false)
        guard fileManager.fileExists(atPath: marker.path) else { return }
        guard servicesMarkerMatches(
            worktreePath: worktreePath,
            instanceNumber: instanceNumber,
            statePath: statePath
        ) else {
            throw TownDockError.staleSnapshot(
                "The local services marker changed during reset. The old state was removed, but the stack was not relaunched."
            )
        }
        let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TownDockError.unsafeOperation("Refusing to remove an unexpected services marker.")
        }
        try fileManager.removeItem(at: marker)
    }

    private func servicesMarkerMatches(
        worktreePath: String,
        instanceNumber: Int,
        statePath: String
    ) -> Bool {
        let marker = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".local-convex-services.md", isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: marker) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128 * 1_024),
              let text = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"(?m)^\*Instance:\s*(\d+)\s*\|\s*State:\s*([^*\r\n]+)\*?\s*$"#
              ),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let numberRange = Range(match.range(at: 1), in: text),
              let observedNumber = Int(text[numberRange]),
              let stateRange = Range(match.range(at: 2), in: text)
        else { return false }
        let observedState = String(text[stateRange]).trimmingCharacters(in: .whitespaces)
        return observedNumber == instanceNumber
            && canonicalPath(observedState) == canonicalPath(statePath)
    }

    private func stateDirectoryIsOwned(
        _ state: StateDirectorySnapshot,
        by worktree: WorktreeSnapshot,
        instanceNumber: Int
    ) -> Bool {
        let path = canonicalPath(state.path)
        let convexRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".convex", isDirectory: true)
            .standardizedFileURL.path
        return state.confidence.rank >= AttributionConfidence.high.rank
            && state.instanceNumber == instanceNumber
            && state.associatedWorktreePath.map(canonicalPath) == canonicalPath(worktree.path)
            && TownStateDirectoryParser.parse(path: path)?.instanceNumber == instanceNumber
            && path.hasPrefix(convexRoot + "/local-backend-")
            && path != convexRoot
    }

    private func blockedPlan(
        worktree: WorktreeSnapshot,
        action: ConvexMaintenanceAction,
        warning: String
    ) -> ConvexMaintenancePlan {
        ConvexMaintenancePlan(
            action: action,
            worktree: worktree,
            instanceNumber: worktree.instance?.number,
            stateDirectory: worktree.instance?.stateDirectory,
            impacts: [],
            warnings: [warning],
            canExecute: false
        )
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func safeEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let home = source["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        var environment = source.filter {
            ["HOME", "USER", "TMPDIR", "LANG", "LC_CTYPE", "SHELL", "SSH_AUTH_SOCK"]
                .contains($0.key)
        }
        environment["PATH"] = [
            "\(home)/Developer/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        environment["LC_ALL"] = "C"
        return environment
    }

    private static func defaultCommand(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            throw TownDockError.commandFailed("Could not run Town’s local Convex maintenance command.")
        }
    }
}
