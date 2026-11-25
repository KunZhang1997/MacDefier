import Darwin
import Foundation

/// Owns the mutation lease and never delegates to a generic Trash path. Public
/// callers cannot grant permission through a title, state, bytes, or metadata.
public enum AIToolCleanupExecutor {
    struct Execution: Sendable {
        var cleanupGuard: AIToolCleanupGuard = .live
        var conversationProof: @Sendable (AICleanupCandidate, String, Set<String>) -> Bool = {
            AIConversationInventory.validateConversation($0, home: $1, excludingMovedPaths: $2)
        }
        var modelProof: @Sendable (AICleanupCandidate, String, Set<String>) -> Bool = {
            AIOllamaInventory.validateModel($0, home: $1, excludingMovedPaths: $2)
        }
        var runtimeProof: @Sendable (AICleanupCandidate) -> Bool = {
            XcodeSimulatorRuntimeInventory.validateRuntime($0)
        }
        var deleteRuntime: @Sendable (AICleanupCandidate) -> Bool = {
            XcodeSimulatorRuntimeInventory.deleteRuntime($0)
        }
        var recycle: @Sendable (AIResource) throws -> String = { try UninstallFileBoundary.move($0.boundary) }
    }

    private struct Moved { let resource: AIResource; let destination: String }

    public static func execute(candidates: [AICleanupCandidate],
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                               onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async -> CleanupResult {
        await execute(candidates: candidates, home: home, onProgress: onProgress, execution: Execution())
    }

    static func execute(candidates: [AICleanupCandidate], home: String,
                        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
                        execution: Execution) async -> CleanupResult {
        var result = CleanupResult()
        guard !candidates.isEmpty else { return result }
        var paths = candidates.flatMap { $0.resources.map(\.path) }
        if candidates.contains(where: { $0.kind == .model }) { paths.append(home + "/.ollama/models") }
        for runtime in candidates where runtime.kind == .simulatorRuntime {
            paths.append("/Library/Developer/CoreSimulator")
            if !runtime.path.isEmpty, runtime.path.hasPrefix("/") { paths.append(runtime.path) }
        }
        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: paths) else {
            result.errors.append("mutation_busy"); return result
        }
        var changedPaths: [String] = []
        var acceptedResources: [AIResource] = []
        var completedModelPaths = Set<String>()
        var seenRuntimeIDs = Set<String>()

        for (index, candidate) in candidates.enumerated() {
            onProgress(Double(index) / Double(candidates.count))
            if candidate.kind == .simulatorRuntime {
                var failure: String?
                let runtimeKey = candidate.metadata["runtimeUUID"] ?? candidate.id
                if Task.isCancelled { failure = "cancelled" }
                else if !candidate.resources.isEmpty || candidate.reportedBytes == 0 || !seenRuntimeIDs.insert(runtimeKey).inserted {
                    failure = "invalid_catalog"
                } else {
                    switch execution.cleanupGuard.state(for: .xcode) {
                    case .inUse: failure = "in_use"
                    case .unknown: failure = "probe_unknown"
                    case .idle:
                        if !execution.runtimeProof(candidate) {
                            failure = "changed"
                        } else {
                            // Re-check Xcode/Simulator activity right before invoking `simctl runtime delete`
                            switch execution.cleanupGuard.state(for: .xcode) {
                            case .inUse: failure = "in_use"
                            case .unknown: failure = "probe_unknown"
                            case .idle:
                                if !execution.deleteRuntime(candidate) {
                                    failure = "runtime_delete_failed"
                                }
                            }
                        }
                    }
                }
                if let failure {
                    result.errors.append("\(failure):\(candidate.path)")
                    result.failedPaths.append(candidate.path)
                } else {
                    result.cleanedCount += 1
                    result.succeededPaths.append(candidate.path)
                    let addition = result.freedBytes.addingReportingOverflow(candidate.reportedBytes)
                    result.freedBytes = addition.overflow ? UInt64.max : addition.partialValue
                    changedPaths.append(candidate.path)
                }
                continue
            }
            var moved: [Moved] = []
            var movedPaths = Set<String>()
            var failure: String?
            let resources = candidate.resources
            if Task.isCancelled { failure = "cancelled" }
            if resources.isEmpty || ![AIDataKind.cache, .oldVersion, .conversation, .model].contains(candidate.kind) {
                failure = "unsupported_kind"
            }
            if AIResourceTotals.unique(acceptedResources + resources).count != acceptedResources.count + resources.count {
                failure = "invalid_catalog"
            }
            if failure == nil, !validate(candidate, home: home, moved: [], completedModels: completedModelPaths, execution: execution) { failure = "invalid_catalog" }
            if failure == nil {
                for resource in resources {
                    if Task.isCancelled { failure = "cancelled"; break }
                    // Do not ask lsof about resources already moved by this operation.
                    let remaining = resources.filter { !movedPaths.contains($0.path) }
                    let guarded = AICleanupCandidate(tool: candidate.tool, kind: candidate.kind,
                        title: candidate.title, resources: remaining, state: .ready, reason: candidate.reason,
                        metadata: candidate.metadata, contextPath: candidate.path)
                    if let reason = execution.cleanupGuard.blockingReason(guarded, home: home) { failure = reason; break }
                    guard validate(candidate, home: home, moved: movedPaths, completedModels: completedModelPaths, execution: execution),
                          resourceStillMatches(resource) else { failure = "changed"; break }
                    // Rebind owner state after metadata/graph inspection too.
                    let owners = Set([candidate.tool] + AIToolCleanupGuard.affectedTools(path: resource.path, home: home))
                    if !(candidate.kind == .model && owners == [.ollama]) {
                        let states = owners.map { execution.cleanupGuard.state(for: $0) }
                        if states.contains(.inUse) { failure = "in_use"; break }
                        if states.contains(.unknown) { failure = "probe_unknown"; break }
                    }
                    do {
                        let destination = try execution.recycle(resource)
                        moved.append(Moved(resource: resource, destination: destination))
                        movedPaths.insert(resource.path)
                        changedPaths.append(resource.path)
                        guard UninstallFileBoundary.isMissing(resource.path),
                              UninstallFileBoundary.matchesTrashedItem(resource.boundary.item, at: destination) else { failure = "changed"; break }
                    } catch {
                        let boundary = error as? UninstallFileBoundary.Failure
                        failure = ["uninstall_manual_required", "uninstall_trash_unsafe", "uninstall_permission_denied",
                                   "uninstall_operation_not_permitted", "uninstall_read_only", "uninstall_cross_volume"].contains(boundary?.code ?? "")
                            ? "manual_required" : "move_failed"
                        break
                    }
                }
            }
            if let failure {
                result.errors.append("\(failure):\(candidate.path)")
                result.failedPaths += resources.filter { !movedPaths.contains($0.path) }.map(\.path)
                if (candidate.kind == .model || candidate.kind == .conversation), !moved.isEmpty {
                    var retained: [Moved] = []
                    for item in moved.reversed() {
                        if !restore(item) {
                            retained.append(item)
                            result.failedPaths.append(item.resource.path)
                            result.errors.append("rollback_failed:\(item.resource.path) → \(item.destination)")
                        }
                    }
                    moved = retained
                }
            } else {
                result.cleanedCount += 1
                if candidate.kind == .model { completedModelPaths.formUnion(resources.map(\.path)) }
            }
            for item in moved {
                acceptedResources.append(item.resource)
                result.succeededPaths.append(item.resource.path)
                result.trashedPaths.append(item.resource.path)
                let addition = result.movedToTrashBytes.addingReportingOverflow(item.resource.bytes)
                result.movedToTrashBytes = addition.overflow ? UInt64.max : addition.partialValue
            }
        }
        await ResourceMutationCoordinator.shared.release(lease)
        CleanupResourceEvents.publish(paths: changedPaths)
        onProgress(1)
        return result
    }

