import Foundation

public enum StackConsoleSource: String, Codable, Hashable, Sendable {
    case managedCapture
    case terminalScrollback
    case unavailable

    public var displayName: String {
        switch self {
        case .managedCapture: "Town Dock capture"
        case .terminalScrollback: "Terminal scrollback"
        case .unavailable: "No capture"
        }
    }
}

public struct StackConsoleSnapshot: Codable, Hashable, Sendable {
    public let source: StackConsoleSource
    public let text: String
    public let path: String?
    public let modifiedAt: Date?
    public let isTruncated: Bool

    public init(
        source: StackConsoleSource,
        text: String,
        path: String? = nil,
        modifiedAt: Date? = nil,
        isTruncated: Bool = false
    ) {
        self.source = source
        self.text = text
        self.path = path
        self.modifiedAt = modifiedAt
        self.isTruncated = isTruncated
    }
}

public enum StackConsoleCapture {
    public static func captureURL(
        for worktreePath: String,
        rootDirectory: URL? = nil
    ) -> URL {
        let root = rootDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Town Dock", isDirectory: true)
            .appendingPathComponent("Consoles", isDirectory: true)
        let canonical = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return root
            .appendingPathComponent(stablePathKey(canonical), isDirectory: true)
            .appendingPathComponent("stack-console.log", isDirectory: false)
    }

    private static func stablePathKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

public enum StackConsoleTranscript {
    /// Converts a PTY transcript into stable, selectable text. Color and cursor
    /// control sequences are removed, while carriage-return updates are
    /// resolved the way a terminal would display their final line.
    public static func render(_ raw: String, maximumLength: Int = 1_048_576) -> String {
        let eraseMarker = "\u{E000}"
        var value = raw.replacingOccurrences(
            of: #"\x1B\[(?:0|1|2)?K"#,
            with: eraseMarker,
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\x1B\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )

        var output = ""
        var line: [Character] = []
        var cursor = 0

        for character in value {
            switch character {
            case "\n":
                output.append(contentsOf: line)
                output.append("\n")
                line.removeAll(keepingCapacity: true)
                cursor = 0
            case "\r":
                cursor = 0
            case "\u{8}", "\u{7F}":
                cursor = max(0, cursor - 1)
            case Character(eraseMarker):
                if cursor < line.count {
                    line.removeSubrange(cursor..<line.count)
                }
            default:
                guard character.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0)
                })
                    || character == "\t"
                else { continue }
                if cursor < line.count {
                    line[cursor] = character
                } else {
                    line.append(character)
                }
                cursor += 1
            }
        }
        output.append(contentsOf: line)
        return SecretRedactor.redact(output, maximumLength: max(1, maximumLength))
    }
}

public actor StackConsoleReader {
    private let rootDirectory: URL?

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
    }

    public func read(
        worktreePath: String,
        maximumBytes: Int = 512 * 1_024
    ) throws -> StackConsoleSnapshot? {
        let capture = StackConsoleCapture.captureURL(
            for: worktreePath,
            rootDirectory: rootDirectory
        )
        guard FileManager.default.fileExists(atPath: capture.path) else { return nil }

        let canonical = capture.resolvingSymlinksInPath()
        guard canonical.path == capture.standardizedFileURL.path else { return nil }
        let values = try canonical.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ])
        guard values.isRegularFile == true else { return nil }

        let handle = try FileHandle(forReadingFrom: canonical)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit = max(1, maximumBytes)
        let truncated = size > UInt64(limit)
        try handle.seek(toOffset: truncated ? size - UInt64(limit) : 0)
        let data = try handle.readToEnd() ?? Data()
        var raw = String(decoding: data, as: UTF8.self)
        if truncated, let newline = raw.firstIndex(of: "\n") {
            raw.removeSubrange(raw.startIndex...newline)
        }

        return StackConsoleSnapshot(
            source: .managedCapture,
            text: StackConsoleTranscript.render(raw),
            path: canonical.path,
            modifiedAt: values.contentModificationDate,
            isTruncated: truncated
        )
    }
}
