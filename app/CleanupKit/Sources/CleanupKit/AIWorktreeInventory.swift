import Darwin
import Foundation

/// Worktrees contain source, ignored builds, and untracked user files. Inventory
/// only: even a clean Git status is never permission to remove a checkout.
public enum AIWorktreeInventory {
    public static func scan(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: Date = Date(),
        verifiedProjectRoots: [String] = [],
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> AICleanupInventory {
        let context = AIInventoryMetadata(home: home, limits: AIInventoryScanLimits(maxEntries: 12_000, maxFiles: 8_000, maxSeconds: 5),
                                          isCancelled: isCancelled)
        guard context.validHome else { return AICleanupInventory(issues: ["worktree_scan_inaccessible"], scannedAt: now) }
        var roots: [(AITool, String)] = [(.codex, context.path(".codex/worktrees")), (.claude, context.path(".claude/worktrees"))]
        // Only explicit project roots whose Git top-level matches the supplied
        // path are considered; never decode a project slug into a guessed path.
        for root in verifiedProjectRoots.prefix(16) {
            if context.stopped() { break }
            guard context.isDirectory(root), let top = git(["rev-parse", "--show-toplevel"], at: root, home: home, isCancelled: isCancelled),
                  AIInventoryMetadata.canonicalPath(top.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) == AIInventoryMetadata.canonicalPath(root)
            else { continue }
            roots.append((.claude, root + "/.claude/worktrees"))
        }
        var candidates: [AICleanupCandidate] = []
        var seen = Set<String>()
        outer: for (tool, root) in roots {
            for container in context.children(root) where context.isDirectory(container) && !URL(fileURLWithPath: container).lastPathComponent.hasPrefix(".") {
                var checkouts: [String]
                if hasGitEntry(container) {
                    checkouts = [container]
                } else {
                    checkouts = context.children(container).filter {
                        context.isDirectory($0) && !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".")
                    }
                    if checkouts.isEmpty { checkouts = [container] }
                }
                for checkout in checkouts {
                    if context.stopped() { break outer }
                    if candidates.count >= 32 { context.issues.insert("conversation_scan_partial"); break outer }
                    guard let pin = try? UninstallFileBoundary.snapshot(checkout), pin.item.kind == mode_t(S_IFDIR) else { continue }
                    let identity = "\(pin.item.device):\(pin.item.inode)"
                    guard seen.insert(identity).inserted else { continue }
                    let footprint = footprint(checkout, context: context)
                    guard let resource = try? AIResource.capture(path: checkout, bytes: footprint.bytes), resource.boundary.item == pin.item else {
                        context.issues.insert("conversation_scan_inaccessible")
                        continue
                    }
                    let status = hasGitEntry(checkout) && !context.stopped()
                        ? inspectGit(checkout, home: home, isCancelled: isCancelled) : nil
                    var metadata = ["producer": "worktree_inventory_v1", "activityEvidence": "file_mtime",
                                    "sizeBasis": "allocated_not_exclusive", "fileCount": String(footprint.files),
                                    "gitStatus": status == nil ? "unknown" : "known",
                                    "trackedChanges": status.map { String($0.tracked) } ?? "unknown",
                                    "untrackedFiles": status.map { String($0.untracked) } ?? "unknown",
                                    "ignoredFiles": status.map { String($0.ignored) } ?? "unknown"]
                    let partial = context.issues.contains("conversation_scan_partial") || context.issues.contains("conversation_scan_cancelled")
                        || context.issues.contains("conversation_scan_inaccessible")
                    metadata["sizeComplete"] = partial ? "false" : "true"
                    let reason: String
                    if partial { reason = "worktree_partial" }
                    else if status == nil { reason = "worktree_status_unknown" }
                    else if status!.tracked > 0 || status!.untracked > 0 { reason = "worktree_has_changes" }
                    else if status!.ignored > 0 { reason = "worktree_has_ignored" }
                    else { reason = "worktree_read_only" }
                    candidates.append(AICleanupCandidate(
                        tool: tool, kind: .worktree, title: URL(fileURLWithPath: checkout).lastPathComponent,
                        resources: [resource], state: .reviewOnly, reason: reason,
                        lastActivity: footprint.latest, metadata: metadata, contextPath: checkout
                    ))
                }
            }
        }
        return AICleanupInventory(candidates: candidates.sorted { $0.path < $1.path },
                                  issues: context.issues.map { $0.replacingOccurrences(of: "conversation_", with: "worktree_") }.sorted(),
                                  scannedAt: now)
    }

