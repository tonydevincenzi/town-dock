import AppKit
import Foundation
import TownDockCore

actor TerminalSessionCoordinator {
    /// Focuses the Terminal.app tab that owns any process in the worktree's
    /// stack. Detached Town Sheriff launches have no TTY and intentionally return
    /// false so the caller can open a fresh shell instead.
    func focusOwningTerminal(for worktree: WorktreeSnapshot) -> Bool {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Terminal"
        ).isEmpty else { return false }

        let processIDs = worktree.instance?.processes.map(\.pid) ?? []
        for pid in processIDs {
            guard let tty = tty(for: pid), focusTerminalTab(tty: tty) else { continue }
            return true
        }
        return false
    }

    /// Returns the visible history from the Terminal tab that owns this stack.
    /// This is a fallback for stacks started manually before Town Sheriff began
    /// capturing its own pseudo-terminal transcript.
    func transcript(for worktree: WorktreeSnapshot) -> String? {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Terminal"
        ).isEmpty else { return nil }

        let processIDs = worktree.instance?.processes.map(\.pid) ?? []
        for pid in processIDs {
            guard let tty = tty(for: pid), let text = terminalHistory(tty: tty) else { continue }
            let rendered = StackConsoleTranscript.render(text, maximumLength: 1_048_576)
            if !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rendered
            }
        }
        return nil
    }

    private func tty(for pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "tty="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^ttys[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "/dev/\(value)"
    }

    private func focusTerminalTab(tty: String) -> Bool {
        guard tty.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil else {
            return false
        }
        let source = """
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is "\(tty)" then
                        set selected tab of terminalWindow to terminalTab
                        set index of terminalWindow to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    private func terminalHistory(tty: String) -> String? {
        guard tty.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let source = """
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is "\(tty)" then
                        set terminalText to history of terminalTab
                        if terminalText is missing value or terminalText is "" then
                            set terminalText to contents of terminalTab
                        end if
                        return terminalText as text
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
              error == nil
        else { return nil }
        return result.stringValue
    }
}
