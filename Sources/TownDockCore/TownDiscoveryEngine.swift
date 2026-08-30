@preconcurrency import Foundation

private enum TownPorts {
    static let maximumInstance = 9
    static let multiplier = 10

    static func frontend(_ n: Int) -> Int { 3_000 + multiplier * n }
    static func electric(_ n: Int) -> Int { 3_090 + multiplier * n }
    static func convexBackend(_ n: Int) -> Int { 3_210 + multiplier * n }
    static func convexSiteProxy(_ n: Int) -> Int { 3_211 + multiplier * n }
    static func harness(_ n: Int) -> Int { 4_000 + multiplier * n }
    static func drizzle(_ n: Int) -> Int { 4_983 + multiplier * n }
    static func dashboard(_ n: Int) -> Int { 6_790 + multiplier * n }

    static let shared: [(ServiceKind, Int)] = [
        (.postgres, 5_433),
        (.temporalGRPC, 7_233),
        (.temporalUI, 8_233),
        (.minioAPI, 9_000),
        (.minioConsole, 9_001),
        (.jaegerUI, 16_686),
        (.otlpGRPC, 4_317),
        (.otlpHTTP, 4_318),
    ]

    static func services(_ n: Int) -> [(ServiceKind, Int)] {
        [
            (.frontend, frontend(n)),
            (.electric, electric(n)),
            (.convexBackend, convexBackend(n)),
            (.convexSiteProxy, convexSiteProxy(n)),
            (.harness, harness(n)),
            (.drizzleStudio, drizzle(n)),
            (.convexDashboard, dashboard(n)),
        ]
    }

    static func instance(for port: Int) -> Int? {
        for n in 1...maximumInstance where services(n).contains(where: { $0.1 == port }) {
            return n
        }
        return nil
    }
}

private struct DockerInventory: Sendable {
    let containers: [DockerContainerRecord]
    let volumes: [DockerVolumeRecord]
}

private final class DiscoveryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stateSizes: [String: UInt64] = [:]
    private var stateSizesUpdatedAt: Date?
    private var stateSizesRefreshing = false
    private var fullFilesByIdentity: [String: ProcessFileEvidence] = [:]
    private var fullFilesUpdatedAt: Date?
    private var fullFilesRefreshing = false
    private var dockerInventory: DockerInventory?
    private var dockerUpdatedAt: Date?
    private var dockerRefreshing = false

    func stateSizeSnapshot(now: Date, interval: TimeInterval) -> ([String: UInt64], Bool) {
        lock.lock()
        defer { lock.unlock() }
        let stale = stateSizesUpdatedAt.map { now.timeIntervalSince($0) >= interval } ?? true
        let refresh = stale && !stateSizesRefreshing
        if refresh { stateSizesRefreshing = true }
        return (stateSizes, refresh)
    }

    func finishStateSizes(_ sizes: [String: UInt64]) {
        lock.lock()
        stateSizes = sizes
        stateSizesUpdatedAt = Date()
        stateSizesRefreshing = false
        lock.unlock()
    }

    func fullFileSnapshot(now: Date, interval: TimeInterval) -> ([String: ProcessFileEvidence], Bool) {
        lock.lock()
        defer { lock.unlock() }
        let stale = fullFilesUpdatedAt.map { now.timeIntervalSince($0) >= interval } ?? true
        let refresh = stale && !fullFilesRefreshing
        if refresh { fullFilesRefreshing = true }
        return (fullFilesByIdentity, refresh)
    }

    func finishFullFiles(_ files: [String: ProcessFileEvidence]) {
        lock.lock()
        fullFilesByIdentity = files
        fullFilesUpdatedAt = Date()
        fullFilesRefreshing = false
        lock.unlock()
    }

    func dockerSnapshot(
        now: Date,
        interval: TimeInterval
    ) -> (inventory: DockerInventory?, shouldRefresh: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let stale = dockerUpdatedAt.map { now.timeIntervalSince($0) >= interval } ?? true
        let refresh = stale && !dockerRefreshing
        if refresh { dockerRefreshing = true }
        return (dockerInventory, refresh)
    }

    func finishDocker(_ inventory: DockerInventory) {
        lock.lock()
        dockerInventory = inventory
        dockerUpdatedAt = Date()
        dockerRefreshing = false
        lock.unlock()
    }
}

private struct WorktreeScan {
    let record: GitWorktreeRecord
    let status: GitStatusSnapshot
    let markerInstance: Int?
    let markerStatePath: String?
    let markerBucketName: String?
    let configuredInstance: Int?
    let health: HealthSnapshot?
    let setupComplete: Bool
}

private struct InstanceAttribution {
    var number: Int
    var confidence: AttributionConfidence
    var evidence: [String]
}

/// Discovers Town worktrees and their local runtime without invoking any Town
/// scripts. The expensive open-file and recursive-size inventories are warmed
/// in the background and cached, allowing a UI to request lightweight snapshots
/// every few seconds.
public final class TownDiscoveryEngine: @unchecked Sendable {
    public let repositoryPath: String

    private let runner: CommandRunner
    private let fileManager: FileManager
    private let cache = DiscoveryCache()

    public init(repositoryPath: String) {
        self.repositoryPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        self.runner = CommandRunner()
        self.fileManager = .default
    }

    public init(repositoryPath: String, runner: CommandRunner) {
        self.repositoryPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        self.runner = runner
        self.fileManager = .default
    }

    public func snapshot() async throws -> TownSnapshot {
        try await Task.detached(priority: .userInitiated) { [self] in
            try snapshotSynchronously()
        }.value
    }

    private func snapshotSynchronously() throws -> TownSnapshot {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: repositoryPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw TownDockError.repositoryNotFound("Town repository is unavailable at \(repositoryPath).")
        }

        let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
        let worktreeOutput: CommandResult
        do {
            worktreeOutput = try runner.run(
                .git,
                arguments: ["worktree", "list", "--porcelain"],
                workingDirectory: repositoryURL,
                timeout: 5,
                maxOutputBytes: 2 * 1_024 * 1_024
            )
        } catch {
            throw TownDockError.repositoryNotFound("Could not inspect Town's Git worktrees.")
        }

