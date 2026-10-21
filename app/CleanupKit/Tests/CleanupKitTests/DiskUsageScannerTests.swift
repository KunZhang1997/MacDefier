import Darwin
import XCTest
@testable import CleanupKit

final class DiskUsageScannerTests: XCTestCase {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [DiskUsageProgress] = []
        func record(_ value: DiskUsageProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var snapshots: [DiskUsageProgress] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ name: String, bytes: Int = 8192) throws -> URL {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: file)
        return file
    }

    func testHiddenFilesPackagesAndNewlineNamesAreCounted() throws {
        let hidden = try write(".hidden")
        let package = try write("Demo.app/Contents/file\nwith\ttabs")
        let scan = DiskUsageScanner.scan(root: root)
        XCTAssertTrue(scan.root?.isComplete == true)
        XCTAssertNotNil(scan.nodes[hidden.path])
        XCTAssertNotNil(scan.nodes[package.path])
        XCTAssertEqual(scan.root?.logicalBytes, 16384)
        XCTAssertEqual(scan.children(of: root.path).count, 2)
    }

    func testHardLinksAreCountedOnceAndSymlinksAreNotFollowed() throws {
        let file = try write("original")
        let hard = root.appendingPathComponent("hard")
        XCTAssertEqual(link(file.path, hard.path), 0)
        let symlink = root.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
        let scan = DiskUsageScanner.scan(root: root)
        XCTAssertEqual(scan.nodes.count, 4)
        XCTAssertEqual(scan.nodes.values.filter(\.isHardLinkDuplicate).count, 1)
        let duplicate = try XCTUnwrap(scan.nodes.values.first(where: \.isHardLinkDuplicate))
        XCTAssertEqual(duplicate.logicalBytes, 8192)
        XCTAssertGreaterThan(scan.root?.hardLinkBytesCountedElsewhere ?? 0, 0)
        XCTAssertTrue(scan.nodes[symlink.path]?.isSymbolicLink == true)
        XCTAssertTrue(scan.root?.isComplete == true)
    }

    func testSparseFileUsesAllocatedBytesSeparatelyFromLogicalSize() throws {
        let file = try write("sparse", bytes: 0)
        let fd = open(file.path, O_WRONLY)
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, 512 * 1024 * 1024), 0)
        let node = try XCTUnwrap(DiskUsageScanner.scan(root: root).nodes[file.path])
        XCTAssertEqual(node.logicalBytes, 512 * 1024 * 1024)
        XCTAssertLessThan(node.allocatedBytes, node.logicalBytes)
    }

    func testEntryLimitPreservesPartialResultsAndReason() throws {
        for i in 0..<5 { _ = try write("file-\(i)") }
        let scan = DiskUsageScanner.scan(root: root, budget: DiskScanBudget(maxEntries: 2))
        XCTAssertEqual(scan.nodes.count, 3)
        XCTAssertTrue(scan.root?.issues.contains(.entryLimit) == true)
        XCTAssertFalse(scan.root?.isComplete ?? true)
        XCTAssertGreaterThan(scan.root?.logicalBytes ?? 0, 0)
    }

    func testDepthAndTimeLimitsAreExplicit() throws {
        let file = try write("child/deep/file")
        let scan = DiskUsageScanner.scan(root: root, budget: DiskScanBudget(maxDepth: 0))
        XCTAssertNil(scan.nodes[file.path])
        XCTAssertTrue(scan.root?.issues.contains(.depthLimit) == true)
        let timed = DiskUsageScanner.scan(root: root, budget: DiskScanBudget(maxSeconds: 0))
        XCTAssertTrue(timed.root?.issues.contains(.timeLimit) == true)
    }

    func testCancellationAndMissingRootCannotLookEmptyAndComplete() {
        let cancelled = DiskUsageScanner.scan(root: root, isCancelled: { true })
        XCTAssertTrue(cancelled.root?.issues.contains(.cancelled) == true)
        let missing = DiskUsageScanner.scan(root: root.appendingPathComponent("missing"))
        XCTAssertTrue(missing.root?.issues.contains(.unreadable) == true)
        XCTAssertFalse(missing.root?.isComplete ?? true)
    }

    func testLiveSnapshotsAreIncompleteAndFinalAccountingIsUnchanged() throws {
        _ = try write("first/file"); _ = try write("second/file")
        let recorder = ProgressRecorder()
        let result = DiskUsageScanner.scan(root: root, onProgress: { recorder.record($0) })
        XCTAssertGreaterThanOrEqual(recorder.snapshots.count, 2)
        XCTAssertEqual(recorder.snapshots.first?.entries, 0)
        XCTAssertEqual(recorder.snapshots.last?.entries, result.nodes.count - 1)
        XCTAssertTrue(recorder.snapshots.allSatisfy { $0.snapshot.root?.issues.contains(.inProgress) == true })
        XCTAssertFalse(result.root?.issues.contains(.inProgress) ?? true)
        XCTAssertTrue(result.root?.isComplete == true)
        XCTAssertEqual(result.root?.logicalBytes, 16384)
    }

    func testProgressCallbackCancellationRetainsAnExplicitPartialResult() {
        let recorder = ProgressRecorder()
        let result = DiskUsageScanner.scan(root: root, onProgress: { recorder.record($0) },
            isCancelled: { !recorder.snapshots.isEmpty })
        XCTAssertTrue(result.root?.issues.contains(.cancelled) == true)
        XCTAssertFalse(result.root?.isComplete ?? true)
    }
}
