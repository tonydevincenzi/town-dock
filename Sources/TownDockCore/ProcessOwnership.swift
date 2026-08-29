import Foundation

/// Narrow, non-secret command-shape checks used as one part of process ownership.
/// A matching command is never sufficient on its own: callers must also verify
/// the process identity and an owned working directory or listener.
enum TownProcessClassifier {
    static func isLifecycleLauncher(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("run local-stack")
            || lower.contains("scripts/local-convex-backend.ts")
    }

    /// Returns only listener/launcher anchors and their recorded descendants.
    /// This keeps unrelated shells, editors, and coding agents out even when
    /// their current directory happens to be the same checkout.
    static func anchoredProcessIDs(
        processes: [ProcessIdentity],
        listenerPIDs: Set<Int32>,
        ownsPath: (ProcessIdentity) -> Bool
    ) -> Set<Int32> {
        var owned = Set(processes.compactMap { process -> Int32? in
            guard ownsPath(process),
                  listenerPIDs.contains(process.pid) || isLifecycleLauncher(process.command)
            else {
                return nil
            }
            return process.pid
        })

        var changed = true
        while changed {
            changed = false
            for process in processes
                where ownsPath(process)
                    && owned.contains(process.parentPID)
                    && owned.insert(process.pid).inserted
            {
                changed = true
            }
        }
        return owned
    }
}
