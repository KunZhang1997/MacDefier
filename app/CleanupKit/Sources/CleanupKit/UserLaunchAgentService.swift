import CryptoKit
import Darwin
import Foundation

public struct UserLaunchAgentEvidence: Hashable, Sendable {
    let snapshot: UninstallFileBoundary.Snapshot
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let label: String
    let contentSHA256: String
}

public enum UserLaunchAgentRunState: String, Equatable, Sendable {
    case running
    case loadedIdle
    case paused
    case unknown
}

public struct UserLaunchAgentItem: Identifiable, Equatable, Sendable {
    public var id: String { plistPath }
    public let label: String
    public let displayName: String
    public let plistPath: String
    public let programPath: String?
    public let targetPath: String?
    public let appBundlePath: String?
    public let isKeepAlive: Bool
    public let isRunAtLoad: Bool
    public let isDisabledInPlist: Bool
    public let targetExistsOnDisk: Bool
    public var runState: UserLaunchAgentRunState
    public var pid: Int?
    public var processStartMicros: UInt64?
    public var lastExitStatus: Int?
    let evidence: UserLaunchAgentEvidence

    public var isLoaded: Bool {
        runState == .running || runState == .loadedIdle
    }
}

public struct UserLaunchAgentScanResult: Equatable, Sendable {
    public let items: [UserLaunchAgentItem]
    public let probeFailed: Bool

    public init(items: [UserLaunchAgentItem], probeFailed: Bool) {
        self.items = items
        self.probeFailed = probeFailed
    }
}

public struct UserLaunchAgentActionResult: Equatable, Sendable {
    public let ok: Bool
    public let errorCode: String?
    public let trashedPath: String?

    public init(ok: Bool, errorCode: String? = nil, trashedPath: String? = nil) {
        self.ok = ok
        self.errorCode = errorCode
        self.trashedPath = trashedPath
    }
}

/// Governance for user-owned `~/Library/LaunchAgents/*.plist` services.
/// Supports non-destructive pause (`launchctl bootout` without deleting the plist),
/// resume (`launchctl bootstrap`), and explicit Trash removal (`bootout` + `UninstallFileBoundary.move`).
public enum UserLaunchAgentService {
    struct Environment: Sendable {
        var uid: @Sendable () -> uid_t
        var runLaunchctl: @Sendable ([String], TimeInterval) -> ProcessRunResult?
        var fileExists: @Sendable (String) -> Bool
        var recycle: @Sendable (UninstallFileBoundary.Snapshot) throws -> String

        init(
            uid: @escaping @Sendable () -> uid_t = { getuid() },
            runLaunchctl: @escaping @Sendable ([String], TimeInterval) -> ProcessRunResult?,
            fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
            recycle: @escaping @Sendable (UninstallFileBoundary.Snapshot) throws -> String = { try UninstallFileBoundary.move($0) }
        ) {
            self.uid = uid
            self.runLaunchctl = runLaunchctl
            self.fileExists = fileExists
            self.recycle = recycle
        }

        static let live = Environment(
            runLaunchctl: { args, timeout in
                try? ProcessRunner.runSync(
                    ["/bin/launchctl"] + args,
                    timeout: timeout,
                    isCancelled: { Task.isCancelled }
                )
            }
        )
    }

