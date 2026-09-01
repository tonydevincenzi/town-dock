import AppKit
import Combine
import Foundation
import TownDockCore

struct BulkNukeReview: Identifiable, Hashable {
    let worktree: WorktreeSnapshot
    let manifest: NukeManifest?
    let error: String?

    var id: String { worktree.id }
    var canExecute: Bool { manifest?.canExecute == true && error == nil }
}

@MainActor
final class TownStore: ObservableObject {
    static let shared = TownStore()

    @Published private(set) var snapshot: TownSnapshot
    @Published private(set) var isRefreshing = false
    @Published private(set) var activeOperations: Set<String> = []
    @Published private(set) var lastError: String?
    @Published private(set) var activityMessage: String?
    @Published private(set) var managedRuns: [ManagedRunRecord] = []

    @Published var logWorktree: WorktreeSnapshot?
    @Published private(set) var worktreeLogs: [WorktreeLogFile] = []
    @Published var selectedLogID: String?
    @Published private(set) var isRefreshingLogs = false
    @Published private(set) var logError: String?

    @Published var consoleWorktree: WorktreeSnapshot?
    @Published private(set) var stackConsole: StackConsoleSnapshot?
    @Published private(set) var isRefreshingConsole = false
    @Published private(set) var consoleError: String?

    @Published var convexWorktree: WorktreeSnapshot?
    @Published private(set) var convexMaintenancePlan: ConvexMaintenancePlan?
    @Published private(set) var isPreparingConvexMaintenance = false
    @Published private(set) var isExecutingConvexMaintenance = false
    @Published private(set) var convexMaintenanceError: String?

    @Published var nukeWorktree: WorktreeSnapshot?
    @Published private(set) var nukeManifest: NukeManifest?
    @Published private(set) var isPreparingNuke = false
    @Published private(set) var isExecutingNuke = false
    @Published private(set) var nukeError: String?

    @Published var bulkNukePresented = false
    @Published private(set) var bulkNukeReviews: [BulkNukeReview] = []
    @Published private(set) var isPreparingBulkNuke = false
    @Published private(set) var isExecutingBulkNuke = false
    @Published private(set) var bulkNukeError: String?
    @Published private(set) var bulkNukeProgress: String?

    @Published var orphanCleanupPresented = false
    @Published private(set) var orphanCleanupManifest: OrphanCleanupManifest?
    @Published private(set) var isPreparingOrphanCleanup = false
    @Published private(set) var isExecutingOrphanCleanup = false
    @Published private(set) var orphanCleanupError: String?
    @Published private(set) var orphanCleanupProgress: OrphanCleanupProgress?

    let repositoryPath: String

    private let discovery: TownDiscoveryEngine
    private let controls: TownControlEngine
    private let nuker: NukeEngine
    private let registry: TownRegistry
    private let managedRunRegistry: ManagedRunRegistry
    private let logReader: WorktreeLogReader
    private let consoleReader: StackConsoleReader
    private let convexMaintenance: ConvexMaintenanceEngine
    private let terminalSessions = TerminalSessionCoordinator()
    private var pollingTask: Task<Void, Never>?
    private var nukePreparationToken = UUID()
    private var bulkNukePreparationToken = UUID()
    private var bulkNukeDeletesLocalBranches = false

