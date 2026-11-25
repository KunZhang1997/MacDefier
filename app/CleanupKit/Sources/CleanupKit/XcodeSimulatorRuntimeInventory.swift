import Foundation

/// Read-only discovery and controlled `simctl` deletion for Xcode Simulator Runtime disk images.
/// Prefers CoreSimulator's direct `simctl` binary so it never triggers `xcrun` CLT install prompts
/// or `xcodebuild -runFirstLaunch`, and still works even after `Xcode.app` itself was uninstalled.
public enum XcodeSimulatorRuntimeInventory {
    private static let directSimctlPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"

    public struct RuntimeEntry: Equatable, Sendable {
        public let uuid: String
        public let name: String
        public let platform: String
        public let version: String
        public let build: String
        public let state: String
        public let sizeBytes: UInt64
        public let deletable: Bool
        public let isBundled: Bool
        public let lastUsedAt: Date?
        public let hasRawLastUsedAt: Bool
        public let mountPath: String?

        public var isReadyToDelete: Bool {
            state.caseInsensitiveCompare("Ready") == .orderedSame && deletable && !isBundled && sizeBytes > 0
        }

        public var isDeleting: Bool {
            state.caseInsensitiveCompare("Deleting") == .orderedSame
                || state.caseInsensitiveCompare("Unmounting") == .orderedSame
        }
    }

    public struct Environment: Sendable {
        public var isInstalled: @Sendable () -> Bool
        public var runSimctl: @Sendable ([String], TimeInterval) -> ProcessRunResult?

        public init(
            isInstalled: @escaping @Sendable () -> Bool,
            runSimctl: @escaping @Sendable ([String], TimeInterval) -> ProcessRunResult?
        ) {
            self.isInstalled = isInstalled
            self.runSimctl = runSimctl
        }

