import Darwin
import Foundation
import XCTest
@testable import CleanupKit

/// All paths are UUID fixtures. No real Applications, home, shared data or Trash
/// is enumerated, and these tests never invoke an uninstall executor.
final class AppInventorySizeTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var shared: URL { root.appendingPathComponent("shared") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/MacDefier-AppSize-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    private func file(_ path: String, bytes: Int = 8192) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x71, count: bytes).write(to: url)
        return url
    }

    private func app(name: String = "FixtureApp", bundleID: String = "org.example.fixtureapp") throws -> URL {
        let url = root.appendingPathComponent("apps/\(name).app")
        let contents = url.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": bundleID, "CFBundleName": name,
                                    "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    private func environment(nodeLimit: Int = 400_000, now: @escaping () -> TimeInterval = { 0 }) -> AppInventory.SizeEnvironment {
        .init(home: home.path, sharedRoot: shared.path, nodeLimit: nodeLimit, now: now)
    }

    private func measured(_ app: URL, nodeLimit: Int = 400_000) throws -> InstalledApp {
        try XCTUnwrap(AppInventory.loadApp(at: app, sizeEnvironment: environment(nodeLimit: nodeLimit)))
    }

    private func allocated(_ urls: URL...) throws -> UInt64 {
        try urls.reduce(0) { total, url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return total + UInt64(info.st_blocks) * 512
        }
    }

    func testExplicitStatesDistinguishEmptyMeasuredFromPending() throws {
        func model(bytes: UInt64 = 0, related: UInt64 = 0, state: AppSizeState? = nil) -> InstalledApp {
            InstalledApp(name: "Fixture", bundleIdentifier: "org.example.fixture", path: root.path,
                         version: "1", bytes: bytes, relatedBytes: related,
                         isSystemLocation: false, canTrashAppBundle: true, sizeState: state)
        }
        XCTAssertEqual(model().sizeState, .pending)
        XCTAssertEqual(model(bytes: 1).sizeState, .measured)
        XCTAssertEqual(model(related: 1).sizeState, .measured)
        XCTAssertEqual(model(state: .measured).sizeState, .measured)
        XCTAssertEqual(model(state: .unavailable).sizeState, .unavailable)

        // A structurally empty bundle may still be listed and is a measured zero.
        let empty = root.appendingPathComponent("apps/Empty.app")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let result = try measured(empty)
        XCTAssertEqual(result.sizeState, .measured)
        XCTAssertEqual(result.totalBytes, 0)
    }

    func testFastListingIsPendingAndDoesNotStartSizeBudget() throws {
        let url = try app()
        var clockReads = 0
        let result = try XCTUnwrap(AppInventory.loadApp(at: url, computeSize: false,
            sizeEnvironment: environment(now: { clockReads += 1; return 0 })))
        XCTAssertEqual(result.sizeState, .pending)
        XCTAssertEqual(result.totalBytes, 0)
        XCTAssertEqual(clockReads, 0)
    }

    func testPackageAndStrictRelatedDataAreMeasuredTogether() throws {
        let url = try app()
        let payload = try file("apps/FixtureApp.app/Contents/payload")
        let data = try file("home/Library/Application Support/org.example.fixtureapp/store")
        let sibling = try file("apps/FixtureApp Game/game")
        _ = try file("home/Library/Application Support/Unrelated/private", bytes: 65536)
        _ = try file("shared/Google/unrelated", bytes: 65536)

        let result = try measured(url)
        XCTAssertEqual(result.sizeState, .measured)
        XCTAssertEqual(result.bytes, try allocated(url.appendingPathComponent("Contents/Info.plist"), payload))
        XCTAssertEqual(result.relatedBytes, try allocated(data, sibling))
        XCTAssertTrue(result.canTrashAppBundle)
    }

    func testOverlappingRelatedRootsAndHardLinksAreCountedOnce() throws {
        let url = try app(name: "Google", bundleID: "com.google.Chrome")
        let data = try file("home/Library/Application Support/Google/Chrome/profile")
        let other = try file("home/Library/Application Support/Google/metadata")
        let hardLink = home.appendingPathComponent("Library/Application Support/Google/Chrome/profile-copy")
        XCTAssertEqual(link(data.path, hardLink.path), 0)

        // Exact Google root and the existing Chrome channel child both match.
        let result = try measured(url)
        XCTAssertEqual(result.sizeState, .measured)
        XCTAssertEqual(result.relatedBytes, try allocated(data, other))
    }

    func testSymlinksAndSpecialFilesAreNeverFollowed() throws {
        let url = try app()
        let outside = try file("outside/secret", bytes: 131072)
        let packageLink = url.appendingPathComponent("Contents/linked-directory")
        try fm.createSymbolicLink(at: packageLink, withDestinationURL: outside.deletingLastPathComponent())
        try fm.createSymbolicLink(at: url.appendingPathComponent("Contents/linked-file"), withDestinationURL: outside)
        let related = home.appendingPathComponent("Library/Application Support/org.example.fixtureapp")
        try fm.createDirectory(at: related.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: related, withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertEqual(mkfifo(url.appendingPathComponent("Contents/pipe").path, 0o600), 0)

        let result = try measured(url)
        XCTAssertEqual(result.sizeState, .measured)
        XCTAssertEqual(result.bytes, try allocated(url.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(result.relatedBytes, 0)
    }

    func testSymlinkAncestorCannotExposeOutsideRelatedTree() throws {
        let url = try app()
        let outside = try file("outside/Library/Application Support/org.example.fixtureapp/secret", bytes: 131072)
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library"),
                                 withDestinationURL: outside.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        let result = try measured(url)
        XCTAssertEqual(result.sizeState, .measured)
        XCTAssertEqual(result.relatedBytes, 0)
    }

    func testZeroDeadlineAndPreCancelledWorkAreUnavailable() throws {
        let url = try app()
        let timedOut = try XCTUnwrap(AppInventory.loadApp(at: url, sizeTimeLimit: 0,
                                                        sizeEnvironment: environment()))
        XCTAssertEqual(timedOut.sizeState, .unavailable)
        XCTAssertEqual(timedOut.totalBytes, 0)
        let cancelled = try XCTUnwrap(AppInventory.loadApp(at: url, sizeEnvironment: environment(), isCancelled: { true }))
        XCTAssertEqual(cancelled.sizeState, .unavailable)
        XCTAssertEqual(cancelled.totalBytes, 0)
    }

    func testPackageAndRelatedDiscoveryShareOneDeadline() throws {
        let url = try app()
        _ = try file("apps/FixtureApp.app/Contents/payload")
        _ = try file("home/Library/Application Support/org.example.fixtureapp/store")
        let full = try measured(url)
        var ticks = 0
        let result = try XCTUnwrap(AppInventory.loadApp(at: url, sizeTimeLimit: 0.6,
            sizeEnvironment: environment(now: { defer { ticks += 1 }; return Double(ticks) * 0.01 })))
        XCTAssertEqual(result.sizeState, .partial)
        XCTAssertEqual(result.bytes, full.bytes, "The package finished before related discovery exhausted the same budget")
        XCTAssertLessThan(result.relatedBytes, full.relatedBytes)
        XCTAssertLessThanOrEqual(ticks, 62, "Related work must not reset the deadline")
    }

    func testNodeBudgetAndMidTraversalCancellationReturnPartial() throws {
        let url = try app()
        for i in 0..<60 { _ = try file("apps/FixtureApp.app/Contents/payload-\(i)") }
        let full = try measured(url)
        let bounded = try measured(url, nodeLimit: 8)
        XCTAssertEqual(bounded.sizeState, .partial)
        XCTAssertGreaterThan(bounded.bytes, 0)
        XCTAssertLessThan(bounded.bytes, full.bytes)
        let noNodes = try measured(url, nodeLimit: 0)
        XCTAssertEqual(noNodes.sizeState, .unavailable)

        let cancellation = CancellationCounter(limit: 40)
        let cancelled = try XCTUnwrap(AppInventory.loadApp(at: url, sizeEnvironment: environment(),
                                                          isCancelled: { cancellation.shouldCancel() }))
        XCTAssertEqual(cancelled.sizeState, .partial)
        XCTAssertGreaterThan(cancelled.bytes, 0)
        XCTAssertLessThan(cancelled.bytes, full.bytes)
        XCTAssertEqual(cancellation.calls, 40)
    }

    func testPermissionFailureIsPartialRatherThanCompleteZero() throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX unreadability fixture requires an unprivileged test process") }
        let url = try app()
        let blockedFile = try file("home/Library/Application Support/org.example.fixtureapp/private")
        let blocked = blockedFile.deletingLastPathComponent()
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        defer { _ = chmod(blocked.path, 0o700) }
        let result = try measured(url)
        XCTAssertEqual(result.sizeState, .partial)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(result.relatedBytes, 0)
    }

    private final class CancellationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let limit: Int
        init(limit: Int) { self.limit = limit }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func shouldCancel() -> Bool {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count >= limit
        }
    }
}
