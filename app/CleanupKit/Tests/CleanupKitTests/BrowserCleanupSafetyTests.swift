import Foundation
import XCTest
@testable import CleanupKit

final class BrowserCleanupSafetyTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: String { root.appendingPathComponent("Home").path }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("MacDefier-browser-safety-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, root.lastPathComponent.hasPrefix("MacDefier-browser-safety-") {
            try? fm.removeItem(at: root)
        }
    }

    private func file(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: home).appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url.path
    }

    private func selectedItem(_ path: String, extras: [String] = [], category: CleanupCategory = .browsers) -> CleanableItem {
        var item = CleanableItem(name: "Browser fixture", path: path, bytes: 7,
                                 category: category, isSelected: false, risk: .rebuild, extraPaths: extras)
        item.isSelected = true
        return item
    }

    private func probe(process: BrowserCleanupActivity = .idle, files: BrowserCleanupActivity = .idle) -> BrowserCleanupGuard {
        BrowserCleanupGuard(processState: { _ in process }, openFileState: { _ in files })
    }

    func testCatalogNeverOffersScriptCache() throws {
        _ = try file("Library/Application Support/Google/Chrome/Default/Service Worker/ScriptCache/entry")
        let specs = BrowserCleanupCatalog.specs(home: home, fm: fm)
        XCTAssertFalse(specs.flatMap(\.paths).contains { $0.contains("/ScriptCache") })
        XCTAssertTrue(specs.flatMap(\.paths).contains { $0.hasSuffix("/Service Worker/CacheStorage") })
    }

    func testScriptCacheCannotBeReintroducedByStalePreview() throws {
        let path = try file("Library/Application Support/Google/Chrome/Default/Service Worker/ScriptCache/entry")
        XCTAssertNotNil(probe().blockingReason(for: path, home: home))
    }

    func testBundleAndExecutableIdentityCoverRenamedAppsAndDetachedHelpers() {
        XCTAssertTrue(BrowserCleanupGuard.isBrowserProcess(
            BrowserProcessIdentity(bundleIdentifier: "com.google.Chrome", executablePath: "/Applications/Renamed.app/Contents/MacOS/renamed"), brand: .chrome))
        XCTAssertTrue(BrowserCleanupGuard.isBrowserProcess(
            BrowserProcessIdentity(bundleIdentifier: nil, executablePath: "/Applications/Renamed.app/Contents/MacOS/Google Chrome Helper (Renderer)"), brand: .chrome))
        XCTAssertTrue(BrowserCleanupGuard.isBrowserProcess(
            BrowserProcessIdentity(bundleIdentifier: nil, executablePath: "/Applications/Microsoft Edge.app/Contents/Frameworks/runtime/crashpad_handler"), brand: .edge))
        XCTAssertFalse(BrowserCleanupGuard.isBrowserProcess(
            BrowserProcessIdentity(bundleIdentifier: "com.example.chrome", executablePath: "/Applications/Chrome Tools.app/Contents/MacOS/Google Chrome Tools"), brand: .chrome))
        XCTAssertFalse(BrowserCleanupGuard.isBrowserProcess(
            BrowserProcessIdentity(bundleIdentifier: nil, executablePath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"), brand: .chrome))
    }

    func testRunningAndUnknownOwnerStatesFailClosed() throws {
        let path = try file("Library/Application Support/Google/Chrome/Default/History")
        for state in [BrowserCleanupActivity.inUse, .unknown] {
            let guardProbe = BrowserCleanupGuard(processState: { _ in state }, openFileState: { _ in
                XCTFail("Owner refusal must not inspect open files")
                return .idle
            })
            XCTAssertNotNil(guardProbe.blockingReason(for: path, home: home))
        }
        XCTAssertNil(probe().blockingReason(for: path, home: home))
    }

    func testOpenAndUnknownFileStatesFailClosed() throws {
        let path = try file("Library/Safari/History.db")
        XCTAssertNotNil(probe(files: .inUse).blockingReason(for: path, home: home))
        XCTAssertNotNil(probe(files: .unknown).blockingReason(for: path, home: home))
    }

    func testBrowserStartingDuringHandleProbeCannotBorrowEarlierIdleState() throws {
        let path = try file("Library/Safari/History.db")
        let state = LockedBrowserState()
        let guardProbe = BrowserCleanupGuard(processState: { _ in state.read() }, openFileState: { _ in
            state.set(.inUse)
            return .idle
        })
        XCTAssertNotNil(guardProbe.blockingReason(for: path, home: home))
        XCTAssertTrue(fm.fileExists(atPath: path))
    }

    func testSQLiteMainAndSidecarsShareOneProbeSelection() throws {
        let base = try file("Library/Safari/History.db")
        _ = try file("Library/Safari/History.db-wal")
        _ = try file("Library/Safari/History.db-shm")
        XCTAssertEqual(Set(BrowserCleanupGuard.sqliteFamily(for: base + "-wal")),
                       Set([base, base + "-wal", base + "-shm"]))
    }

    func testRealReadOnlyHandleProbeDetectsAnOpenWALFixture() throws {
        let base = try file("Library/Safari/History.db")
        let wal = try file("Library/Safari/History.db-wal")
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: wal))
        defer { try? handle.close() }
        XCTAssertEqual(BrowserCleanupGuard.live.openFileState(base), .inUse)
        let guardProbe = BrowserCleanupGuard(processState: { _ in .idle }, openFileState: BrowserCleanupGuard.live.openFileState)
        XCTAssertNotNil(guardProbe.blockingReason(for: base, home: home))
        withExtendedLifetime(handle) {}
    }

    func testBrowserStartingAfterPreviewIsBlockedAtActualExecutor() async throws {
        let path = try file("Library/Application Support/Google/Chrome/Default/History")
        let state = LockedBrowserState()
        let guardProbe = BrowserCleanupGuard(processState: { _ in state.read() }, openFileState: { _ in .idle })
        XCTAssertNil(guardProbe.blockingReason(for: path, home: home))
        state.set(.inUse)
        let executor = TrashExecutor(home: home, browserCleanupGuard: guardProbe, recycle: { _ in
            XCTFail("A stale idle preview must not reach the Trash side effect")
        })
        let result = await executor.trash(items: [selectedItem(path)], onProgress: { _ in })
        XCTAssertEqual(result.failedPaths, [path])
        XCTAssertTrue(result.succeededPaths.isEmpty)
        XCTAssertEqual(result.movedToTrashBytes, 0)
        XCTAssertTrue(fm.fileExists(atPath: path))
    }

    func testExecutorRechecksEveryPathInMultiPathRows() async throws {
        let first = try file("Library/Application Support/Google/Chrome/Default/Cache/first")
        let second = try file("Library/Application Support/Google/Chrome/Default/Code Cache/second")
        let state = LockedBrowserState()
        let guardProbe = BrowserCleanupGuard(processState: { _ in state.read() }, openFileState: { _ in .idle })
        let destination = root.appendingPathComponent("recycled-first")
        let executor = TrashExecutor(home: home, browserCleanupGuard: guardProbe, recycle: { url in
            try FileManager.default.moveItem(at: url, to: destination)
            state.set(.inUse)
        })
        let result = await executor.trash(items: [selectedItem(first, extras: [second])], onProgress: { _ in })
        XCTAssertEqual(result.succeededPaths, [first])
        XCTAssertEqual(result.failedPaths, [second])
        XCTAssertTrue(fm.fileExists(atPath: second))
        XCTAssertTrue(fm.fileExists(atPath: destination.path))
    }

    func testGenericCacheParentCannotBypassBrowserGuard() async throws {
        _ = try file("Library/Caches/Google/Chrome/cache-entry")
        let parent = home + "/Library/Caches/Google"
        XCTAssertEqual(BrowserCleanupGuard.affectedBrowsers(path: parent, home: home), [.chrome])
        let executor = TrashExecutor(home: home, browserCleanupGuard: probe(process: .inUse), recycle: { _ in
            XCTFail("Generic cache categories must preserve a running browser too")
        })
        let result = await executor.trash(items: [selectedItem(parent, category: .userCache)], onProgress: { _ in })
        XCTAssertEqual(result.failedPaths, [parent])
        XCTAssertTrue(fm.fileExists(atPath: parent))
    }

    func testIdleBrowserStillMovesOnlyItsSelectedFixture() async throws {
        let path = try file("Library/Application Support/Microsoft Edge/Default/Cache/entry")
        let sibling = try file("Library/Application Support/Microsoft Edge/Default/Cache/kept")
        let destination = root.appendingPathComponent("recycled-idle")
        let executor = TrashExecutor(home: home, browserCleanupGuard: probe(), recycle: { url in
            try FileManager.default.moveItem(at: url, to: destination)
        })
        let result = await executor.trash(items: [selectedItem(path)], onProgress: { _ in })
        XCTAssertEqual(result.succeededPaths, [path])
        XCTAssertTrue(result.failedPaths.isEmpty)
        XCTAssertEqual(result.movedToTrashBytes, 7)
        XCTAssertTrue(fm.fileExists(atPath: sibling))
        XCTAssertFalse(fm.fileExists(atPath: path))
    }
}

private final class LockedBrowserState: @unchecked Sendable {
    private let lock = NSLock()
    private var state: BrowserCleanupActivity = .idle
    func read() -> BrowserCleanupActivity {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
    func set(_ value: BrowserCleanupActivity) {
        lock.lock()
        defer { lock.unlock() }
        state = value
    }
}
