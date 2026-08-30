import Foundation

public enum AttributionConfidence: String, Codable, Sendable, CaseIterable {
    case certain
    case high
    case inferred
    case ambiguous

    public var rank: Int {
        switch self {
        case .certain: 4
        case .high: 3
        case .inferred: 2
        case .ambiguous: 1
        }
    }
}

public enum ServiceKind: String, Codable, Sendable, CaseIterable {
    case frontend
    case convexBackend
    case convexSiteProxy
    case convexDashboard
    case harness
    case drizzleStudio
    case electric
    case postgres
    case temporalGRPC
    case temporalUI
    case minioAPI
    case minioConsole
    case jaegerUI
    case otlpGRPC
    case otlpHTTP
    case unknown

    public var displayName: String {
        switch self {
        case .frontend: "Frontend"
        case .convexBackend: "Convex"
        case .convexSiteProxy: "Site proxy"
        case .convexDashboard: "Dashboard"
        case .harness: "Harness"
        case .drizzleStudio: "Drizzle"
        case .electric: "Electric"
        case .postgres: "PostgreSQL"
        case .temporalGRPC: "Temporal gRPC"
        case .temporalUI: "Temporal UI"
        case .minioAPI: "MinIO S3"
        case .minioConsole: "MinIO Console"
        case .jaegerUI: "Jaeger"
        case .otlpGRPC: "OTLP gRPC"
        case .otlpHTTP: "OTLP HTTP"
        case .unknown: "Unknown"
        }
    }

    public var isBrowserTarget: Bool {
        switch self {
        case .frontend, .convexDashboard, .harness, .drizzleStudio, .electric,
             .temporalUI, .minioConsole, .jaegerUI:
            true
        default:
            false
        }
    }
}

public enum ServiceState: String, Codable, Sendable {
    case running
    case degraded
    case stopped
    case unknown
}

public struct ProcessIdentity: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(pid)-\(startToken)" }
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let startToken: String
    public let command: String
    public let executablePath: String?
    public let workingDirectory: String?
    public let residentBytes: UInt64
    public let cpuPercent: Double?

    public init(
        pid: Int32,
        parentPID: Int32,
        processGroupID: Int32,
        startToken: String,
        command: String,
        executablePath: String? = nil,
        workingDirectory: String? = nil,
        residentBytes: UInt64 = 0,
        cpuPercent: Double? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.startToken = startToken
        self.command = command
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.residentBytes = residentBytes
        self.cpuPercent = cpuPercent
    }
}

public struct ServiceSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue)-\(port)" }
    public let kind: ServiceKind
    public let port: Int
    public let state: ServiceState
    public let url: URL?
    public let processIDs: [Int32]
    public let detail: String?
    public let isShared: Bool
    public let cpuPercent: Double?
    public let residentBytes: UInt64?

    public init(
        kind: ServiceKind,
        port: Int,
        state: ServiceState,
        url: URL? = nil,
        processIDs: [Int32] = [],
        detail: String? = nil,
        isShared: Bool = false,
        cpuPercent: Double? = nil,
        residentBytes: UInt64? = nil
    ) {
        self.kind = kind
        self.port = port
        self.state = state
        self.url = url
        self.processIDs = processIDs
        self.detail = detail
        self.isShared = isShared
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

public struct GitStatusSnapshot: Codable, Hashable, Sendable {
    public let modifiedCount: Int
    public let stagedCount: Int
    public let untrackedCount: Int
    public let ahead: Int
    public let behind: Int
    public let upstream: String?

    public var isDirty: Bool {
        modifiedCount > 0 || stagedCount > 0 || untrackedCount > 0
    }

    public init(
        modifiedCount: Int = 0,
        stagedCount: Int = 0,
        untrackedCount: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        upstream: String? = nil
    ) {
        self.modifiedCount = modifiedCount
        self.stagedCount = stagedCount
        self.untrackedCount = untrackedCount
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
    }
}

public struct HealthProbeSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let state: ServiceState
    public let detail: String

    public init(name: String, state: ServiceState, detail: String) {
        self.name = name
        self.state = state
        self.detail = detail
    }
}

