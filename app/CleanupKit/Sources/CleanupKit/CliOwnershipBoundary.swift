import Darwin
import Foundation

/// A shared command directory is not a package root. Its individual entries need
/// scan-time evidence so accepting a regular executable cannot authorize a replacement.
struct CliManualEntryEvidence: Hashable, Sendable {
    let source: UninstallFileBoundary.Snapshot
    let resolvedPath: String
    let size: off_t
    let permissions: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    static func capture(_ path: String) -> Self? {
        guard let source = try? UninstallFileBoundary.snapshot(path),
              source.item.owner == getuid(),
              source.item.kind == mode_t(S_IFREG) || source.item.kind == mode_t(S_IFLNK) else { return nil }
        var item = stat()
        guard lstat(path, &item) == 0,
              UninstallFileBoundary.Identity(item) == source.item,
              UninstallFileBoundary.stillMatches(source) else { return nil }
        return Self(source: source, resolvedPath: PathGate.normalize(path), size: item.st_size,
                    permissions: item.st_mode & 0o7777,
                    modifiedSeconds: item.st_mtimespec.tv_sec,
                    modifiedNanoseconds: item.st_mtimespec.tv_nsec)
    }

    var stillMatches: Bool { Self.capture(source.path) == self }
}

/// Execution-time ownership evidence; label/name resemblance is never authority.
enum CliOwnershipBoundary {
    static func programRoots(_ tool: CliTool, home: String = NSHomeDirectory()) -> [String] {
        let shimRoots = [home + "/.local/bin", home + "/bin"].map { ($0 as NSString).standardizingPath }
        return tool.programPaths.compactMap { path in
            let lexical = (path as NSString).standardizingPath
            if shimRoots.contains(lexical) { return nil }
            if let evidence = tool.manualEntryEvidence[lexical], !evidence.stillMatches { return nil }
            if shimRoots.contains(where: { lexical.hasPrefix($0 + "/") }) {
                guard let evidence = tool.manualEntryEvidence[lexical], evidence.stillMatches,
                      evidence.source.item.kind == mode_t(S_IFREG) else { return nil }
                return evidence.resolvedPath
            }
            if (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink { return nil }
            return PathGate.normalize(path)
        }
    }

    static func validateShim(_ path: String, tool: CliTool, home: String = NSHomeDirectory()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return false }
        let resolved = PathGate.normalize(path)
        return programRoots(tool, home: home).contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }

    static func validateAgent(_ agent: CliLaunchAgentInfo, tool: CliTool,
                              home: String = NSHomeDirectory()) throws -> UninstallFileBoundary.Snapshot {
        let root = URL(fileURLWithPath: home + "/Library/LaunchAgents").resolvingSymlinksInPath().path
        let lexical = URL(fileURLWithPath: agent.plistPath).standardizedFileURL
        guard lexical.deletingLastPathComponent().resolvingSymlinksInPath().path == root,
              lexical.pathExtension == "plist" else { throw failure(agent.plistPath) }
        let source = try UninstallFileBoundary.snapshot(agent.plistPath)
        guard source.item.kind == mode_t(S_IFREG), source.item.owner == getuid(),
              let data = try? Data(contentsOf: lexical),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == agent.label else { throw failure(agent.plistPath) }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = (plist["Program"] as? String) ?? arguments.first ?? ""
        guard program.hasPrefix("/") else { throw failure(agent.plistPath) }
        let roots = programRoots(tool, home: home)
        // A known interpreter may launch the selected package via an absolute argument.
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "perl", "bash", "sh", "zsh"]
        var candidates = [program]
        if interpreters.contains(URL(fileURLWithPath: program).lastPathComponent),
           arguments.count > 1, arguments[1].hasPrefix("/") {
            candidates.append(arguments[1])
        }
        guard candidates.contains(where: { candidate in
            let resolved = PathGate.normalize(candidate)
            return roots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
        }), UninstallFileBoundary.stillMatches(source) else { throw failure(agent.plistPath) }
        return source
    }

    private static func failure(_ path: String) -> UninstallFileBoundary.Failure {
        .init(code: "cli_agent_owner_changed", path: path)
    }
}
