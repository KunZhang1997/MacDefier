// UninstallExecutor — identity-bound Trash moves with an app-only authorized fallback.

import AppKit
import Darwin
import Foundation

public actor UninstallExecutor {
    public static let shared = UninstallExecutor()
    private let fm = FileManager.default

    public init() {}

    public func trash(
        items: [CleanableItem],
        appBundlePath: String,
        targetIdentity: UninstallTargetIdentity? = nil,
        forceQuitIfNeeded: Bool = false
    ) async -> CleanupResult {
        var result = CleanupResult()
        // Main bundle first: the fresh container gate correctly sees a live owner until
        // this move succeeds, so residuals must never run ahead of the main app.
        let selected = items.filter(\.isSelected).sorted {
            Self.normalize($0.path) == Self.normalize(appBundlePath)
                && Self.normalize($1.path) != Self.normalize(appBundlePath)
        }
        guard !selected.isEmpty else {
            result.errors.append("没有勾选任何项")
            return result
        }

        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: selected.map(\.path) + [appBundlePath]) else {
            result.errors.append("resource_mutation_busy")
            result.failedPaths = selected.map(\.path)
            return result
        }
        defer { Task { await ResourceMutationCoordinator.shared.release(lease) } }

        let identity = targetIdentity ?? legacyIdentity(appBundlePath)
        let mainSelected = selected.contains { Self.normalize($0.path) == Self.normalize(appBundlePath) }
        var snapshots: [String: Result<UninstallFileBoundary.Snapshot, Error>] = [:]
        for item in selected { snapshots[item.path] = Result { try UninstallFileBoundary.snapshot(item.path) } }
        // Capture identities before quitting: quit hooks must not replace the selected app.
        if mainSelected {
            let quit = await quitIfRunning(appPath: appBundlePath, force: forceQuitIfNeeded)
            if quit == .stillRunning {
                result.requiresForceQuit = true
                result.failedPaths = selected.map(\.path)
                result.errors.append("应用仍在运行；未移动任何文件。请确认是否强制退出并继续。")
                return result
            }
        }

        var mainMoved = !mainSelected
        var authorizationCancelled = false
        for item in selected {
            guard !Task.isCancelled && !authorizationCancelled else {
                result.errors.append("cancelled")
                result.failedPaths.append(item.path)
                continue
            }
            let isMain = Self.normalize(item.path) == Self.normalize(appBundlePath)
            guard isMain || (mainMoved && (!mainSelected || UninstallFileBoundary.isMissing(appBundlePath))) else {
                result.errors.append("uninstall_data_preserved:\(item.path)")
                result.failedPaths.append(item.path)
                continue
            }
            do {
                guard let snapshot = snapshots[item.path] else {
                    throw UninstallFileBoundary.Failure(code: "uninstall_identity_changed", path: item.path)
                }
                let source = try snapshot.get()
                if isMain, identity.hasVerifiedExtensions, !identity.mainBundleMatchesSnapshot(source) {
                    throw UninstallFileBoundary.Failure(code: "uninstall_identity_changed", path: item.path)
                }
                try await trashUserLevel(source, target: identity)
                if isMain { mainMoved = true }
                result.cleanedCount += 1
                result.movedToTrashBytes &+= item.bytes
                result.trashedPaths.append(item.path)
                result.succeededPaths.append(item.path)
            } catch {
                if let failure = error as? UninstallFileBoundary.Failure,
                   ["uninstall_authorization_cancelled", "uninstall_system_result_unknown", "uninstall_helper_recovery_required"].contains(failure.code) {
                    authorizationCancelled = true
                }
                result.errors.append(error.localizedDescription)
                result.failedPaths.append(item.path)
            }
        }

        if result.cleanedCount == 0 && result.errors.isEmpty {
            result.errors.append("未能移动任何项目（可能无权限或文件被占用）")
        }
        CleanupResourceEvents.publish(paths: result.succeededPaths)
        return result
    }

    // MARK: - User level

    private func trashUserLevel(_ source: UninstallFileBoundary.Snapshot, target: UninstallTargetIdentity) async throws {
        let path = source.path
        try UninstallFileBoundary.validate(source)
        // 软链：安全校验对解析后的目标做（且 resolved 必须在允许根内），删除操作用原始 URL（系统删链接本身）
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath().path
        // Executor hard gate: never trash protected / non-removable bundles
        if AppInventory.isProtectedAppBundle(path) || AppInventory.isProtectedAppBundle(resolved) {
            throw UninstallFileBoundary.Failure(code: "blocked", path: path)
        }
        guard isSafe(resolved, target: target) else {
            if let reason = PathGate.uninstallContainerRetentionReason(resolved, target: target) {
                throw UninstallFileBoundary.Failure(code: "uninstall_" + reason, path: path)
            }
            throw UninstallFileBoundary.Failure(code: "blocked", path: path)
        }
        if Self.normalize(path) == Self.normalize(target.originalAppPath),
           source.item.kind != mode_t(S_IFDIR) {
            throw UninstallFileBoundary.Failure(code: "uninstall_identity_changed", path: path)
        }
        if Self.normalize(path) == Self.normalize(target.originalAppPath),
           !target.bundleID.hasPrefix("unknown."), Bundle(url: url)?.bundleIdentifier != target.bundleID {
            throw UninstallFileBoundary.Failure(code: "uninstall_identity_changed", path: path)
        }

        try UninstallFileBoundary.validate(source)
        if let reason = AIToolCleanupGuard.live.blockingReasonForExplicitRemoval(source, home: fm.homeDirectoryForCurrentUser.path) {
            throw UninstallFileBoundary.Failure(code: "ai_cleanup_" + reason, path: path)
        }
        do { _ = try await UninstallSystemTrash.move(source) }
        catch let failure as UninstallFileBoundary.Failure {
            guard Self.normalize(path) == Self.normalize(target.originalAppPath),
                  source.parentPath == "/Applications",
                  failure.path == source.path, failure.operation == "renameatx_np",
                  ["uninstall_permission_denied", "uninstall_operation_not_permitted"].contains(failure.code) else { throw failure }
            try await UninstallPrivilegedTrash.move(source)
        }
    }

    // MARK: - Quit running app

    private enum QuitOutcome {
        case notRunning
        case terminated
        case stillRunning
    }

    private func quitIfRunning(appPath: String, force: Bool) async -> QuitOutcome {
        let normalized = Self.normalize(appPath)
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let url = app.bundleURL else { return false }
            return Self.normalize(url.path) == normalized
        }
        for app in running {
            if force {
                app.forceTerminate()
            } else {
                app.terminate()
            }
        }
        guard !running.isEmpty else { return .notRunning }

        let timeout: UInt64 = force ? 2_000_000_000 : 5_000_000_000
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeout)))
        while ContinuousClock.now < deadline {
            if running.allSatisfy(\.isTerminated) { return .terminated }
            if Task.isCancelled { return .stillRunning }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if force {
            for app in running where !app.isTerminated {
                app.forceTerminate()
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return running.allSatisfy(\.isTerminated) ? .terminated : .stillRunning
    }

    // MARK: - Safety

    private func isSafe(_ path: String, target: UninstallTargetIdentity) -> Bool {
        // PathGate：.app 仅 allowAppBundle；禁 /Applications 他 App；敏感 hardBlock；残留窄根
        PathGate.isSafeForUninstall(path, target: target)
    }

    private func legacyIdentity(_ appBundlePath: String) -> UninstallTargetIdentity {
        let appURL = URL(fileURLWithPath: appBundlePath)
        let bundle = Bundle(url: appURL)
        return UninstallTargetIdentity(
            bundleID: bundle?.bundleIdentifier ?? "unknown.\(appURL.deletingPathExtension().lastPathComponent)",
            displayName: (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? appURL.deletingPathExtension().lastPathComponent,
            originalAppPath: appBundlePath
        )
    }

    private static func normalize(_ path: String) -> String {
        PathGate.normalize(path)
    }

}