    private static func validate(_ candidate: AICleanupCandidate, home: String, moved: Set<String>,
                                 completedModels: Set<String>, execution: Execution) -> Bool {
        switch candidate.kind {
        case .cache, .oldVersion: return moved.isEmpty && AIToolCleanupScanner.validate(candidate, home: home)
        case .simulatorRuntime: return moved.isEmpty && execution.runtimeProof(candidate)
        case .conversation: return execution.conversationProof(candidate, home, moved)
        case .model: return execution.modelProof(candidate, home, moved.union(completedModels))
        default: return false
        }
    }

    static func resourceStillMatches(_ resource: AIResource) -> Bool {
        guard resource.stillMatches(), AIToolCleanupScanner.isPhysical(resource.path),
              resource.boundary.item.owner == getuid(),
              let fresh = try? AIResource.capture(path: resource.path, bytes: resource.bytes) else { return false }
        return fresh.identity == resource.identity && fresh.modifiedAt == resource.modifiedAt
    }

    /// Model transaction recovery. No overwrite, no invented destination, and no
    /// restoration through a replaced directory or a different Trash inode.
    private static func restore(_ moved: Moved) -> Bool {
        let source = moved.resource.boundary
        guard UninstallFileBoundary.isMissing(source.path),
              AIToolCleanupScanner.isPhysical(source.parentPath),
              AIToolCleanupScanner.isPhysical(moved.destination),
              UninstallFileBoundary.matchesTrashedItem(source.item, at: moved.destination) else { return false }
        let toFD = open(source.parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard toFD >= 0 else { return false }
        defer { close(toFD) }
        var parent = stat(), target = stat()
        guard fstat(toFD, &parent) == 0, UninstallFileBoundary.Identity(parent) == source.parent,
              fstatat(toFD, source.name, &target, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { return false }

        let trashURL = URL(fileURLWithPath: moved.destination).standardizedFileURL
        let trashParentPath = trashURL.deletingLastPathComponent().path
        let fromFD = open(trashParentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fromFD >= 0 {
            defer { close(fromFD) }
            var item = stat()
            guard fstatat(fromFD, trashURL.lastPathComponent, &item, AT_SYMLINK_NOFOLLOW) == 0,
                  UninstallFileBoundary.Identity(item) == source.item else { return false }
            return renameatx_np(fromFD, trashURL.lastPathComponent, toFD, source.name, UInt32(RENAME_EXCL)) == 0
        }
        guard errno == EPERM || errno == EACCES else { return false }
        do {
            try FileManager.default.moveItem(atPath: trashURL.path, toPath: source.path)
            var restored = stat()
            guard fstatat(toFD, source.name, &restored, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            return UninstallFileBoundary.Identity(restored) == source.item
        } catch {
            return false
        }
    }
}
