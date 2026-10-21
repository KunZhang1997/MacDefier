import AppKit
import Foundation

/// Unknown is deliberately distinct from idle: a failed probe cannot authorize a move.
enum BrowserCleanupActivity: Sendable, Equatable {
    case idle
    case inUse
    case unknown
}

struct BrowserProcessIdentity: Sendable {
    let bundleIdentifier: String?
    let executablePath: String?
}

/// Read-only probes are injected at the execution boundary. No probe quits a browser.
struct BrowserCleanupGuard: Sendable {
    let processState: @Sendable (BrowserBrand) -> BrowserCleanupActivity
    let openFileState: @Sendable (String) -> BrowserCleanupActivity

    static let live = BrowserCleanupGuard(
        processState: { liveProcessState($0) },
        openFileState: { liveOpenFileState($0) }
    )

    func blockingReason(for path: String, home: String) -> String? {
        // Keep extension service-worker bytecode even when a browser is closed.
        // A stale preview or a generic cache row must not reintroduce this target.
        let normalized = PathGate.standardizeOnly(path).lowercased()
        if normalized.contains("/service worker/scriptcache/")
            || normalized.hasSuffix("/service worker/scriptcache") {
            return "浏览器扩展脚本状态需要保留，已阻止清理"
        }

        let brands = Self.affectedBrowsers(path: path, home: home)
        guard !brands.isEmpty else { return nil }
        for brand in brands {
            if let reason = ownerBlockingReason(for: brand) { return reason }
        }
        switch openFileState(path) {
        case .inUse:
            return "浏览器数据仍有打开的文件或数据库；已保留"
        case .unknown:
            return "无法确认浏览器数据是否正在使用；已保留"
        case .idle:
            // Recursive handle checks can take time. Rebind owner state after
            // that probe, immediately before the caller's Trash side effect.
            for brand in brands {
                if let reason = ownerBlockingReason(for: brand) { return reason }
            }
            return nil
        }
    }

    func ownerBlockingReason(for brand: BrowserBrand) -> String? {
        switch processState(brand) {
        case .inUse:
            return "\(brand.displayName) 或其辅助进程仍在运行；请退出后重新扫描"
        case .unknown:
            return "无法确认 \(brand.displayName) 的运行状态；已保留浏览器数据"
        case .idle:
            return nil
        }
    }

    /// Classify the actual path, including a generic row containing a browser root.
    /// Neither a display name nor a caller-supplied cleanup category grants a bypass.
    static func affectedBrowsers(path: String, home: String) -> [BrowserBrand] {
        let candidates = [PathGate.standardizeOnly(path), PathGate.normalize(path)]
        return BrowserBrand.allCases.filter { brand in
            roots(for: brand, home: home).contains { root in
                let roots = [PathGate.standardizeOnly(root), PathGate.normalize(root)]
                return candidates.contains { candidate in
                    roots.contains { root in
                        candidate == root || candidate.hasPrefix(root + "/")
                            || root.hasPrefix(candidate + "/")
                    }
                }
            }
        }
    }

    private static func roots(for brand: BrowserBrand, home: String) -> [String] {
        switch brand {
        case .safari:
            return ["\(home)/Library/Caches/com.apple.Safari", "\(home)/Library/Caches/CloudKit/com.apple.Safari",
                    "\(home)/Library/WebKit/com.apple.Safari", "\(home)/Library/HTTPStorages/com.apple.Safari",
                    "\(home)/Library/Safari"]
        case .chrome:
            return ["\(home)/Library/Caches/Google/Chrome", "\(home)/Library/Caches/Google/Chrome Beta",
                    "\(home)/Library/Application Support/Google/Chrome", "\(home)/Library/Application Support/Google/Chrome Beta"]
        case .edge:
            return ["\(home)/Library/Caches/Microsoft Edge", "\(home)/Library/Caches/com.microsoft.edgemac",
                    "\(home)/Library/Application Support/Microsoft Edge", "\(home)/Library/Application Support/com.microsoft.edgemac"]
        }
    }