public struct HealthSnapshot: Codable, Hashable, Sendable {
    public let overall: ServiceState
    public let probes: [HealthProbeSnapshot]
    public let recommendations: [String]
    public let measuredAt: Date?

    public init(
        overall: ServiceState,
        probes: [HealthProbeSnapshot] = [],
        recommendations: [String] = [],
        measuredAt: Date? = nil
    ) {
        self.overall = overall
        self.probes = probes
        self.recommendations = recommendations
        self.measuredAt = measuredAt
    }
}

public struct StateDirectorySnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let instanceNumber: Int?
    public let sizeBytes: UInt64
    public let modifiedAt: Date?
    public let isRunning: Bool
    public let associatedWorktreePath: String?
    public let confidence: AttributionConfidence

    public init(
        path: String,
        instanceNumber: Int?,
        sizeBytes: UInt64,
        modifiedAt: Date?,
        isRunning: Bool,
        associatedWorktreePath: String?,
        confidence: AttributionConfidence
    ) {
        self.path = path
        self.instanceNumber = instanceNumber
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.isRunning = isRunning
        self.associatedWorktreePath = associatedWorktreePath
        self.confidence = confidence
    }
}

public struct InstanceSnapshot: Codable, Hashable, Sendable {
    public let number: Int
    public let confidence: AttributionConfidence
    public let evidence: [String]
    public let services: [ServiceSnapshot]
    public let processes: [ProcessIdentity]
    public let stateDirectory: StateDirectorySnapshot?
    public let actualBucketName: String?

    public init(
        number: Int,
        confidence: AttributionConfidence,
        evidence: [String],
        services: [ServiceSnapshot],
        processes: [ProcessIdentity] = [],
        stateDirectory: StateDirectorySnapshot? = nil,
        actualBucketName: String? = nil
    ) {
        self.number = number
        self.confidence = confidence
        self.evidence = evidence
        self.services = services
        self.processes = processes
        self.stateDirectory = stateDirectory
        self.actualBucketName = actualBucketName
    }

    public var isRunning: Bool {
        services.contains { $0.state == .running || $0.state == .degraded }
    }
}

public struct WorktreeSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let head: String
    public let branch: String?
    public let isDetached: Bool
    public let isPrimary: Bool
    public let isLocked: Bool
    public let isPrunable: Bool
    public let gitStatus: GitStatusSnapshot
    public let instance: InstanceSnapshot?
    public let health: HealthSnapshot?
    public let setupComplete: Bool

    public init(
        path: String,
        head: String,
        branch: String?,
        isDetached: Bool,
        isPrimary: Bool,
        isLocked: Bool,
        isPrunable: Bool,
        gitStatus: GitStatusSnapshot,
        instance: InstanceSnapshot?,
        health: HealthSnapshot?,
        setupComplete: Bool
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isPrimary = isPrimary
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.gitStatus = gitStatus
        self.instance = instance
        self.health = health
        self.setupComplete = setupComplete
    }
}

public enum OrphanKind: String, Codable, Sendable {
    case deletedWorktree
    case detachedFromLiveStack
    case unclaimedInstance
    case dormantState
    case staleDocker
}

public struct OrphanSnapshot: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: OrphanKind
    public let title: String
    public let missingPath: String?
    public let instanceNumber: Int?
    public let confidence: AttributionConfidence
    public let reasons: [String]
    public let processes: [ProcessIdentity]
    public let services: [ServiceSnapshot]
    public let stateDirectory: StateDirectorySnapshot?

    public init(
        id: String,
        kind: OrphanKind,
        title: String,
        missingPath: String?,
        instanceNumber: Int?,
        confidence: AttributionConfidence,
        reasons: [String],
        processes: [ProcessIdentity] = [],
        services: [ServiceSnapshot] = [],
        stateDirectory: StateDirectorySnapshot? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.missingPath = missingPath
        self.instanceNumber = instanceNumber
        self.confidence = confidence
        self.reasons = reasons
        self.processes = processes
        self.services = services
        self.stateDirectory = stateDirectory
    }
}

