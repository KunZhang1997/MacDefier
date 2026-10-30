// CliUninstallExecutor — stop LaunchAgents, channel uninstall (npm/brew/uv), optional data trash.
// Product §7.3.1 C1. Does not embed Pearcleaner/Mole.

import Darwin
import Foundation

public struct CliUninstallOptions: Sendable {
    public var stopAgents: Bool
    public var uninstallProgram: Bool
    public var trashDataDirs: Bool
    /// When true, only selected data paths are trashed (subset of tool.dataDirs).
    public var selectedDataPaths: [String]

    public init(
        stopAgents: Bool = true,
        uninstallProgram: Bool = true,
        trashDataDirs: Bool = false,
        selectedDataPaths: [String] = []
    ) {
        self.stopAgents = stopAgents
        self.uninstallProgram = uninstallProgram
        self.trashDataDirs = trashDataDirs
        self.selectedDataPaths = selectedDataPaths
    }
}

public struct CliUninstallResult: Sendable {
    public var steps: [String]
    public var errors: [String]
    public var trashedPaths: [String]
    public var freedBytes: UInt64
    public var movedToTrashBytes: UInt64
    public var programUninstalled: Bool
    public var agentsStopped: Int

    public init(
        steps: [String] = [],
        errors: [String] = [],
        trashedPaths: [String] = [],
        freedBytes: UInt64 = 0,
        movedToTrashBytes: UInt64 = 0,
        programUninstalled: Bool = false,
        agentsStopped: Int = 0
    ) {
        self.steps = steps
        self.errors = errors
        self.trashedPaths = trashedPaths
        self.freedBytes = freedBytes
        self.movedToTrashBytes = movedToTrashBytes
        self.programUninstalled = programUninstalled
        self.agentsStopped = agentsStopped
    }

    public var ok: Bool { errors.isEmpty }
}

public enum CliUninstallExecutor {
    private static let fm = FileManager.default

    typealias ProgramStep = (steps: [String], errors: [String], ok: Bool)
    typealias TrashStep = (steps: [String], errors: [String], trashed: [String], freed: UInt64)
    struct Execution: Sendable {
        let program: @Sendable (CliTool) async -> ProgramStep
        let footprintGone: @Sendable (CliTool) -> Bool
        let trash: @Sendable (String, UInt64) async -> TrashStep
    }