    static func isBrowserProcess(_ identity: BrowserProcessIdentity, brand: BrowserBrand) -> Bool {
        let bundleIDs: [String]
        let executableNames: [String]
        let appNames: [String]
        switch brand {
        case .safari:
            bundleIDs = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
            executableNames = ["Safari", "Safari Technology Preview"]
            appNames = ["Safari.app", "Safari Technology Preview.app"]
        case .chrome:
            bundleIDs = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]
            executableNames = ["Google Chrome", "Google Chrome Beta", "Google Chrome Dev", "Google Chrome Canary", "Google Chrome Helper"]
            appNames = ["Google Chrome.app", "Google Chrome Beta.app", "Google Chrome Dev.app", "Google Chrome Canary.app"]
        case .edge:
            bundleIDs = ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"]
            executableNames = ["Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev", "Microsoft Edge Canary", "Microsoft Edge Helper"]
            appNames = ["Microsoft Edge.app", "Microsoft Edge Beta.app", "Microsoft Edge Dev.app", "Microsoft Edge Canary.app"]
        }
        if let identifier = identity.bundleIdentifier?.lowercased(), bundleIDs.contains(where: {
            identifier == $0.lowercased() || identifier.hasPrefix($0.lowercased() + ".")
        }) { return true }
        guard let executable = identity.executablePath, !executable.isEmpty else { return false }
        let leaf = URL(fileURLWithPath: executable).lastPathComponent
        if executableNames.contains(where: { leaf == $0 || leaf.hasPrefix($0 + " (") }) { return true }
        return appNames.contains { executable.contains("/" + $0 + "/") }
    }

    private static func liveProcessState(_ brand: BrowserBrand) -> BrowserCleanupActivity {
        let applications = NSWorkspace.shared.runningApplications.map {
            BrowserProcessIdentity(bundleIdentifier: $0.bundleIdentifier, executablePath: $0.executableURL?.path)
        }
        if applications.contains(where: { isBrowserProcess($0, brand: brand) }) { return .inUse }

        // Workspace does not include every detached helper. A bounded complete ps
        // snapshot covers executable paths without relying on localized app names.
        guard let run = try? ProcessRunner.runSync(
            ["/bin/ps", "-axo", "comm="], timeout: 2, isCancelled: { Task.isCancelled }
        ), run.succeeded, !run.stdout.isEmpty, run.stderr.isEmpty else { return .unknown }
        let executables = run.stdoutString.split(whereSeparator: \.isNewline)
        guard !executables.isEmpty else { return .unknown }
        return executables.contains {
            isBrowserProcess(BrowserProcessIdentity(bundleIdentifier: nil,
                executablePath: String($0).trimmingCharacters(in: .whitespaces)), brand: brand)
        } ? .inUse : .idle
    }

    private static func liveOpenFileState(_ path: String) -> BrowserCleanupActivity {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "/usr/sbin/lsof") else { return .unknown }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &directory) else { return .unknown }
        let arguments: [String]
        if directory.boolValue {
            arguments = ["/usr/sbin/lsof", "-nP", "-Fpn", "+D", path]
        } else {
            arguments = ["/usr/sbin/lsof", "-nP", "-Fpn", "--"] + sqliteFamily(for: path, fm: fm)
        }
        guard let run = try? ProcessRunner.runSync(arguments, timeout: 2, isCancelled: { Task.isCancelled }),
              !run.timedOut, !run.wasCancelled, !run.outputLimitExceeded else { return .unknown }
        if !run.stdout.isEmpty { return .inUse }
        // lsof uses 1 for a completed empty selection. Diagnostics, including a
        // partial traversal, must never become evidence that a database is idle.
        return run.exitCode == 1 && run.stderr.isEmpty ? .idle : .unknown
    }

    static func sqliteFamily(for path: String, fm: FileManager = .default) -> [String] {
        var base = path
        for suffix in ["-wal", "-shm", "-journal"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }
        return [base, base + "-wal", base + "-shm", base + "-journal"]
            .filter { fm.fileExists(atPath: $0) }
    }
}
