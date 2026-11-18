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

    func testSumAllocatedBytesMatchesTreeScanAcrossHardLinksSymlinksAndBudgets() throws {
        let fileA = try write("nested/a.bin", bytes: 12_288)
        _ = try write("nested/deeper/b.bin", bytes: 20_480)
        _ = try write(".hidden-data", bytes: 4_096)
        let hardLink = root.appendingPathComponent("nested/a-hardlink.bin")
        XCTAssertEqual(link(fileA.path, hardLink.path), 0)

        let external = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSumOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try Data(repeating: 9, count: 65_536).write(to: external.appendingPathComponent("outside.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("external-link"),
            withDestinationURL: external
        )

        // Full scan parity
        let fullScan = DiskUsageScanner.scan(root: root)
        let fullSum = DiskUsageScanner.sumAllocatedBytes(root: root)
        XCTAssertEqual(fullSum.allocatedBytes, fullScan.root?.allocatedBytes)
        XCTAssertEqual(fullSum.isComplete, fullScan.root?.isComplete)
        XCTAssertTrue(fullSum.isComplete)

        // Single file parity
        let singleScan = DiskUsageScanner.scan(root: fileA)
        let singleSum = DiskUsageScanner.sumAllocatedBytes(root: fileA)
        XCTAssertEqual(singleSum.allocatedBytes, singleScan.root?.allocatedBytes)
        XCTAssertEqual(singleSum.isComplete, singleScan.root?.isComplete)

        // Depth budget parity
        let depthBudget = DiskScanBudget(maxDepth: 0)
        let depthScan = DiskUsageScanner.scan(root: root, budget: depthBudget)
        let depthSum = DiskUsageScanner.sumAllocatedBytes(root: root, budget: depthBudget)
        XCTAssertEqual(depthSum.allocatedBytes, depthScan.root?.allocatedBytes)
        XCTAssertFalse(depthSum.isComplete)

        // Entry budget parity (incomplete flag + bounded positive bytes)
        let entryBudget = DiskScanBudget(maxEntries: 2)
        let entryScan = DiskUsageScanner.scan(root: root, budget: entryBudget)
        let entrySum = DiskUsageScanner.sumAllocatedBytes(root: root, budget: entryBudget)
        XCTAssertEqual(entrySum.allocatedBytes, entryScan.root?.allocatedBytes)
        XCTAssertFalse(entrySum.isComplete)

        // Zero time budget, cancellation, and missing root parity
        let zeroTimeSum = DiskUsageScanner.sumAllocatedBytes(root: root, budget: DiskScanBudget(maxSeconds: 0))
        XCTAssertFalse(zeroTimeSum.isComplete)
        let cancelledSum = DiskUsageScanner.sumAllocatedBytes(root: root, isCancelled: { true })
        XCTAssertFalse(cancelledSum.isComplete)
        let missingSum = DiskUsageScanner.sumAllocatedBytes(root: root.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(missingSum.allocatedBytes, 0)
        XCTAssertFalse(missingSum.isComplete)
    }

    func testScanInteractiveMatchesFullAccountingAcrossHardLinksSymlinksSparseAndDeepTrees() throws {
        let a = try write("Library/Application Support/Demo/cache.bin", bytes: 98_304)
        _ = try write("Downloads/archive.pkg", bytes: 131_072)
        _ = try write(".hidden/config.json", bytes: 8_192)
        let hard = root.appendingPathComponent("Library/Application Support/Demo/cache-hardlink.bin")
        XCTAssertEqual(link(a.path, hard.path), 0)

        let symlink = root.appendingPathComponent("Downloads/loop")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)

        let sparse = try write("Downloads/sparse.img", bytes: 0)
        let sfd = open(sparse.path, O_WRONLY)
        defer { close(sfd) }
        XCTAssertEqual(ftruncate(sfd, 16 * 1024 * 1024), 0)

        let baseline = DiskUsageScanner.scan(root: root)
        let interactive = DiskUsageScanner.scanInteractive(root: root)

        XCTAssertEqual(interactive.root?.allocatedBytes, baseline.root?.allocatedBytes)
        XCTAssertEqual(interactive.root?.logicalBytes, baseline.root?.logicalBytes)
        XCTAssertEqual(interactive.root?.hardLinkBytesCountedElsewhere, baseline.root?.hardLinkBytesCountedElsewhere)
        XCTAssertEqual(interactive.root?.isComplete, true)
        XCTAssertEqual(interactive.nodes[symlink.path]?.isSymbolicLink, true)
    }

    func testScanInteractivePreservesExactBytesWhenPruningDeepSmallLeavesAndExpandsSubtree() throws {
        // Depth 6 leaf files (< 64 KB) omit individual leaf nodes from the global map
        // while preserving 100% of allocated & logical bytes on every ancestor.
        let deepDirRel = "L1/L2/L3/L4/L5/L6"
        for idx in 0..<40 {
            _ = try write("\(deepDirRel)/tiny-\(idx).txt", bytes: 4_096)
        }
        let baseline = DiskUsageScanner.scan(root: root)
        let interactive = DiskUsageScanner.scanInteractive(root: root)

        XCTAssertEqual(interactive.root?.allocatedBytes, baseline.root?.allocatedBytes)
        XCTAssertEqual(interactive.root?.logicalBytes, baseline.root?.logicalBytes)
        XCTAssertEqual(interactive.root?.isComplete, true)

        // Expand deepDir on demand and merge into root snapshot while keeping rootPath.
        let deepURL = root.appendingPathComponent(deepDirRel)
        let expanded = DiskUsageScanner.scanInteractive(
            root: deepURL,
            options: DiskInteractiveScanOptions(
                maxDepth: 6,
                minRetainedChildBytesAfterShallowDepth: 0,
                shallowFullRetentionDepth: 4,
                maxRetainedSmallChildrenPerDirectory: 256,
                workerCount: 2
            )
        )
        let merged = interactive.mergingExpandedSubtree(expanded)
        XCTAssertEqual(merged.rootPath, interactive.rootPath)
        XCTAssertEqual(merged.children(of: deepURL.path).count, 40)
    }

    func testScanInteractiveCancellationAndVolumeOverview() throws {
        for idx in 0..<12 {
            _ = try write("branch-\(idx)/sub/item.dat", bytes: 8_192)
        }
        let cancelled = DiskUsageScanner.scanInteractive(root: root, isCancelled: { true })
        XCTAssertTrue(cancelled.root?.issues.contains(.cancelled) == true)
        XCTAssertFalse(cancelled.root?.isComplete ?? true)

        let overview = try XCTUnwrap(DiskUsageScanner.volumeOverview(for: URL(fileURLWithPath: "/")))
        XCTAssertGreaterThan(overview.totalBytes, 0)
        XCTAssertLessThanOrEqual(overview.usedBytes, overview.totalBytes)
        XCTAssertLessThanOrEqual(overview.availableBytes, overview.totalBytes)
        XCTAssertTrue(overview.isRootFileSystem)
        XCTAssertFalse(overview.volumeName.isEmpty)
    }

    func testSeedSubtreesAndSubtreeExtractionPreserveExactAccounting() throws {
        let userAData = try write("Users/alice/Library/Caches/big.bin", bytes: 196_608)
        _ = try write("Users/alice/Downloads/pkg.dmg", bytes: 131_072)
        _ = try write("Applications/Demo.app/Contents/MacOS/Demo", bytes: 98_304)
        _ = try write("System/core.dat", bytes: 65_536)

        let aliceURL = root.appendingPathComponent("Users/alice")
        let aliceSeed = DiskUsageScanner.scanInteractive(root: aliceURL)
        let fullCold = DiskUsageScanner.scanInteractive(root: root)
        let fullSeeded = DiskUsageScanner.scanInteractive(root: root, seedSubtrees: [aliceSeed])

        XCTAssertEqual(fullSeeded.root?.allocatedBytes, fullCold.root?.allocatedBytes)
        XCTAssertEqual(fullSeeded.root?.logicalBytes, fullCold.root?.logicalBytes)
        XCTAssertNotNil(fullSeeded.nodes[PathGate.standardizeOnly(userAData.path)])

        let projected = try XCTUnwrap(fullSeeded.extractingSubtree(at: aliceURL.path))
        XCTAssertEqual(projected.root?.allocatedBytes, aliceSeed.root?.allocatedBytes)
        XCTAssertNotNil(projected.nodes[PathGate.standardizeOnly(userAData.path)])
    }
}