        let records = GitWorktreePorcelainParser.parse(worktreeOutput.stdout)
        guard !records.isEmpty else {
            throw TownDockError.repositoryNotFound("No Town Git worktrees were found.")
        }

        var warnings: [String] = []
        let primaryPath = records.first?.path
        let scans = scanWorktrees(records, warnings: &warnings)
        let listeners = scanListeners(warnings: &warnings)
        let psRecords = scanProcesses(warnings: &warnings)
        let processByPID = Dictionary(uniqueKeysWithValues: psRecords.map { ($0.pid, $0) })
        let candidatePIDs = candidateProcessIDs(
            processes: psRecords,
            listeners: listeners,
            worktreePaths: scans.map(\.record.path)
        )

        let lightweightFiles = scanProcessFiles(
            pids: candidatePIDs,
            descriptors: "cwd,txt",
            timeoutPerChunk: 2,
            maxOutputBytesPerChunk: 512 * 1_024
        )
        let fullFiles = cachedFullFileEvidence(
            candidates: candidatePIDs,
            processByPID: processByPID
        )
        let fileEvidence = mergeFileEvidence(lightweight: lightweightFiles, cachedFull: fullFiles)
        let identities = makeProcessIdentities(
            records: psRecords,
            candidatePIDs: candidatePIDs,
            evidence: fileEvidence
        )
        let identityByPID = Dictionary(uniqueKeysWithValues: identities.map { ($0.pid, $0) })

        var attributions = scans.map {
            attribution(
                for: $0,
                listeners: listeners,
                processByPID: processByPID,
                fileEvidence: fileEvidence
            )
        }
        downgradeDuplicateAttributions(&attributions)

        let stateDirectories = scanStateDirectories(
            listeners: listeners,
            worktreeScans: scans,
            attributions: attributions,
            fileEvidence: fileEvidence
        )
        let listenersByPort = Dictionary(grouping: listeners, by: \.port)
        let docker = scanDockerInventory(warnings: &warnings)

        var worktrees: [WorktreeSnapshot] = []
        for (index, scan) in scans.enumerated() {
            let attribution = attributions[index]
            let instance: InstanceSnapshot?
            if let attribution {
                let processes = relatedProcesses(
                    worktreePath: scan.record.path,
                    statePath: scan.markerStatePath,
                    instance: attribution.number,
                    listeners: listeners,
                    processByPID: processByPID,
                    fileEvidence: fileEvidence,
                    identities: identityByPID
                )
                let services = makeServices(
                    instance: attribution.number,
                    listenersByPort: listenersByPort,
                    processByPID: processByPID,
                    docker: docker
                )
                instance = InstanceSnapshot(
                    number: attribution.number,
                    confidence: attribution.confidence,
                    evidence: attribution.evidence,
                    services: services,
                    processes: processes,
                    stateDirectory: stateDirectories.first {
                        $0.associatedWorktreePath == scan.record.path
                    },
                    actualBucketName: scan.markerBucketName
                )
            } else {
                instance = nil
            }

            worktrees.append(
                WorktreeSnapshot(
                    path: scan.record.path,
                    head: scan.record.head,
                    branch: scan.record.branch,
                    isDetached: scan.record.isDetached,
                    isPrimary: scan.record.path == primaryPath,
                    isLocked: scan.record.isLocked,
                    isPrunable: scan.record.isPrunable,
                    gitStatus: scan.status,
                    instance: instance,
                    health: scan.health,
                    setupComplete: scan.setupComplete
                )
            )
        }

        let orphans = makeOrphans(
            worktreeScans: scans,
            attributions: attributions,
            listeners: listeners,
            processByPID: processByPID,
            fileEvidence: fileEvidence,
            identities: identityByPID,
            stateDirectories: stateDirectories,
            docker: docker
        )
        // A live but unclaimed backend is an orphaned stack, not dormant
        // storage. Registry enrichment later removes stopped state that is
        // still provably associated with a current worktree.
        let dormantStates = stateDirectories.filter { !$0.isRunning }