    public static func uninstall(tool: CliTool, options: CliUninstallOptions) async -> CliUninstallResult {
        let paths = tool.programPaths + tool.dataDirs.map(\.path) + tool.agents.map(\.plistPath)
        guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: paths) else {
            return CliUninstallResult(errors: ["resource_mutation_busy"])
        }
        defer { Task { await ResourceMutationCoordinator.shared.release(lease) } }
        let result = await execute(tool: tool, options: options, execution: Execution(
            program: { await uninstallProgram($0) },
            footprintGone: { programFootprintGone($0) },
            trash: { await trashPath($0, bytesHint: $1) }
        ))
        if result.programUninstalled || result.agentsStopped > 0 || !result.trashedPaths.isEmpty {
            CleanupResourceEvents.publish(paths: paths)
        }
        return result
    }

    static func execute(tool: CliTool, options: CliUninstallOptions, execution: Execution) async -> CliUninstallResult {
        var result = CliUninstallResult()
        let programSnapshots = tool.programPaths.compactMap { try? UninstallFileBoundary.snapshot($0) }
        guard !Task.isCancelled else { result.errors.append("cancelled"); return result }

        if tool.protected {
            result.errors.append("protected")
            return result
        }

        // L0 agents
        if options.stopAgents {
            for agent in tool.agents {
                guard !Task.isCancelled else { result.errors.append("cancelled"); return result }
                let r = await stopAndTrashAgent(agent, tool: tool, programSnapshots: programSnapshots)
                result.steps.append(contentsOf: r.steps)
                result.errors.append(contentsOf: r.errors)
                result.trashedPaths.append(contentsOf: r.trashed)
                if r.stopped { result.agentsStopped += 1 }
                if requiresStopping(r.errors) { return result }
            }
            guard result.errors.isEmpty else { return result }
        }

        // L1 program
        guard !Task.isCancelled else { result.errors.append("cancelled"); return result }
        if options.uninstallProgram {
            let r = await execution.program(tool)
            result.steps.append(contentsOf: r.steps)
            result.errors.append(contentsOf: r.errors)
            let actuallyGone = r.ok && execution.footprintGone(tool)
            result.programUninstalled = actuallyGone
            if r.ok && !actuallyGone {
                result.errors.append("program_still_present")
            }
            if actuallyGone {
                if tool.channel == .manual || tool.channel == .unknown {
                    result.movedToTrashBytes &+= tool.programBytes
                } else {
                    result.freedBytes &+= tool.programBytes
                }
            }
        }

        // L2 data
        if options.trashDataDirs {
            guard !options.uninstallProgram || result.programUninstalled else {
                result.errors.append("cli_data_preserved_program_failed")
                return result
            }
            guard !Task.isCancelled else {
                result.errors.append("cancelled")
                return result
            }
            let paths: [String]
            if options.selectedDataPaths.isEmpty {
                paths = tool.dataDirs.map(\.path)
            } else {
                let allow = Set(tool.dataDirs.map { PathGate.normalize($0.path) })
                paths = options.selectedDataPaths.filter { allow.contains(PathGate.normalize($0)) }
            }
            for path in paths {
                guard !Task.isCancelled else { result.errors.append("cancelled"); return result }
                let r = await execution.trash(path, tool.dataDirs.first(where: { $0.path == path })?.bytes ?? 0)
                result.steps.append(contentsOf: r.steps)
                result.errors.append(contentsOf: r.errors)
                result.trashedPaths.append(contentsOf: r.trashed)
                result.movedToTrashBytes &+= r.freed
                if requiresStopping(r.errors) { return result }
            }
        }

        return result
    }

    // MARK: - Agents

    private static func stopAndTrashAgent(_ agent: CliLaunchAgentInfo, tool: CliTool,
                                         programSnapshots: [UninstallFileBoundary.Snapshot]) async -> (steps: [String], errors: [String], trashed: [String], stopped: Bool) {
        var steps: [String] = []
        var errors: [String] = []
        var trashed: [String] = []
        var stopped = false
        guard !programSnapshots.isEmpty, programSnapshots.allSatisfy(UninstallFileBoundary.stillMatches) else {
            return ([], ["cli_agent_owner_changed:\(agent.plistPath)"], [], false)
        }
        let source: UninstallFileBoundary.Snapshot
        do { source = try CliOwnershipBoundary.validateAgent(agent, tool: tool) }
        catch { return ([], [error.localizedDescription], [], false) }
        func stillOwned() -> Bool {
            (try? CliOwnershipBoundary.validateAgent(agent, tool: tool).item) == source.item
                && UninstallFileBoundary.stillMatches(source)
                && programSnapshots.allSatisfy(UninstallFileBoundary.stillMatches)
        }
        let uid = getuid()
        let domain = "gui/\(uid)"
        // Prefer bootout by plist path; fallback label.
        let cmd1 = await runCapture(["/bin/launchctl", "bootout", domain, agent.plistPath], timeout: 15)
        guard !Task.isCancelled else { return (steps, ["cancelled"], [], false) }
        if cmd1.code == 0 {
            steps.append("launchctl bootout \(agent.label)")
            stopped = true
        } else {
            guard stillOwned() else { return (steps, ["cli_agent_owner_changed:\(agent.plistPath)"], [], false) }
            let cmd2 = await runCapture(["/bin/launchctl", "bootout", domain + "/" + agent.label], timeout: 15)
            if cmd2.code == 0 {
                steps.append("launchctl bootout \(agent.label)")
                stopped = true
            } else {
                // unload legacy
                guard stillOwned() else { return (steps, ["cli_agent_owner_changed:\(agent.plistPath)"], [], false) }
                let cmd3 = await runCapture(["/bin/launchctl", "unload", agent.plistPath], timeout: 15)
                if cmd3.code == 0 {
                    steps.append("launchctl unload \(agent.label)")
                    stopped = true
                } else {
                    // A stale inventory 'running=false' cannot authorize removing a live service.
                    return (steps, [cmd3.stderr, "cli_agent_stop_failed:\(agent.plistPath)"].filter { !$0.isEmpty }, [], false)
                }
            }
        }

        guard stillOwned() else {
            return (steps, ["cli_agent_owner_changed:\(agent.plistPath)"], [], stopped)
        }
        // Ownership was re-read after launchctl; move exactly the validated inode.
        let tr = await trashPath(agent.plistPath, bytesHint: 0, snapshot: source)
        steps.append(contentsOf: tr.steps)
        errors.append(contentsOf: tr.errors)
        trashed.append(contentsOf: tr.trashed)
        return (steps, errors, trashed, stopped)
    }

    // MARK: - Program

    private static func programFootprintGone(_ tool: CliTool) -> Bool {
        // Package-manager commands can return success while leaving a shim or a
        // package path behind. Never report its bytes as reclaimed in that case.
        let paths = tool.programPaths.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return true }
        return paths.allSatisfy(UninstallFileBoundary.isMissing)
    }

    private static func uninstallProgram(_ tool: CliTool) async -> (steps: [String], errors: [String], ok: Bool) {
        switch tool.channel {
        case .npm:
            return await uninstallNpm(tool)
        case .brew:
            return await uninstallBrew(tool)
        case .uv:
            return await uninstallUv(tool)
        case .manual, .unknown:
            return await uninstallManualProgram(tool)
        }
    }

    private static func uninstallNpm(_ tool: CliTool) async -> (steps: [String], errors: [String], ok: Bool) {
        guard let nodeModulesParent = tool.programPaths.first.flatMap({ npmPrefix(fromPackagePath: $0) }) else {
            return ([], ["npm_prefix"], false)
        }
        guard let npmBin = await resolveNpmBinary(preferHomebrew: nodeModulesParent.hasPrefix("/opt/homebrew")
                                            || nodeModulesParent.hasPrefix("/usr/local")) else {
            return ([], ["npm_missing"], false)
        }
        let args = [npmBin, "uninstall", "-g", tool.packageId, "--prefix", nodeModulesParent]
        let r = await runCapture(args, timeout: 120)
        let step = "npm uninstall -g \(tool.packageId) --prefix \(nodeModulesParent)"
        if r.code == 0 {
            return ([step], [], true)
        }
        guard !Task.isCancelled else { return ([step], ["cancelled"], false) }
        // Retry via login shell PATH (no hard-coded node major)
        let r2 = await runCapture(["/bin/zsh", "-lc", "npm uninstall -g \(shellEscape(tool.packageId)) --prefix \(shellEscape(nodeModulesParent))"], timeout: 120)
        if r2.code == 0 {
            return ([step + " (zsh)"], [], true)
        }
        // Report the final attempt's reason, not stale output from the first try.
        let err = r2.stderr.isEmpty ? r.stderr : r2.stderr
        return ([step], [err.isEmpty ? "npm_failed" : err], false)
    }

    /// Resolve `npm` without pinning a single Homebrew node major (e.g. node@22).
    /// Order: `brew --prefix node` → `brew --prefix node@*` candidates → `which npm`.
    static func resolveNpmBinary(preferHomebrew: Bool = true) async -> String? {
        if preferHomebrew {
            if let brew = await which("brew") {
                // Unversioned node formula first
                let pref = await runCapture([brew, "--prefix", "node"], timeout: 5)
                if pref.code == 0 {
                    let root = pref.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let candidate = (root as NSString).appendingPathComponent("bin/npm")
                    if fm.isExecutableFile(atPath: candidate) { return candidate }
                }
                // Common versioned kegs (probe, never sole hard pin)
                for formula in ["node@22", "node@20", "node@18"] {
                    let p = await runCapture([brew, "--prefix", formula], timeout: 5)
                    if p.code == 0 {
                        let root = p.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        let candidate = (root as NSString).appendingPathComponent("bin/npm")
                        if fm.isExecutableFile(atPath: candidate) { return candidate }
                    }
                }
            }
            // Apple Silicon / Intel Homebrew well-known roots (any installed node, not only @22)
            for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
                let unversioned = "\(root)/node/bin/npm"
                if fm.isExecutableFile(atPath: unversioned) { return unversioned }
            }
        }
        if let w = await which("npm") { return w }
        // Do not treat non-existent /usr/bin/npm as success path — only return if executable
        if fm.isExecutableFile(atPath: "/usr/bin/npm") { return "/usr/bin/npm" }
        return nil
    }

    private static func uninstallBrew(_ tool: CliTool) async -> (steps: [String], errors: [String], ok: Bool) {
        guard let brew = await which("brew") else {
            return ([], ["brew_missing"], false)
        }
        let r = await runCapture([brew, "uninstall", tool.packageId], timeout: 180)
        let step = "brew uninstall \(tool.packageId)"
        if r.code == 0 {
            return ([step], [], true)
        }
        return ([step], [r.stderr.isEmpty ? "brew_failed" : r.stderr], false)
    }

    private static func uninstallUv(_ tool: CliTool) async -> (steps: [String], errors: [String], ok: Bool) {
        let r = await runCapture(["/bin/zsh", "-lc", "uv tool uninstall \(shellEscape(tool.packageId))"], timeout: 120)
        let step = "uv tool uninstall \(tool.packageId)"
        if r.code == 0 {
            return ([step], [], true)
        }
        return ([step], [r.stderr.isEmpty ? "uv_failed" : r.stderr], false)
    }

    /// Only explicit program paths and symlinks freshly bound to those paths are eligible.
    static func uninstallManualProgram(
        _ tool: CliTool,
        home: String = NSHomeDirectory(),
        trash: (UninstallFileBoundary.Snapshot) async -> TrashStep = { source in
            await trashPath(source.path, bytesHint: 0, snapshot: source)
        }
    ) async -> ProgramStep {
        if tool.programPaths.isEmpty {
            return (["no program package"], [], true)
        }
        var steps: [String] = []
        var errors: [String] = []
        let plan: [UninstallFileBoundary.Snapshot]
        do { plan = try manualProgramPlan(tool, home: home) }
        catch { return ([], [error.localizedDescription], false) }
        for source in plan {
            guard !Task.isCancelled else { return (steps, errors + ["cancelled"], false) }
            if let evidence = tool.manualEntryEvidence[source.path], !evidence.stillMatches {
                return (steps, errors + ["cli_manual_owner_changed:\(source.path)"], false)
            }
            let r = await trash(source)
            steps.append(contentsOf: r.steps)
            errors.append(contentsOf: r.errors)
            if requiresStopping(r.errors) { return (steps, errors, false) }
        }

        if steps.isEmpty && errors.isEmpty {
            return (["manual: nothing to remove"], [], true)
        }
        return (steps, errors, errors.isEmpty)
    }

    static func manualProgramPlan(_ tool: CliTool, home: String = NSHomeDirectory()) throws -> [UninstallFileBoundary.Snapshot] {
        let shimRoots = [home + "/.local/bin", home + "/bin"].map { ($0 as NSString).standardizingPath }
        var paths = tool.programPaths
        for path in paths {
            let lexical = (path as NSString).standardizingPath
            guard !shimRoots.contains(lexical) else {
                throw UninstallFileBoundary.Failure(code: "cli_manual_shared_root", path: path)
            }
            if let evidence = tool.manualEntryEvidence[lexical] {
                // Preserve a fresh POSIX refusal instead of mislabelling a denied
                // metadata read as replacement of the previewed command.
                do {
                    _ = try UninstallFileBoundary.snapshot(path)
                } catch {
                    if UninstallFileBoundary.isMissing(path) { continue }
                    throw error
                }
                if !evidence.stillMatches {
                    throw UninstallFileBoundary.Failure(code: "cli_manual_owner_changed", path: path)
                }
            }
        }
        for bin in tool.bins {
            guard !bin.isEmpty, bin != ".", bin != "..", !bin.contains("/"), !bin.utf8.contains(0) else {
                throw UninstallFileBoundary.Failure(code: "cli_manual_owner_changed", path: bin)
            }
            for base in shimRoots {
                let path = (base as NSString).appendingPathComponent(bin)
                do {
                    _ = try UninstallFileBoundary.snapshot(path)
                    paths.append(path)
                } catch {
                    if !UninstallFileBoundary.isMissing(path) { throw error }
                }
            }
        }
        var seen = Set<String>()
        var plan: [UninstallFileBoundary.Snapshot] = []
        for path in paths where seen.insert((path as NSString).standardizingPath).inserted {
            let source: UninstallFileBoundary.Snapshot
            do {
                source = try UninstallFileBoundary.snapshot(path)
            } catch {
                if UninstallFileBoundary.isMissing(path) { continue }
                throw error
            }
            let lexical = (path as NSString).standardizingPath
            if shimRoots.contains(where: { lexical.hasPrefix($0 + "/") }) {
                if source.item.kind == mode_t(S_IFREG) {
                    guard let evidence = tool.manualEntryEvidence[lexical],
                          tool.programPaths.contains(lexical), evidence.stillMatches else {
                        throw UninstallFileBoundary.Failure(code: "cli_manual_ownership_unverified", path: path)
                    }
                } else if !CliOwnershipBoundary.validateShim(path, tool: tool, home: home) {
                    throw UninstallFileBoundary.Failure(code: "cli_manual_owner_changed", path: path)
                }
            }
            plan.append(source)
        }
        // Shims precede their program directories. No inferred downloads/bundled siblings.
        return plan.sorted { ($0.item.kind == mode_t(S_IFLNK) ? 0 : 1) < ($1.item.kind == mode_t(S_IFLNK) ? 0 : 1) }
    }

    /// package path: .../lib/node_modules/name or .../lib/node_modules/@scope/name → npm prefix
    private static func npmPrefix(fromPackagePath path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        for _ in 0..<8 {
            if url.lastPathComponent == "node_modules" {
                // .../prefix/lib/node_modules
                let lib = url.deletingLastPathComponent()
                if lib.lastPathComponent == "lib" {
                    return lib.deletingLastPathComponent().path
                }
                return lib.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    // MARK: - Trash

    /// Align with `UninstallExecutor.trashUserLevel`: PathGate/existence on **resolved** target,
    /// `trashItem` on the **original** path URL so symlinks are moved (not their out-of-tree targets).
    static func trashPath(_ path: String, bytesHint: UInt64,
                          snapshot: UninstallFileBoundary.Snapshot? = nil) async -> (steps: [String], errors: [String], trashed: [String], freed: UInt64) {
        let resolved = PathGate.normalize(path)
        // Only ENOENT proves absence; permission errors are not "already removed".
        if UninstallFileBoundary.isMissing(path) {
            return (["skip missing \(path)"], [], [], 0)
        }
        // Gate on resolved path (block escape via symlink into secrets / system)
        guard PathGate.isSafeToTrash(resolved) else {
            return ([], ["blocked:\(path)"], [], 0)
        }
        // Never trash MacDefier app data via generic path
        if resolved.lowercased().contains("macdefier") && resolved.lowercased().contains("/library/") {
            return ([], ["protected_data"], [], 0)
        }
        if path.lowercased().contains("macdefier") && path.lowercased().contains("/library/") {
            return ([], ["protected_data"], [], 0)
        }
        do {
            let source = try snapshot ?? UninstallFileBoundary.snapshot(path)
            if let reason = AIToolCleanupGuard.live.blockingReasonForExplicitRemoval(source, home: fm.homeDirectoryForCurrentUser.path) {
                return ([], ["ai_cleanup_\(reason):\(path)"], [], 0)
            }
            _ = try await UninstallSystemTrash.move(source)
            return (["trash \(path)"], [], [path], bytesHint)
        } catch {
            return ([], [error.localizedDescription], [], 0)
        }
    }

    // MARK: - Shell

    private static func requiresStopping(_ errors: [String]) -> Bool {
        errors.contains { error in
            let code = error.split(separator: ":", maxSplits: 1).first.map(String.init)
            return code == "uninstall_authorization_cancelled" || code == "uninstall_system_result_unknown"
        }
    }

    private static func which(_ cmd: String) async -> String? {
        let r = await runCapture(["/usr/bin/which", cmd], timeout: 3)
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.code == 0, !p.isEmpty, fm.isExecutableFile(atPath: p) else { return nil }
        return p
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct ProcOut {
        var code: Int32
        var stdout: String
        /// A stable reason code, never raw stderr.
        var stderr: String
    }

    /// 异步子进程：禁止在 async 路径用 runSync + Thread.sleep 占协作线程池。
    private static func runCapture(_ args: [String], timeout: TimeInterval) async -> ProcOut {
        do {
            let run = try await ProcessRunner.run(args, timeout: timeout)
            let code: Int32 = run.succeeded ? 0 : (run.exitCode == 0 ? -1 : run.exitCode)
            let message = run.timedOut ? "timeout" : (run.wasCancelled ? "cancelled" : (run.outputLimitExceeded ? "output_limit" : run.stderrString))
            return ProcOut(code: code, stdout: run.stdoutString,
                           stderr: run.succeeded ? "" : UninstallCommandFailure.code(stderr: message, exitCode: code))
        } catch {
            return ProcOut(code: -1, stdout: "", stderr: "command_launch_failed")
        }
    }
}
