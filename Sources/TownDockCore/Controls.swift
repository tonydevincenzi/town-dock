@preconcurrency import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ControlAction: String, Codable, Sendable {
    case start
    case gracefulStop
    case restart
    case forceKill
    case orphanKill
}

public struct ControlResult: Codable, Hashable, Sendable {
    public let action: ControlAction
    public let affectedProcessIDs: [Int32]
    public let message: String

    public init(
        action: ControlAction,
        affectedProcessIDs: [Int32] = [],
        message: String
    ) {
        self.action = action
        self.affectedProcessIDs = affectedProcessIDs
        self.message = message
    }
}

typealias ControlCommand = @Sendable (
    _ tool: CommandTool,
    _ arguments: [String],
    _ workingDirectory: URL?,
    _ allowedExitCodes: Set<Int32>
) throws -> CommandResult

typealias ControlLauncher = @Sendable (
    _ executable: URL,
    _ arguments: [String],
    _ workingDirectory: URL
) throws -> Int32

typealias ControlSignalSender = @Sendable (
    _ processID: Int32,
    _ signal: Int32
) throws -> Void

typealias ControlSleeper = @Sendable (_ nanoseconds: UInt64) async throws -> Void

/// Executes lifecycle operations for a Town worktree without invoking a shell.
///
/// Every destructive process action revalidates PID start time, process group,
/// and current working directory immediately before signalling. A stale or
/// ambiguous snapshot is rejected instead of being used as a best guess.
public actor TownControlEngine {
    private let runCommand: ControlCommand
    private let launchProcess: ControlLauncher
    private let sendSignal: ControlSignalSender
    private let sleep: ControlSleeper
    private let consoleRoot: URL?

    public init(commandRunner: CommandRunner = CommandRunner()) {
        self.runCommand = { tool, arguments, workingDirectory, allowedExitCodes in
            try commandRunner.run(
                tool,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeout: 8,
                allowedExitCodes: allowedExitCodes
            )
        }
        self.launchProcess = Self.defaultLauncher
        self.sendSignal = Self.defaultSignalSender
        self.sleep = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        self.consoleRoot = nil
    }

    init(
        runCommand: @escaping ControlCommand,
        launchProcess: @escaping ControlLauncher = TownControlEngine.defaultLauncher,
        sendSignal: @escaping ControlSignalSender = TownControlEngine.defaultSignalSender,
        sleep: @escaping ControlSleeper = { _ in },
        consoleRoot: URL? = nil
    ) {
        self.runCommand = runCommand
        self.launchProcess = launchProcess
        self.sendSignal = sendSignal
        self.sleep = sleep
        self.consoleRoot = consoleRoot
    }

    /// Starts Town's sanctioned local-stack task in a detached pseudo-terminal.
    /// The owner-only transcript lets Town Sheriff display the same unified stream
    /// as an interactive launch; values are redacted before they reach the UI.
    public func start(_ worktree: WorktreeSnapshot) async throws -> ControlResult {
        try launch(worktree, allowPreviouslyRunning: false, action: .start)
    }

    /// Relaunches the same numbered stack after a separately verified
    /// maintenance operation has already stopped it and removed local state.
    public func startAfterMaintenance(_ worktree: WorktreeSnapshot) async throws -> ControlResult {
        try launch(worktree, allowPreviouslyRunning: true, action: .restart)
    }

    /// Sends TERM to the verified launcher(s), gives Town's cleanup handlers a
    /// grace period, then sweeps only the still-matching owned processes.
    public func stop(_ worktree: WorktreeSnapshot) async throws -> ControlResult {
        try validateProcessOwnership(for: worktree)
        let candidates = eligibleProcesses(in: worktree)
        guard !candidates.isEmpty else {
            return ControlResult(
                action: .gracefulStop,
                message: "No owned Town processes are running for this worktree."
            )
        }

        let roots = ownedRoots(for: worktree)
        let verified = try candidates.filter { try processStillMatches($0, ownedByAny: roots) }
        guard !verified.isEmpty else {
            throw TownDockError.staleSnapshot(
                "None of the recorded processes still match this worktree. Refresh before stopping it."
            )
        }

        let verifiedIDs = Set(verified.map(\.pid))
        let launchers = verified.filter { !verifiedIDs.contains($0.parentPID) }
        for process in launchers {
            try signal(process.pid, SIGTERM)
        }

        // Town's launcher gives its own children up to three seconds to clean
        // up. Do not race that cleanup with our final listener sweep.
        try await sleep(4_250_000_000)

        var affected = Set(launchers.map(\.pid))
        for process in verified {
            guard try processStillMatches(process, ownedByAny: roots) else { continue }
            try signal(process.pid, SIGKILL)
            affected.insert(process.pid)
        }
        affected.formUnion(try await sweepAfterGrace(worktree))

        return ControlResult(
            action: .gracefulStop,
            affectedProcessIDs: affected.sorted(),
            message: "Stopped the verified Town process tree."
        )
    }

    public func restart(_ worktree: WorktreeSnapshot) async throws -> ControlResult {
        _ = try await stop(worktree)
        let started = try launch(worktree, allowPreviouslyRunning: true, action: .restart)
        return started
    }

    /// Immediately sends KILL, but only after the same ownership checks used by
    /// graceful stop. Shared-service PIDs are never eligible.
    public func forceKill(_ worktree: WorktreeSnapshot) async throws -> ControlResult {
        try validateProcessOwnership(for: worktree)
        let candidates = eligibleProcesses(in: worktree)
        guard !candidates.isEmpty else {
            return ControlResult(
                action: .forceKill,
                message: "No owned Town processes are running for this worktree."
            )
        }

        let roots = ownedRoots(for: worktree)
        var affected: [Int32] = []
        for process in candidates {
            guard try processStillMatches(process, ownedByAny: roots) else { continue }
            try signal(process.pid, SIGKILL)
            affected.append(process.pid)
        }
        affected.append(contentsOf: try await sweepAfterGrace(worktree))
        affected = Array(Set(affected)).sorted()
        guard !affected.isEmpty else {
            throw TownDockError.staleSnapshot(
                "None of the recorded processes still match this worktree. Refresh before killing them."
            )
        }

        return ControlResult(
            action: .forceKill,
            affectedProcessIDs: affected.sorted(),
            message: "Force-killed the verified Town processes."
        )
    }

    public func killOrphan(_ orphan: OrphanSnapshot) async throws -> ControlResult {
        guard orphan.confidence.rank >= AttributionConfidence.high.rank else {
            throw TownDockError.unsafeOperation(
                "Refusing to kill an orphan whose ownership is ambiguous."
            )
        }

        let sharedPIDs = Set(
            orphan.services.filter(\.isShared).flatMap(\.processIDs)
        )
        let listenerPIDs = Set(
            orphan.services.filter { !$0.isShared }.flatMap(\.processIDs)
        )
        let listenerGroups = Set(orphan.processes.compactMap { process in
            listenerPIDs.contains(process.pid) ? process.processGroupID : nil
        })
        let dormantStateRoot: String? = {
            guard orphan.kind == .dormantState,
                  let state = orphan.stateDirectory,
                  let descriptor = TownStateDirectoryParser.parse(path: state.path),
                  descriptor.instanceNumber == orphan.instanceNumber
            else {
                return nil
            }
            return state.path
        }()
        let ownsDormantState: (ProcessIdentity) -> Bool = { process in
            guard let dormantStateRoot, let cwd = process.workingDirectory else { return false }
            return self.path(cwd, isInside: dormantStateRoot)
        }
        let candidates = orphan.processes.filter { process in
            !sharedPIDs.contains(process.pid)
                && !TownProcessClassifier.isSharedRuntimeHost(process.command)
                && (orphan.missingPath != nil
                    || listenerPIDs.contains(process.pid)
                    || listenerGroups.contains(process.processGroupID)
                    || ownsDormantState(process))
        }
        guard !candidates.isEmpty else {
            return ControlResult(
                action: .orphanKill,
                message: "This orphan has no eligible processes."
            )
        }

        var verified: [ProcessIdentity] = []
        for process in candidates {
            if orphan.missingPath == nil,
               !listenerPIDs.contains(process.pid),
               !listenerGroups.contains(process.processGroupID),
               !ownsDormantState(process) {
                continue
            }
            // A deleted-worktree orphan can include a launcher rooted in the
            // vanished checkout and backends rooted in their owned state
            // directory. Pin every PID to its own freshly observed cwd instead
            // of forcing the whole process tree under the missing checkout.
            let ownershipRoot = ownsDormantState(process)
                ? dormantStateRoot
                : (process.workingDirectory ?? orphan.missingPath)
            guard let ownershipRoot else {
                throw TownDockError.unsafeOperation(
                    "Refusing an orphan process without a verifiable working directory."
                )
            }
            if try processStillMatches(process, ownedByAny: [ownershipRoot]) {
                verified.append(process)
            }
        }
        guard !verified.isEmpty else {
            throw TownDockError.staleSnapshot(
                "The orphan process identities changed. Refresh before killing them."
            )
        }

        let verifiedIDs = Set(verified.map(\.pid))
        let launchers = verified.filter { !verifiedIDs.contains($0.parentPID) }
        for process in launchers {
            try signal(process.pid, SIGTERM)
        }
        try await sleep(1_000_000_000)

        var affected = Set(launchers.map(\.pid))
        for process in verified {
            let ownershipRoot = ownsDormantState(process)
                ? dormantStateRoot
                : (process.workingDirectory ?? orphan.missingPath)
            guard let ownershipRoot else {
                continue
            }
            guard try processStillMatches(process, ownedByAny: [ownershipRoot]) else { continue }
            try signal(process.pid, SIGKILL)
            affected.insert(process.pid)
        }

        return ControlResult(
            action: .orphanKill,
            affectedProcessIDs: affected.sorted(),
            message: "Stopped the verified orphan process tree."
        )
    }

    /// Final, ownership-checked listener sweep used after a graceful nuke stop.
    /// This catches children spawned after the discovery snapshot without ever
    /// touching fixed shared infrastructure ports.
    func sweepAfterGrace(_ worktree: WorktreeSnapshot) async throws -> [Int32] {
        guard let instance = worktree.instance,
              instance.confidence.rank >= AttributionConfidence.high.rank
        else {
            return []
        }

        let ports = Set(instance.services.filter { !$0.isShared }.map(\.port))
        var processIDs = Set<Int32>()
        for port in ports where port > 0 && port <= 65_535 {
            let result = try runCommand(
                .lsof,
                ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"],
                nil,
                [0, 1]
            )
            for line in result.stdout.split(whereSeparator: \.isNewline) {
                guard line.first == "p", let pid = Int32(line.dropFirst()) else { continue }
                processIDs.insert(pid)
            }
        }

        let roots = ownedRoots(for: worktree)
        var killed: [Int32] = []
        for pid in processIDs.sorted() {
            guard let cwd = try currentWorkingDirectory(of: pid),
                  roots.contains(where: { path(cwd, isInside: $0) })
            else {
                continue
            }
            try signal(pid, SIGKILL)
            killed.append(pid)
        }
        return killed
    }

    private func launch(
        _ worktree: WorktreeSnapshot,
        allowPreviouslyRunning: Bool,
        action: ControlAction
    ) throws -> ControlResult {
        if !allowPreviouslyRunning, worktree.instance?.isRunning == true {
            throw TownDockError.unsafeOperation("This worktree is already running.")
        }
        if let instance = worktree.instance,
           instance.confidence == .ambiguous
        {
            throw TownDockError.unsafeOperation(
                "Refusing to start with an ambiguous instance assignment."
            )
        }

        let directory = try validatedWorktreeDirectory(worktree.path)
        let mise = directory.appendingPathComponent("mise", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: mise.path) else {
            throw TownDockError.repositoryNotFound(
                "The worktree does not contain an executable ./mise launcher."
            )
        }

        var arguments = ["run", "local-stack"]
        if let number = worktree.instance?.number {
            guard (1...9).contains(number) else {
                throw TownDockError.unsafeOperation("Town instance numbers must be from 1 through 9.")
            }
            arguments += ["--", "-n", String(number)]
        }

        let capture = try prepareConsoleCapture(for: directory)
        let script = URL(fileURLWithPath: "/usr/bin/script", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw TownDockError.commandFailed("macOS's pseudo-terminal recorder is unavailable.")
        }
        let scriptArguments = ["-q", "-F", "-t", "0", capture.path, mise.path] + arguments
        let pid = try launchProcess(script, scriptArguments, directory)
        return ControlResult(
            action: action,
            affectedProcessIDs: [pid],
            message: action == .restart ? "Restarted Town's local stack." : "Started Town's local stack."
        )
    }

    private func validateProcessOwnership(for worktree: WorktreeSnapshot) throws {
        if let instance = worktree.instance,
           instance.confidence.rank < AttributionConfidence.high.rank,
           !instance.processes.isEmpty
        {
            throw TownDockError.unsafeOperation(
                "Refusing to signal processes with ambiguous worktree ownership."
            )
        }
    }

    private func eligibleProcesses(in worktree: WorktreeSnapshot) -> [ProcessIdentity] {
        guard let instance = worktree.instance else { return [] }
        let sharedPIDs = Set(instance.services.filter(\.isShared).flatMap(\.processIDs))
        let listenerPIDs = Set(instance.services.filter { !$0.isShared }.flatMap(\.processIDs))
        let roots = ownedRoots(for: worktree)
        let ownsPath: (ProcessIdentity) -> Bool = { process in
            process.workingDirectory.map { cwd in
                roots.contains(where: { self.path(cwd, isInside: $0) })
            } == true
        }
        let anchoredPIDs = TownProcessClassifier.anchoredProcessIDs(
            processes: instance.processes,
            listenerPIDs: listenerPIDs,
            ownsPath: ownsPath
        )
        return instance.processes.filter { process in
            !sharedPIDs.contains(process.pid)
                && process.pid > 1
                && process.pid != getpid()
                && anchoredPIDs.contains(process.pid)
                && ownsPath(process)
        }
    }

    private func processStillMatches(
        _ process: ProcessIdentity,
        ownedByAny ownershipRoots: [String]
    ) throws -> Bool {
        guard process.pid > 1, process.pid != getpid(), !process.startToken.isEmpty else {
            return false
        }
        let result = try runCommand(
            .ps,
            ["-p", String(process.pid), "-o", "lstart=", "-o", "pgid="],
            nil,
            [0, 1]
        )
        guard result.terminationStatus == 0,
              let current = parseProcessStartAndGroup(result.stdout),
              current.groupID == process.processGroupID,
              normalizeStartToken(current.startToken) == normalizeStartToken(process.startToken),
              let cwd = try currentWorkingDirectory(of: process.pid),
              ownershipRoots.contains(where: { path(cwd, isInside: $0) })
        else {
            return false
        }
        return true
    }

    private func ownedRoots(for worktree: WorktreeSnapshot) -> [String] {
        var roots = [worktree.path]
        if let instance = worktree.instance,
           instance.confidence.rank >= AttributionConfidence.high.rank,
           let state = instance.stateDirectory,
           state.confidence.rank >= AttributionConfidence.high.rank,
           state.instanceNumber == instance.number,
           state.associatedWorktreePath.map({ canonicalPath($0) }) == canonicalPath(worktree.path),
           canonicalPath(state.path).hasPrefix(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".convex/local-backend-")
                    .standardizedFileURL.path
           )
        {
            roots.append(state.path)
        }
        return roots
    }

    private func currentWorkingDirectory(of pid: Int32) throws -> String? {
        let result = try runCommand(
            .lsof,
            ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
            nil,
            [0, 1]
        )
        guard result.terminationStatus == 0 else { return nil }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.first == "n" })
            .map { String($0.dropFirst()).replacingOccurrences(of: " (deleted)", with: "") }
    }

    private func parseProcessStartAndGroup(
        _ output: String
    ) -> (startToken: String, groupID: Int32)? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let groupID = Int32(fields.last!) else { return nil }
        return (fields.dropLast().joined(separator: " "), groupID)
    }

    private func validatedWorktreeDirectory(_ rawPath: String) throws -> URL {
        let directory = URL(fileURLWithPath: rawPath, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard directory.path != "/",
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw TownDockError.repositoryNotFound("The worktree directory is unavailable.")
        }

        let result = try runCommand(
            .git,
            ["-C", directory.path, "rev-parse", "--show-toplevel"],
            nil,
            [0]
        )
        let observed = canonicalPath(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        guard observed == canonicalPath(directory.path) else {
            throw TownDockError.staleSnapshot(
                "The selected directory is no longer the recorded Git worktree."
            )
        }
        return directory
    }

    private func prepareConsoleCapture(for worktree: URL) throws -> URL {
        let capture = StackConsoleCapture.captureURL(
            for: worktree.path,
            rootDirectory: consoleRoot
        )
        let directory = capture.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            if FileManager.default.fileExists(atPath: capture.path) {
                let handle = try FileHandle(forWritingTo: capture)
                try handle.truncate(atOffset: 0)
                try handle.close()
            } else if !FileManager.default.createFile(
                atPath: capture.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) {
                throw TownDockError.commandFailed("Could not create the stack console capture.")
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: capture.path
            )
            return capture
        } catch let error as TownDockError {
            throw error
        } catch {
            throw TownDockError.commandFailed("Could not prepare the stack console capture.")
        }
    }

    private func signal(_ pid: Int32, _ value: Int32) throws {
        guard pid > 1, pid != getpid() else {
            throw TownDockError.unsafeOperation("Refusing to signal a protected process ID.")
        }
        try sendSignal(pid, value)
    }

    private func path(_ candidate: String, isInside root: String) -> Bool {
        let child = canonicalPath(candidate)
        let parent = canonicalPath(root)
        guard parent != "/" else { return false }
        return child == parent || child.hasPrefix(parent + "/")
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Discovery serializes `ps` start times with underscores so they remain a
    /// stable, single-field identity token. Revalidation reads the same value
    /// directly from `ps`, which returns spaces. Compare their canonical forms
    /// without weakening the PID, process-group, or cwd ownership checks.
    private func normalizeStartToken(_ value: String) -> String {
        normalizeWhitespace(value.replacingOccurrences(of: "_", with: " "))
    }

    fileprivate static func defaultLauncher(
        executable: URL,
        arguments: [String],
        workingDirectory: URL
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let source = ProcessInfo.processInfo.environment
        let home = source["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let safePath = [
            "\(home)/Developer/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        var environment = source.filter {
            ["HOME", "USER", "TMPDIR", "LANG", "LC_CTYPE", "SHELL", "SSH_AUTH_SOCK"]
                .contains($0.key)
        }
        environment["PATH"] = safePath
        environment["LC_ALL"] = "C"
        // `/usr/bin/script` gives the stack a PTY, but our detached launcher has
        // no parent terminal from which to inherit these values. Supply the same
        // capabilities as a normal modern Terminal session so CLI tools retain
        // their colors and interactive rendering in Town Sheriff's console.
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["CLICOLOR"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TownDockError.commandFailed("Could not launch Town's local stack.")
        }
        return process.processIdentifier
    }

    fileprivate static func defaultSignalSender(processID: Int32, signal: Int32) throws {
        guard kill(processID, signal) == 0 || errno == ESRCH else {
            throw TownDockError.commandFailed("Could not signal process \(processID).")
        }
    }
}
