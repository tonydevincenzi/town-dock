import Foundation

public struct ManagedRunRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String { worktreePath }

    public let worktreePath: String
    public let instanceNumber: Int?
    public let launcherPID: Int32
    public let launchedAt: Date
    public let lastSeenRunningAt: Date?

    public init(
        worktreePath: String,
        instanceNumber: Int?,
        launcherPID: Int32,
        launchedAt: Date = Date(),
        lastSeenRunningAt: Date? = nil
    ) {
        self.worktreePath = Self.canonicalPath(worktreePath)
        self.instanceNumber = instanceNumber
        self.launcherPID = launcherPID
        self.launchedAt = launchedAt
        self.lastSeenRunningAt = lastSeenRunningAt
    }

    fileprivate func seenRunning(at date: Date) -> ManagedRunRecord {
        ManagedRunRecord(
            worktreePath: worktreePath,
            instanceNumber: instanceNumber,
            launcherPID: launcherPID,
            launchedAt: launchedAt,
            lastSeenRunningAt: date
        )
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

/// Stores only process identity metadata—never command output, arguments, or
/// environment values—so Town Dock can recognize stacks it launched after the
/// app itself restarts.
public actor ManagedRunRegistry {
    private let storageURL: URL
    private var cached: [ManagedRunRecord]?

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            self.storageURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Town Dock", isDirectory: true)
                .appendingPathComponent("managed-runs.json", isDirectory: false)
        }
    }

    @discardableResult
    public func recordLaunch(
        worktreePath: String,
        instanceNumber: Int?,
        launcherPID: Int32,
        launchedAt: Date = Date()
    ) throws -> [ManagedRunRecord] {
        guard launcherPID > 1 else { return try load() }
        var records = try load()
        let canonical = ManagedRunRecord.canonicalPath(worktreePath)
        records.removeAll { $0.worktreePath == canonical }
        records.append(ManagedRunRecord(
            worktreePath: canonical,
            instanceNumber: instanceNumber,
            launcherPID: launcherPID,
            launchedAt: launchedAt
        ))
        try save(records)
        return records.sorted(by: Self.sortRecords)
    }

    @discardableResult
    public func remove(worktreePath: String) throws -> [ManagedRunRecord] {
        var records = try load()
        let canonical = ManagedRunRecord.canonicalPath(worktreePath)
        records.removeAll { $0.worktreePath == canonical }
        try save(records)
        return records.sorted(by: Self.sortRecords)
    }

    /// Retains a new launch during its startup grace period, refreshes records
    /// whose worktree is running, and removes records for deleted/stopped stacks.
    @discardableResult
    public func reconcile(
        snapshot: TownSnapshot,
        now: Date = Date(),
        startupGrace: TimeInterval = 120
    ) throws -> [ManagedRunRecord] {
        let worktrees = Dictionary(uniqueKeysWithValues: snapshot.worktrees.map {
            (ManagedRunRecord.canonicalPath($0.path), $0)
        })
        var changed = false
        let records = try load().compactMap { record -> ManagedRunRecord? in
            guard let worktree = worktrees[record.worktreePath] else {
                changed = true
                return nil
            }
            if worktree.instance?.isRunning == true {
                let refreshed = record.seenRunning(at: now)
                if refreshed != record { changed = true }
                return refreshed
            }
            if record.lastSeenRunningAt != nil {
                changed = true
                return nil
            }
            if now.timeIntervalSince(record.launchedAt) <= startupGrace {
                return record
            }
            changed = true
            return nil
        }
        if changed { try save(records) }
        return records.sorted(by: Self.sortRecords)
    }

    public func records() throws -> [ManagedRunRecord] {
        try load().sorted(by: Self.sortRecords)
    }

    private func load() throws -> [ManagedRunRecord] {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            cached = []
            return []
        }
        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ManagedRunRecord].self, from: data)
        cached = decoded
        return decoded
    }

    private func save(_ records: [ManagedRunRecord]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.townDock.encode(records.sorted(by: Self.sortRecords))
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )
        cached = records
    }

    private static func sortRecords(_ lhs: ManagedRunRecord, _ rhs: ManagedRunRecord) -> Bool {
        lhs.launchedAt > rhs.launchedAt
    }
}

private extension JSONEncoder {
    static var townDock: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