        return TownSnapshot(
            repositoryPath: repositoryPath,
            worktrees: worktrees.sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return (lhs.branch ?? lhs.path).localizedStandardCompare(rhs.branch ?? rhs.path) == .orderedAscending
            },
            orphans: orphans,
            sharedServices: makeSharedServices(
                listenersByPort: listenersByPort,
                processByPID: processByPID,
                docker: docker
            ),
            dormantStates: dormantStates.sorted {
                ($0.instanceNumber ?? Int.max) < ($1.instanceNumber ?? Int.max)
            },
            warnings: Array(Set(warnings.map { SecretRedactor.redact($0, maximumLength: 512) })).sorted()
        )
    }

    private func scanWorktrees(
        _ records: [GitWorktreeRecord],
        warnings: inout [String]
    ) -> [WorktreeScan] {
        var scans: [WorktreeScan] = []
        for record in records {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: record.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                // Worktrees can disappear between Git's list and this loop.
                warnings.append("A registered worktree disappeared during refresh.")
                continue
            }
            let url = URL(fileURLWithPath: record.path, isDirectory: true)
            let status: GitStatusSnapshot
            do {
                let result = try runner.run(
                    .git,
                    arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=normal"],
                    workingDirectory: url,
                    timeout: 4,
                    maxOutputBytes: 4 * 1_024 * 1_024
                )
                status = GitStatusPorcelainV2Parser.parse(result.stdout)
            } catch {
                status = GitStatusSnapshot()
                warnings.append("Git status was unavailable for one worktree.")
            }

            let marker = parseServicesMarker(
                readBoundedFile(url.appendingPathComponent(".local-convex-services.md"), limit: 128 * 1_024)
            )
            let configured = parseConfiguredInstance(
                readBoundedFile(url.appendingPathComponent("mise.local.toml"), limit: 128 * 1_024)
            ) ?? parseConfiguredInstance(
                readBoundedFile(url.appendingPathComponent(".mise.local.toml"), limit: 128 * 1_024)
            )
            let health = readTail(
                url.appendingPathComponent("logs/stack-health.jsonl"),
                limit: 512 * 1_024
            ).flatMap(TownHealthJSONLParser.parse)
            let setup = fileManager.fileExists(
                atPath: url.appendingPathComponent("logs/.worktree-setup-complete").path
            )
            scans.append(
                WorktreeScan(
                    record: record,
                    status: status,
                    markerInstance: marker.instance,
                    markerStatePath: marker.statePath,
                    markerBucketName: marker.bucketName,
                    configuredInstance: configured,
                    health: health,
                    setupComplete: setup
                )
            )
        }
        return scans
    }

    private func scanListeners(warnings: inout [String]) -> [ListenerRecord] {
        do {
            let result = try runner.run(
                .lsof,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"],
                timeout: 4,
                maxOutputBytes: 4 * 1_024 * 1_024,
                allowedExitCodes: [0, 1]
            )
            return LSOFListenerParser.parse(result.stdout)
        } catch {
            warnings.append("Listening-port inventory is unavailable.")
            return []
        }
    }

    private func scanProcesses(warnings: inout [String]) -> [PSProcessRecord] {
        do {
            let result = try runner.run(
                .ps,
                arguments: ["-axo", "pid=,ppid=,pgid=,lstart=,pcpu=,rss=,command="],
                timeout: 4,
                maxOutputBytes: 8 * 1_024 * 1_024
            )
            return PSMetadataParser.parse(result.stdout)
        } catch {
            warnings.append("Process metadata is unavailable.")
            return []
        }
    }

    private func candidateProcessIDs(
        processes: [PSProcessRecord],
        listeners: [ListenerRecord],
        worktreePaths: [String]
    ) -> [Int32] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var selected = Set(listeners.map(\.pid))
        let townTerms = [
            "local-convex", "local-stack", "stack-health", "--instance-name instance-",
            "harness-electric", "convex-local-backend", "scripts/dev", "next-server",
            ".convex/local-backend-instance-",
        ]
        for process in processes {
            let lower = process.command.lowercased()
            if townTerms.contains(where: { lower.contains($0) }) ||
                worktreePaths.contains(where: { process.command.contains($0) }) {
                selected.insert(process.pid)
            }
        }

        // Include bounded ancestry and descendants. This picks up launch wrappers
        // while protecting the scanner from malformed/cyclic process metadata.
        for seed in Array(selected) {
            var cursor = seed
            var seen = Set<Int32>()
            for _ in 0..<12 {
                guard let process = byPID[cursor],
                      process.parentPID > 1,
                      seen.insert(process.parentPID).inserted
                else {
                    break
                }
                selected.insert(process.parentPID)
                cursor = process.parentPID
            }
        }
        let children = Dictionary(grouping: processes, by: \.parentPID)
        var queue = Array(selected)
        while let pid = queue.popLast(), selected.count < 512 {
            for child in children[pid, default: []] where selected.insert(child.pid).inserted {
                queue.append(child.pid)
            }
        }
        return Array(selected.sorted().prefix(512))
    }

    private func scanProcessFiles(
        pids: [Int32],
        descriptors: String?,
        timeoutPerChunk: TimeInterval,
        maxOutputBytesPerChunk: Int
    ) -> [ProcessFileEvidence] {
        guard !pids.isEmpty else { return [] }
        var result: [ProcessFileEvidence] = []
        for chunkStart in stride(from: 0, to: pids.count, by: 64) {
            let chunk = pids[chunkStart..<min(chunkStart + 64, pids.count)]
            var arguments = ["-nP", "-a", "-p", chunk.map(String.init).joined(separator: ",")]
            if let descriptors {
                arguments.append(contentsOf: ["-d", descriptors])
            }
            arguments.append(contentsOf: ["-F", "pfn"])
            guard let output = try? runner.run(
                .lsof,
                arguments: arguments,
                timeout: timeoutPerChunk,
                maxOutputBytes: maxOutputBytesPerChunk,
                allowedExitCodes: [0, 1]
            ) else {
                continue
            }
            result.append(contentsOf: LSOFProcessFileParser.parse(output.stdout))
        }
        return Array(mergeFileEvidence(lightweight: result, cachedFull: []).values)
    }

    private func cachedFullFileEvidence(
        candidates: [Int32],
        processByPID: [Int32: PSProcessRecord]
    ) -> [ProcessFileEvidence] {
        let (cached, shouldRefresh) = cache.fullFileSnapshot(now: Date(), interval: 45)
        if shouldRefresh {
            let runner = self.runner
            let cache = self.cache
            let identities = processByPID
            Task.detached(priority: .utility) {
                var files: [ProcessFileEvidence] = []
                for chunkStart in stride(from: 0, to: candidates.count, by: 32) {
                    let chunk = candidates[chunkStart..<min(chunkStart + 32, candidates.count)]
                    let arguments = [
                        "-nP", "-a", "-p", chunk.map(String.init).joined(separator: ","),
                        "-F", "pfn",
                    ]
                    guard let output = try? runner.run(
                        .lsof,
                        arguments: arguments,
                        timeout: 3,
                        maxOutputBytes: 1 * 1_024 * 1_024,
                        allowedExitCodes: [0, 1]
                    ) else {
                        continue
                    }
                    files.append(contentsOf: LSOFProcessFileParser.parse(output.stdout))
                }
                let merged = Self.mergeFileEvidenceStatic(files)
                var keyed: [String: ProcessFileEvidence] = [:]
                for evidence in merged {
                    guard let process = identities[evidence.pid] else { continue }
                    keyed["\(evidence.pid)-\(process.startToken)"] = evidence
                }
                cache.finishFullFiles(keyed)
            }
        }
        return cached.compactMap { key, evidence in
            guard let process = processByPID[evidence.pid],
                  key == "\(evidence.pid)-\(process.startToken)"
            else {
                return nil
            }
            return evidence
        }
    }

    private func mergeFileEvidence(
        lightweight: [ProcessFileEvidence],
        cachedFull: [ProcessFileEvidence]
    ) -> [Int32: ProcessFileEvidence] {
        let merged = Self.mergeFileEvidenceStatic(cachedFull + lightweight)
        return Dictionary(uniqueKeysWithValues: merged.map { ($0.pid, $0) })
    }

    private static func mergeFileEvidenceStatic(_ evidence: [ProcessFileEvidence]) -> [ProcessFileEvidence] {
        let grouped = Dictionary(grouping: evidence, by: \.pid)
        return grouped.map { pid, values in
            ProcessFileEvidence(
                pid: pid,
                workingDirectory: values.compactMap(\.workingDirectory).last,
                executablePath: values.compactMap(\.executablePath).last,
                openPaths: Array(Set(values.flatMap(\.openPaths))).sorted()
            )
        }
    }

    private func makeProcessIdentities(
        records: [PSProcessRecord],
        candidatePIDs: [Int32],
        evidence: [Int32: ProcessFileEvidence]
    ) -> [ProcessIdentity] {
        let wanted = Set(candidatePIDs)
        return records.filter { wanted.contains($0.pid) }.map { record in
            ProcessIdentity(
                pid: record.pid,
                parentPID: record.parentPID,
                processGroupID: record.processGroupID,
                startToken: record.startToken,
                command: record.command,
                executablePath: evidence[record.pid]?.executablePath,
                workingDirectory: evidence[record.pid]?.workingDirectory,
                residentBytes: record.residentBytes,
                cpuPercent: record.cpuPercent
            )
        }
    }

    private func attribution(
        for scan: WorktreeScan,
        listeners: [ListenerRecord],
        processByPID: [Int32: PSProcessRecord],
        fileEvidence: [Int32: ProcessFileEvidence]
    ) -> InstanceAttribution? {
        if let marker = scan.markerInstance, (1...TownPorts.maximumInstance).contains(marker) {
            return InstanceAttribution(
                number: marker,
                confidence: .certain,
                evidence: ["Town services marker names instance \(marker)."]
            )
        }
        if let configured = scan.configuredInstance,
           (1...TownPorts.maximumInstance).contains(configured) {
            return InstanceAttribution(
                number: configured,
                confidence: .high,
                evidence: ["Checkout-local Mise configuration names instance \(configured)."]
            )
        }

        var scores: [Int: (AttributionConfidence, Set<String>)] = [:]
        for listener in listeners {
            guard let n = TownPorts.instance(for: listener.port) else { continue }
            let evidence = pathEvidence(
                pid: listener.pid,
                worktreePath: scan.record.path,
                processByPID: processByPID,
                fileEvidence: fileEvidence
            )
            guard let evidence else { continue }
            var current = scores[n] ?? (.ambiguous, [])
            if evidence.0.rank > current.0.rank { current.0 = evidence.0 }
            current.1.insert(evidence.1)
            scores[n] = current
        }
        guard let best = scores.sorted(by: { lhs, rhs in
            if lhs.value.0.rank != rhs.value.0.rank { return lhs.value.0.rank > rhs.value.0.rank }
            return lhs.key < rhs.key
        }).first else {
            return nil
        }
        let ties = scores.values.filter { $0.0.rank == best.value.0.rank }.count
        return InstanceAttribution(
            number: best.key,
            confidence: ties > 1 ? .ambiguous : best.value.0,
            evidence: Array(best.value.1).sorted()
        )
    }

    private func downgradeDuplicateAttributions(_ attributions: inout [InstanceAttribution?]) {
        let grouped = Dictionary(grouping: attributions.indices.compactMap { index -> (Int, Int)? in
            guard let number = attributions[index]?.number else { return nil }
            return (number, index)
        }, by: { $0.0 })
        for (number, entries) in grouped where entries.count > 1 {
            for (_, index) in entries {
                attributions[index]?.confidence = .ambiguous
                attributions[index]?.evidence.append(
                    "Instance \(number) is also claimed by another live worktree."
                )
            }
        }
    }

    private func pathEvidence(
        pid: Int32,
        worktreePath: String,
        processByPID: [Int32: PSProcessRecord],
        fileEvidence: [Int32: ProcessFileEvidence]
    ) -> (AttributionConfidence, String)? {
        var cursor: Int32? = pid
        var seen = Set<Int32>()
        for depth in 0..<12 {
            guard let current = cursor,
                  seen.insert(current).inserted,
                  let process = processByPID[current]
            else {
                break
            }
            if let cwd = fileEvidence[current]?.workingDirectory,
               path(cwd, belongsTo: worktreePath) {
                return (
                    depth == 0 ? .certain : .high,
                    depth == 0
                        ? "A listener's working directory is this worktree."
                        : "A listener ancestor's working directory is this worktree."
                )
            }
            if fileEvidence[current]?.openPaths.contains(where: { path($0, belongsTo: worktreePath) }) == true {
                return (.high, "A listener process has an open file in this worktree.")
            }
            if process.command.contains(worktreePath) {
                return (.inferred, "A listener process references this worktree path.")
            }
            cursor = process.parentPID > 1 ? process.parentPID : nil
        }
        return nil
    }

    private func relatedProcesses(
        worktreePath: String,
        statePath: String?,
        instance: Int,
        listeners: [ListenerRecord],
        processByPID: [Int32: PSProcessRecord],
        fileEvidence: [Int32: ProcessFileEvidence],
        identities: [Int32: ProcessIdentity]
    ) -> [ProcessIdentity] {
        let ports = Set(TownPorts.services(instance).map(\.1))
        let roots = [worktreePath, statePath].compactMap { $0 }
        let candidateListeners = Set(listeners.filter { ports.contains($0.port) }.map(\.pid))

        func hasOwnedPath(_ pid: Int32) -> Bool {
            guard let process = processByPID[pid] else { return false }
            return roots.contains { root in
                fileEvidence[pid]?.workingDirectory.map { path($0, belongsTo: root) } == true
                    || fileEvidence[pid]?.openPaths.contains(where: { path($0, belongsTo: root) }) == true
                    || process.command.contains(root)
            }
        }

        // Expected port numbers alone are not ownership. Anchor a tree only
        // when the listener or its ancestry has exact path/instance evidence.
        var selected = Set<Int32>()
        for listenerPID in candidateListeners {
            var cursor: Int32? = listenerPID
            var chain: [Int32] = []
            var anchored = false
            var seen = Set<Int32>()
            for _ in 0..<16 {
                guard let pid = cursor,
                      seen.insert(pid).inserted,
                      let process = processByPID[pid]
                else {
                    break
                }
                let ownsPath = hasOwnedPath(pid)
                let ownsInstance = command(process.command, hasInstance: instance)
                guard ownsPath || ownsInstance else { break }
                chain.append(pid)
                anchored = true
                if TownProcessClassifier.isLifecycleLauncher(process.command) {
                    break
                }
                cursor = process.parentPID > 1 ? process.parentPID : nil
            }
            if anchored { selected.formUnion(chain) }
        }

        // Keep the sanctioned launcher even while its children are still
        // starting and have not bound their ports yet.
        for (pid, process) in processByPID
            where hasOwnedPath(pid) && TownProcessClassifier.isLifecycleLauncher(process.command)
        {
            selected.insert(pid)
        }

        // Watchers and workers often have neither an instance flag nor a
        // listener. Include only descendants of the verified anchors above.
        let children = Dictionary(grouping: processByPID.values, by: \.parentPID)
        var queue = Array(selected)
        while let pid = queue.popLast(), selected.count < 512 {
            for child in children[pid, default: []] where selected.insert(child.pid).inserted {
                queue.append(child.pid)
            }
        }
        return selected.compactMap { identities[$0] }.sorted { $0.pid < $1.pid }
    }

    private func makeServices(
        instance: Int,
        listenersByPort: [Int: [ListenerRecord]],
        processByPID: [Int32: PSProcessRecord],
        docker: DockerInventory
    ) -> [ServiceSnapshot] {
        TownPorts.services(instance).map { kind, port in
            let records = listenersByPort[port, default: []]
            let metrics = serviceMetrics(
                port: port,
                listeners: records,
                processByPID: processByPID,
                docker: docker
            )
            return ServiceSnapshot(
                kind: kind,
                port: port,
                state: records.isEmpty ? .stopped : .running,
                url: browserURL(kind: kind, port: port),
                processIDs: Array(Set(records.map(\.pid))).sorted(),
                detail: nil,
                isShared: false,
                cpuPercent: metrics?.cpuPercent,
                residentBytes: metrics?.residentBytes,
                metricsIdentity: metrics?.identity
            )
        }
    }

    private func makeSharedServices(
        listenersByPort: [Int: [ListenerRecord]],
        processByPID: [Int32: PSProcessRecord],
        docker: DockerInventory
    ) -> [ServiceSnapshot] {
        TownPorts.shared.map { kind, port in
            let records = listenersByPort[port, default: []]
            let metrics = serviceMetrics(
                port: port,
                listeners: records,
                processByPID: processByPID,
                docker: docker
            )
            return ServiceSnapshot(
                kind: kind,
                port: port,
                state: records.isEmpty ? .stopped : .running,
                url: browserURL(kind: kind, port: port),
                processIDs: Array(Set(records.map(\.pid))).sorted(),
                detail: nil,
                isShared: true,
                cpuPercent: metrics?.cpuPercent,
                residentBytes: metrics?.residentBytes,
                metricsIdentity: metrics?.identity
            )
        }
    }

    private func serviceMetrics(
        port: Int,
        listeners: [ListenerRecord],
        processByPID: [Int32: PSProcessRecord],
        docker: DockerInventory
    ) -> (cpuPercent: Double, residentBytes: UInt64, identity: String?)? {
        if let container = docker.containers.first(where: {
            $0.publishedPorts.contains(port) && $0.cpuPercent != nil && $0.residentBytes != nil
        }), let cpuPercent = container.cpuPercent, let residentBytes = container.residentBytes {
            let identity = container.id.isEmpty
                ? "docker-name:\(container.name.lowercased())"
                : "docker:\(container.id.lowercased())"
            return (cpuPercent, residentBytes, identity)
        }

        let processes = Set(listeners.map(\.pid)).compactMap { processByPID[$0] }
        guard !processes.isEmpty else { return nil }
        let residentBytes = processes.reduce(UInt64(0)) { total, process in
            let (sum, overflow) = total.addingReportingOverflow(process.residentBytes)
            return overflow ? UInt64.max : sum
        }
        return (
            cpuPercent: processes.reduce(0) { $0 + $1.cpuPercent },
            residentBytes: residentBytes,
            identity: nil
        )
    }

    private func browserURL(kind: ServiceKind, port: Int) -> URL? {
        guard kind.isBrowserTarget else { return nil }
        return URL(string: "http://localhost:\(port)")
    }

    private func scanStateDirectories(
        listeners: [ListenerRecord],
        worktreeScans: [WorktreeScan],
        attributions: [InstanceAttribution?],
        fileEvidence: [Int32: ProcessFileEvidence]
    ) -> [StateDirectorySnapshot] {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".convex", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let descriptors = urls.compactMap { TownStateDirectoryParser.parse(path: $0.path) }
        let paths = descriptors.map(\.path)
        let (sizes, shouldRefresh) = cache.stateSizeSnapshot(now: Date(), interval: 120)
        if shouldRefresh {
            let runner = self.runner
            let cache = self.cache
            Task.detached(priority: .utility) {
                guard !paths.isEmpty,
                      let result = try? runner.run(
                          .du,
                          arguments: ["-sk"] + paths,
                          timeout: 25,
                          maxOutputBytes: 1 * 1_024 * 1_024,
                          allowedExitCodes: [0, 1]
                      )
                else {
                    cache.finishStateSizes([:])
                    return
                }
                cache.finishStateSizes(TownStateDirectoryParser.parseDUKilobytes(result.stdout))
            }
        }

        let runningPorts = Set(listeners.map(\.port))
        return descriptors.map { descriptor in
            // N alone is never ownership evidence: historical/corrupt state
            // directories can share an instance number. Prefer the exact path
            // recorded by the bounded services marker. For a running backend,
            // exact open-file evidence inside the state directory is also safe.
            var associated = worktreeScans.first(where: { scan in
                guard let markerPath = scan.markerStatePath else { return false }
                return normalizeDeletedPath(markerPath) == descriptor.path
            })?.record.path
            if associated == nil {
                let backendPIDs = listeners
                    .filter { $0.port == descriptor.backendPort }
                    .map(\.pid)
                let processOwnsState = backendPIDs.contains { pid in
                    fileEvidence[pid]?.workingDirectory.map {
                        path($0, belongsTo: descriptor.path)
                    } == true || fileEvidence[pid]?.openPaths.contains(where: {
                        path($0, belongsTo: descriptor.path)
                    }) == true
                }
                if processOwnsState {
                    let matchingWorktrees = attributions.indices.compactMap { index -> String? in
                        guard attributions[index]?.number == descriptor.instanceNumber else { return nil }
                        return worktreeScans[index].record.path
                    }
                    if matchingWorktrees.count == 1 { associated = matchingWorktrees[0] }
                }
            }
            let modified = try? URL(fileURLWithPath: descriptor.path)
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return StateDirectorySnapshot(
                path: descriptor.path,
                instanceNumber: descriptor.instanceNumber,
                sizeBytes: sizes[descriptor.path] ?? 0,
                modifiedAt: modified ?? nil,
                isRunning: runningPorts.contains(descriptor.backendPort),
                associatedWorktreePath: associated,
                confidence: associated == nil ? .ambiguous : .high
            )
        }
    }

    private func scanDockerInventory(warnings: inout [String]) -> DockerInventory {
        let (cached, shouldRefresh) = cache.dockerSnapshot(now: Date(), interval: 6)
        if let cached {
            if shouldRefresh {
                let runner = self.runner
                let cache = self.cache
                Task.detached(priority: .utility) {
                    let refreshed = (try? Self.loadDockerInventory(using: runner)) ?? cached
                    cache.finishDocker(refreshed)
                }
            }
            return cached
        }
        guard shouldRefresh else {
            return DockerInventory(containers: [], volumes: [])
        }
        do {
            let inventory = try Self.loadDockerInventory(using: runner)
            cache.finishDocker(inventory)
            return inventory
        } catch {
            warnings.append("Docker inventory is unavailable.")
            let empty = DockerInventory(containers: [], volumes: [])
            cache.finishDocker(empty)
            return empty
        }
    }

    private static func loadDockerInventory(using runner: CommandRunner) throws -> DockerInventory {
        let containers = try runner.run(
            .docker,
            arguments: ["ps", "-a", "--no-trunc", "--format", "{{json .}}"],
            timeout: 3,
            maxOutputBytes: 2 * 1_024 * 1_024
        )
        let volumes = try runner.run(
            .docker,
            arguments: ["volume", "ls", "--format", "{{json .}}"],
            timeout: 3,
            maxOutputBytes: 2 * 1_024 * 1_024
        )
        let parsedContainers = DockerInventoryParser.parseContainers(containers.stdout)
        let containersWithStats: [DockerContainerRecord]
        if let stats = try? runner.run(
            .docker,
            arguments: ["stats", "--no-stream", "--format", "{{json .}}"],
            timeout: 6,
            maxOutputBytes: 2 * 1_024 * 1_024
        ) {
            containersWithStats = DockerInventoryParser.addingStats(
                stats.stdout,
                to: parsedContainers
            )
        } else {
            containersWithStats = parsedContainers
        }
        return DockerInventory(
            containers: containersWithStats,
            volumes: DockerInventoryParser.parseVolumes(volumes.stdout)
        )
    }

    private func makeOrphans(
        worktreeScans: [WorktreeScan],
        attributions: [InstanceAttribution?],
        listeners: [ListenerRecord],
        processByPID: [Int32: PSProcessRecord],
        fileEvidence: [Int32: ProcessFileEvidence],
        identities: [Int32: ProcessIdentity],
        stateDirectories: [StateDirectorySnapshot],
        docker: DockerInventory
    ) -> [OrphanSnapshot] {
        let claimed = Set(attributions.compactMap(\.?.number))
        let livePaths = worktreeScans.map(\.record.path)
        let listenersByInstance = Dictionary(grouping: listeners.compactMap { listener -> (Int, ListenerRecord)? in
            TownPorts.instance(for: listener.port).map { ($0, listener) }
        }, by: { $0.0 })
        var orphans: [OrphanSnapshot] = []
        var orphanedPIDs = Set<Int32>()

        for (number, entries) in listenersByInstance.sorted(by: { $0.key < $1.key })
            where !claimed.contains(number) {
            let instanceListeners = entries.map(\.1)
            let pids = Set(instanceListeners.map(\.pid))
            let processes = orphanProcessTree(
                instance: number,
                listenerPIDs: pids,
                processByPID: processByPID,
                fileEvidence: fileEvidence,
                identities: identities
            )
            orphanedPIDs.formUnion(processes.map(\.pid))
            let repositoryName = URL(fileURLWithPath: repositoryPath).lastPathComponent
            let missing = processes.lazy.compactMap { process -> String? in
                let paths = [fileEvidence[process.pid]?.workingDirectory]
                    + (fileEvidence[process.pid]?.openPaths.map(Optional.some) ?? [])
                return paths.compactMap { $0 }.compactMap {
                    self.suspectedMissingWorktreeRoot(path: $0, repositoryName: repositoryName)
                }.first
            }.first
            let servicesByPort = Dictionary(grouping: instanceListeners, by: \.port)
            orphans.append(
                OrphanSnapshot(
                    id: "unclaimed-instance-\(number)",
                    kind: missing == nil ? .unclaimedInstance : .deletedWorktree,
                    title: missing == nil
                        ? "Unclaimed Town instance \(number)"
                        : "Deleted-worktree instance \(number)",
                    missingPath: missing,
                    instanceNumber: number,
                    confidence: missing == nil ? .high : .certain,
                    reasons: missing == nil
                        ? ["Town instance ports are listening, but no registered worktree claims them."]
                        : ["Town instance ports remain active after their working directory disappeared."],
                    processes: processes,
                    services: makeServices(
                        instance: number,
                        listenersByPort: servicesByPort,
                        processByPID: processByPID,
                        docker: docker
                    ),
                    stateDirectory: stateDirectories.first { state in
                        state.instanceNumber == number && pids.contains { pid in
                            fileEvidence[pid]?.workingDirectory.map {
                                path($0, belongsTo: state.path)
                            } == true || fileEvidence[pid]?.openPaths.contains(where: {
                                path($0, belongsTo: state.path)
                            }) == true
                        }
                    }
                )
            )
        }

        // Processes may survive without retaining a listening socket. CWD and
        // exact instance flags let us identify those without matching arbitrary
        // Node processes by name alone.
        var deletedGroups: [String: [ProcessIdentity]] = [:]
        for (pid, process) in processByPID where !orphanedPIDs.contains(pid) {
            guard let cwd = fileEvidence[pid]?.workingDirectory,
                  let root = suspectedMissingWorktreeRoot(
                      path: cwd,
                      repositoryName: URL(fileURLWithPath: repositoryPath).lastPathComponent
                  ),
                  !livePaths.contains(where: { path(root, belongsTo: $0) }),
                  process.command.contains("instance-") || process.command.lowercased().contains("town") ||
                    process.command.lowercased().contains("convex")
            else {
                continue
            }
            if let identity = identities[pid] {
                deletedGroups[root, default: []].append(identity)
            }
        }
        for (path, processes) in deletedGroups.sorted(by: { $0.key < $1.key }) {
            let numbers = Set(processes.compactMap { instanceNumber(from: $0.command) })
            orphans.append(
                OrphanSnapshot(
                    id: "deleted-worktree-\(stableID(path))",
                    kind: .deletedWorktree,
                    title: "Processes from a deleted Town worktree",
                    missingPath: path,
                    instanceNumber: numbers.count == 1 ? numbers.first : nil,
                    confidence: .high,
                    reasons: ["Processes retain a missing Town working directory."],
                    processes: processes.sorted { $0.pid < $1.pid }
                )
            )
        }

        for state in stateDirectories where state.associatedWorktreePath == nil && !state.isRunning {
            let stateProcesses = identities.values.filter { process in
                guard !orphanedPIDs.contains(process.pid),
                      !TownProcessClassifier.isSharedRuntimeHost(process.command),
                      let cwd = process.workingDirectory
                else {
                    return false
                }
                return path(cwd, belongsTo: state.path)
            }.sorted { $0.pid < $1.pid }
            orphanedPIDs.formUnion(stateProcesses.map(\.pid))
            orphans.append(
                OrphanSnapshot(
                    id: "dormant-state-\(stableID(state.path))",
                    kind: .dormantState,
                    title: state.instanceNumber.map { "Dormant state for instance \($0)" } ?? "Dormant Convex state",
                    missingPath: nil,
                    instanceNumber: state.instanceNumber,
                    confidence: .high,
                    reasons: stateProcesses.isEmpty
                        ? ["No active backend or registered worktree owns this state directory."]
                        : ["Detached Convex executor processes still hold this unclaimed state directory."],
                    processes: stateProcesses,
                    stateDirectory: state
                )
            )
        }

        let staleContainers = docker.containers.filter { container in
            let lower = container.name.lowercased()
            let townLike = lower.contains("harness") || lower.contains("electric") || lower.contains("town")
            let stopped = container.state.lowercased() != "running"
            return townLike && stopped && container.instanceNumber.map { !claimed.contains($0) } != false
        }
        let mountedVolumeNames = Set(docker.containers.flatMap(\.mountedVolumes))
        let staleVolumes = docker.volumes.filter { volume in
            let lower = volume.name.lowercased()
            let townLike = lower.contains("harness") || lower.contains("electric") || lower.contains("town")
            return townLike
                && !mountedVolumeNames.contains(volume.name)
                && volume.instanceNumber.map { !claimed.contains($0) } != false
        }
        let staleNumbers = Set(staleContainers.compactMap(\.instanceNumber) + staleVolumes.compactMap(\.instanceNumber))
        for number in staleNumbers.sorted() {
            let containers = staleContainers.filter { $0.instanceNumber == number }.map(\.name)
            let volumes = staleVolumes.filter { $0.instanceNumber == number }.map(\.name)
            let reasons = containers.map { "Stopped container: \($0)" } + volumes.map { "Unclaimed volume: \($0)" }
            orphans.append(
                OrphanSnapshot(
                    id: "stale-docker-\(number)",
                    kind: .staleDocker,
                    title: "Stale Docker resources for instance \(number)",
                    missingPath: nil,
                    instanceNumber: number,
                    confidence: .high,
                    reasons: reasons
                )
            )
        }

        return orphans.sorted { lhs, rhs in
            if (lhs.instanceNumber ?? Int.max) != (rhs.instanceNumber ?? Int.max) {
                return (lhs.instanceNumber ?? Int.max) < (rhs.instanceNumber ?? Int.max)
            }
            return lhs.title < rhs.title
        }
    }

    private func orphanProcessTree(
        instance: Int,
        listenerPIDs: Set<Int32>,
        processByPID: [Int32: PSProcessRecord],
        fileEvidence: [Int32: ProcessFileEvidence],
        identities: [Int32: ProcessIdentity]
    ) -> [ProcessIdentity] {
        let repositoryName = URL(fileURLWithPath: repositoryPath).lastPathComponent
        var selected = Set(listenerPIDs.filter { pid in
            processByPID[pid].map {
                !TownProcessClassifier.isSharedRuntimeHost($0.command)
            } == true
        })
        for (pid, process) in processByPID
            where command(process.command, hasInstance: instance)
                && !TownProcessClassifier.isSharedRuntimeHost(process.command)
        {
            selected.insert(pid)
        }

        var missingRoots = Set<String>()
        for pid in selected {
            let paths = [fileEvidence[pid]?.workingDirectory]
                + (fileEvidence[pid]?.openPaths.map(Optional.some) ?? [])
            for candidate in paths.compactMap({ $0 }) {
                if let root = suspectedMissingWorktreeRoot(
                    path: candidate,
                    repositoryName: repositoryName
                ) {
                    missingRoots.insert(root)
                }
            }
        }
        if !missingRoots.isEmpty {
            for (pid, process) in processByPID {
                let evidence = fileEvidence[pid]
                let belongsToMissingRoot = missingRoots.contains { root in
                    evidence?.workingDirectory.map { path($0, belongsTo: root) } == true
                        || evidence?.openPaths.contains(where: { path($0, belongsTo: root) }) == true
                        || process.command.contains(root)
                }
                if belongsToMissingRoot { selected.insert(pid) }
            }
        }

        // Include descendants of verified anchors (watchers and workers often
        // omit the instance flag) and only Town-shaped ancestors, stopping
        // before a terminal, editor, or coding-agent host can be swept in.
        let children = Dictionary(grouping: processByPID.values, by: \.parentPID)
        var queue = Array(selected)
        while let pid = queue.popLast(), selected.count < 512 {
            for child in children[pid, default: []]
                where !TownProcessClassifier.isSharedRuntimeHost(child.command)
                    && selected.insert(child.pid).inserted
            {
                queue.append(child.pid)
            }
        }
        let townTerms = ["local-stack", "local-convex-backend", "scripts/local-convex-backend"]
        for seed in Array(selected) {
            var cursor = processByPID[seed]?.parentPID
            var depth = 0
            while let pid = cursor, pid > 1, depth < 12,
                  let process = processByPID[pid]
            {
                let evidence = fileEvidence[pid]
                let belongsToMissingRoot = missingRoots.contains { root in
                    evidence?.workingDirectory.map { path($0, belongsTo: root) } == true
                        || evidence?.openPaths.contains(where: { path($0, belongsTo: root) }) == true
                        || process.command.contains(root)
                }
                let townShaped = !TownProcessClassifier.isSharedRuntimeHost(process.command)
                    && (townTerms.contains { process.command.lowercased().contains($0) }
                        || command(process.command, hasInstance: instance))
                guard !TownProcessClassifier.isSharedRuntimeHost(process.command),
                      belongsToMissingRoot || townShaped
                else { break }
                selected.insert(pid)
                cursor = process.parentPID
                depth += 1
            }
        }
        return selected.compactMap { identities[$0] }
            .filter { !TownProcessClassifier.isSharedRuntimeHost($0.command) }
            .sorted { $0.pid < $1.pid }
    }

    private struct ServicesMarker {
        let instance: Int?
        let statePath: String?
        let bucketName: String?
    }

    private func parseServicesMarker(_ text: String?) -> ServicesMarker {
        guard let text else { return ServicesMarker(instance: nil, statePath: nil, bucketName: nil) }
        let instance: Int?
        if
              let expression = try? NSRegularExpression(pattern: #"(?m)^\*Instance:\s*(\d+)\s*\|"#),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text),
              let number = Int(text[range]),
              (1...TownPorts.maximumInstance).contains(number)
        {
            instance = number
        } else {
            instance = nil
        }

        var statePath: String?
        if let instance,
           let expression = try? NSRegularExpression(
               pattern: #"(?m)^\*Instance:\s*\d+\s*\|\s*State:\s*([^*\r\n]+)\*?\s*$"#
           ),
           let match = expression.firstMatch(
               in: text,
               range: NSRange(text.startIndex..<text.endIndex, in: text)
           ),
           let range = Range(match.range(at: 1), in: text) {
            let candidate = String(text[range]).trimmingCharacters(in: .whitespaces)
            let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            let convexRoot = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".convex", isDirectory: true)
                .standardizedFileURL.path
            if normalized.hasPrefix(convexRoot + "/"),
               TownStateDirectoryParser.parse(path: normalized)?.instanceNumber == instance {
                statePath = normalized
            }
        }

        var bucketName: String?
        if let expression = try? NSRegularExpression(
            pattern: #"(?m)^S3_BUCKET_NAME=([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])\s*$"#
        ),
           let match = expression.firstMatch(
               in: text,
               range: NSRange(text.startIndex..<text.endIndex, in: text)
           ),
           let range = Range(match.range(at: 1), in: text) {
            let candidate = String(text[range])
            if let instance,
               candidate.hasSuffix("-\(instance)"),
               !candidate.contains(".."),
               candidate.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) == nil {
                bucketName = candidate
            }
        }
        return ServicesMarker(instance: instance, statePath: statePath, bucketName: bucketName)
    }

    private func parseConfiguredInstance(_ text: String?) -> Int? {
        guard let text,
              let expression = try? NSRegularExpression(
                  pattern: #"(?m)^\s*TOWN_INSTANCE_N\s*=\s*[\"']?(\d+)[\"']?\s*(?:#.*)?$"#
              ),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text),
              let number = Int(text[range]),
              (1...TownPorts.maximumInstance).contains(number)
        else {
            return nil
        }
        return number
    }

    private func readBoundedFile(_ url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func readTail(_ url: URL, limit: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > limit ? end - limit : 0
        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            return text
        } catch {
            return nil
        }
    }

    private func path(_ candidate: String, belongsTo root: String) -> Bool {
        let candidate = normalizeDeletedPath(candidate)
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func normalizeDeletedPath(_ value: String) -> String {
        let stripped = value.hasSuffix(" (deleted)") ? String(value.dropLast(" (deleted)".count)) : value
        return URL(fileURLWithPath: stripped).standardizedFileURL.path
    }

    private func suspectedMissingWorktreeRoot(path: String, repositoryName: String) -> String? {
        let normalized = normalizeDeletedPath(path)
        let components = URL(fileURLWithPath: normalized).pathComponents
        guard let index = components.lastIndex(of: repositoryName) else { return nil }
        let root = NSString.path(withComponents: Array(components.prefix(index + 1)))
        guard !fileManager.fileExists(atPath: root) else { return nil }
        return root
    }

    private func command(_ command: String, hasInstance number: Int) -> Bool {
        let flag = "--instance-name instance-\(number)"
        var search = command.startIndex
        while let range = command.range(of: flag, range: search..<command.endIndex) {
            let previous = range.lowerBound == command.startIndex ? nil : command[command.index(before: range.lowerBound)]
            let next = range.upperBound == command.endIndex ? nil : command[range.upperBound]
            if previous.map(\.isWhitespace) ?? true, next.map(\.isWhitespace) ?? true {
                return true
            }
            search = range.upperBound
        }
        return false
    }

    private func instanceNumber(from command: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: #"(?:^|\s)--instance-name\s+instance-(\d+)(?:\s|$)"#),
              let match = expression.firstMatch(
                  in: command,
                  range: NSRange(command.startIndex..<command.endIndex, in: command)
              ),
              let range = Range(match.range(at: 1), in: command)
        else {
            return nil
        }
        return Int(command[range])
    }

    private func stableID(_ value: String) -> String {
        // FNV-1a is deterministic across launches, unlike Swift's randomized Hashable.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
