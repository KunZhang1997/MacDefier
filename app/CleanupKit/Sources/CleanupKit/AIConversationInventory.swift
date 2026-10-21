import Darwin
import Foundation

/// Metadata inventory, never a transcript parser. Native sessions have indexes,
/// attachments, or other owner-managed state and are intentionally review-only.
public enum AIConversationInventory {
    public static func scan(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: Date = Date(),
        includeWorktrees: Bool = true,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> AICleanupInventory {
        scan(home: home, now: now, limits: AIInventoryScanLimits(), includeWorktrees: includeWorktrees, isCancelled: isCancelled)
    }

    static func scan(
        home: String, now: Date, limits: AIInventoryScanLimits,
        includeWorktrees: Bool = true,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> AICleanupInventory {
        let context = AIInventoryMetadata(home: home, limits: limits, isCancelled: isCancelled)
        guard context.validHome else {
            return AICleanupInventory(issues: ["conversation_scan_inaccessible"], scannedAt: now)
        }
        var groups: [Group] = []
        for relative in [".codex/sessions", ".codex/archived_sessions"] {
            var group = Group(tool: .codex, root: context.path(relative), format: "codex_rollout")
            codex(group.root, archived: relative.hasSuffix("archived_sessions"), context: context, group: &group)
            groups.append(group)
        }
        var cursor = Group(tool: .cursor, root: context.path(".cursor/projects"), format: "cursor_saved_transcript")
        for project in context.children(cursor.root) where context.isDirectory(project) && !project.lastComponent.hasPrefix(".") {
            let transcripts = project + "/agent-transcripts"
            for item in context.children(transcripts) {
                if let id = transcriptID(item.lastComponent, extensions: ["jsonl", "txt"]) {
                    cursor.add(item, session: project + "/" + id, context: context)
                } else if uuid(item.lastComponent), context.isDirectory(item) {
                    for suffix in ["jsonl", "txt"] {
                        cursor.add(item + "/" + item.lastComponent + "." + suffix, session: project + "/" + item.lastComponent, context: context)
                    }
                    for child in context.children(item + "/subagents") {
                        if transcriptID(child.lastComponent, extensions: ["jsonl", "txt"]) != nil {
                            cursor.add(child, session: project + "/" + item.lastComponent, context: context)
                        }
                    }
                }
            }
        }
        groups.append(cursor)

        var claude = Group(tool: .claude, root: context.path(".claude/projects"), format: "claude_project_jsonl")
        for project in context.children(claude.root) where context.isDirectory(project) && !project.lastComponent.hasPrefix(".") {
            for item in context.children(project) {
                if let id = transcriptID(item.lastComponent, extensions: ["jsonl"]) {
                    claude.add(item, session: project + "/" + id, context: context)
                } else if uuid(item.lastComponent), context.isDirectory(item) {
                    for child in context.children(item + "/subagents") {
                        let name = child.lastComponent
                        if name.hasPrefix("agent-"), name.hasSuffix(".jsonl"),
                           safeToken(String(name.dropFirst(6).dropLast(6))) {
                            claude.add(child, session: item, context: context)
                        }
                    }
                }
            }
        }
        groups.append(claude)

        for base in [".kimi-code", ".kimi"] {
            var group = Group(tool: .kimi, root: context.path(base + "/sessions"), format: "kimi_session_files")
            for workspace in context.children(group.root) where context.isDirectory(workspace) && !workspace.lastComponent.hasPrefix(".") {
                for session in context.children(workspace) {
                    if let id = transcriptID(session.lastComponent, extensions: ["jsonl"]) {
                        group.add(session, session: workspace + "/" + id, context: context)
                        continue
                    }
                    let name = session.lastComponent
                    let id = name.hasPrefix("session_") ? String(name.dropFirst(8))
                        : name.hasPrefix("ses_") ? String(name.dropFirst(4)) : name
                    guard uuid(id), context.isDirectory(session) else { continue }
                    // Moonshot's file-based CLI and the installed Kimi Code layout.
                    // State, indexes, logs, auth, and arbitrary agent files stay out.
                    group.add(session + "/context.jsonl", session: session, context: context)
                    group.add(session + "/wire.jsonl", session: session, context: context)
                    for agent in context.children(session + "/agents") where safeToken(agent.lastComponent) && context.isDirectory(agent) {
                        group.add(agent + "/wire.jsonl", session: session, context: context)
                    }
                }
            }
            groups.append(group)
        }

        var candidates = groups.flatMap { $0.candidates() }
        // Worktree inventory has its own smaller, bounded Git/metadata budget.
        if includeWorktrees && !isCancelled() {
            let worktrees = AIWorktreeInventory.scan(home: home, now: now, isCancelled: isCancelled)
            candidates += worktrees.candidates
            context.issues.formUnion(worktrees.issues)
        } else if isCancelled() {
            context.issues.insert("conversation_scan_cancelled")
        }
        return AICleanupInventory(candidates: candidates.sorted { $0.id < $1.id },
                                  issues: context.issues.sorted(), scannedAt: now)
    }

    /// No native transcript format currently has an independently disposable proof.
    /// A caller changing the candidate's state/metadata cannot enable a raw-file
    /// delete that leaves Codex/Cursor/Claude/Kimi indexes or related state behind.
    public static func validateConversation(_ candidate: AICleanupCandidate, home: String) -> Bool {
        false
    }

    private static func codex(_ root: String, archived: Bool, context: AIInventoryMetadata, group: inout Group) {
        if archived {
            for file in context.children(root) where rolloutID(file.lastComponent) != nil {
                group.add(file, session: rolloutID(file.lastComponent)!, context: context)
            }
        } else {
            for year in context.children(root) where digits(year.lastComponent, count: 4) && context.isDirectory(year) {
                for month in context.children(year) where digits(month.lastComponent, count: 2) && context.isDirectory(month) {
                    for day in context.children(month) where digits(day.lastComponent, count: 2) && context.isDirectory(day) {
                        for file in context.children(day) {
                            if let id = rolloutID(file.lastComponent) { group.add(file, session: id, context: context) }
                        }
                    }
                }
            }
        }
    }

    private static func rolloutID(_ name: String) -> String? {
        let suffix = name.hasSuffix(".jsonl.zst") ? 10 : name.hasSuffix(".jsonl") ? 6 : 0
        guard suffix > 0 else { return nil }
        let stem = String(name.dropLast(suffix))
        guard stem.hasPrefix("rollout-"), stem.count >= 44, stem.suffix(37).first == "-" else { return nil }
        let id = String(stem.suffix(36))
        return uuid(id) ? id : nil
    }

    private static func transcriptID(_ name: String, extensions: [String]) -> String? {
        for ext in extensions where name.hasSuffix("." + ext) {
            let stem = String(name.dropLast(ext.count + 1))
            if uuid(stem) { return stem }
        }
        return nil
    }

    private static func uuid(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    private static func digits(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func safeToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private struct Group {
        let tool: AITool
        let root: String
        let format: String
        var sessions: [String: [AIResource]] = [:]

        mutating func add(_ path: String, session: String, context: AIInventoryMetadata) {
            guard let resource = context.resource(path) else { return }
            sessions[session, default: []].append(resource)
        }

        func candidates() -> [AICleanupCandidate] {
            sessions.keys.sorted().compactMap { session in
                guard let resources = sessions[session], let first = resources.first else { return nil }
                let latest = resources.map(\.modifiedAt).filter { $0 != .distantPast }.max()
                return AICleanupCandidate(
                    id: tool.rawValue + ":conversation:" + root + ":" + session,
                    tool: tool, kind: .conversation,
                    title: tool.name + " · " + URL(fileURLWithPath: session).lastPathComponent,
                    resources: resources, state: .reviewOnly, reason: "indexed_conversations",
                    lastActivity: latest,
                    metadata: ["producer": "conversation_inventory_v1", "format": format,
                               "sessionCount": "1", "fileCount": String(resources.count), "storeRoot": root,
                               "activityEvidence": "file_mtime", "sizeBasis": "allocated_not_exclusive"],
                    contextPath: first.path
                )
            }
        }
    }
}

struct AIInventoryScanLimits {
    var maxEntries = 12_000
    var maxFiles = 12_000
    var maxSeconds: TimeInterval = 4
}

/// Streams directory names with global entry/file/time/cancellation budgets.
/// No file content, JSON, compressed transcript, or SQLite database is opened.
final class AIInventoryMetadata {
    let home: String
    let validHome: Bool
    var issues = Set<String>()
    private let limits: AIInventoryScanLimits
    private let isCancelled: @Sendable () -> Bool
    private let started = ContinuousClock.now
    private var entries = 0
    private var files = 0

    init(home: String, limits: AIInventoryScanLimits, isCancelled: @escaping @Sendable () -> Bool) {
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path
        self.limits = limits
        self.isCancelled = isCancelled
        let syntax = home.hasPrefix("/") && !home.utf8.contains(0) && !home.split(separator: "/").contains("..")
        if syntax, let fd = Self.directoryFD(home) { close(fd); validHome = true }
        else { validHome = false }
    }

    func path(_ relative: String) -> String { home + "/" + relative }

    func stopped() -> Bool {
        if isCancelled() { issues.insert("conversation_scan_cancelled"); return true }
        if entries >= limits.maxEntries || files >= limits.maxFiles
            || started.duration(to: .now) >= .seconds(max(0, limits.maxSeconds)) {
            issues.insert("conversation_scan_partial")
            return true
        }
        return false
    }

    func isDirectory(_ path: String) -> Bool {
        guard let fd = Self.directoryFD(path) else {
            if errno == EACCES || errno == EPERM { issues.insert("conversation_scan_inaccessible") }
            return false
        }
        close(fd)
        return true
    }

    func children(_ path: String) -> [String] {
        guard !stopped() else { return [] }
        guard let snapshot = try? UninstallFileBoundary.snapshot(path) else {
            var info = stat()
            if lstat(path, &info) != 0, errno != ENOENT { issues.insert("conversation_scan_inaccessible") }
            return []
        }
        guard snapshot.item.kind == mode_t(S_IFDIR) else { return [] }
        guard let fd = Self.directoryFD(path) else { issues.insert("conversation_scan_inaccessible"); return [] }
        var info = stat()
        guard fstat(fd, &info) == 0, UninstallFileBoundary.Identity(info) == snapshot.item,
              let stream = fdopendir(fd) else {
            close(fd)
            issues.insert("conversation_scan_inaccessible")
            return []
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while !stopped(), let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            entries += 1
            result.append(path + "/" + name)
            errno = 0
        }
        if errno != 0 { issues.insert("conversation_scan_inaccessible") }
        guard UninstallFileBoundary.stillMatches(snapshot) else {
            issues.insert("conversation_scan_inaccessible")
            return []
        }
        return result.sorted()
    }

    func resource(_ path: String) -> AIResource? {
        guard !stopped() else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let fd = Self.directoryFD(url.deletingLastPathComponent().path) else {
            if errno == EACCES || errno == EPERM { issues.insert("conversation_scan_inaccessible") }
            return nil
        }
        defer { close(fd) }
        var info = stat()
        var parent = stat()
        guard fstat(fd, &parent) == 0, fstatat(fd, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_blocks >= 0 else { return nil }
        let allocation = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
        guard !allocation.overflow,
              let resource = try? AIResource.capture(path: path, bytes: allocation.partialValue),
              resource.boundary.item == UninstallFileBoundary.Identity(info),
              resource.boundary.parent == UninstallFileBoundary.Identity(parent) else { return nil }
        files += 1
        return resource
    }

    static func canonicalPath(_ path: String) -> String {
        let value = URL(fileURLWithPath: path).standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where value == alias || value.hasPrefix(alias + "/") {
            return "/private" + value
        }
        return value
    }

    private static func directoryFD(_ path: String) -> Int32? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), !path.split(separator: "/").contains("..") else { return nil }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for component in canonicalPath(path).split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }
}

private extension String {
    var lastComponent: String { (self as NSString).lastPathComponent }
}