    private struct Footprint {
        var bytes: UInt64 = 0
        var files = 0
        var latest: Date?
    }

    private static func footprint(_ root: String, context: AIInventoryMetadata) -> Footprint {
        var result = Footprint()
        var stack = [root]
        var seen = Set<String>()
        while !stack.isEmpty, !context.stopped() {
            let directory = stack.removeLast()
            for child in context.children(directory) {
                if context.isDirectory(child) { stack.append(child) }
                else if let resource = context.resource(child), seen.insert(resource.identity).inserted {
                    let sum = result.bytes.addingReportingOverflow(resource.bytes)
                    result.bytes = sum.overflow ? UInt64.max : sum.partialValue
                    result.files += 1
                    if resource.modifiedAt != .distantPast {
                        result.latest = max(result.latest ?? .distantPast, resource.modifiedAt)
                    }
                }
                if context.stopped() { break }
            }
        }
        return result
    }

    private static func hasGitEntry(_ root: String) -> Bool {
        guard let entry = try? UninstallFileBoundary.snapshot(root + "/.git") else { return false }
        return entry.item.kind == mode_t(S_IFREG) || entry.item.kind == mode_t(S_IFDIR)
    }

    private struct GitStatus {
        var tracked = 0
        var untracked = 0
        var ignored = 0
    }

    private static func inspectGit(_ path: String, home: String, isCancelled: @escaping @Sendable () -> Bool) -> GitStatus? {
        guard let before = try? UninstallFileBoundary.snapshot(path + "/.git"),
              let top = git(["rev-parse", "--show-toplevel"], at: path, home: home, isCancelled: isCancelled),
              AIInventoryMetadata.canonicalPath(top.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) == AIInventoryMetadata.canonicalPath(path),
              let output = git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"],
                               at: path, home: home, isCancelled: isCancelled),
              UninstallFileBoundary.stillMatches(before) else { return nil }
        var result = GitStatus()
        let records = output.stdout.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else { return nil }
            let first = record[record.startIndex], second = record[record.startIndex + 1]
            if first == 63 && second == 63 { result.untracked += 1 }
            else if first == 33 && second == 33 { result.ignored += 1 }
            else {
                result.tracked += 1
                if first == 82 || first == 67 || second == 82 || second == 67 { index += 1 }
            }
            index += 1
        }
        return result
    }

    private static func git(_ arguments: [String], at path: String, home: String,
                            isCancelled: @escaping @Sendable () -> Bool) -> ProcessRunResult? {
        guard !isCancelled() else { return nil }
        // Status must not run user fsmonitor hooks, inherit GIT_DIR redirects,
        // refresh the index, or fetch objects from a promisor remote.
        let environment = ["PATH": "/usr/bin:/bin", "HOME": home, "LC_ALL": "C",
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                           "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"]
        guard let result = try? ProcessRunner.runSync(
            ["/usr/bin/git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
             "-c", "core.hooksPath=/dev/null", "-C", path] + arguments,
            environment: environment, timeout: 1.25,
            outputLimits: ProcessOutputLimits(stdoutBytes: 256 * 1024, stderrBytes: 16 * 1024), isCancelled: isCancelled
        ), result.succeeded else { return nil }
        return result
    }
}
