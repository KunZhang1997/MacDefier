import Darwin
import Foundation
import XCTest
@testable import CleanupKit

final class AIConversationInventoryTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home").path }
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"
    private let c = "33333333-3333-4333-8333-333333333333"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("AIConversationFixture-\(UUID().uuidString)")
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult
    private func write(_ relative: String, text: String = "PRIVATE_PROMPT_MUST_NOT_APPEAR", date: Date? = nil) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: path) }
        return path
    }

    private func conversations() -> [AICleanupCandidate] {
        AIConversationInventory.scan(home: home, now: now).candidates.filter { $0.kind == .conversation }
    }

    func testCodexKeepsPerSessionActivityAndCompressedArchivesWithoutReadingContents() throws {
        let old = now.addingTimeInterval(-200 * 86_400)
        let recent = now.addingTimeInterval(-2 * 86_400)
        let first = try write(".codex/sessions/2026/01/01/rollout-2026-01-01T01-02-03-\(a).jsonl", date: old)
        let second = try write(".codex/sessions/2026/01/01/rollout-2026-01-01T03-02-01-\(b).jsonl", date: recent)
        let archive = try write(".codex/archived_sessions/rollout-2026-01-01T03-02-01-\(c).jsonl.zst", text: "not-valid-JSON-or-Zstandard", date: old)
        _ = try write(".codex/session_index.jsonl")
        _ = try write(".codex/state_5.sqlite")
        let rows = conversations()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.flatMap(\.resources).map(\.path)), Set([first, second, archive]))
        XCTAssertEqual(rows.filter { ($0.lastActivity ?? now) < now.addingTimeInterval(-90 * 86_400) }.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.state == .reviewOnly && !$0.canSelect && $0.reason == "indexed_conversations" })
        XCTAssertTrue(rows.allSatisfy { $0.metadata["activityEvidence"] == "file_mtime" })
        XCTAssertFalse(String(describing: rows.map { [$0.title, $0.reason, String(describing: $0.metadata)] }).contains("PRIVATE_PROMPT"))
    }

    func testCursorCoalescesMigrationCopiesAndSubagentsWithinOneSession() throws {
        let base = ".cursor/projects/Workspace/agent-transcripts/"
        let old = now.addingTimeInterval(-120 * 86_400)
        let recent = now.addingTimeInterval(-10 * 86_400)
        _ = try write(base + a + ".txt", date: old)
        _ = try write(base + a + "/" + a + ".jsonl", date: old)
        _ = try write(base + a + "/subagents/" + b + ".jsonl", date: recent)
        _ = try write(base + c + ".jsonl", date: old)
        _ = try write(base + a + "/state.vscdb")
        _ = try write(".cursor/projects/.hidden-archive/agent-transcripts/" + b + ".txt")
        let rows = conversations()
        XCTAssertEqual(rows.count, 2)
        let row = try XCTUnwrap(rows.first { $0.resources.count == 3 })
        XCTAssertEqual(row.lastActivity?.timeIntervalSince1970, recent.timeIntervalSince1970)
        XCTAssertEqual(row.metadata["fileCount"], "3")
        XCTAssertEqual(row.metadata["sessionCount"], "1")
        XCTAssertEqual(row.metadata["format"], "cursor_saved_transcript")
        XCTAssertFalse(row.canSelect, "A plain text extension alone does not prove an independently disposable export")
    }

    func testClaudeIncludesOnlySessionJSONLAndKnownSubagents() throws {
        let base = ".claude/projects/-Users-fixture-project/"
        let main = try write(base + a + ".jsonl")
        let child = try write(base + a + "/subagents/agent-a7b8c9.jsonl")
        _ = try write(base + "sessions-index.json")
        _ = try write(base + "memory/MEMORY.md")
        _ = try write(base + a + "/tool-results/result.json")
        _ = try write(base + a + "/subagents/agent-a7b8c9.meta.json")
        _ = try write(".claude/settings.json")
        let rows = conversations()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(Set(rows[0].resources.map(\.path)), Set([main, child]))
        XCTAssertEqual(rows[0].tool, .claude)
    }

    func testKimiSupportsInstalledAndLegacyPreciseSessionLeavesOnly() throws {
        let native = ".kimi-code/sessions/wd_fixture_0123456789ab/session_" + a
        let legacy = ".kimi/sessions/0123456789abcdef0123456789abcdef/" + b
        let wire = try write(native + "/agents/main/wire.jsonl")
        let context = try write(legacy + "/context.jsonl")
        let oldWire = try write(legacy + "/wire.jsonl")
        _ = try write(native + "/state.json")
        _ = try write(native + "/logs/kimi-code.log")
        _ = try write(".kimi-code/session_index.jsonl")
        _ = try write(".kimi-code/search-index/db.wal")
        _ = try write(".kimi-code/credentials/kimi-code.json")
        let rows = conversations()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.flatMap(\.resources).map(\.path)), Set([wire, context, oldWire]))
        XCTAssertTrue(rows.allSatisfy { $0.tool == .kimi && !$0.canSelect })
    }

    func testSymlinksAndUnrecognizedFilesAreNeverIncluded() throws {
        let target = try write("outside/" + a + ".jsonl")
        let folder = home + "/.cursor/projects/P/agent-transcripts"
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: folder + "/" + a + ".jsonl", withDestinationPath: target)
        try fm.createSymbolicLink(atPath: folder + "/" + b, withDestinationPath: home + "/outside")
        _ = try write(".codex/sessions/2026/01/01/history.jsonl")
        _ = try write(".codex/sessions/2026/01/01/rollout-not-a-session.jsonl")
        _ = try write(".cursor/projects/P/agent-transcripts/notes.txt")
        XCTAssertTrue(conversations().isEmpty)
        let external = root.appendingPathComponent("External").path
        try fm.createDirectory(atPath: external + "/projects/P/agent-transcripts", withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: URL(fileURLWithPath: external + "/projects/P/agent-transcripts/" + c + ".jsonl"))
        try fm.removeItem(atPath: home + "/.cursor")
        try fm.createSymbolicLink(atPath: home + "/.cursor", withDestinationPath: external)
        XCTAssertTrue(conversations().isEmpty)
    }

    func testHardlinksDoNotDoubleCountPhysicalTotals() throws {
        let first = try write(".cursor/projects/P/agent-transcripts/" + a + ".txt")
        let second = home + "/.cursor/projects/P/agent-transcripts/" + b + ".txt"
        try fm.linkItem(atPath: first, toPath: second)
        let resources = conversations().flatMap(\.resources)
        XCTAssertEqual(resources.count, 2)
        XCTAssertEqual(AIResourceTotals.unique(resources).count, 1)
        XCTAssertEqual(AIResourceTotals.bytes(resources), resources[0].bytes)
    }

    func testCancelledAndEntryBoundedScansAreExplicitlyPartial() throws {
        for n in 0..<20 { _ = try write(".cursor/projects/P/agent-transcripts/\(n).txt") }
        let cancelled = AIConversationInventory.scan(home: home, now: now, isCancelled: { true })
        XCTAssertTrue(cancelled.candidates.isEmpty)
        XCTAssertTrue(cancelled.issues.contains("conversation_scan_cancelled"))
        let bounded = AIConversationInventory.scan(home: home, now: now,
            limits: AIInventoryScanLimits(maxEntries: 4, maxFiles: 100, maxSeconds: 2), isCancelled: { false })
        XCTAssertTrue(bounded.issues.contains("conversation_scan_partial"))
        let invalidHome = AIConversationInventory.scan(home: home + "/../Home", now: now)
        XCTAssertTrue(invalidHome.candidates.isEmpty)
        XCTAssertTrue(invalidHome.issues.contains("conversation_scan_inaccessible"))
    }

    func testForgedReadyMetadataCannotAuthorizeIndexedConversationDeletion() throws {
        _ = try write(".cursor/projects/P/agent-transcripts/" + a + ".txt")
        var candidate = try XCTUnwrap(conversations().first)
        candidate.state = .ready
        candidate.reason = "standalone_export"
        candidate.metadata = ["producer": "trusted", "safe": "true"]
        XCTAssertFalse(AIConversationInventory.validateConversation(candidate, home: home))
        try Data("new appended messages".utf8).write(to: URL(fileURLWithPath: candidate.resources[0].path))
        XCTAssertFalse(AIConversationInventory.validateConversation(candidate, home: home))
    }

    func testWorktreeStatusIncludesTrackedUntrackedAndIgnoredWithoutModifyingIndex() throws {
        let path = home + "/.codex/worktrees/token/repo"
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git(["init", "-q", path])
        try git(["-C", path, "config", "user.name", "Fixture"])
        try git(["-C", path, "config", "user.email", "fixture@example.invalid"])
        _ = try write(".codex/worktrees/token/repo/tracked.txt", text: "initial")
        _ = try write(".codex/worktrees/token/repo/.gitignore", text: "ignored.txt\n")
        try git(["-C", path, "add", "."])
        try git(["-C", path, "commit", "-qm", "fixture"])
        _ = try write(".codex/worktrees/token/repo/tracked.txt", text: "changed")
        _ = try write(".codex/worktrees/token/repo/untracked.txt")
        _ = try write(".codex/worktrees/token/repo/ignored.txt")
        let before = try Data(contentsOf: URL(fileURLWithPath: path + "/.git/index"))
        let rows = AIWorktreeInventory.scan(home: home, now: now).candidates
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.metadata["trackedChanges"], "1")
        XCTAssertEqual(row.metadata["untrackedFiles"], "1")
        XCTAssertEqual(row.metadata["ignoredFiles"], "1")
        XCTAssertEqual(row.reason, "worktree_has_changes")
        XCTAssertFalse(row.canSelect)
        XCTAssertEqual(before, try Data(contentsOf: URL(fileURLWithPath: path + "/.git/index")))
    }

    func testWorktreeUnknownAndSymlinkStayReadOnly() throws {
        _ = try write(".claude/worktrees/orphan/source.swift")
        let rows = AIWorktreeInventory.scan(home: home, now: now).candidates
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].reason, "worktree_status_unknown")
        XCTAssertEqual(rows[0].metadata["gitStatus"], "unknown")
        XCTAssertFalse(rows[0].canSelect)
        try fm.createSymbolicLink(atPath: home + "/.claude/worktrees/link", withDestinationPath: home + "/.claude/worktrees/orphan")
        XCTAssertEqual(AIWorktreeInventory.scan(home: home, now: now).candidates.count, 1)
    }

    func testUnreadableWorktreeDirectoryDoesNotClaimCompleteSize() throws {
        _ = try write(".claude/worktrees/orphan/restricted/hidden.swift")
        let restricted = home + "/.claude/worktrees/orphan/restricted"
        XCTAssertEqual(chmod(restricted, 0), 0)
        defer { _ = chmod(restricted, 0o700) }
        let report = AIWorktreeInventory.scan(home: home, now: now)
        let row = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(row.metadata["sizeComplete"], "false")
        XCTAssertEqual(row.reason, "worktree_partial")
        XCTAssertTrue(report.issues.contains("worktree_scan_inaccessible"))
    }

    private func git(_ args: [String]) throws {
        let result = try ProcessRunner.runSync(["/usr/bin/git"] + args, environment: ["PATH": "/usr/bin:/bin", "HOME": home,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: 3)
        XCTAssertTrue(result.succeeded, result.stderrString)
    }
}
