@preconcurrency import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Executables used by Town Dock's read-only discovery pass.
///
/// Keeping this list closed prevents repository text from becoming an executable
/// name. `CommandRunner` also invokes the executable directly; it never passes
/// arguments through a shell.
public enum CommandTool: String, CaseIterable, Sendable {
    case git
    case lsof
    case ps
    case docker
    case du
}

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let terminationStatus: Int32
    public let wasTruncated: Bool

    public var succeeded: Bool { terminationStatus == 0 }

    public init(
        stdout: String,
        stderr: String,
        terminationStatus: Int32,
        wasTruncated: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.terminationStatus = terminationStatus
        self.wasTruncated = wasTruncated
    }
}

/// Resolves only known tools, preferring macOS system locations and common
/// package-manager locations before consulting absolute entries in `PATH`.
public struct ToolResolver: Sendable {
    private let searchDirectories: [String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        var directories = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
        if let home {
            directories.append("\(home)/.docker/bin")
            directories.append("\(home)/Developer/bin")
        }
        for entry in environment["PATH", default: ""].split(separator: ":").map(String.init) {
            guard entry.hasPrefix("/") else { continue }
            directories.append(entry)
        }
        self.searchDirectories = directories.reduce(into: []) { result, directory in
            let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path
            if !result.contains(normalized) {
                result.append(normalized)
            }
        }
    }

    public func resolve(_ tool: CommandTool) throws -> URL {
        let fileManager = FileManager.default
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(tool.rawValue, isDirectory: false)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path)
            else {
                continue
            }
            return candidate
        }
        throw TownDockError.unsupported("Required tool '\(tool.rawValue)' is unavailable.")
    }
}

private final class BoundedCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private(set) var wasTruncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - storage.count)
        if remaining > 0 {
            storage.append(data.prefix(remaining))
        }
        if data.count > remaining {
            wasTruncated = true
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }

    func truncated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasTruncated
    }
}

/// A bounded, timeout-aware process runner. It deliberately does not expose a
/// shell API and never includes captured output in thrown errors, because tool
/// output can contain credentials or environment-derived URLs.
public final class CommandRunner: @unchecked Sendable {
    private let resolver: ToolResolver
    private let baseEnvironment: [String: String]

    public init(resolver: ToolResolver = ToolResolver()) {
        self.resolver = resolver
        let source = ProcessInfo.processInfo.environment
        let allowedKeys = [
            "PATH", "HOME", "USER", "TMPDIR", "SHELL", "LANG", "LC_CTYPE",
            "XDG_CONFIG_HOME", "DOCKER_HOST", "SSH_AUTH_SOCK",
        ]
        var environment = source.filter { allowedKeys.contains($0.key) }
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        self.baseEnvironment = environment
    }

    @discardableResult
    public func run(
        _ tool: CommandTool,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 8,
        maxOutputBytes: Int = 4 * 1_024 * 1_024,
        allowedExitCodes: Set<Int32> = [0]
    ) throws -> CommandResult {
        try run(
            executable: resolver.resolve(tool),
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            allowedExitCodes: allowedExitCodes
        )
    }

    @discardableResult
    public func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 8,
        maxOutputBytes: Int = 4 * 1_024 * 1_024,
        allowedExitCodes: Set<Int32> = [0]
    ) throws -> CommandResult {
        let executable = executable.standardizedFileURL
        guard executable.isFileURL,
              executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              arguments.count <= 4_096,
              arguments.allSatisfy({ !$0.contains("\0") }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576
        else {
            throw TownDockError.unsafeOperation("Refusing an invalid command invocation.")
        }

        if let workingDirectory {
            var isDirectory: ObjCBool = false
            guard workingDirectory.isFileURL,
                  FileManager.default.fileExists(
                      atPath: workingDirectory.standardizedFileURL.path,
                      isDirectory: &isDirectory
                  ),
                  isDirectory.boolValue
            else {
                throw TownDockError.repositoryNotFound("Working directory is unavailable.")
            }
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = BoundedCommandOutput(limit: maxOutputBytes)
        let stderr = BoundedCommandOutput(limit: maxOutputBytes)

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory?.standardizedFileURL
        process.environment = baseEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdout.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw TownDockError.commandFailed("Could not launch \(executable.lastPathComponent).")
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline {
                usleep(20_000)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        if timedOut {
            throw TownDockError.commandFailed("\(executable.lastPathComponent) timed out.")
        }

        let result = CommandResult(
            stdout: stdout.string(),
            stderr: stderr.string(),
            terminationStatus: process.terminationStatus,
            wasTruncated: stdout.truncated() || stderr.truncated()
        )
        guard allowedExitCodes.contains(result.terminationStatus) else {
            throw TownDockError.commandFailed(
                "\(executable.lastPathComponent) exited with status \(result.terminationStatus)."
            )
        }
        return result
    }
}