    init(repositoryPath: String = TownStore.defaultRepositoryPath) {
        self.repositoryPath = repositoryPath
        snapshot = .empty(repositoryPath: repositoryPath)
        discovery = TownDiscoveryEngine(repositoryPath: repositoryPath)
        controls = TownControlEngine()
        let registry = TownRegistry()
        self.registry = registry
        nuker = NukeEngine(registry: registry)
        managedRunRegistry = ManagedRunRegistry()
        logReader = WorktreeLogReader()
        consoleReader = StackConsoleReader()
        convexMaintenance = ConvexMaintenanceEngine()

        // MenuBarExtra content is created lazily the first time it is opened.
        // Start discovery here so the icon, counts, and durable ownership
        // registry are already current before that first click.
        Task { @MainActor [weak self] in
            self?.startPolling()
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    static var defaultRepositoryPath: String {
        if let configured = ProcessInfo.processInfo.environment["TOWN_REPOSITORY_PATH"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: configured).expandingTildeInPath
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/town", isDirectory: true)
            .path
    }

    var runningWorktreeCount: Int {
        snapshot.worktrees.filter { $0.instance?.isRunning == true }.count
    }

    var issueCount: Int {
        snapshot.orphans.count
            + snapshot.worktrees.filter { $0.health?.overall == .degraded }.count
            + snapshot.warnings.count
    }

    var menuBarSymbol: String {
        if isRefreshing && snapshot.worktrees.isEmpty { return "arrow.triangle.2.circlepath" }
        if issueCount > 0 { return "exclamationmark.triangle.fill" }
        if runningWorktreeCount > 0 { return "building.2.fill" }
        return "building.2"
    }

    func startPolling() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await self?.refresh(silent: true)
            }
        }
    }

    func refresh(silent: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let discovered = try await discovery.snapshot()
            try await registry.record(snapshot: discovered)
            snapshot = await registry.enrich(snapshot: discovered)
            if let reconciled = try? await managedRunRegistry.reconcile(snapshot: snapshot) {
                managedRuns = reconciled
            }
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            if !silent || snapshot.worktrees.isEmpty {
                lastError = error.localizedDescription
            }
        }
    }

    func start(_ worktree: WorktreeSnapshot) {
        runControl(key: operationKey("start", worktree.id)) {
            let result = try await self.controls.start(worktree)
            await self.recordManagedLaunch(result, for: worktree)
            return result
        }
    }

    func stop(_ worktree: WorktreeSnapshot) {
        runControl(key: operationKey("stop", worktree.id)) {
            let result = try await self.controls.stop(worktree)
            await self.forgetManagedLaunch(for: worktree)
            return result
        }
    }

    func restart(_ worktree: WorktreeSnapshot) {
        runControl(key: operationKey("restart", worktree.id)) {
            let result = try await self.controls.restart(worktree)
            await self.recordManagedLaunch(result, for: worktree)
            return result
        }
    }

    func forceKill(_ worktree: WorktreeSnapshot) {
        runControl(key: operationKey("kill", worktree.id)) {
            let result = try await self.controls.forceKill(worktree)
            await self.forgetManagedLaunch(for: worktree)
            return result
        }
    }

    func managedRun(for worktree: WorktreeSnapshot) -> ManagedRunRecord? {
        let canonical = ManagedRunRecord.canonicalPath(worktree.path)
        return managedRuns.first { $0.worktreePath == canonical }
    }

    func isManagedLaunchPending(_ worktree: WorktreeSnapshot) -> Bool {
        guard worktree.instance?.isRunning != true,
              let run = managedRun(for: worktree)
        else { return false }
        return Date().timeIntervalSince(run.launchedAt) <= 120
    }

    func kill(_ orphan: OrphanSnapshot) {
        runControl(key: operationKey("orphan", orphan.id)) {
            try await self.controls.killOrphan(orphan)
        }
    }

    func isOperating(on id: String) -> Bool {
        activeOperations.contains { $0.hasSuffix("|\(id)") }
    }

    func requestNuke(_ worktree: WorktreeSnapshot) {
        guard !worktree.isPrimary else { return }
        nukeManifest = nil
        nukeError = nil
        nukeWorktree = worktree
        Task { await prepareNuke(deleteLocalBranch: false) }
    }

    func prepareNuke(deleteLocalBranch: Bool) async {
        guard let worktree = nukeWorktree, !isExecutingNuke else { return }
        let token = UUID()
        nukePreparationToken = token
        isPreparingNuke = true
        nukeManifest = nil
        nukeError = nil

        do {
            let manifest = try await nuker.dryRun(
                worktree: worktree,
                repositoryPath: repositoryPath,
                deleteLocalBranch: deleteLocalBranch
            )
            guard nukePreparationToken == token, nukeWorktree?.id == worktree.id else { return }
            nukeManifest = manifest
        } catch {
            guard nukePreparationToken == token, nukeWorktree?.id == worktree.id else { return }
            nukeManifest = nil
            nukeError = error.localizedDescription
        }
        if nukePreparationToken == token {
            isPreparingNuke = false
        }
    }

    @discardableResult
    func executeNuke(deleteLocalBranch: Bool) async -> Bool {
        guard let manifest = nukeManifest else { return false }
        isExecutingNuke = true
        nukeError = nil
        defer { isExecutingNuke = false }

        do {
            let result = try await nuker.execute(
                manifest: manifest,
                repositoryPath: repositoryPath,
                confirmationText: manifest.confirmationText,
                deleteLocalBranch: deleteLocalBranch
            )
            let removedCount = result.outcomes.filter { $0.disposition == .removed }.count
            let skippedCount = result.outcomes.filter { $0.disposition == .skipped }.count
            activityMessage = skippedCount == 0
                ? "Nuked the worktree and removed \(removedCount) verified targets."
                : "Nuked the worktree: \(removedCount) targets removed, \(skippedCount) skipped."
            nukeWorktree = nil
            nukeManifest = nil
            await refresh()
            return true
        } catch {
            nukeError = error.localizedDescription
            return false
        }
    }

    func dismissNuke() {
        guard !isExecutingNuke else { return }
        nukePreparationToken = UUID()
        nukeWorktree = nil
        nukeManifest = nil
        isPreparingNuke = false
        nukeError = nil
    }

    func requestBulkNuke() {
        bulkNukePresented = true
        bulkNukeReviews = []
        bulkNukeError = nil
        bulkNukeProgress = nil
    }

    func prepareBulkNuke(
        worktrees: [WorktreeSnapshot],
        deleteLocalBranches: Bool
    ) async {
        guard !isExecutingBulkNuke else { return }
        let candidates = worktrees.filter { !$0.isPrimary }
        let token = UUID()
        bulkNukePreparationToken = token
        bulkNukeDeletesLocalBranches = deleteLocalBranches
        isPreparingBulkNuke = true
        bulkNukeReviews = []
        bulkNukeError = nil
        bulkNukeProgress = nil

        var reviews: [BulkNukeReview] = []
        for worktree in candidates {
            guard bulkNukePreparationToken == token else { return }
            do {
                let manifest = try await nuker.dryRun(
                    worktree: worktree,
                    repositoryPath: repositoryPath,
                    deleteLocalBranch: deleteLocalBranches
                )
                reviews.append(BulkNukeReview(worktree: worktree, manifest: manifest, error: nil))
            } catch {
                reviews.append(BulkNukeReview(
                    worktree: worktree,
                    manifest: nil,
                    error: error.localizedDescription
                ))
            }
        }

        guard bulkNukePreparationToken == token else { return }
        bulkNukeReviews = reviews
        isPreparingBulkNuke = false
    }

    @discardableResult
    func executeBulkNuke(
        deleteLocalBranches: Bool
    ) async -> Bool {
        let manifests = bulkNukeReviews.compactMap { review in
            review.canExecute ? review.manifest : nil
        }
        guard !manifests.isEmpty else {
            bulkNukeError = "No selected worktree has a safe, executable deletion manifest."
            return false
        }
        guard deleteLocalBranches == bulkNukeDeletesLocalBranches else {
            bulkNukeError = "The branch deletion setting changed. Review a fresh manifest before deleting."
            return false
        }

        isExecutingBulkNuke = true
        bulkNukeError = nil
        defer { isExecutingBulkNuke = false }

        var completed = 0
        var removedTargets = 0
        do {
            for manifest in manifests {
                bulkNukeProgress = "Deleting \(manifest.worktree.displayName) · \(completed + 1) of \(manifests.count)"
                let result = try await nuker.execute(
                    manifest: manifest,
                    repositoryPath: repositoryPath,
                    confirmationText: manifest.confirmationText,
                    deleteLocalBranch: deleteLocalBranches
                )
                completed += 1
                removedTargets += result.outcomes.filter { $0.disposition == .removed }.count
            }

            activityMessage = "Nuked \(completed) worktree\(completed == 1 ? "" : "s") and removed \(removedTargets) verified targets."
            bulkNukePresented = false
            bulkNukeReviews = []
            bulkNukeProgress = nil
            await refresh()
            return true
        } catch {
            bulkNukeProgress = nil
            bulkNukeError = completed == 0
                ? error.localizedDescription
                : "Deleted \(completed) of \(manifests.count) worktrees, then stopped safely: \(error.localizedDescription)"
            await refresh()
            return false
        }
    }

    func dismissBulkNuke() {
        guard !isExecutingBulkNuke else { return }
        bulkNukePreparationToken = UUID()
        bulkNukePresented = false
        bulkNukeReviews = []
        isPreparingBulkNuke = false
        bulkNukeError = nil
        bulkNukeProgress = nil
    }

    func requestOrphanCleanup() {
        orphanCleanupPresented = true
        orphanCleanupManifest = nil
        orphanCleanupError = nil
        Task { await prepareOrphanCleanup() }
    }

    func prepareOrphanCleanup() async {
        guard !isExecutingOrphanCleanup else { return }
        isPreparingOrphanCleanup = true
        orphanCleanupError = nil
        orphanCleanupProgress = nil
        orphanCleanupManifest = await nuker.orphanCleanupDryRun(snapshot: snapshot)
        isPreparingOrphanCleanup = false
    }

    @discardableResult
    func executeOrphanCleanup() async -> Bool {
        guard let manifest = orphanCleanupManifest else { return false }
        isExecutingOrphanCleanup = true
        orphanCleanupError = nil
        orphanCleanupProgress = nil
        defer { isExecutingOrphanCleanup = false }

        do {
            let result = try await nuker.executeOrphanCleanup(
                manifest: manifest,
                repositoryPath: repositoryPath,
                confirmationText: manifest.confirmationText,
                progress: { [weak self] update in
                    await MainActor.run {
                        self?.orphanCleanupProgress = update
                    }
                }
            )
            let removed = result.outcomes.filter { $0.disposition == .removed }.count
            let absent = result.outcomes.filter { $0.disposition == .alreadyAbsent }.count
            activityMessage = absent == 0
                ? "Removed \(removed) verified orphan targets."
                : "Orphan cleanup finished: \(removed) removed, \(absent) already absent."
            isExecutingOrphanCleanup = false
            dismissOrphanCleanup()
            await refresh()
            return true
        } catch {
            orphanCleanupError = error.localizedDescription
            return false
        }
    }

    func dismissOrphanCleanup() {
        guard !isExecutingOrphanCleanup else { return }
        orphanCleanupPresented = false
        orphanCleanupManifest = nil
        orphanCleanupError = nil
        orphanCleanupProgress = nil
        isPreparingOrphanCleanup = false
    }

    func dismissActivity() {
        activityMessage = nil
    }

    func dismissError() {
        lastError = nil
    }

    func openInChrome(_ url: URL) {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        guard FileManager.default.fileExists(atPath: chromeURL.path) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: chromeURL,
                    configuration: configuration
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openFrontend(for worktree: WorktreeSnapshot) {
        guard let url = worktree.instance?.services
            .first(where: { $0.kind == .frontend && $0.url != nil })?.url
            ?? worktree.instance?.services.first(where: { $0.kind.isBrowserTarget && $0.url != nil })?.url
        else { return }
        openInChrome(url)
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openOrFocusTerminal(for worktree: WorktreeSnapshot) {
        Task {
            if await terminalSessions.focusOwningTerminal(for: worktree) {
                activityMessage = "Focused the Terminal tab that owns this stack."
            } else {
                openTerminal(at: worktree.path)
            }
        }
    }

    func requestLogs(_ worktree: WorktreeSnapshot) {
        logWorktree = worktree
        worktreeLogs = []
        selectedLogID = nil
        logError = nil
        Task { await refreshLogs() }
    }

    func refreshLogs() async {
        guard let worktree = logWorktree, !isRefreshingLogs else { return }
        isRefreshingLogs = true
        defer { isRefreshingLogs = false }
        do {
            let files = try await logReader.read(worktreePath: worktree.path)
            guard logWorktree?.id == worktree.id else { return }
            worktreeLogs = files
            if selectedLogID == nil || !files.contains(where: { $0.id == selectedLogID }) {
                selectedLogID = files.first?.id
            }
            logError = nil
        } catch {
            guard logWorktree?.id == worktree.id else { return }
            logError = error.localizedDescription
        }
    }

    func dismissLogs() {
        logWorktree = nil
        worktreeLogs = []
        selectedLogID = nil
        logError = nil
        isRefreshingLogs = false
    }

    var selectedLog: WorktreeLogFile? {
        worktreeLogs.first { $0.id == selectedLogID }
    }

    func requestConsole(_ worktree: WorktreeSnapshot) {
        consoleWorktree = worktree
        stackConsole = nil
        consoleError = nil
        Task { await refreshConsole() }
    }

    func refreshConsole() async {
        guard let worktree = consoleWorktree, !isRefreshingConsole else { return }
        isRefreshingConsole = true
        defer { isRefreshingConsole = false }

        do {
            if let captured = try await consoleReader.read(worktreePath: worktree.path),
               !captured.text.isEmpty {
                guard consoleWorktree?.id == worktree.id else { return }
                stackConsole = captured
                consoleError = nil
                return
            }

            if let terminalText = await terminalSessions.transcript(for: worktree) {
                guard consoleWorktree?.id == worktree.id else { return }
                stackConsole = StackConsoleSnapshot(
                    source: .terminalScrollback,
                    text: terminalText,
                    rawTranscript: Data(terminalText.utf8)
                )
                consoleError = nil
                return
            }

            guard consoleWorktree?.id == worktree.id else { return }
            stackConsole = StackConsoleSnapshot(
                source: .unavailable,
                text: "No unified stack output is captured yet.\n\nStart or restart this worktree from Town Sheriff to capture the exact local-stack stream here."
            )
            consoleError = nil
        } catch {
            guard consoleWorktree?.id == worktree.id else { return }
            consoleError = error.localizedDescription
        }
    }

    func dismissConsole() {
        consoleWorktree = nil
        stackConsole = nil
        consoleError = nil
        isRefreshingConsole = false
    }

    func copyConsole() {
        guard let text = stackConsole?.text, !text.isEmpty else { return }
        copy(text)
        activityMessage = "Copied the redacted stack console."
    }

    func copyLatestConsoleLines(_ count: Int = 200) {
        guard let text = stackConsole?.text, !text.isEmpty else { return }
        let lines = text.components(separatedBy: .newlines)
        copy(lines.suffix(max(1, count)).joined(separator: "\n"))
        activityMessage = "Copied the latest redacted console lines."
    }

    func requestConvexMaintenance(_ worktree: WorktreeSnapshot) {
        convexWorktree = worktree
        convexMaintenancePlan = nil
        convexMaintenanceError = nil
        Task { await prepareConvexMaintenance(action: .clearData) }
    }

    func prepareConvexMaintenance(action: ConvexMaintenanceAction) async {
        guard let worktree = convexWorktree, !isExecutingConvexMaintenance else { return }
        isPreparingConvexMaintenance = true
        convexMaintenanceError = nil
        let plan = await convexMaintenance.dryRun(worktree: worktree, action: action)
        guard convexWorktree?.id == worktree.id else { return }
        convexMaintenancePlan = plan
        isPreparingConvexMaintenance = false
    }

    @discardableResult
    func executeConvexMaintenance() async -> Bool {
        guard let worktree = convexWorktree,
              let plan = convexMaintenancePlan,
              plan.canExecute,
              !isExecutingConvexMaintenance
        else { return false }
        let key = operationKey("convex", worktree.id)
        activeOperations.insert(key)
        isExecutingConvexMaintenance = true
        convexMaintenanceError = nil
        defer {
            activeOperations.remove(key)
            isExecutingConvexMaintenance = false
        }
        do {
            let result = try await convexMaintenance.execute(
                plan: plan,
                repositoryPath: repositoryPath
            )
            if let launcherPID = result.launcherPID,
               let records = try? await managedRunRegistry.recordLaunch(
                worktreePath: worktree.path,
                instanceNumber: plan.instanceNumber,
                launcherPID: launcherPID
               ) {
                managedRuns = records
            }
            activityMessage = result.message
            convexWorktree = nil
            convexMaintenancePlan = nil
            await refresh()
            return true
        } catch {
            convexMaintenanceError = error.localizedDescription
            await refresh()
            return false
        }
    }

    func dismissConvexMaintenance() {
        guard !isExecutingConvexMaintenance else { return }
        convexWorktree = nil
        convexMaintenancePlan = nil
        convexMaintenanceError = nil
        isPreparingConvexMaintenance = false
    }

    func revealLogs(for worktree: WorktreeSnapshot) {
        let logs = URL(fileURLWithPath: worktree.path, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([logs])
    }

    private func openTerminal(at path: String) {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()

        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    [folderURL],
                    withApplicationAt: terminalURL,
                    configuration: configuration
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func runControl(
        key: String,
        operation: @escaping @MainActor () async throws -> ControlResult
    ) {
        guard !activeOperations.contains(key) else { return }
        activeOperations.insert(key)
        lastError = nil

        Task {
            defer { activeOperations.remove(key) }
            do {
                let result = try await operation()
                activityMessage = result.message
                try? await Task.sleep(for: .milliseconds(350))
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func operationKey(_ action: String, _ id: String) -> String {
        "\(action)|\(id)"
    }

    private func recordManagedLaunch(
        _ result: ControlResult,
        for worktree: WorktreeSnapshot
    ) async {
        guard let launcherPID = result.affectedProcessIDs.first else { return }
        if let records = try? await managedRunRegistry.recordLaunch(
            worktreePath: worktree.path,
            instanceNumber: worktree.instance?.number,
            launcherPID: launcherPID
        ) {
            managedRuns = records
        }
    }

    private func forgetManagedLaunch(for worktree: WorktreeSnapshot) async {
        if let records = try? await managedRunRegistry.remove(worktreePath: worktree.path) {
            managedRuns = records
        }
    }
}
