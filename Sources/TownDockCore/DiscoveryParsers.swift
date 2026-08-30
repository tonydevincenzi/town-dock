import Foundation

public enum SecretRedactor {
    private static let replacements: [(String, String)] = [
        (#"(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]"),
        (#"(?i)(--[a-z0-9-]*(?:admin-key|api-key|access-key|secret|token|password|credential)[a-z0-9-]*(?:=|\s+))(?:\"[^\"]*\"|'[^']*'|\S+)"#, "$1[REDACTED]"),
        (#"(?i)(\b(?:[A-Z][A-Z0-9_]*_)?(?:ADMIN_KEY|API_KEY|ACCESS_KEY|SECRET|SECRET_ACCESS_KEY|CLIENT_SECRET|INSTANCE_SECRET|PASSWORD|TOKEN)\s*=\s*)(?:\"[^\"]*\"|'[^']*'|\S+)"#, "$1[REDACTED]"),
        (#"(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[REDACTED]"),
        (#"(?i)([?&](?:admin[_-]?key|api[_-]?key|access[_-]?key|secret|token|password)=)[^&\s]+"#, "$1[REDACTED]"),
        (#"(?i)([a-z][a-z0-9+.-]*://)[^/@\s:]+:[^/@\s]+@"#, "$1[REDACTED]@"),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "[REDACTED JWT]"),
        (#"\b[A-Za-z0-9._-]+\|[A-Fa-f0-9]{32,}\b"#, "[REDACTED ADMIN KEY]"),
    ]

    public static func redact(_ value: String, maximumLength: Int = 2_048) -> String {
        var result = value.replacingOccurrences(of: "\0", with: "")
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        if result.count > maximumLength {
            result = String(result.prefix(maximumLength)) + "…"
        }
        return result
    }
}

public struct GitWorktreeRecord: Hashable, Sendable {
    public let path: String
    public let head: String
    public let branch: String?
    public let isDetached: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(
        path: String,
        head: String,
        branch: String?,
        isDetached: Bool,
        isLocked: Bool,
        isPrunable: Bool
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

public enum GitWorktreePorcelainParser {
    public static func parse(_ text: String) -> [GitWorktreeRecord] {
        struct Builder {
            var path: String?
            var head = ""
            var branch: String?
            var detached = false
            var locked = false
            var prunable = false
        }

        var records: [GitWorktreeRecord] = []
        var builder = Builder()

        func append(_ builder: Builder, to records: inout [GitWorktreeRecord]) {
            guard let path = builder.path, path.hasPrefix("/") else { return }
            records.append(
                GitWorktreeRecord(
                    path: URL(fileURLWithPath: path).standardizedFileURL.path,
                    head: builder.head,
                    branch: builder.branch,
                    isDetached: builder.detached,
                    isLocked: builder.locked,
                    isPrunable: builder.prunable
                )
            )
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                append(builder, to: &records)
                builder = Builder()
            } else if line.hasPrefix("worktree ") {
                if builder.path != nil {
                    append(builder, to: &records)
                    builder = Builder()
                }
                builder.path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                builder.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let reference = String(line.dropFirst("branch ".count))
                builder.branch = reference.hasPrefix("refs/heads/")
                    ? String(reference.dropFirst("refs/heads/".count))
                    : reference
            } else if line == "detached" {
                builder.detached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                builder.locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                builder.prunable = true
            }
        }
        append(builder, to: &records)
        return records
    }
}

public enum GitStatusPorcelainV2Parser {
    public static func parse(_ text: String) -> GitStatusSnapshot {
        var modified = 0
        var staged = 0
        var untracked = 0
        var ahead = 0
        var behind = 0
        var upstream: String?

        for rawLine in text.components(separatedBy: .newlines) where !rawLine.isEmpty {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let components = line.split(separator: " ")
                for component in components {
                    if component.hasPrefix("+") {
                        ahead = Int(component.dropFirst()) ?? 0
                    } else if component.hasPrefix("-") {
                        behind = Int(component.dropFirst()) ?? 0
                    }
                }
            } else if line.hasPrefix("? ") {
                untracked += 1
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count >= 2 else { continue }
                let status = fields[1]
                guard status.count >= 2 else { continue }
                let x = status[status.startIndex]
                let y = status[status.index(after: status.startIndex)]
                if x != "." && x != " " { staged += 1 }
                if y != "." && y != " " { modified += 1 }
            }
        }

        return GitStatusSnapshot(
            modifiedCount: modified,
            stagedCount: staged,
            untrackedCount: untracked,
            ahead: ahead,
            behind: behind,
            upstream: upstream
        )
    }
}

public struct ListenerRecord: Hashable, Sendable {
    public let pid: Int32
    public let command: String
    public let address: String
    public let port: Int

    public init(pid: Int32, command: String, address: String, port: Int) {
        self.pid = pid
        self.command = command
        self.address = address
        self.port = port
    }
}

public enum LSOFListenerParser {
    public static func parse(_ text: String) -> [ListenerRecord] {
        let lines = text.components(separatedBy: .newlines)
        if lines.contains(where: { $0.hasPrefix("p") && Int32($0.dropFirst()) != nil }) {
            return parseFieldOutput(lines)
        }
        return parseColumnOutput(lines)
    }

    private static func parseFieldOutput(_ lines: [String]) -> [ListenerRecord] {
        var pid: Int32?
        var command = ""
        var records: [ListenerRecord] = []
        var seen = Set<String>()
        for line in lines where !line.isEmpty {
            switch line.first {
            case "p":
                pid = Int32(line.dropFirst())
                command = ""
            case "c":
                command = SecretRedactor.redact(String(line.dropFirst()), maximumLength: 256)
            case "n":
                let address = SecretRedactor.redact(String(line.dropFirst()), maximumLength: 512)
                guard let pid, let port = port(from: address) else { continue }
                let key = "\(pid):\(port)"
                guard seen.insert(key).inserted else { continue }
                records.append(ListenerRecord(pid: pid, command: command, address: address, port: port))
            default:
                continue
            }
        }
        return records
    }

    private static func parseColumnOutput(_ lines: [String]) -> [ListenerRecord] {
        var records: [ListenerRecord] = []
        var seen = Set<String>()
        for line in lines where !line.isEmpty && !line.hasPrefix("COMMAND") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2,
                  let pid = Int32(fields[1]),
                  let addressField = fields.reversed().first(where: { port(from: String($0)) != nil })
            else {
                continue
            }
            let address = SecretRedactor.redact(String(addressField), maximumLength: 512)
            guard let port = port(from: address) else { continue }
            let key = "\(pid):\(port)"
            guard seen.insert(key).inserted else { continue }
            records.append(
                ListenerRecord(
                    pid: pid,
                    command: SecretRedactor.redact(String(fields[0]), maximumLength: 256),
                    address: address,
                    port: port
                )
            )
        }
        return records
    }

    private static func port(from address: String) -> Int? {
        guard let match = address.range(of: #":(\d+)(?:\s|$|->)"#, options: .regularExpression) else {
            return nil
        }
        let token = address[match].dropFirst().prefix { $0.isNumber }
        guard let value = Int(token), (1...65_535).contains(value) else { return nil }
        return value
    }
}

public struct PSProcessRecord: Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let startToken: String
    public let cpuPercent: Double
    public let residentBytes: UInt64
    public let command: String

    public init(
        pid: Int32,
        parentPID: Int32,
        processGroupID: Int32,
        startToken: String,
        cpuPercent: Double,
        residentBytes: UInt64,
        command: String
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.startToken = startToken
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.command = command
    }
}

public enum PSMetadataParser {
    public static func parse(_ text: String) -> [PSProcessRecord] {
        guard let expression = try? NSRegularExpression(
            pattern: #"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+([0-9]+(?:\.[0-9]+)?)\s+(\d+)\s*(.*)$"#
        ) else {
            return []
        }

        return text.components(separatedBy: .newlines).compactMap { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  match.numberOfRanges == 8,
                  let pid = capture(match, 1, line).flatMap(Int32.init),
                  let parent = capture(match, 2, line).flatMap(Int32.init),
                  let group = capture(match, 3, line).flatMap(Int32.init),
                  let start = capture(match, 4, line),
                  let cpuPercent = capture(match, 5, line).flatMap(Double.init),
                  let rssKB = capture(match, 6, line).flatMap(UInt64.init),
                  let command = capture(match, 7, line)
            else {
                return nil
            }
            return PSProcessRecord(
                pid: pid,
                parentPID: parent,
                processGroupID: group,
                startToken: start.replacingOccurrences(of: " ", with: "_"),
                cpuPercent: cpuPercent,
                residentBytes: rssKB.multipliedReportingOverflow(by: 1_024).overflow
                    ? UInt64.max
                    : rssKB * 1_024,
                command: SecretRedactor.redact(command, maximumLength: 2_048)
            )
        }
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

public struct ProcessFileEvidence: Hashable, Sendable {
    public let pid: Int32
    public let workingDirectory: String?
    public let executablePath: String?
    public let openPaths: [String]

    public init(pid: Int32, workingDirectory: String?, executablePath: String?, openPaths: [String]) {
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.executablePath = executablePath
        self.openPaths = openPaths
    }
}

public enum LSOFProcessFileParser {
    public static func parse(_ text: String) -> [ProcessFileEvidence] {
        struct Builder {
            var cwd: String?
            var executable: String?
            var openPaths: [String] = []
        }
        var builders: [Int32: Builder] = [:]
        var currentPID: Int32?
        var currentDescriptor: String?

        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            switch line.first {
            case "p":
                currentPID = Int32(line.dropFirst())
                currentDescriptor = nil
            case "f":
                currentDescriptor = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            case "n":
                guard let currentPID else { continue }
                let rawPath = String(line.dropFirst())
                guard rawPath.hasPrefix("/") else { continue }
                let path = SecretRedactor.redact(rawPath, maximumLength: 4_096)
                var builder = builders[currentPID, default: Builder()]
                switch currentDescriptor {
                case "cwd":
                    builder.cwd = path
                case "txt":
                    if builder.executable == nil { builder.executable = path }
                    builder.openPaths.append(path)
                default:
                    builder.openPaths.append(path)
                }
                builders[currentPID] = builder
            default:
                continue
            }
        }

        return builders.map { pid, builder in
            ProcessFileEvidence(
                pid: pid,
                workingDirectory: builder.cwd,
                executablePath: builder.executable,
                openPaths: Array(Set(builder.openPaths)).sorted()
            )
        }.sorted { $0.pid < $1.pid }
    }
}

public enum TownHealthJSONLParser {
    public static func parse(_ text: String) -> HealthSnapshot? {
        for line in text.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let overallRaw = object["overall"] as? String
            else {
                continue
            }

            var probes: [HealthProbeSnapshot] = []
            if let dictionary = object["probes"] as? [String: Any] {
                for name in dictionary.keys.sorted() {
                    guard let value = dictionary[name] as? [String: Any] else { continue }
                    probes.append(probe(name: name, value: value))
                }
            } else if let array = object["probes"] as? [[String: Any]] {
                for value in array {
                    guard let name = value["name"] as? String else { continue }
                    probes.append(probe(name: name, value: value))
                }
            }

            let recommendations = (object["recommendations"] as? [String] ?? [])
                .prefix(30)
                .map { SecretRedactor.redact($0, maximumLength: 1_024) }
            let measuredAt = (object["ts"] as? String).flatMap(parseDate)
            return HealthSnapshot(
                overall: state(overallRaw),
                probes: probes,
                recommendations: recommendations,
                measuredAt: measuredAt
            )
        }
        return nil
    }

    private static func probe(name: String, value: [String: Any]) -> HealthProbeSnapshot {
        let severity = (value["severity"] as? String) ?? ((value["ok"] as? Bool) == true ? "ok" : "error")
        return HealthProbeSnapshot(
            name: SecretRedactor.redact(name, maximumLength: 160),
            state: state(severity),
            detail: SecretRedactor.redact(value["detail"] as? String ?? "No detail", maximumLength: 1_024)
        )
    }

    private static func state(_ value: String) -> ServiceState {
        switch value.lowercased() {
        case "ok", "healthy", "running": .running
        case "warn", "warning", "error", "failed", "degraded": .degraded
        case "stopped", "down": .stopped
        default: .unknown
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct StateDirectoryDescriptor: Hashable, Sendable {
    public let path: String
    public let instanceName: String
    public let instanceNumber: Int
    public let backendPort: Int

    public init(path: String, instanceName: String, instanceNumber: Int, backendPort: Int) {
        self.path = path
        self.instanceName = instanceName
        self.instanceNumber = instanceNumber
        self.backendPort = backendPort
    }
}

public enum TownStateDirectoryParser {
    public static func parse(path: String) -> StateDirectoryDescriptor? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent
        guard let expression = try? NSRegularExpression(pattern: #"^local-backend-(.+)-(\d+)$"#),
              let match = expression.firstMatch(
                  in: name,
                  range: NSRange(name.startIndex..<name.endIndex, in: name)
              ),
              let nameRange = Range(match.range(at: 1), in: name),
              let portRange = Range(match.range(at: 2), in: name),
              let port = Int(name[portRange])
        else {
            return nil
        }
        let number = (port - 3_210) / 10
        guard (1...9).contains(number), 3_210 + number * 10 == port else { return nil }
        return StateDirectoryDescriptor(
            path: url.path,
            instanceName: SecretRedactor.redact(String(name[nameRange]), maximumLength: 256),
            instanceNumber: number,
            backendPort: port
        )
    }

    public static func parseDUKilobytes(_ text: String) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let separator = line.firstIndex(where: { $0.isWhitespace }),
                  let kilobytes = UInt64(line[..<separator])
            else {
                continue
            }
            let path = line[separator...].trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { continue }
            let multiplication = kilobytes.multipliedReportingOverflow(by: 1_024)
            result[URL(fileURLWithPath: path).standardizedFileURL.path] = multiplication.overflow
                ? UInt64.max
                : multiplication.partialValue
        }
        return result
    }
}

public struct DockerContainerRecord: Hashable, Sendable {
    public let id: String
    public let name: String
    public let state: String
    public let status: String
    public let publishedPorts: [Int]
    public let mountedVolumes: [String]
    public let instanceNumber: Int?
    public let cpuPercent: Double?
    public let residentBytes: UInt64?

    public init(
        id: String,
        name: String,
        state: String,
        status: String,
        publishedPorts: [Int],
        mountedVolumes: [String] = [],
        instanceNumber: Int?,
        cpuPercent: Double? = nil,
        residentBytes: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.status = status
        self.publishedPorts = publishedPorts
        self.mountedVolumes = mountedVolumes
        self.instanceNumber = instanceNumber
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

public struct DockerVolumeRecord: Hashable, Sendable {
    public let name: String
    public let driver: String
    public let instanceNumber: Int?

    public init(name: String, driver: String, instanceNumber: Int?) {
        self.name = name
        self.driver = driver
        self.instanceNumber = instanceNumber
    }
}

public enum DockerInventoryParser {
    public static func parseContainers(_ text: String) -> [DockerContainerRecord] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            let name = safeName(string(object, keys: ["Names", "Name"]))
            guard !name.isEmpty else { return nil }
            let portsText = string(object, keys: ["Ports"])
            return DockerContainerRecord(
                id: safeIdentifier(string(object, keys: ["ID", "Id"])),
                name: name,
                state: safeName(string(object, keys: ["State"])),
                status: SecretRedactor.redact(string(object, keys: ["Status"]), maximumLength: 512),
                publishedPorts: publishedPorts(portsText),
                mountedVolumes: mountedVolumeNames(string(object, keys: ["Mounts"])),
                instanceNumber: instanceNumber(from: name)
            )
        }
    }

    public static func parseVolumes(_ text: String) -> [DockerVolumeRecord] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            let name = safeName(string(object, keys: ["Name"]))
            guard !name.isEmpty else { return nil }
            return DockerVolumeRecord(
                name: name,
                driver: safeName(string(object, keys: ["Driver"])),
                instanceNumber: instanceNumber(from: name)
            )
        }
    }

    public static func addingStats(
        _ text: String,
        to containers: [DockerContainerRecord]
    ) -> [DockerContainerRecord] {
        let statsByName = Dictionary(uniqueKeysWithValues: text.components(separatedBy: .newlines).compactMap {
            line -> (String, (Double, UInt64))? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            let name = safeName(string(object, keys: ["Name"])).lowercased()
            guard !name.isEmpty,
                  let cpuPercent = percent(string(object, keys: ["CPUPerc"])),
                  let residentBytes = memoryBytes(string(object, keys: ["MemUsage"]))
            else {
                return nil
            }
            return (name, (cpuPercent, residentBytes))
        })

        return containers.map { container in
            let stats = statsByName[container.name.lowercased()]
            return DockerContainerRecord(
                id: container.id,
                name: container.name,
                state: container.state,
                status: container.status,
                publishedPorts: container.publishedPorts,
                mountedVolumes: container.mountedVolumes,
                instanceNumber: container.instanceNumber,
                cpuPercent: stats?.0,
                residentBytes: stats?.1
            )
        }
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return ""
    }

    private static func safeName(_ value: String) -> String {
        SecretRedactor.redact(value, maximumLength: 512)
            .replacingOccurrences(of: #"[^A-Za-z0-9._/@:+-]"#, with: "?", options: .regularExpression)
    }

    private static func safeIdentifier(_ value: String) -> String {
        String(value.prefix(128)).filter { $0.isHexDigit || $0 == "-" || $0 == "_" }
    }

    private static func mountedVolumeNames(_ value: String) -> [String] {
        value.split(separator: ",").compactMap { raw in
            let name = safeName(String(raw).trimmingCharacters(in: .whitespacesAndNewlines))
            return name.isEmpty || name.contains("?") ? nil : name
        }
    }

    private static func percent(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    private static func memoryBytes(_ value: String) -> UInt64? {
        let token = value.components(separatedBy: "/").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let expression = try? NSRegularExpression(
            pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)$"#,
            options: [.caseInsensitive]
        ),
        let match = expression.firstMatch(
            in: token,
            range: NSRange(token.startIndex..<token.endIndex, in: token)
        ),
        let numberRange = Range(match.range(at: 1), in: token),
        let unitRange = Range(match.range(at: 2), in: token),
        let number = Double(token[numberRange])
        else {
            return nil
        }

        let unit = token[unitRange].lowercased()
        let multiplier: Double = switch unit {
        case "kb": 1_000
        case "kib": 1_024
        case "mb": 1_000_000
        case "mib": 1_048_576
        case "gb": 1_000_000_000
        case "gib": 1_073_741_824
        case "tb": 1_000_000_000_000
        case "tib": 1_099_511_627_776
        default: 1
        }
        let bytes = number * multiplier
        guard bytes.isFinite, bytes >= 0 else { return nil }
        guard bytes < Double(UInt64.max) else { return UInt64.max }
        return UInt64(bytes.rounded())
    }

    private static func publishedPorts(_ value: String) -> [Int] {
        guard let expression = try? NSRegularExpression(pattern: #"(?:^|[,\s])(?:[^,\s]*:)?(\d+)->\d+/(?:tcp|udp)"#) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: value),
                  let port = Int(value[capture]),
                  (1...65_535).contains(port)
            else {
                return nil
            }
            return port
        }
    }

    private static func instanceNumber(from value: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: #"(?:^|[-_])(?:instance[-_])?(\d+)(?:$|[-_])"#),
              let match = expression.matches(
                  in: value,
                  range: NSRange(value.startIndex..<value.endIndex, in: value)
              ).last,
              let range = Range(match.range(at: 1), in: value),
              let number = Int(value[range]),
              (1...999).contains(number)
        else {
            return nil
        }
        return number
    }
}