public struct TownSnapshot: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let repositoryPath: String
    public let worktrees: [WorktreeSnapshot]
    public let orphans: [OrphanSnapshot]
    public let sharedServices: [ServiceSnapshot]
    public let dormantStates: [StateDirectorySnapshot]
    public let warnings: [String]

    public init(
        generatedAt: Date = Date(),
        repositoryPath: String,
        worktrees: [WorktreeSnapshot],
        orphans: [OrphanSnapshot],
        sharedServices: [ServiceSnapshot],
        dormantStates: [StateDirectorySnapshot],
        warnings: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.repositoryPath = repositoryPath
        self.worktrees = worktrees
        self.orphans = orphans
        self.sharedServices = sharedServices
        self.dormantStates = dormantStates
        self.warnings = warnings
    }

    public static func empty(repositoryPath: String) -> TownSnapshot {
        TownSnapshot(
            repositoryPath: repositoryPath,
            worktrees: [],
            orphans: [],
            sharedServices: [],
            dormantStates: []
        )
    }
}

public enum DestructiveTargetKind: String, Codable, Hashable, Sendable {
    case processGroup
    case listener
    case dockerContainer
    case dockerVolume
    case postgresDatabase
    case postgresReplicationSlot
    case minioBucket
    case convexStateDirectory
    case tunnelMarker
    case worktreeDirectory
    case gitRegistration
    case localBranch
    case remoteSubscription
    case temporalHistory
}

public struct DestructiveTarget: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: DestructiveTargetKind
    public let label: String
    public let identifier: String
    public let estimatedBytes: UInt64?
    public let confidence: AttributionConfidence
    public let selectedByDefault: Bool
    public let actionable: Bool
    public let note: String?

    public init(
        id: String,
        kind: DestructiveTargetKind,
        label: String,
        identifier: String,
        estimatedBytes: UInt64? = nil,
        confidence: AttributionConfidence,
        selectedByDefault: Bool = true,
        actionable: Bool = true,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.identifier = identifier
        self.estimatedBytes = estimatedBytes
        self.confidence = confidence
        self.selectedByDefault = selectedByDefault
        self.actionable = actionable
        self.note = note
    }
}

public struct NukeManifest: Codable, Hashable, Sendable {
    public let worktree: WorktreeSnapshot
    public let targets: [DestructiveTarget]
    public let warnings: [String]
    public let confirmationText: String
    public let canExecute: Bool

    public init(
        worktree: WorktreeSnapshot,
        targets: [DestructiveTarget],
        warnings: [String],
        confirmationText: String,
        canExecute: Bool
    ) {
        self.worktree = worktree
        self.targets = targets
        self.warnings = warnings
        self.confirmationText = confirmationText
        self.canExecute = canExecute
    }
}

public struct OrphanCleanupManifest: Codable, Hashable, Sendable {
    public let targets: [DestructiveTarget]
    public let warnings: [String]
    public let confirmationText: String
    public let canExecute: Bool

    public init(
        targets: [DestructiveTarget],
        warnings: [String],
        confirmationText: String = "REMOVE ALL ORPHANS",
        canExecute: Bool
    ) {
        self.targets = targets
        self.warnings = warnings
        self.confirmationText = confirmationText
        self.canExecute = canExecute
    }
}

public struct OrphanCleanupProgress: Codable, Hashable, Sendable {
    public let completedTargets: Int
    public let totalTargets: Int
    public let currentTargetLabel: String

    public init(
        completedTargets: Int,
        totalTargets: Int,
        currentTargetLabel: String
    ) {
        self.completedTargets = completedTargets
        self.totalTargets = totalTargets
        self.currentTargetLabel = currentTargetLabel
    }
}

public struct OrphanCleanupResult: Codable, Hashable, Sendable {
    public let outcomes: [NukeTargetOutcome]
    public let completedAt: Date

    public init(outcomes: [NukeTargetOutcome], completedAt: Date = Date()) {
        self.outcomes = outcomes
        self.completedAt = completedAt
    }
}

public enum TownDockError: LocalizedError, Sendable {
    case commandFailed(String)
    case repositoryNotFound(String)
    case unsafeOperation(String)
    case staleSnapshot(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(message),
             let .repositoryNotFound(message),
             let .unsafeOperation(message),
             let .staleSnapshot(message),
             let .unsupported(message):
            message
        }
    }
}
