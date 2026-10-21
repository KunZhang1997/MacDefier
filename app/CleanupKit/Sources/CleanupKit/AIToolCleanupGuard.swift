import AppKit
import Foundation

public enum AIToolCleanupActivity: Sendable, Equatable { case idle, inUse, unknown }

/// Read-only probes. Failure is unknown, never proof that an owner is absent.
public struct AIToolCleanupGuard: Sendable {
    let processState: @Sendable (AITool) -> AIToolCleanupActivity
    let openFileState: @Sendable (String) -> AIToolCleanupActivity

    public init(processState: @escaping @Sendable (AITool) -> AIToolCleanupActivity,
                openFileState: @escaping @Sendable (String) -> AIToolCleanupActivity) {
        self.processState = processState; self.openFileState = openFileState
    }
    public static let live = AIToolCleanupGuard(processState: { liveProcessState($0) }, openFileState: { liveOpenFileState($0) })
    public func state(for tool: AITool) -> AIToolCleanupActivity { processState(tool) }

    /// Dedicated previews still need owner and handle revalidation at execution.
    public func blockingReason(_ candidate: AICleanupCandidate, home: String) -> String? {
        let tools = Set([candidate.tool] + candidate.resources.flatMap { Self.affectedTools(path: $0.path, home: home) })
        for tool in tools {
            if let reason = ownerReason(tool) { return reason }
        }
        for resource in candidate.resources {
            switch openFileState(resource.path) {
            case .inUse: return "open_files"
            case .unknown: return "handle_probe_unknown"
            case .idle: break
            }
        }
        // A tool may have started while recursive lsof was inspecting the tree.
        for tool in tools {
            if let reason = ownerReason(tool) { return reason }
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
        for tool in tools {
            if let reason = ownerReason(tool) { return reason }
        }
        switch openFileState(path) {
        case .inUse: return "open_files"
        case .unknown: return "handle_probe_unknown"
        case .idle: break
        }
        for tool in tools {
            if let reason = ownerReason(tool) { return reason }
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
        if NSWorkspace.shared.runningApplications.contains(where: {
            matches(tool: tool, bundleID: $0.bundleIdentifier, command: $0.executableURL?.path ?? "")
        }) { return .inUse }
        guard let run = try? ProcessRunner.runSync(["/bin/ps", "-axo", "command=", "-ww"], timeout: 2,
            isCancelled: { Task.isCancelled }), run.succeeded, !run.stdout.isEmpty, run.stderr.isEmpty else { return .unknown }
        return run.stdoutString.split(whereSeparator: \.isNewline).contains {
            matches(tool: tool, command: String($0))
        } ? .inUse : .idle
    }

    private static func liveOpenFileState(_ path: String) -> AIToolCleanupActivity {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return .unknown }
        let args = directory.boolValue ? ["/usr/sbin/lsof", "-nP", "-Fpn", "+D", path]
            : ["/usr/sbin/lsof", "-nP", "-Fpn", "--"] + BrowserCleanupGuard.sqliteFamily(for: path)
        guard let run = try? ProcessRunner.runSync(args, timeout: 2, isCancelled: { Task.isCancelled }),
              !run.timedOut, !run.wasCancelled, !run.outputLimitExceeded else { return .unknown }
        if !run.stdout.isEmpty { return .inUse }
        return run.exitCode == 1 && run.stderr.isEmpty ? .idle : .unknown
    }
}
