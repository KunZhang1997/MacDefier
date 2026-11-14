import AppKit
import Foundation

public enum AIToolCleanupActivity: Sendable, Equatable { case idle, inUse, unknown }

/// Scan/check-scoped process table cache so evaluating 100+ items or multiple tools/browsers
/// forks `/bin/ps` at most once instead of 100–200 times. Never persisted across scans.
final class CleanupProcessSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let runPS: @Sendable ([String]) -> ProcessRunResult?
    private let runningApplicationsProvider: @Sendable () -> [BrowserProcessIdentity]

    private var cachedApps: [BrowserProcessIdentity]?
    private var didCaptureCommandLines = false
    private var cachedCommandLines: [String]?
    private var didCaptureExecutableLines = false
    private var cachedExecutableLines: [String]?
    private var aiActivityMemo: [AITool: AIToolCleanupActivity] = [:]
    private var browserActivityMemo: [BrowserBrand: BrowserCleanupActivity] = [:]

    init(
        runningApplicationsProvider: @escaping @Sendable () -> [BrowserProcessIdentity] = {
            NSWorkspace.shared.runningApplications.map {
                BrowserProcessIdentity(bundleIdentifier: $0.bundleIdentifier, executablePath: $0.executableURL?.path)
            }
        },
        runPS: @escaping @Sendable ([String]) -> ProcessRunResult? = { args in
            try? ProcessRunner.runSync(args, timeout: 2, isCancelled: { Task.isCancelled })
        }
    ) {
        self.runningApplicationsProvider = runningApplicationsProvider
        self.runPS = runPS
    }

    func aiToolActivity(for tool: AITool) -> AIToolCleanupActivity {
        lock.lock()
        if let cached = aiActivityMemo[tool] {
            lock.unlock()
            return cached
        }
        let apps = ensureAppsLocked()
        lock.unlock()

        if apps.contains(where: {
            AIToolCleanupGuard.matches(tool: tool, bundleID: $0.bundleIdentifier, command: $0.executablePath ?? "")
        }) {
            lock.lock()
            aiActivityMemo[tool] = .inUse
            lock.unlock()
            return .inUse
        }

        let lines = commandLines()
        let result: AIToolCleanupActivity
        if let lines {
            result = lines.contains { AIToolCleanupGuard.matches(tool: tool, command: $0) } ? .inUse : .idle
        } else {
            result = .unknown
        }
        lock.lock()
        aiActivityMemo[tool] = result
        lock.unlock()
        return result
    }

    func browserActivity(for brand: BrowserBrand) -> BrowserCleanupActivity {
        lock.lock()
        if let cached = browserActivityMemo[brand] {
            lock.unlock()
            return cached
        }
        let apps = ensureAppsLocked()
        lock.unlock()

        if apps.contains(where: { BrowserCleanupGuard.isBrowserProcess($0, brand: brand) }) {
            lock.lock()
            browserActivityMemo[brand] = .inUse
            lock.unlock()
            return .inUse
        }

        let executables = executableLines()
        let result: BrowserCleanupActivity
        if let executables, !executables.isEmpty {
            result = executables.contains {
                BrowserCleanupGuard.isBrowserProcess(
                    BrowserProcessIdentity(bundleIdentifier: nil, executablePath: $0.trimmingCharacters(in: .whitespaces)),
                    brand: brand
                )
            } ? .inUse : .idle
        } else {
            result = .unknown
        }
        lock.lock()
        browserActivityMemo[brand] = result
        lock.unlock()
        return result
    }

    private func ensureAppsLocked() -> [BrowserProcessIdentity] {
        if let cachedApps { return cachedApps }
        let loaded = runningApplicationsProvider()
        cachedApps = loaded
        return loaded
    }

    private func commandLines() -> [String]? {
        lock.lock()
        if didCaptureCommandLines {
            let lines = cachedCommandLines
            lock.unlock()
            return lines
        }
        lock.unlock()

        let run = runPS(["/bin/ps", "-axo", "command=", "-ww"])
        let parsed: [String]?
        if let run, run.succeeded, !run.stdout.isEmpty, run.stderr.isEmpty {
            parsed = run.stdoutString.split(whereSeparator: \.isNewline).map(String.init)
        } else {
            parsed = nil
        }

        lock.lock()
        if !didCaptureCommandLines {
            didCaptureCommandLines = true
            cachedCommandLines = parsed
        }
        let result = cachedCommandLines
        lock.unlock()
        return result
    }

    private func executableLines() -> [String]? {
        lock.lock()
        if didCaptureExecutableLines {
            let lines = cachedExecutableLines
            lock.unlock()
            return lines
        }
        lock.unlock()

        let run = runPS(["/bin/ps", "-axo", "comm="])
        let parsed: [String]?
        if let run, run.succeeded, !run.stdout.isEmpty, run.stderr.isEmpty {
            let lines = run.stdoutString.split(whereSeparator: \.isNewline).map(String.init)
            parsed = lines.isEmpty ? nil : lines
        } else {
            parsed = nil
        }

        lock.lock()
        if !didCaptureExecutableLines {
            didCaptureExecutableLines = true
            cachedExecutableLines = parsed
        }
        let result = cachedExecutableLines
        lock.unlock()
        return result
    }
}