        public static let live = Environment(
            isInstalled: {
                guard FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator") else {
                    return false
                }
                if FileManager.default.isExecutableFile(atPath: directSimctlPath) {
                    return true
                }
                let hasDeveloperDir = FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer")
                    || FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools")
                return hasDeveloperDir && FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
            },
            runSimctl: { args, timeout in
                let command: [String]
                if FileManager.default.isExecutableFile(atPath: directSimctlPath) {
                    command = [directSimctlPath] + args
                } else {
                    command = ["/usr/bin/xcrun", "simctl"] + args
                }
                return try? ProcessRunner.runSync(
                    command,
                    timeout: timeout,
                    isCancelled: { Task.isCancelled }
                )
            }
        )
    }

    public static func scan(
        now: Date = Date(),
        cleanupGuard: AIToolCleanupGuard = .live,
        environment: Environment = .live,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> AICleanupInventory {
        guard !isCancelled() else {
            return AICleanupInventory(issues: ["runtime_scan_cancelled"], scannedAt: now)
        }
        guard environment.isInstalled() else {
            return AICleanupInventory(candidates: [], issues: [], scannedAt: now)
        }

        guard let entries = fetchEntries(environment: environment, isCancelled: isCancelled) else {
            let issue = isCancelled() ? "runtime_scan_cancelled" : "runtime_scan_failed"
            return AICleanupInventory(candidates: [], issues: [issue], scannedAt: now)
        }
        if isCancelled() {
            return AICleanupInventory(issues: ["runtime_scan_cancelled"], scannedAt: now)
        }
        guard !entries.isEmpty else {
            return AICleanupInventory(candidates: [], issues: [], scannedAt: now)
        }

        let xcodeActivity = cleanupGuard.boundToProcessSnapshotIfLive().state(for: .xcode)
        let candidates = entries.map { entry -> AICleanupCandidate in
            let state: AICandidateState
            let reason: String
            if entry.isDeleting {
                state = .retained
                reason = "runtime_deleting"
            } else if !entry.deletable || entry.isBundled {
                state = .retained
                reason = "xcode_bundled_runtime"
            } else if entry.sizeBytes == 0 || !entry.isReadyToDelete {
                state = .reviewOnly
                reason = "runtime_not_ready"
            } else {
                switch xcodeActivity {
                case .idle:
                    state = .ready
                    reason = (!entry.hasRawLastUsedAt && entry.lastUsedAt == nil) ? "runtime_never_used" : "simulator_runtime"
                case .inUse:
                    state = .inUse
                    reason = "in_use"
                case .unknown:
                    state = .unknown
                    reason = "probe_unknown"
                }
            }

            let title = entry.build.isEmpty ? entry.name : "\(entry.name) (\(entry.build))"
            let displayPath = entry.mountPath ?? "/Library/Developer/CoreSimulator/Runtimes/\(entry.uuid)"
            return AICleanupCandidate(
                id: "xcode:simruntime:\(entry.uuid)",
                tool: .xcode,
                kind: .simulatorRuntime,
                title: title,
                resources: [],
                reportedBytes: entry.sizeBytes,
                state: state,
                reason: reason,
                lastActivity: entry.lastUsedAt,
                metadata: [
                    "producer": "xcode_simruntime_v1",
                    "runtimeUUID": entry.uuid,
                    "version": entry.version,
                    "build": entry.build,
                    "platform": entry.platform,
                    "runtimeState": entry.state,
                    "deletable": entry.deletable ? "true" : "false",
                ],
                contextPath: displayPath
            )
        }
        return AICleanupInventory(
            candidates: candidates.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.id < $1.id
            },
            issues: [],
            scannedAt: now
        )
    }

    public static func validateRuntime(
        _ candidate: AICleanupCandidate,
        environment: Environment = .live
    ) -> Bool {
        guard candidate.tool == .xcode,
              candidate.kind == .simulatorRuntime,
              candidate.resources.isEmpty,
              candidate.reportedBytes > 0,
              candidate.metadata["producer"] == "xcode_simruntime_v1",
              let rawUUID = candidate.metadata["runtimeUUID"],
              let canonicalUUID = UUID(uuidString: rawUUID)?.uuidString,
              canonicalUUID == rawUUID,
              environment.isInstalled(),
              let entries = fetchEntries(environment: environment),
              let live = entries.first(where: { $0.uuid == canonicalUUID })
        else {
            return false
        }
        return live.isReadyToDelete
            && live.version == (candidate.metadata["version"] ?? "")
            && live.build == (candidate.metadata["build"] ?? "")
    }

    public static func deleteRuntime(
        _ candidate: AICleanupCandidate,
        environment: Environment = .live
    ) -> Bool {
        guard let rawUUID = candidate.metadata["runtimeUUID"],
              let canonicalUUID = UUID(uuidString: rawUUID)?.uuidString,
              canonicalUUID == rawUUID,
              validateRuntime(candidate, environment: environment)
        else {
            return false
        }
        guard let run = environment.runSimctl(["runtime", "delete", canonicalUUID], 30),
              run.succeeded
        else {
            return false
        }
        // On macOS 15+ / Xcode 16+, large disk-image runtimes transition immediately to `Deleting`
        // while APFS reclaims blocks asynchronously in the background, or disappear immediately.
        guard let afterEntries = fetchEntries(environment: environment) else {
            return true
        }
        if let remaining = afterEntries.first(where: { $0.uuid == canonicalUUID }) {
            return remaining.isDeleting
        }
        return true
    }

    static func fetchEntries(
        environment: Environment,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> [RuntimeEntry]? {
        guard !isCancelled() else { return nil }
        if let jsonRun = environment.runSimctl(["runtime", "list", "-j"], 5),
           jsonRun.succeeded,
           let parsed = parseJSON(jsonRun.stdout) {
            return parsed
        }
        guard !isCancelled() else { return nil }
        if let verboseRun = environment.runSimctl(["runtime", "list", "-v"], 5),
           verboseRun.succeeded {
            return parseVerboseText(verboseRun.stdoutString)
        }
        return nil
    }

    public static func parseJSON(_ data: Data) -> [RuntimeEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if root.isEmpty { return [] }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoStandard = ISO8601DateFormatter()
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        var entries: [RuntimeEntry] = []
        var sawRuntimeCandidate = false
        for (key, rawValue) in root {
            guard let dict = rawValue as? [String: Any] else { continue }
            if dict["identifier"] != nil || dict["state"] != nil || dict["sizeBytes"] != nil || UUID(uuidString: key) != nil {
                sawRuntimeCandidate = true
            }
            let rawID = (dict["identifier"] as? String) ?? key
            guard let uuid = UUID(uuidString: rawID)?.uuidString else { continue }
            let version = (dict["version"] as? String) ?? ""
            let build = (dict["build"] as? String) ?? ""
            let platformID = (dict["platformIdentifier"] as? String) ?? ""
            let platform = Self.humanPlatform(from: platformID, fallbackName: dict["name"] as? String)
            let name = (dict["name"] as? String) ?? (version.isEmpty ? platform : "\(platform) \(version)")
            let state = (dict["state"] as? String) ?? "Unknown"
            let sizeBytes: UInt64 = {
                if let n = dict["sizeBytes"] as? UInt64 { return n }
                if let n = dict["sizeBytes"] as? Int64, n >= 0 { return UInt64(n) }
                if let n = dict["sizeBytes"] as? Int, n >= 0 { return UInt64(n) }
                if let n = dict["sizeBytes"] as? NSNumber, n.int64Value >= 0 { return n.uint64Value }
                return 0
            }()
            let deletable = (dict["deletable"] as? Bool) ?? true
            let kind = (dict["kind"] as? String)?.lowercased() ?? ""
            let isBundled = kind.contains("bundled")
            let mountPath = (dict["mountPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let rawLastUsed = (dict["lastUsedAt"] as? String ?? (dict["lastUsedAt"] as? [String: Any])?["date"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasRawLastUsedAt = rawLastUsed.map { !$0.isEmpty } ?? false
            let lastUsedAt: Date? = {
                guard let rawDate = rawLastUsed, !rawDate.isEmpty else {
                    return nil
                }
                return isoFractional.date(from: rawDate)
                    ?? isoStandard.date(from: rawDate)
                    ?? fallbackFormatter.date(from: rawDate)
            }()
            entries.append(RuntimeEntry(
                uuid: uuid,
                name: name,
                platform: platform,
                version: version,
                build: build,
                state: state,
                sizeBytes: sizeBytes,
                deletable: deletable,
                isBundled: isBundled,
                lastUsedAt: lastUsedAt,
                hasRawLastUsedAt: hasRawLastUsedAt,
                mountPath: mountPath
            ))
        }
        if entries.isEmpty && !sawRuntimeCandidate {
            return nil
        }
        return entries.sorted { $0.uuid < $1.uuid }
    }

    public static func parseVerboseText(_ text: String) -> [RuntimeEntry] {
        // Matches lines like: `iOS 27.1 (24A94425) - 1F2867E1-21E0-47F0-9192-C4A4FCA39326`
        // followed by indented `State: Ready`, `Last Used At: 2026-11-15 17:30:19 +0000`, `Size: 7.3G`
        let headerRegex = try? NSRegularExpression(
            pattern: #"^([A-Za-z][A-Za-z0-9 ]*?)\s+([0-9][0-9A-Za-z._-]*)\s+\(([0-9A-Za-z]+)\)\s+-\s+([0-9A-Fa-f-]{36})(?:\s+\(([^)]+)\))?\s*$"#
        )
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoStandard = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        struct Partial {
            var uuid: String
            var platform: String
            var version: String
            var build: String
            var state: String
            var sizeBytes: UInt64 = 0
            var deletable: Bool = true
            var isBundled: Bool = false
            var lastUsedAt: Date?
            var hasRawLastUsedAt: Bool = false
            var mountPath: String?
        }

        var list: [RuntimeEntry] = []
        var current: Partial?

        func flush() {
            guard let cur = current else { return }
            list.append(RuntimeEntry(
                uuid: cur.uuid,
                name: "\(cur.platform) \(cur.version)",
                platform: cur.platform,
                version: cur.version,
                build: cur.build,
                state: cur.state,
                sizeBytes: cur.sizeBytes,
                deletable: cur.deletable,
                isBundled: cur.isBundled,
                lastUsedAt: cur.lastUsedAt,
                hasRawLastUsedAt: cur.hasRawLastUsedAt,
                mountPath: cur.mountPath
            ))
            current = nil
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let ns = NSRange(line.startIndex..<line.endIndex, in: line)
                if let m = headerRegex?.firstMatch(in: line, options: [], range: ns),
                   let rPlat = Range(m.range(at: 1), in: line),
                   let rVer = Range(m.range(at: 2), in: line),
                   let rBuild = Range(m.range(at: 3), in: line),
                   let rUUID = Range(m.range(at: 4), in: line),
                   let canonicalUUID = UUID(uuidString: String(line[rUUID]))?.uuidString {
                    flush()
                    let inlineState = m.range(at: 5).location != NSNotFound
                        ? Range(m.range(at: 5), in: line).map { String(line[$0]) } ?? "Ready"
                        : "Ready"
                    current = Partial(
                        uuid: canonicalUUID,
                        platform: String(line[rPlat]),
                        version: String(line[rVer]),
                        build: String(line[rBuild]),
                        state: inlineState
                    )
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard current != nil else { continue }
            if trimmed.hasPrefix("State:") {
                current?.state = trimmed.dropFirst("State:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Last Used At:") {
                let rawDate = trimmed.dropFirst("Last Used At:".count).trimmingCharacters(in: .whitespaces)
                if !rawDate.isEmpty, rawDate.lowercased() != "(null)", rawDate.lowercased() != "none" {
                    current?.hasRawLastUsedAt = true
                    current?.lastUsedAt = dateFormatter.date(from: rawDate)
                        ?? isoFractional.date(from: rawDate)
                        ?? isoStandard.date(from: rawDate)
                }
            } else if trimmed.hasPrefix("Size:") {
                let rawSize = trimmed.dropFirst("Size:".count).trimmingCharacters(in: .whitespaces)
                current?.sizeBytes = parseHumanSize(rawSize)
            } else if trimmed.hasPrefix("Deletable:") {
                let val = trimmed.dropFirst("Deletable:".count).trimmingCharacters(in: .whitespaces).lowercased()
                current?.deletable = (val == "yes" || val == "true" || val == "1")
            } else if trimmed.hasPrefix("Image Kind:") {
                let kindVal = trimmed.dropFirst("Image Kind:".count).trimmingCharacters(in: .whitespaces).lowercased()
                if kindVal.contains("bundled") {
                    current?.isBundled = true
                }
            } else if trimmed.hasPrefix("Mount Path:") {
                let mp = trimmed.dropFirst("Mount Path:".count).trimmingCharacters(in: .whitespaces)
                if !mp.isEmpty { current?.mountPath = mp }
            }
        }
        flush()
        return list
    }

    private static func parseHumanSize(_ raw: String) -> UInt64 {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let numPart = trimmed.prefix { $0.isNumber || $0 == "." }
        let unitPart = trimmed.dropFirst(numPart.count).trimmingCharacters(in: .whitespaces).uppercased()
        guard let val = Double(numPart), val.isFinite, val >= 0 else { return 0 }
        let mult: Double
        if unitPart.hasPrefix("T") { mult = 1_000_000_000_000 }
        else if unitPart.hasPrefix("G") { mult = 1_000_000_000 }
        else if unitPart.hasPrefix("M") { mult = 1_000_000 }
        else if unitPart.hasPrefix("K") { mult = 1_000 }
        else { mult = 1 }
        let bytes = val * mult
        guard bytes < Double(UInt64.max) else { return UInt64.max }
        return UInt64(bytes)
    }

    private static func humanPlatform(from platformID: String, fallbackName: String?) -> String {
        let lower = platformID.lowercased()
        if lower.contains("iphone") || lower.contains(".ios") { return "iOS" }
        if lower.contains("watch") { return "watchOS" }
        if lower.contains("appletv") || lower.contains("tvos") { return "tvOS" }
        if lower.contains("xrsimulator") || lower.contains("vision") { return "visionOS" }
        if let fallbackName, let first = fallbackName.split(separator: " ").first {
            return String(first)
        }
        return "iOS"
    }
}
