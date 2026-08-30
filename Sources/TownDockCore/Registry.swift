import Foundation

public struct WorktreeRegistryRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String { canonicalPath }
    public let canonicalPath: String
    public var branch: String?
    public var head: String
    public var instanceNumber: Int?
    public var stateDirectory: String?
    public var bucketName: String?
    public var lastSeenAt: Date
    public var lastSeenRunningAt: Date?

    public init(
        canonicalPath: String,
        branch: String?,
        head: String,
        instanceNumber: Int?,
        stateDirectory: String?,
        bucketName: String?,
        lastSeenAt: Date,
        lastSeenRunningAt: Date?
    ) {
        self.canonicalPath = canonicalPath
        self.branch = branch
        self.head = head
        self.instanceNumber = instanceNumber
        self.stateDirectory = stateDirectory
        self.bucketName = bucketName
        self.lastSeenAt = lastSeenAt
        self.lastSeenRunningAt = lastSeenRunningAt
    }
}

/// Durable ownership memory for associations Town itself does not preserve.
///
/// `.local-convex-services.md` is deleted after a clean stop and instance
/// numbers are reusable, so stopped state cannot safely be attributed from
/// repository files alone. Town Sheriff records only associations it observed
/// with high-confidence evidence; destructive code must still revalidate them.
public actor TownRegistry {
    private let fileURL: URL
    private var recordsByPath: [String: WorktreeRegistryRecord]

    public init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL
        self.recordsByPath = Self.load(from: resolvedURL)
    }

    public func records() -> [WorktreeRegistryRecord] {
        recordsByPath.values.sorted { $0.canonicalPath < $1.canonicalPath }
    }

    public func record(snapshot: TownSnapshot) throws {
        var changed = false

        for worktree in snapshot.worktrees {
            let canonicalPath = URL(fileURLWithPath: worktree.path)
                .standardizedFileURL.path
            let observedInstance = worktree.instance.flatMap { instance in
                instance.confidence.rank >= AttributionConfidence.high.rank
                    ? instance
                    : nil
            }
            let previous = recordsByPath[canonicalPath]
            let record = WorktreeRegistryRecord(
                canonicalPath: canonicalPath,
                branch: worktree.branch ?? previous?.branch,
                head: worktree.head,
                instanceNumber: observedInstance?.number ?? previous?.instanceNumber,
                stateDirectory: observedInstance?.stateDirectory?.path
                    ?? previous?.stateDirectory,
                bucketName: observedInstance?.actualBucketName
                    ?? previous?.bucketName,
                lastSeenAt: snapshot.generatedAt,
                lastSeenRunningAt: observedInstance?.isRunning == true
                    ? snapshot.generatedAt
                    : previous?.lastSeenRunningAt
            )

            if record != previous {
                recordsByPath[canonicalPath] = record
                changed = true
            }
        }

        if changed {
            try persist()
        }
    }

    public func remove(canonicalPath: String) throws {
        let path = URL(fileURLWithPath: canonicalPath).standardizedFileURL.path
        guard recordsByPath.removeValue(forKey: path) != nil else { return }
        try persist()
    }

    public func record(forPath path: String) -> WorktreeRegistryRecord? {
        recordsByPath[URL(fileURLWithPath: path).standardizedFileURL.path]
    }

    /// Restores a previously observed instance association after Town has
    /// cleanly stopped and removed its services marker.
    ///
    /// Instance numbers are reusable, so a registry record is considered only
    /// when no current worktree or running orphan claims the number and exactly
    /// one registered worktree wants it. The exact state path and bucket were
    /// captured from a high-confidence live observation; neither is guessed
    /// from the number alone.
    public func enrich(snapshot: TownSnapshot) -> TownSnapshot {
        let observedNumbers = Set<Int>(snapshot.worktrees.compactMap { worktree -> Int? in
            guard let instance = worktree.instance,
                  instance.confidence.rank >= AttributionConfidence.high.rank
            else {
                return nil
            }
            return instance.number
        })
        let runningOrphanNumbers = Set<Int>(snapshot.orphans.compactMap { orphan -> Int? in
            guard orphan.confidence.rank >= AttributionConfidence.high.rank,
                  !orphan.processes.isEmpty || orphan.services.contains(where: {
                      $0.state == .running || $0.state == .degraded
                  })
            else {
                return nil
            }
            return orphan.instanceNumber
        })

        var candidatesByNumber: [Int: [(Int, WorktreeRegistryRecord)]] = [:]
        for (index, worktree) in snapshot.worktrees.enumerated()
            where worktree.instance == nil
        {
            let path = canonicalPath(worktree.path)
            guard let record = recordsByPath[path],
                  let number = record.instanceNumber,
                  (1...9).contains(number),
                  !observedNumbers.contains(number),
                  !runningOrphanNumbers.contains(number)
            else {
                continue
            }
            candidatesByNumber[number, default: []].append((index, record))
        }

        var worktrees = snapshot.worktrees
        var restoredStatePaths = Set<String>()
        var restoredNumbers = Set<Int>()
        for (number, candidates) in candidatesByNumber where candidates.count == 1 {
            let (index, record) = candidates[0]
            let worktree = worktrees[index]
            let state = restoredState(
                record: record,
                number: number,
                worktreePath: worktree.path,
                dormantStates: snapshot.dormantStates
            )
            if let state {
                restoredStatePaths.insert(canonicalPath(state.path))
            }
            restoredNumbers.insert(number)
            worktrees[index] = replacingInstance(
                in: worktree,
                with: InstanceSnapshot(
                    number: number,
                    confidence: .high,
                    evidence: [
                        "Town Sheriff previously observed this exact worktree, instance, state path, and bucket while it was live.",
                    ],
                    services: expectedServices(for: number),
                    processes: [],
                    stateDirectory: state,
                    actualBucketName: record.bucketName
                )
            )
        }

        let orphans = snapshot.orphans.filter { orphan in
            if orphan.kind == .dormantState,
               let path = orphan.stateDirectory?.path,
               restoredStatePaths.contains(canonicalPath(path)) {
                return false
            }
            if orphan.kind == .staleDocker,
               let number = orphan.instanceNumber,
               restoredNumbers.contains(number) {
                return false
            }
            return true
        }
        let dormantStates = snapshot.dormantStates.filter {
            !restoredStatePaths.contains(canonicalPath($0.path))
        }

        return TownSnapshot(
            generatedAt: snapshot.generatedAt,
            repositoryPath: snapshot.repositoryPath,
            worktrees: worktrees,
            orphans: orphans,
            sharedServices: snapshot.sharedServices,
            dormantStates: dormantStates,
            warnings: snapshot.warnings
        )
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let payload = recordsByPath.values.sorted {
            $0.canonicalPath < $1.canonicalPath
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: fileURL, options: [.atomic])
    }

    private func restoredState(
        record: WorktreeRegistryRecord,
        number: Int,
        worktreePath: String,
        dormantStates: [StateDirectorySnapshot]
    ) -> StateDirectorySnapshot? {
        guard let rawPath = record.stateDirectory else { return nil }
        let path = canonicalPath(rawPath)
        let convexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".convex", isDirectory: true)
            .standardizedFileURL.path
        guard path.hasPrefix(convexRoot + "/local-backend-"),
              TownStateDirectoryParser.parse(path: path)?.instanceNumber == number
        else {
            return nil
        }

        let observed = dormantStates.first { canonicalPath($0.path) == path }
        return StateDirectorySnapshot(
            path: path,
            instanceNumber: number,
            sizeBytes: observed?.sizeBytes ?? 0,
            modifiedAt: observed?.modifiedAt,
            isRunning: false,
            associatedWorktreePath: canonicalPath(worktreePath),
            confidence: .high
        )
    }

    private func replacingInstance(
        in worktree: WorktreeSnapshot,
        with instance: InstanceSnapshot
    ) -> WorktreeSnapshot {
        WorktreeSnapshot(
            path: worktree.path,
            head: worktree.head,
            branch: worktree.branch,
            isDetached: worktree.isDetached,
            isPrimary: worktree.isPrimary,
            isLocked: worktree.isLocked,
            isPrunable: worktree.isPrunable,
            gitStatus: worktree.gitStatus,
            instance: instance,
            health: worktree.health,
            setupComplete: worktree.setupComplete
        )
    }

    private func expectedServices(for number: Int) -> [ServiceSnapshot] {
        let services: [(ServiceKind, Int)] = [
            (.frontend, 3_000 + number * 10),
            (.electric, 3_090 + number * 10),
            (.convexBackend, 3_210 + number * 10),
            (.convexSiteProxy, 3_211 + number * 10),
            (.harness, 4_000 + number * 10),
            (.drizzleStudio, 4_983 + number * 10),
            (.convexDashboard, 6_790 + number * 10),
        ]
        return services.map { kind, port in
            ServiceSnapshot(
                kind: kind,
                port: port,
                state: .stopped,
                url: kind.isBrowserTarget ? URL(string: "http://localhost:\(port)") : nil
            )
        }
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func load(from url: URL) -> [String: WorktreeRegistryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode(
            [WorktreeRegistryRecord].self,
            from: data
        ) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map {
            ($0.canonicalPath, $0)
        })
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Town Dock", isDirectory: true)
            .appendingPathComponent("registry.json", isDirectory: false)
    }
}
