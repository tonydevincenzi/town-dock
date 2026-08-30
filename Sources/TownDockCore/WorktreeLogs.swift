import Foundation

public struct WorktreeLogFile: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }

    public let name: String
    public let path: String
    public let sizeBytes: UInt64
    public let modifiedAt: Date?
    public let text: String
    public let isTruncated: Bool

    public init(
        name: String,
        path: String,
        sizeBytes: UInt64,
        modifiedAt: Date?,
        text: String,
        isTruncated: Bool
    ) {
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.text = text
        self.isTruncated = isTruncated
    }
}

public actor WorktreeLogReader {
    public init() {}

    /// Reads bounded tails of Town's existing service logs. Symlinks that leave
    /// the worktree log directory are rejected.
    public func read(
        worktreePath: String,
        maximumFiles: Int = 16,
        maximumBytesPerFile: Int = 192 * 1_024
    ) throws -> [WorktreeLogFile] {
        let root = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: logs.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return [] }

        let canonicalLogs = logs.resolvingSymlinksInPath().path
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let candidates = try FileManager.default.contentsOfDirectory(
            at: logs,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (URL, URLResourceValues)? in
            guard url.pathExtension.lowercased() == "log" else { return nil }
            let canonical = url.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(canonicalLogs + "/") else { return nil }
            let values = try canonical.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return (canonical, values)
        }.sorted {
            ($0.1.contentModificationDate ?? .distantPast)
                > ($1.1.contentModificationDate ?? .distantPast)
        }

        return try candidates.prefix(max(0, maximumFiles)).map { url, values in
            let size = UInt64(max(0, values.fileSize ?? 0))
            let tail = try readTail(url, maximumBytes: max(1, maximumBytesPerFile))
            return WorktreeLogFile(
                name: url.lastPathComponent,
                path: url.path,
                sizeBytes: size,
                modifiedAt: values.contentModificationDate,
                text: stripANSI(tail.text),
                isTruncated: tail.isTruncated
            )
        }
    }

    private func readTail(_ url: URL, maximumBytes: Int) throws -> (text: String, isTruncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let truncated = size > UInt64(maximumBytes)
        var beginsAtLineBoundary = true
        if truncated {
            let start = size - UInt64(maximumBytes)
            if start > 0 {
                try handle.seek(toOffset: start - 1)
                beginsAtLineBoundary = try handle.read(upToCount: 1) == Data([0x0A])
            }
            try handle.seek(toOffset: start)
        } else {
            try handle.seek(toOffset: 0)
        }
        let data = try handle.readToEnd() ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if truncated, !beginsAtLineBoundary, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...newline)
        }
        return (text, truncated)
    }

    private func stripANSI(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\x1B\[[0-?]*[ -/]*[@-~]"#
        ) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
    }
}