    private static let maxPlistBytes: off_t = 512 * 1024
    private static let shells: Set<String> = ["sh", "bash", "zsh"]
    private static let interpreters: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl", "bash", "sh", "zsh", "env"
    ]
    private static let valueTakingFlags: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader",
        "-I", "-C", "-W", "-X", "--config"
    ]
    private static let inlineEvalFlags: Set<String> = [
        "-e", "--eval", "-p", "--print", "-c", "-m", "--command"
    ]
    private static let defaultSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    public static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 200, !label.contains("..") else { return false }
        let lower = label.lowercased()
        if lower.hasPrefix("com.apple.") || lower == "com.macdefier.app" || lower.hasPrefix("com.macdefier.") {
            return false
        }
        guard let first = label.unicodeScalars.first,
              (first.value >= 0x30 && first.value <= 0x39)
                  || (first.value >= 0x41 && first.value <= 0x5A)
                  || (first.value >= 0x61 && first.value <= 0x7A)
        else {
            return false
        }
        for scalar in label.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x30 && v <= 0x39)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A)
                || v == 0x2E // .
                || v == 0x5F // _
                || v == 0x2D // -
                || v == 0x40 // @ (e.g. homebrew.mxcl.postgresql@15, mysql@8.4)
                || v == 0x2B // +
            if !ok { return false }
        }
        return true
    }

    public static func defaultSort(_ items: [UserLaunchAgentItem]) -> [UserLaunchAgentItem] {
        items.sorted { lhs, rhs in
            let lRank = sortRank(lhs)
            let rRank = sortRank(rhs)
            if lRank != rRank { return lRank < rRank }
            let nameCmp = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return lhs.plistPath < rhs.plistPath
        }
    }

    public static func scan(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> UserLaunchAgentScanResult {
        scan(home: home, environment: .live, isCancelled: isCancelled)
    }

    static func scan(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: Environment,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> UserLaunchAgentScanResult {
        guard !isCancelled() else { return UserLaunchAgentScanResult(items: [], probeFailed: true) }
        let launchAgentsDir = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        let uid = environment.uid()

        guard isSafeLaunchAgentsDirectory(launchAgentsDir, home: home, uid: uid) else {
            return UserLaunchAgentScanResult(items: [], probeFailed: false)
        }
        let canonicalDir = URL(fileURLWithPath: launchAgentsDir).resolvingSymlinksInPath().path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: launchAgentsDir) else {
            return UserLaunchAgentScanResult(items: [], probeFailed: false)
        }

        let statuses = queryLaunchctlStatuses(environment: environment)
        let probeFailed = (statuses == nil)

        var parsedPlists: [(path: String, parsed: VerifiedPlist)] = []
        var labelCounts: [String: Int] = [:]
        for name in names.sorted() where name.lowercased().hasSuffix(".plist") {
            if isCancelled() { return UserLaunchAgentScanResult(items: [], probeFailed: true) }
            let path = (launchAgentsDir as NSString).appendingPathComponent(name)
            guard let parsed = readVerifiedPlist(
                at: path,
                canonicalDir: canonicalDir,
                uid: uid,
                fileExists: environment.fileExists
            ) else {
                continue
            }
            parsedPlists.append((path: path, parsed: parsed))
            labelCounts[parsed.label, default: 0] += 1
        }

        var loadedPathCache: [String: String?] = [:]
        var items: [UserLaunchAgentItem] = []
        for entry in parsedPlists {
            if isCancelled() { return UserLaunchAgentScanResult(items: items, probeFailed: true) }
            let path = entry.path
            let parsed = entry.parsed

            let runState: UserLaunchAgentRunState
            var pid: Int?
            var startMicros: UInt64?
            var exitStatus: Int?

            if let statuses {
                if let live = statuses[parsed.label] {
                    let loadedPath: String?
                    if let cached = loadedPathCache[parsed.label] {
                        loadedPath = cached
                    } else {
                        let queried = queryLoadedPlistPath(uid: uid, label: parsed.label, environment: environment)
                        loadedPathCache[parsed.label] = queried
                        loadedPath = queried
                    }

                    if let loadedPath {
                        if PathGate.normalize(loadedPath) == PathGate.normalize(path) {
                            pid = live.pid
                            startMicros = live.pid.flatMap { liveProcessInfo(for: $0)?.startMicros }
                            exitStatus = live.exitStatus
                            runState = (live.pid != nil) ? .running : .loadedIdle
                        } else {
                            runState = .paused
                        }
                    } else if (labelCounts[parsed.label] ?? 0) > 1 {
                        // Ambiguous duplicate label without `launchctl print` path disambiguation
                        runState = .unknown
                    } else {
                        pid = live.pid
                        startMicros = live.pid.flatMap { liveProcessInfo(for: $0)?.startMicros }
                        exitStatus = live.exitStatus
                        runState = (live.pid != nil) ? .running : .loadedIdle
                    }
                } else {
                    runState = .paused
                }
            } else {
                runState = .unknown
            }

            items.append(UserLaunchAgentItem(
                label: parsed.label,
                displayName: parsed.displayName,
                plistPath: path,
                programPath: parsed.programPath,
                targetPath: parsed.targetPath,
                appBundlePath: parsed.appBundlePath,
                isKeepAlive: parsed.isKeepAlive,
                isRunAtLoad: parsed.isRunAtLoad,
                isDisabledInPlist: parsed.isDisabledInPlist,
                targetExistsOnDisk: parsed.targetExistsOnDisk,
                runState: runState,
                pid: pid,
                processStartMicros: startMicros,
                lastExitStatus: exitStatus,
                evidence: parsed.evidence
            ))
        }

        return UserLaunchAgentScanResult(items: defaultSort(items), probeFailed: probeFailed)
    }

    public static func pause(
        _ item: UserLaunchAgentItem,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) async -> UserLaunchAgentActionResult {
        await pause(item, home: home, environment: .live)
    }

    static func pause(
        _ item: UserLaunchAgentItem,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: Environment
    ) async -> UserLaunchAgentActionResult {
        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: [item.plistPath]) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "busy")
        }
        let outcome = pauseLocked(item, home: home, environment: environment)
        await ResourceMutationCoordinator.shared.release(lease)
        return outcome
    }

    private static func pauseLocked(
        _ item: UserLaunchAgentItem,
        home: String,
        environment: Environment
    ) -> UserLaunchAgentActionResult {
        let uid = environment.uid()
        let launchAgentsDir = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        guard stillMatches(item, home: home, uid: uid, fileExists: environment.fileExists),
              isValidLabel(item.label)
        else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "changed")
        }

        let loadedPath = queryLoadedPlistPath(uid: uid, label: item.label, environment: environment)
        if let loadedPath, PathGate.normalize(loadedPath) != PathGate.normalize(item.plistPath) {
            return UserLaunchAgentActionResult(ok: false, errorCode: "pause_failed")
        }
        let hasSibling = hasSiblingWithSameLabel(item, launchAgentsDir: launchAgentsDir, uid: uid, fileExists: environment.fileExists)

        let domain = "gui/\(uid)"
        let r1 = environment.runLaunchctl(["bootout", domain, item.plistPath], 12)
        if r1?.succeeded != true, loadedPath == nil, !hasSibling {
            guard stillMatches(item, home: home, uid: uid, fileExists: environment.fileExists) else {
                return UserLaunchAgentActionResult(ok: false, errorCode: "changed")
            }
            _ = environment.runLaunchctl(["bootout", "\(domain)/\(item.label)"], 12)
        }

        guard let statuses = queryLaunchctlStatuses(environment: environment) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "status_probe_failed")
        }
        if statuses[item.label] != nil {
            if let afterLoaded = queryLoadedPlistPath(uid: uid, label: item.label, environment: environment),
               PathGate.normalize(afterLoaded) != PathGate.normalize(item.plistPath) {
                return UserLaunchAgentActionResult(ok: true)
            }
            return UserLaunchAgentActionResult(ok: false, errorCode: "pause_failed")
        }
        return UserLaunchAgentActionResult(ok: true)
    }

    public static func resume(
        _ item: UserLaunchAgentItem,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) async -> UserLaunchAgentActionResult {
        await resume(item, home: home, environment: .live)
    }

    static func resume(
        _ item: UserLaunchAgentItem,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: Environment
    ) async -> UserLaunchAgentActionResult {
        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: [item.plistPath]) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "busy")
        }
        let outcome = resumeLocked(item, home: home, environment: environment)
        await ResourceMutationCoordinator.shared.release(lease)
        return outcome
    }

    private static func resumeLocked(
        _ item: UserLaunchAgentItem,
        home: String,
        environment: Environment
    ) -> UserLaunchAgentActionResult {
        let launchAgentsDir = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        let uid = environment.uid()
        let canonicalDir = URL(fileURLWithPath: launchAgentsDir).resolvingSymlinksInPath().path
        guard isSafeLaunchAgentsDirectory(launchAgentsDir, home: home, uid: uid),
              let fresh = readVerifiedPlist(at: item.plistPath, canonicalDir: canonicalDir, uid: uid, fileExists: environment.fileExists),
              fresh.evidence == item.evidence,
              isValidLabel(item.label)
        else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "changed")
        }
        guard fresh.targetExistsOnDisk else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "target_missing")
        }
        let hasSibling = hasSiblingWithSameLabel(item, launchAgentsDir: launchAgentsDir, uid: uid, fileExists: environment.fileExists)

        let domain = "gui/\(uid)"
        let r1 = environment.runLaunchctl(["bootstrap", domain, item.plistPath], 12)
        if r1?.succeeded != true, !hasSibling {
            guard stillMatches(item, home: home, uid: uid, fileExists: environment.fileExists) else {
                return UserLaunchAgentActionResult(ok: false, errorCode: "changed")
            }
            _ = environment.runLaunchctl(["enable", "\(domain)/\(item.label)"], 8)
            _ = environment.runLaunchctl(["bootstrap", domain, item.plistPath], 12)
        }

        guard let statuses = queryLaunchctlStatuses(environment: environment) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "status_probe_failed")
        }
        guard statuses[item.label] != nil else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "resume_failed")
        }
        if let loadedPath = queryLoadedPlistPath(uid: uid, label: item.label, environment: environment),
           PathGate.normalize(loadedPath) != PathGate.normalize(item.plistPath) {
            return UserLaunchAgentActionResult(ok: false, errorCode: "resume_failed")
        }
        return UserLaunchAgentActionResult(ok: true)
    }

    public static func moveToTrash(
        _ item: UserLaunchAgentItem,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) async -> UserLaunchAgentActionResult {
        await moveToTrash(item, home: home, environment: .live)
    }

    static func moveToTrash(
        _ item: UserLaunchAgentItem,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: Environment
    ) async -> UserLaunchAgentActionResult {
        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: [item.plistPath]) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "busy")
        }
        let outcome = moveToTrashLocked(item, home: home, environment: environment)
        await ResourceMutationCoordinator.shared.release(lease)
        return outcome
    }

    private static func moveToTrashLocked(
        _ item: UserLaunchAgentItem,
        home: String,
        environment: Environment
    ) -> UserLaunchAgentActionResult {
        let uid = environment.uid()
        let launchAgentsDir = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        guard stillMatches(item, home: home, uid: uid, fileExists: environment.fileExists),
              isValidLabel(item.label)
        else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "changed")
        }

        guard let beforeStatuses = queryLaunchctlStatuses(environment: environment) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "status_probe_failed")
        }
        if beforeStatuses[item.label] != nil {
            let loadedPath = queryLoadedPlistPath(uid: uid, label: item.label, environment: environment)
            let ownedByOtherPlist = loadedPath.map { PathGate.normalize($0) != PathGate.normalize(item.plistPath) } ?? false
            if !ownedByOtherPlist {
                let hasSibling = hasSiblingWithSameLabel(item, launchAgentsDir: launchAgentsDir, uid: uid, fileExists: environment.fileExists)
                if loadedPath == nil && hasSibling {
                    return UserLaunchAgentActionResult(ok: false, errorCode: "pause_failed")
                }
                let domain = "gui/\(uid)"
                let r1 = environment.runLaunchctl(["bootout", domain, item.plistPath], 12)
                if r1?.succeeded != true, loadedPath == nil, !hasSibling {
                    guard stillMatches(item, home: home, uid: uid, fileExists: environment.fileExists) else {
                        return UserLaunchAgentActionResult(ok: false, errorCode: "changed")
                    }
                    _ = environment.runLaunchctl(["bootout", "\(domain)/\(item.label)"], 12)
                }
                guard let afterStatuses = queryLaunchctlStatuses(environment: environment) else {
                    return UserLaunchAgentActionResult(ok: false, errorCode: "status_probe_failed")
                }
                if afterStatuses[item.label] != nil {
                    let afterLoaded = queryLoadedPlistPath(uid: uid, label: item.label, environment: environment)
                    let nowOwnedByOther = afterLoaded.map { PathGate.normalize($0) != PathGate.normalize(item.plistPath) } ?? false
                    if !nowOwnedByOther {
                        return UserLaunchAgentActionResult(ok: false, errorCode: "pause_failed")
                    }
                }
            }
        }

        guard stillMatches(item, home: home, uid: uid, fileExists: environment.fileExists) else {
            return UserLaunchAgentActionResult(ok: false, errorCode: "changed")
        }

        do {
            let destination = try environment.recycle(item.evidence.snapshot)
            guard UninstallFileBoundary.isMissing(item.plistPath),
                  UninstallFileBoundary.matchesTrashedItem(item.evidence.snapshot.item, at: destination)
            else {
                return UserLaunchAgentActionResult(ok: false, errorCode: "changed")
            }
            CleanupResourceEvents.publish(paths: [item.plistPath])
            return UserLaunchAgentActionResult(ok: true, trashedPath: destination)
        } catch {
            return UserLaunchAgentActionResult(ok: false, errorCode: "trash_failed")
        }
    }

    /// Live parent-PID chain supervisor lookup with process birth-time (`pbi_start_tvsec`) validation
    /// so PID reuse across cached reports can never misattribute a child process.
    public static func findSupervisorService(
        forPID childPID: Int,
        in services: [UserLaunchAgentItem]
    ) -> UserLaunchAgentItem? {
        guard childPID > 1 else { return nil }
        var byPID: [Int: UserLaunchAgentItem] = [:]
        for svc in services where svc.runState == .running {
            if let p = svc.pid, p > 1 {
                byPID[p] = svc
            }
        }
        guard !byPID.isEmpty, var currentInfo = liveProcessInfo(for: childPID) else { return nil }
        var current = childPID
        var visited = Set<Int>()
        for _ in 0..<8 {
            if let hit = byPID[current] {
                if let expectedStart = hit.processStartMicros, expectedStart != currentInfo.startMicros {
                    return nil
                }
                return hit
            }
            let parent = currentInfo.ppid
            guard visited.insert(current).inserted,
                  parent > 1,
                  parent != current,
                  let parentInfo = liveProcessInfo(for: parent),
                  parentInfo.startMicros <= currentInfo.startMicros
            else {
                break
            }
            current = parent
            currentInfo = parentInfo
        }
        return nil
    }

    /// Mockable parent-PID chain supervisor lookup for unit tests.
    static func findSupervisorService(
        forPID childPID: Int,
        in services: [UserLaunchAgentItem],
        parentPIDProvider: (Int) -> Int?
    ) -> UserLaunchAgentItem? {
        guard childPID > 1 else { return nil }
        var byPID: [Int: UserLaunchAgentItem] = [:]
        for svc in services where svc.runState == .running {
            if let p = svc.pid, p > 1 {
                byPID[p] = svc
            }
        }
        guard !byPID.isEmpty else { return nil }
        var current = childPID
        var visited = Set<Int>()
        for _ in 0..<8 {
            if let hit = byPID[current] { return hit }
            guard visited.insert(current).inserted,
                  let parent = parentPIDProvider(current),
                  parent > 1,
                  parent != current
            else {
                break
            }
            current = parent
        }
        return nil
    }

    public static func liveProcessInfo(for pid: Int) -> (ppid: Int, startMicros: UInt64)? {
        guard let pid32 = pid_t(exactly: pid), pid32 > 1 else { return nil }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let got = proc_pidinfo(pid32, PROC_PIDTBSDINFO, 0, &info, expected)
        guard got == expected else { return nil }
        let ppid = Int(info.pbi_ppid)
        let start = UInt64(info.pbi_start_tvsec) &* 1_000_000 &+ UInt64(info.pbi_start_tvusec)
        return (ppid: ppid, startMicros: start)
    }

    // MARK: - Internal Helpers

    private struct VerifiedPlist {
        let label: String
        let displayName: String
        let programPath: String?
        let targetPath: String?
        let appBundlePath: String?
        let isKeepAlive: Bool
        let isRunAtLoad: Bool
        let isDisabledInPlist: Bool
        let targetExistsOnDisk: Bool
        let evidence: UserLaunchAgentEvidence
    }

    private static func hasSiblingWithSameLabel(
        _ item: UserLaunchAgentItem,
        launchAgentsDir: String,
        uid: uid_t,
        fileExists: (String) -> Bool
    ) -> Bool {
        let canonicalDir = URL(fileURLWithPath: launchAgentsDir).resolvingSymlinksInPath().path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: launchAgentsDir) else {
            return false
        }
        let selfNorm = PathGate.normalize(item.plistPath)
        for name in names where name.lowercased().hasSuffix(".plist") {
            let candidatePath = (launchAgentsDir as NSString).appendingPathComponent(name)
            if PathGate.normalize(candidatePath) == selfNorm { continue }
            if let other = readVerifiedPlist(at: candidatePath, canonicalDir: canonicalDir, uid: uid, fileExists: fileExists),
               other.label == item.label {
                return true
            }
        }
        return false
    }

    private static func isSafeLaunchAgentsDirectory(_ dir: String, home: String, uid: uid_t) -> Bool {
        let libDir = (home as NSString).appendingPathComponent("Library")
        for check in [libDir, dir] {
            var st = stat()
            guard lstat(check, &st) == 0 else { return false }
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }
            guard st.st_uid == uid else { return false }
        }
        return AIToolCleanupScanner.isPhysical(dir)
    }

    private static func stillMatches(
        _ item: UserLaunchAgentItem,
        home: String,
        uid: uid_t,
        fileExists: (String) -> Bool
    ) -> Bool {
        let launchAgentsDir = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        guard isSafeLaunchAgentsDirectory(launchAgentsDir, home: home, uid: uid) else { return false }
        let canonicalDir = URL(fileURLWithPath: launchAgentsDir).resolvingSymlinksInPath().path
        guard let fresh = readVerifiedPlist(
            at: item.plistPath,
            canonicalDir: canonicalDir,
            uid: uid,
            fileExists: fileExists
        ) else {
            return false
        }
        return fresh.evidence == item.evidence && UninstallFileBoundary.stillMatches(item.evidence.snapshot)
    }

    private static func readVerifiedPlist(
        at path: String,
        canonicalDir: String,
        uid: uid_t,
        fileExists: (String) -> Bool
    ) -> VerifiedPlist? {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL
        guard lexical.pathExtension.lowercased() == "plist",
              lexical.deletingLastPathComponent().resolvingSymlinksInPath().path == canonicalDir,
              AIToolCleanupScanner.isPhysical(path),
              let snapshot = try? UninstallFileBoundary.snapshot(path),
              snapshot.item.kind == mode_t(S_IFREG),
              snapshot.item.owner == uid
        else {
            return nil
        }

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              st.st_uid == uid,
              st.st_size > 0,
              st.st_size <= maxPlistBytes,
              UninstallFileBoundary.Identity(st) == snapshot.item
        else {
            return nil
        }

        guard let data = readAllBytes(fd: fd, maxBytes: Int(maxPlistBytes)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let rawLabel = plist["Label"] as? String
        else {
            return nil
        }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label == rawLabel, isValidLabel(label) else { return nil }
        guard UninstallFileBoundary.stillMatches(snapshot) else { return nil }

        let (program, target) = extractProgramAndTarget(from: plist)
        let isKeepAlive = parseKeepAlive(plist["KeepAlive"])
        let isRunAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        let isDisabledInPlist = (plist["Disabled"] as? Bool) ?? false
        let targetExists = verifyTargetExists(
            plist: plist,
            program: program,
            target: target,
            fileExists: fileExists
        )

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let appBundlePath = resolveAppBundlePath(programPath: program, targetPath: target, fileExists: fileExists)
        let displayName = deriveDisplayName(label: label, programPath: program, targetPath: target)
        let evidence = UserLaunchAgentEvidence(
            snapshot: snapshot,
            size: st.st_size,
            modifiedSeconds: st.st_mtimespec.tv_sec,
            modifiedNanoseconds: st.st_mtimespec.tv_nsec,
            label: label,
            contentSHA256: digest
        )
        return VerifiedPlist(
            label: label,
            displayName: displayName,
            programPath: program,
            targetPath: target,
            appBundlePath: appBundlePath,
            isKeepAlive: isKeepAlive,
            isRunAtLoad: isRunAtLoad,
            isDisabledInPlist: isDisabledInPlist,
            targetExistsOnDisk: targetExists,
            evidence: evidence
        )
    }

    private static func verifyTargetExists(
        plist: [String: Any],
        program: String?,
        target: String?,
        fileExists: (String) -> Bool
    ) -> Bool {
        if program == nil && target == nil {
            if let bundleProg = (plist["BundleProgram"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleProg.isEmpty {
                return true
            }
            return false
        }

        if let program {
            if program.hasPrefix("/") {
                if !fileExists(program) { return false }
            } else if program.contains("/") {
                if let wd = (plist["WorkingDirectory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   wd.hasPrefix("/") {
                    let resolved = URL(fileURLWithPath: wd).appendingPathComponent(program).standardizedFileURL.path
                    if !fileExists(resolved) { return false }
                }
            } else {
                let envPath = (plist["EnvironmentVariables"] as? [String: Any])?["PATH"] as? String ?? defaultSearchPath
                let foundInPath = envPath.split(separator: ":").contains { dir in
                    guard !dir.isEmpty else { return false }
                    let candidate = (String(dir) as NSString).appendingPathComponent(program)
                    return fileExists(candidate)
                }
                if !foundInPath { return false }
            }
        }

        if let target, target.hasPrefix("/"), target != program {
            if !fileExists(target) { return false }
        }
        return true
    }

    private static func readAllBytes(fd: Int32, maxBytes: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(fd, base, ptr.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            if data.count + n > maxBytes { return nil }
            data.append(buffer, count: n)
        }
        return data
    }

    static func parseKeepAlive(_ raw: Any?) -> Bool {
        if let flag = raw as? Bool { return flag }
        if let dict = raw as? [String: Any] {
            return !dict.isEmpty
        }
        return false
    }

    static func extractProgramAndTarget(from plist: [String: Any]) -> (program: String?, target: String?) {
        let args = (plist["ProgramArguments"] as? [String]) ?? []
        let rawProg = (plist["Program"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstArg = args.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = (rawProg?.isEmpty == false ? rawProg : nil) ?? (firstArg?.isEmpty == false ? firstArg : nil)
        guard let primary else { return (nil, nil) }

        var base = URL(fileURLWithPath: primary).lastPathComponent.lowercased()
        guard interpreters.contains(base), args.count > 1 else {
            return (primary, nil)
        }

        var idx = 1
        if base == "env" {
            while idx < args.count {
                let token = args[idx]
                if token.hasPrefix("-") || token.contains("=") {
                    idx += 1
                    continue
                }
                let innerBase = URL(fileURLWithPath: token).lastPathComponent.lowercased()
                if interpreters.contains(innerBase) {
                    base = innerBase
                    idx += 1
                    break
                }
                return (primary, resolveScriptPath(token, plist: plist))
            }
        }

        if (base == "bun" || base == "deno"), idx < args.count, args[idx] == "run" {
            idx += 1
        }

        while idx < args.count {
            let token = args[idx]
            if shells.contains(base) {
                if token == "--command" { return (primary, nil) }
                if token.hasPrefix("-"), !token.hasPrefix("--"), token.dropFirst().contains("c") {
                    // Inline shell command (`sh -c ...`, `zsh -lc ...`), not a script file path
                    return (primary, nil)
                }
            }
            if inlineEvalFlags.contains(token) {
                return (primary, nil)
            }
            if valueTakingFlags.contains(token) {
                idx += 2
                continue
            }
            if token == "--" {
                idx += 1
                break
            }
            if token.hasPrefix("-") {
                idx += 1
                continue
            }
            return (primary, resolveScriptPath(token, plist: plist))
        }

        if idx < args.count {
            return (primary, resolveScriptPath(args[idx], plist: plist))
        }
        return (primary, nil)
    }

    private static func resolveScriptPath(_ token: String, plist: [String: Any]) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return trimmed }
        if let wd = (plist["WorkingDirectory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           wd.hasPrefix("/") {
            return URL(fileURLWithPath: wd).appendingPathComponent(trimmed).standardizedFileURL.path
        }
        return nil
    }

    private static func resolveAppBundlePath(
        programPath: String?,
        targetPath: String?,
        fileExists: (String) -> Bool
    ) -> String? {
        for candidate in [targetPath, programPath].compactMap({ $0 }) {
            if let appRange = candidate.range(of: ".app/", options: .caseInsensitive) {
                let appPath = String(candidate[..<appRange.upperBound].dropLast())
                if fileExists(appPath) { return appPath }
            }
        }
        return nil
    }

    private static let knownBrandTitles: [String: String] = [
        "mysql": "MySQL",
        "postgresql": "PostgreSQL",
        "postgres": "PostgreSQL",
        "redis": "Redis",
        "mongodb": "MongoDB",
        "mariadb": "MariaDB",
        "nginx": "Nginx",
        "ollama": "Ollama",
        "openclaw": "OpenClaw",
        "workbuddy": "WorkBuddy",
        "chatgpt": "ChatGPT",
        "vscode": "VS Code",
        "antigravity": "Antigravity",
        "cursor": "Cursor",
        "windsurf": "Windsurf",
        "claude": "Claude",
        "codex": "Codex",
        "docker": "Docker",
        "syncthing": "Syncthing",
    ]

    private static func prettifyToken(_ raw: String) -> String {
        if let atIdx = raw.firstIndex(of: "@") {
            let namePart = String(raw[..<atIdx])
            let verPart = String(raw[raw.index(after: atIdx)...])
            let baseTitle = prettifyToken(namePart)
            return verPart.isEmpty ? baseTitle : "\(baseTitle) \(verPart)"
        }
        let lower = raw.lowercased()
        if let known = knownBrandTitles[lower] { return known }
        switch lower {
        case "mcp": return "MCP"
        case "cli": return "CLI"
        case "ui": return "UI"
        case "api": return "API"
        case "macos", "mac": return "Mac"
        default:
            guard let head = raw.first else { return raw }
            return String(head).uppercased() + raw.dropFirst()
        }
    }

    static func deriveDisplayName(label: String, programPath: String?, targetPath: String?) -> String {
        for candidate in [targetPath, programPath].compactMap({ $0 }) {
            if let appRange = candidate.range(of: ".app/", options: .caseInsensitive) {
                let appPath = String(candidate[..<appRange.upperBound].dropLast())
                let appName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
                if !appName.isEmpty { return appName }
            }
        }
        let lower = label.lowercased()
        if lower.hasPrefix("homebrew.mxcl.") {
            let pkg = String(label.dropFirst("homebrew.mxcl.".count))
            return pkg.isEmpty ? label : prettifyToken(pkg)
        }
        let ignoredPrefixes: Set<String> = ["com", "org", "io", "ai", "net", "app", "dev", "me", "co", "cn"]
        var parts = label
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { !$0.isEmpty }
        if let first = parts.first, ignoredPrefixes.contains(first.lowercased()), parts.count > 1 {
            parts.removeFirst()
        }
        guard !parts.isEmpty else { return label }
        return parts.prefix(4).map(prettifyToken).joined(separator: " ")
    }

    static func queryLoadedPlistPath(
        uid: uid_t,
        label: String,
        environment: Environment
    ) -> String? {
        guard isValidLabel(label),
              let run = environment.runLaunchctl(["print", "gui/\(uid)/\(label)"], 4),
              run.succeeded
        else {
            return nil
        }
        return parseLaunchctlPrintPath(run.stdoutString)
    }

    static func parseLaunchctlPrintPath(_ output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("path = ") {
                let value = String(trimmed.dropFirst("path = ".count)).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("/") { return value }
            }
        }
        return nil
    }

    static func queryLaunchctlStatuses(
        environment: Environment
    ) -> [String: (pid: Int?, exitStatus: Int?)]? {
        guard let run = environment.runLaunchctl(["list"], 6), run.succeeded else {
            return nil
        }
        return parseLaunchctlListOutput(run.stdoutString)
    }

    public static func parseLaunchctlListOutput(_ output: String) -> [String: (pid: Int?, exitStatus: Int?)] {
        var result: [String: (pid: Int?, exitStatus: Int?)] = [:]
        for (lineIdx, rawLine) in output.split(whereSeparator: \.isNewline).enumerated() {
            let line = String(rawLine)
            if lineIdx == 0, line.lowercased().hasPrefix("pid") { continue }
            let tabCols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let cols: [String]
            if tabCols.count == 3 {
                cols = tabCols
            } else {
                cols = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
            guard cols.count == 3 else { continue }
            let pidStr = cols[0]
            let statusStr = cols[1]
            let label = cols[2].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            let pid = (pidStr == "-") ? nil : Int(pidStr)
            let exitCode = (statusStr == "-") ? nil : Int(statusStr)
            result[label] = (pid: pid, exitStatus: exitCode)
        }
        return result
    }

    private static func sortRank(_ item: UserLaunchAgentItem) -> Int {
        switch item.runState {
        case .running:
            return item.isKeepAlive ? 0 : 1
        case .loadedIdle:
            return item.isKeepAlive ? 2 : 3
        case .unknown:
            return 4
        case .paused:
            return 5
        }
    }
}
