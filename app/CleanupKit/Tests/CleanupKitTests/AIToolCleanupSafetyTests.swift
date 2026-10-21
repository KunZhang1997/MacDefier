import Darwin
import XCTest
@testable import CleanupKit

final class AIToolCleanupSafetyTests: XCTestCase {
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home").path }
    private var trash: String { root.appendingPathComponent("FixtureTrash").path }
    private let idle = AIToolCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .idle })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AIToolSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ relative: String, contents: String = "fixture", executable: Bool = false) throws -> String {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        return path
    }
    private func scan(_ guardProbe: AIToolCleanupGuard? = nil) -> AICleanupInventory {
        AIToolCleanupScanner.scan(home: home, cliInventory: [], cleanupGuard: guardProbe ?? idle)
    }
    private func cacheCandidate() throws -> AICleanupCandidate {
        try write("Library/Caches/Codex/Default/Cache/item")
        return try XCTUnwrap(scan().candidates.first { $0.kind == .cache })
    }
    private func execution(_ probe: AIToolCleanupGuard? = nil) -> AIToolCleanupExecutor.Execution {
        let destination = trash
        return AIToolCleanupExecutor.Execution(cleanupGuard: probe ?? idle,
            recycle: { try UninstallFileBoundary.move($0.boundary, toTrashDirectory: destination) })
    }

    func testCodexOnlySixFixedCacheLeavesAreCandidates() throws {
        for profile in ["Default", "Default/Partitions/codex-browser-app", "codex-browser-app"] {
            for leaf in ["Cache", "Code Cache"] { try write("Library/Caches/Codex/\(profile)/\(leaf)/item") }
        }
        try write("Library/Caches/Codex/Default/Local Storage/keep")
        try write(".codex/auth.json")
        try write("Library/Application Support/Codex/IndexedDB/keep")
        let rows = scan().candidates
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .cache && $0.state == .ready })
        XCTAssertFalse(rows.contains { $0.path.contains("Local Storage") || $0.path.contains("Application Support") || $0.path.contains("auth") })
    }

    func testDataSectionScansPartitionTheOriginalInventory() throws {
        try write("Library/Application Support/Cursor/Cache/item")
        try write(".cache/kimi/item")
        let original = scan().candidates
        let app = AIToolCleanupScanner.scan(home: home, cliInventory: [], section: .appData, cleanupGuard: idle).candidates
        let cli = AIToolCleanupScanner.scan(home: home, cliInventory: [], section: .cliData, cleanupGuard: idle).candidates
        XCTAssertFalse(app.isEmpty); XCTAssertFalse(cli.isEmpty)
        XCTAssertTrue(Set(app.map(\.id)).isDisjoint(with: Set(cli.map(\.id))))
        XCTAssertEqual(Set((app + cli).map(\.id)), Set(original.map(\.id)))
        XCTAssertTrue(app.allSatisfy { $0.dataSection == .appData })
        XCTAssertTrue(cli.allSatisfy { $0.dataSection == .cliData })
    }

    func testRunningAndUnknownAreNotSelectable() throws {
        _ = try cacheCandidate()
        for state in [AIToolCleanupActivity.inUse, .unknown] {
            let probe = AIToolCleanupGuard(processState: { _ in state }, openFileState: { _ in .idle })
            let row = try XCTUnwrap(scan(probe).candidates.first)
            XCTAssertFalse(row.canSelect)
            XCTAssertEqual(row.state, state == .inUse ? .inUse : .unknown)
        }
    }

    func testSymlinkCacheAndAncestorCannotGrantPermission() throws {
        let outside = try write("Outside/keep")
        let cache = home + "/Library/Caches/Codex/Default/Cache"
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: cache).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: cache, withDestinationPath: URL(fileURLWithPath: outside).deletingLastPathComponent().path)
        XCTAssertTrue(scan().candidates.isEmpty)
        XCTAssertEqual(idle.blockingReason(for: cache, home: home), "dedicated_preview_required")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
    }

    func testGenericParentDurableAndVersionPathsRequireDedicatedPreview() throws {
        let cache = try cacheCandidate()
        XCTAssertNil(idle.blockingReason(for: cache.path, home: home))
        XCTAssertEqual(idle.blockingReason(for: home + "/Library/Caches", home: home), "dedicated_preview_required")
        for relative in [".codex", ".claude", ".kimi-code", ".ollama/models", ".gemini/tmp", ".local/share/claude/versions", "Library/WebKit/com.electron.ollama", "Library/Caches/com.anthropic.claude"] {
            XCTAssertEqual(idle.blockingReason(for: home + "/" + relative, home: home), "dedicated_preview_required")
        }
    }

    private func installVersions(active: String?) throws {
        for version in ["1.0.0", "2.0.0", "3.0.0", "4.0.0"] {
            try write(".local/share/claude/versions/\(version)", executable: true)
        }
        if let active {
            try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/claude", withDestinationPath: home + "/.local/share/claude/versions/" + active)
        }
    }

    func testCurrentRollbackAndNewerVersionAreRetained() throws {
        try installVersions(active: "3.0.0")
        let rows = scan().candidates.filter { $0.kind == .oldVersion }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first { $0.path.hasSuffix("1.0.0") }?.state, .ready)
        XCTAssertEqual(rows.first { $0.path.hasSuffix("2.0.0") }?.reason, "rollback_kept")
        XCTAssertEqual(rows.first { $0.path.hasSuffix("3.0.0") }?.reason, "active_version_kept")
        XCTAssertEqual(rows.first { $0.path.hasSuffix("4.0.0") }?.reason, "newer_version_retained")
    }

    func testUnknownActiveVersionRetainsEveryVersion() throws {
        try installVersions(active: nil)
        let rows = scan().candidates.filter { $0.kind == .oldVersion }
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.state == .retained && $0.reason == "active_version_unknown" })
    }

    func testActiveVersionSwitchAfterPreviewBlocksOldCandidate() async throws {
        try installVersions(active: "3.0.0")
        let row = try XCTUnwrap(scan().candidates.first { $0.kind == .oldVersion && $0.state == .ready })
        try FileManager.default.removeItem(atPath: home + "/.local/bin/claude")
        try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/claude", withDestinationPath: row.path)
        let result = await AIToolCleanupExecutor.execute(candidates: [row], home: home, execution: execution())
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.path))
    }

    func testChangedCacheContentsAndReplacementAreRejected() async throws {
        let row = try cacheCandidate()
        try write("Library/Caches/Codex/Default/Cache/item", contents: "changed content")
        var result = await AIToolCleanupExecutor.execute(candidates: [row], home: home, execution: execution())
        XCTAssertEqual(result.cleanedCount, 0)
        try FileManager.default.removeItem(atPath: row.path)
        try write("Library/Caches/Codex/Default/Cache/new")
        result = await AIToolCleanupExecutor.execute(candidates: [row], home: home, execution: execution())
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.path))
    }

    func testForgedCacheCallerCannotDeleteDurableData() async throws {
        let row = try cacheCandidate()
        let auth = try write(".codex/auth.json")
        let resource = try AIResource.capture(path: auth, bytes: 1)
        let forged = AICleanupCandidate(tool: .codex, kind: .cache, title: "safe cache", resources: [resource],
            state: .ready, reason: "cache", metadata: row.metadata)
        let result = await AIToolCleanupExecutor.execute(candidates: [forged], home: home, execution: execution())
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: auth))
    }

    func testToolStartedAndHandleProbeUnknownAfterPreviewBlockExecution() async throws {
        let row = try cacheCandidate()
        let probes = [
            AIToolCleanupGuard(processState: { _ in .inUse }, openFileState: { _ in .idle }),
            AIToolCleanupGuard(processState: { _ in .unknown }, openFileState: { _ in .idle }),
            AIToolCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .inUse }),
            AIToolCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .unknown })
        ]
        for probe in probes {
            let result = await AIToolCleanupExecutor.execute(candidates: [row], home: home, execution: execution(probe))
            XCTAssertEqual(result.cleanedCount, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: row.path))
        }
    }

    func testValidCacheMovesOnlyToFixtureTrash() async throws {
        let row = try cacheCandidate()
        let result = await AIToolCleanupExecutor.execute(candidates: [row], home: home, execution: execution())
        XCTAssertEqual(result.cleanedCount, 1)
        XCTAssertEqual(result.succeededPaths, [row.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: row.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash + "/Cache/item"))
    }

    private func modelFixture() throws -> AICleanupCandidate {
        let blob = try write(".ollama/models/blobs/sha256-fixture")
        let manifest = try write(".ollama/models/manifests/fixture")
        return AICleanupCandidate(tool: .ollama, kind: .model, title: "fixture",
            resources: [try AIResource.capture(path: blob, bytes: 7), try AIResource.capture(path: manifest, bytes: 7)],
            state: .ready, reason: "model")
    }

    func testModelHalfFailureRestoresAlreadyMovedBlob() async throws {
        let row = try modelFixture()
        var config = execution()
        config.modelProof = { _, _, excluding in excluding.isEmpty }
        let result = await AIToolCleanupExecutor.execute(candidates: [row], home: home, execution: config)
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertEqual(result.movedToTrashBytes, 0)
        XCTAssertTrue(result.succeededPaths.isEmpty)
        XCTAssertTrue(row.resources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash).isEmpty)
    }

    func testModelRollbackNeverOverwritesRecreatedSource() async throws {
        let row = try modelFixture()
        let blob = row.resources[0].path, destination = trash
        var config = execution()
        config.modelProof = { _, _, _ in true }
        config.recycle = { resource in
            let moved = try UninstallFileBoundary.move(resource.boundary, toTrashDirectory: destination)
            if resource.path == blob { try Data("replacement".utf8).write(to: URL(fileURLWithPath: blob)) }
            return moved
        }
        let result = await AIToolCleanupExecutor.execute(candidates: [row], home: home, execution: config)
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertTrue(result.errors.contains { $0.hasPrefix("rollback_failed:") })
        XCTAssertEqual(try String(contentsOfFile: blob), "replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination + "/sha256-fixture"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.resources[1].path))
    }

    func testProcessMatchingUsesBundleExecutableAndHelperScriptIdentity() {
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .codex, bundleID: "com.openai.codex", command: "localized-name"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .codex, command: "node /opt/npm/@openai/codex/bin/codex.js"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .cursor, command: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"))
        XCTAssertFalse(AIToolCleanupGuard.matches(tool: .codex, command: "/usr/bin/notcodex --flag"))
        XCTAssertTrue(AIToolCleanupGuard.matches(tool: .gemini, command: "node /opt/npm/@google/gemini-cli/dist/index.js"))
    }

    private func realModelGraph(twoModels: Bool) throws -> (home: String, shared: [String]) {
        let config = "sha256:" + String(repeating: "0", count: 64)
        let shared = "sha256:" + String(repeating: "a", count: 64)
        let a = "sha256:" + String(repeating: "b", count: 64)
        let b = "sha256:" + String(repeating: "c", count: 64)
        for digest in [config, shared, a, b] {
            try write(".ollama/models/blobs/" + digest.replacingOccurrences(of: ":", with: "-"), contents: String(repeating: "x", count: 1024))
        }
        func descriptor(_ digest: String) -> [String: Any] {
            ["digest": digest, "size": 1024, "mediaType": "application/vnd.ollama.image.model"]
        }
        for (name, layer) in twoModels ? [("alpha", a), ("beta", b)] : [("alpha", a)] {
            let object: [String: Any] = ["schemaVersion": 2, "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
                "config": descriptor(config), "layers": [descriptor(shared), descriptor(layer)]]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try write(".ollama/models/manifests/registry.ollama.ai/library/\(name)/latest", contents: String(decoding: data, as: UTF8.self))
        }
        let physicalHome = AIToolCleanupScanner.physicalPath(home)
        return (physicalHome, [config, shared].map { physicalHome + "/.ollama/models/blobs/" + $0.replacingOccurrences(of: ":", with: "-") })
    }

    func testRealModelGraphBatchCompletesAndPreservesOriginallySharedBlobs() async throws {
        let fixture = try realModelGraph(twoModels: true)
        let rows = AIOllamaInventory.scan(home: fixture.home).candidates
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.canSelect))
        let result = await AIToolCleanupExecutor.execute(candidates: rows, home: fixture.home, execution: execution())
        XCTAssertEqual(result.cleanedCount, 2, result.errors.joined(separator: ","))
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(rows.flatMap(\.resources).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(fixture.shared.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    func testRealModelManifestMoveFailureRollsBackCompleteBlobSet() async throws {
        let fixture = try realModelGraph(twoModels: false)
        let row = try XCTUnwrap(AIOllamaInventory.scan(home: fixture.home).candidates.first)
        let destination = trash, manifest = row.path
        var config = execution()
        config.recycle = { resource in
            if resource.path == manifest { throw AIResourceError.invalidPath }
            return try UninstallFileBoundary.move(resource.boundary, toTrashDirectory: destination)
        }
        let result = await AIToolCleanupExecutor.execute(candidates: [row], home: fixture.home, execution: config)
        XCTAssertEqual(result.cleanedCount, 0)
        XCTAssertEqual(result.movedToTrashBytes, 0)
        XCTAssertFalse(result.errors.contains { $0.hasPrefix("rollback_failed") })
        XCTAssertTrue(row.resources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash).isEmpty)
        XCTAssertTrue(AIOllamaInventory.scan(home: fixture.home).candidates.allSatisfy(\.canSelect))
    }

    func testConcurrentResourceLeaseBlocksExecution() async throws {
        let row = try cacheCandidate()
        let acquired = await ResourceMutationCoordinator.shared.acquire(paths: [row.path])
        let lease = try XCTUnwrap(acquired)
        let result = await AIToolCleanupExecutor.execute(candidates: [row], home: home, execution: execution())
        await ResourceMutationCoordinator.shared.release(lease)
        XCTAssertEqual(result.errors, ["mutation_busy"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.path))
    }

    func testExplicitRemovalProtectsSharedDesktopOwnerAndUnknownState() throws {
        try write(".codex/sessions/session.jsonl")
        let source = try UninstallFileBoundary.snapshot(home + "/.codex")
        XCTAssertNil(idle.blockingReasonForExplicitRemoval(source, home: home))
        for state in [AIToolCleanupActivity.inUse, .unknown] {
            let probe = AIToolCleanupGuard(processState: { _ in state }, openFileState: { _ in .idle })
            XCTAssertEqual(probe.blockingReasonForExplicitRemoval(source, home: home),
                           state == .inUse ? "in_use" : "probe_unknown")
        }
        let handles = AIToolCleanupGuard(processState: { _ in .idle }, openFileState: { _ in .unknown })
        XCTAssertEqual(handles.blockingReasonForExplicitRemoval(source, home: home), "handle_probe_unknown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testExplicitRemovalRejectsSwappedSourceAndSymlink() throws {
        try write(".codex/keep")
        let source = try UninstallFileBoundary.snapshot(home + "/.codex")
        try FileManager.default.moveItem(atPath: source.path, toPath: home + "/HeldCodex")
        try write(".codex/replacement")
        XCTAssertEqual(idle.blockingReasonForExplicitRemoval(source, home: home), "changed")
        try FileManager.default.removeItem(atPath: home + "/.codex")
        try FileManager.default.createSymbolicLink(atPath: home + "/.codex", withDestinationPath: home + "/HeldCodex")
        let link = try UninstallFileBoundary.snapshot(home + "/.codex")
        XCTAssertEqual(idle.blockingReasonForExplicitRemoval(link, home: home), "changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/HeldCodex/keep"))
    }

    func testExplicitRemovalLeavesUnrelatedUninstallPathsToTheirOwnGate() throws {
        let file = try write("Downloads/ordinary.txt")
        let source = try UninstallFileBoundary.snapshot(file)
        let unknown = AIToolCleanupGuard(processState: { _ in .unknown }, openFileState: { _ in .unknown })
        XCTAssertNil(unknown.blockingReasonForExplicitRemoval(source, home: home))
    }
}
