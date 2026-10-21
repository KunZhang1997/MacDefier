import CryptoKit
import Darwin
import Foundation

/// Fixed rebuildable leaves only. Durable profiles, auth, memories, sessions,
/// indexes, model blobs, and worktrees never become cache targets.
public enum AIToolCleanupScanner {
    struct CacheTarget { let tool: AITool; let path: String; let name: String }
    struct VersionTarget { let tool: AITool; let root: String; let activeLink: String }
    struct Measurement { let bytes: UInt64; let signature: String; let complete: Bool }

    static func cacheTargets(home: String) -> [CacheTarget] {
        var result: [CacheTarget] = []
        func add(_ tool: AITool, _ relative: String, _ name: String) {
            result.append(CacheTarget(tool: tool, path: home + "/" + relative, name: name))
        }
        // Six measured Codex Chromium leaves, without any Application Support state.
        for profile in ["Default", "Default/Partitions/codex-browser-app", "codex-browser-app"] {
            for leaf in ["Cache", "Code Cache"] { add(.codex, "Library/Caches/Codex/\(profile)/\(leaf)", "Codex · \(profile) · \(leaf)") }
        }
        for (tool, product) in [(AITool.cursor, "Cursor"), (.claude, "Claude"), (.antigravity, "Antigravity"), (.lmstudio, "LM Studio")] {
            for leaf in ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"] {
                add(tool, "Library/Application Support/\(product)/\(leaf)", "\(tool.name) · \(leaf)")
            }
        }
        for leaf in ["CachedData", "CachedExtensionVSIXs"] { add(.cursor, "Library/Application Support/Cursor/\(leaf)", "Cursor · \(leaf)") }
        for leaf in ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"] {
            add(.antigravity, ".gemini/antigravity-browser-profile/Default/\(leaf)", "Antigravity · \(leaf)")
        }
        for (tool, relative, name) in [
            (AITool.opencode, ".cache/opencode", "OpenCode cache"), (.gemini, ".cache/gemini", "Gemini cache"),
            (.kimi, ".cache/kimi", "Kimi cache"), (.kimi, "Library/Caches/kimi", "Kimi cache"),
            (.ollama, ".ollama/logs", "Ollama logs"), (.ollama, "Library/Caches/ollama", "Ollama cache"),
            (.ollama, "Library/Caches/com.electron.ollama", "Ollama cache"),
            (.lmstudio, ".lmstudio/server-logs", "LM Studio server logs")
        ] { add(tool, relative, name) }
        return result
    }

    static func versionTargets(home: String) -> [VersionTarget] {
        [VersionTarget(tool: .claude, root: home + "/.local/share/claude/versions", activeLink: home + "/.local/bin/claude"),
         VersionTarget(tool: .cursor, root: home + "/.local/share/cursor-agent/versions", activeLink: home + "/.local/bin/cursor-agent"),
         VersionTarget(tool: .copilot, root: home + "/.copilot/pkg/universal", activeLink: home + "/.local/bin/copilot")]
    }

    public static func scan(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                            cliInventory: [CliTool], now: Date = Date(),
                            section: AIDataSection? = nil,
                            cleanupGuard: AIToolCleanupGuard = .live,
                            isCancelled: @Sendable () -> Bool = { Task.isCancelled }) -> AICleanupInventory {
        var result = AICleanupInventory(scannedAt: now)
        var states: [AITool: AIToolCleanupActivity] = [:]
        func activity(_ tool: AITool) -> AIToolCleanupActivity {
            if let state = states[tool] { return state }
            let state = cleanupGuard.state(for: tool); states[tool] = state; return state
        }
        func activity(_ tool: AITool, path: String) -> AIToolCleanupActivity {
            let values = Set([tool] + AIToolCleanupGuard.affectedTools(path: path, home: home)).map { activity($0) }
            if values.contains(.inUse) { return .inUse }
            return values.contains(.unknown) ? .unknown : .idle
        }
        for target in cacheTargets(home: home) {
            if let section, AIDataSection.classify(kind: .cache, path: target.path) != section { continue }
            if isCancelled() { result.issues.append("cancelled"); return result }
            guard exists(target.path) else { continue }
            if let item = item(tool: target.tool, kind: .cache, path: target.path, title: target.name,
                               state: activity(target.tool, path: target.path), reason: "cache", isCancelled: isCancelled) {
                result.candidates.append(item)
            } else { result.issues.append("invalid_catalog") }
        }
        for target in versionTargets(home: home) {
            if let section, section != .cliData { continue }
            if isCancelled() { result.issues.append("cancelled"); return result }
            guard exists(target.root) else { continue }
            result.candidates += versionCandidates(target, state: activity(target.tool), isCancelled: isCancelled)
        }
        // An absent executable alone is not an uninstall record. Reuse the
        // existing owner proof, and keep durable whole stores inspection-only.
        for (tool, relative) in [(AITool.codex, ".codex"), (.claude, ".claude"), (.kimi, ".kimi")] {
            if let section, section != .cliData { continue }
            let path = home + "/" + relative
            guard exists(path), OrphanScanner.isVerifiedCLIDataOrphan(path, cliInventory: cliInventory, home: home),
                  cliInventory.filter({ $0.dataDirs.contains { $0.path == path } }).allSatisfy({ $0.channel != .manual && $0.channel != .unknown }) else { continue }
            if var candidate = item(tool: tool, kind: .leftover, path: path, title: tool.name,
                                    state: activity(tool), reason: "verified_leftover", isCancelled: isCancelled) {
                candidate.state = .reviewOnly
                candidate.reason = "durable_data"
                result.candidates.append(candidate)
            }
        }
        return result
    }

    private static func item(tool: AITool, kind: AIDataKind, path: String, title: String,
                             state: AIToolCleanupActivity, reason: String,
                             isCancelled: @Sendable () -> Bool) -> AICleanupCandidate? {
        guard isPhysical(path), let measurement = measure(path, isCancelled: isCancelled),
              let resource = try? AIResource.capture(path: path, bytes: measurement.bytes),
              resource.boundary.item.owner == getuid() else { return nil }
        let status: AICandidateState = !measurement.complete ? .reviewOnly : (state == .idle ? .ready : (state == .inUse ? .inUse : .unknown))
        let why = !measurement.complete ? "partial_scan" : (state == .idle ? reason : (state == .inUse ? "in_use" : "probe_unknown"))
        return AICleanupCandidate(tool: tool, kind: kind, title: title, resources: [resource], state: status,
            reason: why, lastActivity: resource.modifiedAt, metadata: ["metadataSHA256": measurement.signature])
    }

    private static func versionCandidates(_ target: VersionTarget, state: AIToolCleanupActivity,
                                           isCancelled: @Sendable () -> Bool) -> [AICleanupCandidate] {
        guard isPhysical(target.root) else { return [] }
        let listing = DiskUsageScanner.scan(root: URL(fileURLWithPath: target.root),
            budget: DiskScanBudget(maxEntries: 501, maxDepth: 0, maxSeconds: 0.2), isCancelled: isCancelled)
        guard let root = listing.root, root.children.count <= 500,
              root.issues.subtracting([.depthLimit]).isEmpty else {
            return [AICleanupCandidate(tool: target.tool, kind: .oldVersion, title: target.tool.name,
                resources: [], state: .reviewOnly, reason: "partial_scan", contextPath: target.root)]
        }
        let names = root.children.map { URL(fileURLWithPath: $0).lastPathComponent }
        let entries = names.filter(validVersionName).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let active = activeEntry(target, entries: entries)
        let rollback = active.flatMap { current in entries.first { $0.compare(current, options: .numeric) == .orderedAscending } }
        return entries.compactMap { name in
            if isCancelled() { return nil }
            let path = target.root + "/" + name
            guard var candidate = item(tool: target.tool, kind: .oldVersion, path: path,
                                        title: target.tool.name + " · " + name, state: state,
                                        reason: "old_version", isCancelled: isCancelled) else { return nil }
            candidate.metadata["activeEntry"] = active ?? ""
            candidate.metadata["rollbackEntry"] = rollback ?? ""
            if active == nil { candidate.state = .retained; candidate.reason = "active_version_unknown" }
            else if name == active { candidate.state = .retained; candidate.reason = "active_version_kept" }
            else if name == rollback { candidate.state = .retained; candidate.reason = "rollback_kept" }
            else if name.compare(active!, options: .numeric) != .orderedAscending {
                candidate.state = .retained; candidate.reason = "newer_version_retained"
            }
            return candidate
        }
    }

    private static func activeEntry(_ target: VersionTarget, entries: [String]) -> String? {
        var info = stat()
        guard lstat(target.activeLink, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
              let resolved = realpath(target.activeLink, nil) else { return nil }
        defer { free(resolved) }
        let active = String(cString: resolved), root = physicalPath(target.root)
        guard active.hasPrefix(root + "/"), FileManager.default.isExecutableFile(atPath: active) else { return nil }
        let name = active.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
        return name.flatMap { entries.contains($0) ? $0 : nil }
    }

    static func validate(_ candidate: AICleanupCandidate, home: String) -> Bool {
        guard candidate.resources.count == 1, candidate.path == candidate.resources[0].path,
              candidate.resources[0].stillMatches(), isPhysical(candidate.path) else { return false }
        let fresh: AICleanupCandidate?
        let idle = AIToolCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .idle })
        switch candidate.kind {
        case .cache:
            guard let target = cacheTargets(home: home).first(where: { $0.tool == candidate.tool && $0.path == candidate.path }) else { return false }
            fresh = item(tool: target.tool, kind: .cache, path: target.path, title: target.name, state: .idle, reason: "cache", isCancelled: { Task.isCancelled })
        case .oldVersion:
            guard let target = versionTargets(home: home).first(where: { $0.tool == candidate.tool && URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path == $0.root }) else { return false }
            fresh = versionCandidates(target, state: idle.state(for: target.tool), isCancelled: { Task.isCancelled }).first { $0.path == candidate.path }
        default: return false
        }
        guard let fresh, fresh.state == .ready, fresh.resources.first?.identity == candidate.resources.first?.identity,
              fresh.resources.first?.modifiedAt == candidate.resources.first?.modifiedAt,
              fresh.metadata == candidate.metadata else { return false }
        return true
    }

    static func validVersionName(_ name: String) -> Bool {
        name.range(of: "^[0-9][0-9A-Za-z._+-]{0,127}$", options: .regularExpression) != nil
    }
    static func exists(_ path: String) -> Bool { var value = stat(); return lstat(path, &value) == 0 }
    static func physicalPath(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") { return "/private" + path }
        return path
    }
    static func isPhysical(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0), !path.split(separator: "/").contains("..") else { return false }
        let physical = physicalPath(path)
        var current = ""
        for part in physical.split(separator: "/") {
            current += "/" + part
            var info = stat()
            guard lstat(current, &info) == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { return false }
        }
        return true
    }

    /// Metadata only; no prompt/session contents. Any incomplete walk is not executable.
    static func measure(_ path: String, isCancelled: @Sendable () -> Bool = { Task.isCancelled }) -> Measurement? {
        guard isPhysical(path) else { return nil }
        let scan = DiskUsageScanner.scan(root: URL(fileURLWithPath: path),
            budget: DiskScanBudget(maxEntries: 5_000, maxSeconds: 0.5), isCancelled: isCancelled)
        guard let root = scan.root else { return nil }
        var hasher = SHA256(), complete = root.isComplete
        for key in scan.nodes.keys.sorted() {
            var info = stat()
            guard lstat(key, &info) == 0 else { complete = false; continue }
            let record = "\(key)|\(info.st_dev)|\(info.st_ino)|\(info.st_mode)|\(info.st_uid)|\(info.st_size)|\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\n"
            hasher.update(data: Data(record.utf8))
        }
        return Measurement(bytes: root.allocatedBytes,
            signature: hasher.finalize().map { String(format: "%02x", $0) }.joined(), complete: complete)
    }
}
