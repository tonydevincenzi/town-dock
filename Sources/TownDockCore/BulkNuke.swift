import Foundation

/// User-controlled filters for choosing worktrees in the bulk nuke flow.
/// The primary checkout is never eligible, regardless of these settings.
public struct BulkNukeCriteria: Codable, Hashable, Sendable {
    public var includeRunning: Bool
    public var includeStopped: Bool
    public var includeClean: Bool
    public var includeDirty: Bool
    public var includeSetupComplete: Bool
    public var includeSetupIncomplete: Bool

    public init(
        includeRunning: Bool = false,
        includeStopped: Bool = true,
        includeClean: Bool = true,
        includeDirty: Bool = false,
        includeSetupComplete: Bool = true,
        includeSetupIncomplete: Bool = true
    ) {
        self.includeRunning = includeRunning
        self.includeStopped = includeStopped
        self.includeClean = includeClean
        self.includeDirty = includeDirty
        self.includeSetupComplete = includeSetupComplete
        self.includeSetupIncomplete = includeSetupIncomplete
    }

    public func matches(_ worktree: WorktreeSnapshot) -> Bool {
        guard !worktree.isPrimary else { return false }
        guard !worktree.isLocked else { return false }

        let isRunning = worktree.instance?.isRunning == true
        guard isRunning ? includeRunning : includeStopped else { return false }
        guard worktree.gitStatus.isDirty ? includeDirty : includeClean else { return false }
        guard worktree.setupComplete ? includeSetupComplete : includeSetupIncomplete else { return false }
        return true
    }

    public func matchingWorktrees(in worktrees: [WorktreeSnapshot]) -> [WorktreeSnapshot] {
        worktrees.filter(matches)
    }
}