/// Read-only probes. Failure is unknown, never proof that an owner is absent.
public struct AIToolCleanupGuard: Sendable {
    let processState: @Sendable (AITool) -> AIToolCleanupActivity
    let openFileState: @Sendable (String) -> AIToolCleanupActivity
    private let usesLiveProcessProbe: Bool

    public init(processState: @escaping @Sendable (AITool) -> AIToolCleanupActivity,
                openFileState: @escaping @Sendable (String) -> AIToolCleanupActivity) {
        self.processState = processState
        self.openFileState = openFileState
        self.usesLiveProcessProbe = false
    }

    private init(
        processState: @escaping @Sendable (AITool) -> AIToolCleanupActivity,
        openFileState: @escaping @Sendable (String) -> AIToolCleanupActivity,
        usesLiveProcessProbe: Bool
    ) {
        self.processState = processState
        self.openFileState = openFileState
        self.usesLiveProcessProbe = usesLiveProcessProbe
    }

    public static let live = AIToolCleanupGuard(
        processState: { liveProcessState($0) },
        openFileState: { liveOpenFileState($0) },
        usesLiveProcessProbe: true
    )

    static func withCapturedProcessSnapshot(_ snapshot: CleanupProcessSnapshot = .init()) -> AIToolCleanupGuard {
        AIToolCleanupGuard(
            processState: { snapshot.aiToolActivity(for: $0) },
            openFileState: { liveOpenFileState($0) },
            usesLiveProcessProbe: false
        )
    }

    func boundToProcessSnapshotIfLive(_ snapshot: CleanupProcessSnapshot = .init()) -> AIToolCleanupGuard {
        usesLiveProcessProbe ? Self.withCapturedProcessSnapshot(snapshot) : self
    }

    public func state(for tool: AITool) -> AIToolCleanupActivity { processState(tool) }
    public func openFileActivity(for path: String) -> AIToolCleanupActivity { openFileState(path) }

    /// Dedicated previews still need owner and handle revalidation at execution.
    public func blockingReason(_ candidate: AICleanupCandidate, home: String) -> String? {
        let scoped = boundToProcessSnapshotIfLive()
        let tools = Set([candidate.tool] + candidate.resources.flatMap { Self.affectedTools(path: $0.path, home: home) })
        // Idle `ollama serve` / `Ollama.app` stays resident without opening unloaded model files;
        // active inference (`ollama runner`) holds open file descriptors checked immediately below.
        let skipIdleDaemonOwner = candidate.kind == .model && tools == [.ollama]
        if !skipIdleDaemonOwner {
            for tool in tools {
                if let reason = scoped.ownerReason(tool) { return reason }
            }
        }
        for resource in candidate.resources {
            switch openFileState(resource.path) {
            case .inUse: return "open_files"
            case .unknown: return "handle_probe_unknown"
            case .idle: break
            }
        }
        return nil
    }

    /// The caller already owns an explicit uninstall/data-removal preview.
    /// Reuse activity protection without granting a generic durable-root bypass.
    func blockingReasonForExplicitRemoval(_ source: UninstallFileBoundary.Snapshot, home: String) -> String? {
        let owners = Self.affectedTools(path: source.path, home: home)
        guard let owner = owners.first else { return nil }
        guard AIToolCleanupScanner.isPhysical(source.path),
              let resource = try? AIResource.capture(path: source.path, bytes: 0),
              resource.boundary.path == source.path,
              resource.boundary.parentPath == source.parentPath,
              resource.boundary.parent == source.parent,
              resource.boundary.item == source.item else { return "changed" }
        let candidate = AICleanupCandidate(tool: owner, kind: .leftover, title: owner.name,
            resources: [resource], state: .ready, reason: "explicit_removal", contextPath: source.path)
        if let reason = blockingReason(candidate, home: home) { return reason }
        guard UninstallFileBoundary.stillMatches(source),
              AIToolCleanupExecutor.resourceStillMatches(resource) else { return "changed" }
        return nil
    }

