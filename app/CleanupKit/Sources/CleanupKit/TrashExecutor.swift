// TrashExecutor — move selected paths to Trash (product rule: 进废纸篓，可撤销).
// Safety checks adapted from PureMac CleaningEngine allow-list spirit (MIT).

import AppKit
import Foundation

public actor TrashExecutor {
    private let fm = FileManager.default
    private let executionHome: String
    private let recycle: @Sendable (URL) throws -> Void
    private let browserCleanupGuard: BrowserCleanupGuard

    public init() {
        executionHome = FileManager.default.homeDirectoryForCurrentUser.path
        browserCleanupGuard = .live
        recycle = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        }
    }

    /// Tests replace only the OS Trash side effect with a UUID-owned fixture move.
    init(home: String, browserCleanupGuard: BrowserCleanupGuard = .live,
         recycle: @escaping @Sendable (URL) throws -> Void) {
        executionHome = home
        self.browserCleanupGuard = browserCleanupGuard
        self.recycle = recycle
    }

    public func trash(
        items: [CleanableItem],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> CleanupResult {
        var result = CleanupResult()
        let selected = items.filter { $0.isSelected && $0.risk != .skip }
        guard !selected.isEmpty else { return result }
        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: selected.flatMap(\.allPaths)) else {
            result.errors.append("resource_mutation_busy")
            result.failedPaths = selected.flatMap(\.allPaths)
            result.failures = result.failedPaths.map { .init(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent, kind: .busy) }
            return result
        }
        defer { Task { await ResourceMutationCoordinator.shared.release(lease) } }

        // Orphan ownership can change after preview (for example the user
        // reinstalls Cursor). Refresh the installed-app snapshot at the
        // destructive boundary; an empty snapshot is treated as unverifiable
        // and therefore blocks orphan deletion below.
        let installedApps: [InstalledApp]? = selected.contains { $0.category == .orphans }
            ? AppInventory.fetchInstalledApps(
                includeSystemApps: true,
                computeSize: false,
                isCancelled: { Task.isCancelled }
            )
            : nil

        let containers: [ContainerOwnership] = installedApps.map {
            ContainerOwnershipScanner.scan(installed: $0)
        } ?? []

        for (index, item) in selected.enumerated() {
            if Task.isCancelled { break }
            onProgress(Double(index) / Double(selected.count))
            let outcome = trashOne(item, installedApps: installedApps, containers: containers)
            result.succeededPaths.append(contentsOf: outcome.succeededPaths)
            result.failedPaths.append(contentsOf: outcome.failedPaths)
            result.freedBytes &+= outcome.permanentlyFreedBytes
            result.movedToTrashBytes &+= outcome.movedToTrashBytes
            result.errors.append(contentsOf: outcome.errors)
            result.failures.append(contentsOf: outcome.failures)
            if outcome.failedPaths.isEmpty, !outcome.succeededPaths.isEmpty {
                result.cleanedCount += 1
                result.trashedPaths.append(item.path)
            }
            await Task.yield()
        }
        onProgress(1)
        CleanupResourceEvents.publish(paths: result.succeededPaths)
        return result
    }

    private struct ItemOutcome {
        var succeededPaths: [String] = []
        var failedPaths: [String] = []
        var movedToTrashBytes: UInt64 = 0
        var permanentlyFreedBytes: UInt64 = 0
        var errors: [String] = []
        var failures: [CleanupFailure] = []
    }

    private func trashOne(_ item: CleanableItem, installedApps: [InstalledApp]?, containers: [ContainerOwnership]) -> ItemOutcome {
        var outcome = ItemOutcome()
        if item.risk == .skip {
            outcome.failedPaths = item.allPaths
            outcome.errors.append("\(item.name): \(TrashError.blocked(item.path).localizedDescription)")
            return outcome
        }
        let paths = item.allPaths
        guard !paths.isEmpty else {
            outcome.failedPaths = [item.path]
            outcome.errors.append("\(item.name): \(TrashError.missing(item.path).localizedDescription)")
            return outcome
        }

        for path in paths {
            if Task.isCancelled {
                outcome.failedPaths.append(path)
                outcome.errors.append("\(item.name): 已取消，未处理 \(path)")
                continue
            }
            if item.category == .orphans {
                // Refresh CLI discovery at execution, not from the old preview. A
                // reinstall may have a different package path or install channel.
                let cliInventory: [CliTool]? = OrphanScanner.isCLIDataRoot(path)
                    ? CliToolInventory.fetchAll(computeSize: false, isCancelled: { Task.isCancelled })
                    : nil
                if Self.shouldBlockOrphanPath(path, installedApps: installedApps,
                                             containerOwnership: containers, cliInventory: cliInventory) {
                    outcome.failedPaths.append(path)
                    outcome.errors.append("\(item.name): 应用或 CLI 仍在使用该目录，或缺少可核验的卸载证据；已阻止清理 \(path)")
                    continue
                }
            }
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath()
            guard fm.fileExists(atPath: resolved.path) || fm.fileExists(atPath: path) else {
                outcome.failedPaths.append(path)
                outcome.errors.append("\(item.name): \(TrashError.missing(path).localizedDescription)")
                outcome.failures.append(.init(path: path, name: item.name, kind: .missing))
                continue
            }
            let allowed = item.category == .orphans
                ? PathGate.isSafeOrphanToTrash(path, installedApps: installedApps, home: executionHome)
                : (isSafeToTrash(resolved.path) || isSafeToTrash(path))
            guard allowed else {
                outcome.failedPaths.append(path)
                outcome.errors.append("\(item.name): \(TrashError.blocked(path).localizedDescription)")
                continue
            }
            let pathBytes: UInt64 = {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if vals?.isDirectory == true { return 0 }
                return UInt64(vals?.fileSize ?? 0)
            }()

            do {
                // Probe the actual path at the last boundary, for every path in a
                // multi-path row and regardless of the row's display/category.
                if let reason = browserCleanupGuard.blockingReason(for: path, home: executionHome) {
                    outcome.failedPaths.append(path)
                    outcome.errors.append("\(item.name) · \(path): \(reason)")
                    outcome.failures.append(.init(path: path, name: item.name, kind: .inUse, detail: reason))
                    continue
                }
                if let reason = AIToolCleanupGuard.live.blockingReason(for: path, home: executionHome) {
                    outcome.failedPaths.append(path)
                    outcome.errors.append("\(item.name) · \(path): ai_cleanup_\(reason)")
                    continue
                }
                guard CleanupEligibility.canMoveToTrash(path) else {
                    outcome.failedPaths.append(path)
                    outcome.errors.append("\(item.name) · \(path): cleanup_permission_denied")
                    outcome.failures.append(.init(path: path, name: item.name, kind: .permissionDenied))
                    continue
                }
                if item.category == .trash && isUnderUserTrash(resolved.path) {
                    try fm.removeItem(at: url)
                    outcome.permanentlyFreedBytes &+= pathBytes
                } else {
                    try recycle(url)
                    outcome.movedToTrashBytes &+= pathBytes
                }
                outcome.succeededPaths.append(path)
            } catch {
                outcome.failedPaths.append(path)
                outcome.errors.append("\(item.name) · \(path): \(error.localizedDescription)")
                outcome.failures.append(.init(path: path, name: item.name, kind: CleanupEligibility.classify(error), detail: error.localizedDescription))
            }
        }
        let classified = Set(outcome.failures.map(\.path))
        for path in outcome.failedPaths where !classified.contains(path) {
            outcome.failures.append(.init(path: path, name: item.name, kind: Task.isCancelled ? .cancelled : .protectedResource))
        }
        // Directory sizes were measured by the scanner. Attribute that estimate only
        // when every path completed; never guess bytes for a partial multi-path result.
        if outcome.failedPaths.isEmpty, paths.count == outcome.succeededPaths.count, item.bytes > 0 {
            if item.category == .trash {
                outcome.permanentlyFreedBytes = item.bytes
            } else {
                outcome.movedToTrashBytes = item.bytes
            }
        }
        return outcome
    }

    /// Destructive backstop for stale previews and app reinstalls.
    /// `nil` / empty means the inventory could not be trusted, so fail closed.
    static func shouldBlockOrphanPath(
        _ path: String,
        installedApps: [InstalledApp]?,
        containerOwnership: [ContainerOwnership]? = nil,
        cliInventory: [CliTool]? = nil,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Bool {
        guard let installedApps, !installedApps.isEmpty else { return true }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if AppOwnership.isOwnedByInstalled(name: name, path: path, apps: installedApps) { return true }
        if path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") {
            return ContainerOwnershipScanner.inspect(
                path: path, isGroupContainer: path.contains("/Library/Group Containers/"), installed: installedApps
            ).confidence != .verifiedOrphan
        }
        if path.contains("/Library/") {
            let containers = containerOwnership ?? ContainerOwnershipScanner.scan(installed: installedApps)
            guard let evidence = OrphanScanner.libraryOrphanOwner(
                name: name, path: path, installed: installedApps, containerOwnership: containers
            ) else { return true }
            // Recheck the witness immediately before use; an app may have reappeared
            // since this batch's metadata snapshot was created.
            return ContainerOwnershipScanner.inspect(
                path: evidence.path, isGroupContainer: false, installed: installedApps
            ).confidence != .verifiedOrphan
        }
        return !OrphanScanner.isVerifiedCLIDataOrphan(path, cliInventory: cliInventory, home: home)
    }

    private func isUnderUserTrash(_ path: String) -> Bool {
        PathGate.isUnderUserTrash(path)
    }

    private func isSafeToTrash(_ path: String) -> Bool {
        PathGate.isSafeToTrash(path)
    }
}

public enum TrashError: LocalizedError {
    case missing(String)
    case blocked(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let p): return "路径不存在：\(p)"
        case .blocked(let p): return "安全策略拒绝：\(p)"
        case .timeout(let p): return "移入废纸篓超时（可能在等系统授权），结果未知按失败处理：\(p)"
        }
    }
}