    /// Scan-time preview check: validates cache target scope and owner process liveness
    /// using the shared scan snapshot, deferring expensive recursive `lsof` to execution.
    func previewBlockingReason(for path: String, home: String) -> String? {
        let tools = Self.affectedTools(path: path, home: home)
        guard !tools.isEmpty else { return nil }
        let physical = AIToolCleanupScanner.physicalPath(PathGate.normalize(path))
        let physicalHome = AIToolCleanupScanner.physicalPath(PathGate.normalize(home))
        guard AIToolCleanupScanner.isPhysical(path),
              AIToolCleanupScanner.cacheTargets(home: physicalHome).contains(where: {
                  Self.isWithin(physical, $0.path)
              }) else { return "dedicated_preview_required" }
        let scoped = boundToProcessSnapshotIfLive()
        for tool in tools {
            if let reason = scoped.ownerReason(tool) { return reason }
        }
        return nil
    }

    /// Called by generic Trash too. A broad parent, durable store, model, or old
    /// version cannot acquire permission merely by being named a generic cache.
    public func blockingReason(for path: String, home: String) -> String? {
        let tools = Self.affectedTools(path: path, home: home)
        guard !tools.isEmpty else { return nil }
        let physical = AIToolCleanupScanner.physicalPath(PathGate.normalize(path))
        let physicalHome = AIToolCleanupScanner.physicalPath(PathGate.normalize(home))
        guard AIToolCleanupScanner.isPhysical(path),
              AIToolCleanupScanner.cacheTargets(home: physicalHome).contains(where: {
                  Self.isWithin(physical, $0.path)
              }) else { return "dedicated_preview_required" }
        let scoped = boundToProcessSnapshotIfLive()
        for tool in tools {
            if let reason = scoped.ownerReason(tool) { return reason }
        }
        switch openFileState(path) {
        case .inUse: return "open_files"
        case .unknown: return "handle_probe_unknown"
        case .idle: break
        }
        return nil
    }

    private func ownerReason(_ tool: AITool) -> String? {
        switch processState(tool) {
        case .idle: return nil
        case .inUse: return "in_use"
        case .unknown: return "probe_unknown"
        }
    }

    static func affectedTools(path: String, home: String) -> [AITool] {
        let paths = [PathGate.standardizeOnly(path), PathGate.normalize(path)].map(AIToolCleanupScanner.physicalPath)
        let physicalHome = AIToolCleanupScanner.physicalPath(PathGate.normalize(home))
        var roots: [(AITool, String)] = AIToolCleanupScanner.cacheTargets(home: physicalHome).map { ($0.tool, $0.path) }
        let durable: [(AITool, [String])] = [
            (.codex, [".codex", "Library/Application Support/Codex", "Library/Caches/Codex", "Library/Caches/com.openai.codex"]),
            (.claude, [".claude", ".local/share/claude", "Library/Application Support/Claude", "Library/Caches/Claude", "Library/Caches/com.anthropic.claude"]),
            (.cursor, [".cursor", ".cursor-agent", ".local/share/cursor-agent", "Library/Application Support/Cursor", "Library/Caches/Cursor", "Library/Caches/com.todesktop.cursor"]),
            (.copilot, [".copilot"]), (.antigravity, ["Library/Application Support/Antigravity", ".gemini/antigravity-browser-profile", "Library/Caches/Antigravity", "Library/Caches/com.google.antigravity"]),
            (.opencode, [".local/share/opencode", ".config/opencode"]),
            (.kimi, [".kimi", ".kimi-code", "Library/Application Support/kimi", "Library/Application Support/kimi-desktop"]),
            (.gemini, [".gemini"]),
            (.ollama, [".ollama", "Library/WebKit/com.electron.ollama", "Library/Saved Application State/com.electron.ollama.savedState"]),
            (.lmstudio, [".lmstudio", "Library/Application Support/LM Studio", "Library/Caches/LM Studio", "Library/Caches/ai.elementlabs.lmstudio"])
        ]
        roots += durable.flatMap { tool, relative in relative.map { (tool, physicalHome + "/" + $0) } }
        return AITool.allCases.filter { tool in
            roots.contains { root in root.0 == tool && paths.contains { ResourceMutationCoordinator.overlaps($0, root.1) } }
        }
    }

    private static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func matches(tool: AITool, bundleID: String? = nil, command: String) -> Bool {
        let bundles: [AITool: [String]] = [
            .codex: ["com.openai.codex"], .claude: ["com.anthropic.claude"], .cursor: ["com.todesktop.cursor"],
            .antigravity: ["com.google.antigravity"], .ollama: ["com.electron.ollama"],
            .lmstudio: ["ai.elementlabs.lmstudio", "com.lmstudio.app"], .kimi: ["com.moonshot.kimi"]
        ]
        if let id = bundleID?.lowercased(), bundles[tool, default: []].contains(id) { return true }
        let text = command.lowercased()
        let tokens = text.split(whereSeparator: \.isWhitespace).map { URL(fileURLWithPath: String($0)).lastPathComponent }
        let names: [AITool: Set<String>] = [
            .codex: ["codex", "codex-app-server"], .claude: ["claude", "claude-code"],
            .cursor: ["cursor", "cursor-agent"], .copilot: ["copilot"],
            .antigravity: ["antigravity"], .opencode: ["opencode"], .kimi: ["kimi", "kimi-code"],
            .gemini: ["gemini"], .ollama: ["ollama"], .lmstudio: ["lms", "lmstudio"]
        ]
        if tokens.contains(where: { names[tool, default: []].contains($0) }) { return true }
        let markers: [AITool: [String]] = [
            .codex: ["codex.app/", "/@openai/codex/", "/.codex/", "/codex/bin/"],
            .claude: ["claude.app/", "/@anthropic-ai/claude-code/", "/.local/share/claude/versions/"],
            .cursor: ["cursor.app/", "/.local/share/cursor-agent/versions/"],
            .copilot: ["/github-copilot/", "/.copilot/pkg/"], .antigravity: ["antigravity.app/", "antigravity-browser-profile"],
            .opencode: ["/opencode/bin/"], .kimi: ["/kimi-cli/", "/kimi-code/"],
            .gemini: ["/@google/gemini-cli/", "antigravity-browser-profile"],
            .ollama: ["ollama.app/", "/ollama serve"], .lmstudio: ["lm studio.app/", "/lmstudio/"]
        ]
        return markers[tool, default: []].contains { text.contains($0) }
    }

    private static func liveProcessState(_ tool: AITool) -> AIToolCleanupActivity {
        CleanupProcessSnapshot().aiToolActivity(for: tool)
    }

    /// Snapshot all currently open file paths once via kernel fd table (`lsof -nP -Fn`),
    /// avoiding recursive `lsof +D` timeouts on large Application Support / model directories.
    public static func captureOpenFilePaths() -> Set<String>? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return nil }
        guard let run = try? ProcessRunner.runSync(
            ["/usr/sbin/lsof", "-nP", "-Fn"],
            timeout: 4,
            isCancelled: { Task.isCancelled }
        ), !run.timedOut, !run.wasCancelled, !run.outputLimitExceeded,
              (run.exitCode == 0 || run.exitCode == 1) else {
            return nil
        }
        var paths = Set<String>()
        for line in run.stdoutString.split(whereSeparator: \.isNewline) where line.first == "n" {
            let raw = String(line.dropFirst())
            if raw.hasPrefix("/") {
                paths.insert(raw)
            }
        }
        return paths
    }

    public static func openFileActivity(for path: String, in openPaths: Set<String>?) -> AIToolCleanupActivity {
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        guard let openPaths else { return .unknown }
        let candidates = Set([
            PathGate.standardizeOnly(path),
            PathGate.normalize(path),
            AIToolCleanupScanner.physicalPath(path)
        ])
        for target in candidates where !target.isEmpty {
            let prefix = target.hasSuffix("/") ? target : target + "/"
            if openPaths.contains(where: { $0 == target || $0.hasPrefix(prefix) }) {
                return .inUse
            }
        }
        return .idle
    }

    private static func liveOpenFileState(_ path: String) -> AIToolCleanupActivity {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return .unknown }
        if directory.boolValue {
            return openFileActivity(for: path, in: captureOpenFilePaths())
        }
        let args = ["/usr/sbin/lsof", "-nP", "-Fpn", "--"] + BrowserCleanupGuard.sqliteFamily(for: path)
        guard let run = try? ProcessRunner.runSync(args, timeout: 2, isCancelled: { Task.isCancelled }),
              !run.timedOut, !run.wasCancelled, !run.outputLimitExceeded else { return .unknown }
        if !run.stdout.isEmpty { return .inUse }
        return run.exitCode == 1 && run.stderr.isEmpty ? .idle : .unknown
    }
}
