import XCTest
import Combine
@testable import CleanupKit

@MainActor
final class CleanupPerformanceTests: XCTestCase {
    func testLargePreviewSelectionResponsiveness() async {
        let service = CleanupService()
        let count = 2_000
        let root = NSTemporaryDirectory() + "MacDefier-selection-benchmark"
        let items = (0..<count).map { index in
            CleanableItem(id: "perf-\(index)", name: "log-\(index)",
                          path: "\(root)/logs/item-\(index)", bytes: 1024,
                          category: .userLogs, isSelected: false, risk: .safe)
        }
        service.testScanHandler = { _ in
            [CleanupCategoryGroup(category: .userLogs, items: items)]
        }
        let ready = expectation(description: "large preview prepared")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 20)
        XCTAssertEqual(service.totalBytes, UInt64(count * 1024))

        var timings: [Double] = []
        for index in 0..<30 {
            let started = Date()
            service.setSelected(itemID: "perf-1999", selected: index.isMultiple(of: 2))
            // Visible checkbox bindings must not walk the full list per row.
            for row in 0..<200 { _ = service.isItemSelected(id: "perf-\(1800 + row)") }
            timings.append(Date().timeIntervalSince(started) * 1000)
        }
        timings.sort()
        // Deliberately generous to tolerate loaded CI, while catching the former
        // half-second filesystem traversal on every checkbox interaction.
        XCTAssertLessThan(timings[28], 75, "selection work must fit comfortably below a visible UI stall")
        let bulkStart = Date()
        service.selectLowRiskOnly()
        XCTAssertEqual(service.selectedCount, count)
        XCTAssertEqual(service.selectedBytes, UInt64(count * 1024))
        service.clearAllSelection()
        XCTAssertEqual(service.selectedCount, 0)
        print(String(format: "PERF_SELECTION items=%d p50_ms=%.3f p95_ms=%.3f max_ms=%.3f bulk_and_clear_ms=%.3f", count, timings[15], timings[28], timings[29], Date().timeIntervalSince(bulkStart) * 1000))
    }

    func testPreviewIndexCountsSelectedSubtreesWithoutDoubleCounting() throws {
        func item(_ id: String, _ path: String, _ bytes: UInt64) -> CleanableItem {
            CleanableItem(id: id, name: id, path: path, bytes: bytes,
                          category: .userLogs, isSelected: false, risk: .safe)
        }
        let root = NSTemporaryDirectory() + "MacDefier-index-test"
        let prepared = try CleanupPreviewIndex.prepare([
            CleanupCategoryGroup(category: .userLogs, items: [
                item("parent", root + "/a", 100),
                item("child", root + "/a/child", 30),
                item("sibling", root + "/a-foo", 20)
            ])
        ])
        XCTAssertEqual(prepared.index.totalBytes, 120)
        XCTAssertEqual(prepared.index.bytes(selectedIDs: ["child", "sibling"]), 50)
        XCTAssertEqual(prepared.index.bytes(selectedIDs: ["parent", "child", "sibling"]), 120)
        XCTAssertEqual(prepared.index.bytes(selectedIDs: []), 0)
    }

    func testCachedPreviewNeverAuthorizesRetargetedSymlink() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacDefier-preview-gate-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let safe = root.appendingPathComponent("safe.log")
        let alias = root.appendingPathComponent("alias.log")
        try Data("test fixture".utf8).write(to: safe)
        try fm.createSymbolicLink(at: alias, withDestinationURL: safe)
        let candidate = CleanableItem(id: "alias", name: "alias.log", path: alias.path, bytes: 12,
                                     category: .userLogs, isSelected: false, risk: .safe)
        let service = CleanupService()
        service.testScanHandler = { _ in [CleanupCategoryGroup(category: .userLogs, items: [candidate])] }
        let ready = expectation(description: "symlink preview ready")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(PathGate.isSafeToTrash(alias.path))
        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(at: alias, withDestinationURL: fm.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"))
        XCTAssertFalse(PathGate.isSafeToTrash(alias.path))

        // Presentation stays a snapshot; execution must use current filesystem state.
        XCTAssertEqual(service.previewPaths(for: candidate), [alias.path])
        service.setSelected(itemID: "alias", selected: true)
        XCTAssertEqual(service.selectedBytes, 12)
        service.testTrashHandler = { _ in
            XCTFail("cached display metadata must never bypass live PathGate")
            return CleanupResult()
        }
        let validationFinished = expectation(description: "background preflight rejects changed target")
        let subscription = service.$phase.dropFirst().sink { phase in
            if case .preview = phase { validationFinished.fulfill() }
        }
        service.confirmTrash()
        await fulfillment(of: [validationFinished], timeout: 2)
        XCTAssertFalse(service.isDestructiveBusy)
        XCTAssertTrue(service.hasStalePreview)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertTrue(fm.fileExists(atPath: safe.path))
        withExtendedLifetime(subscription) {}
    }

    func testUnchangedSelectionsDoNotRepublishWholeList() async {
        let item = CleanableItem(id: "one", name: "one.log", path: NSTemporaryDirectory() + "one.log",
                                 bytes: 12, category: .userLogs, isSelected: false, risk: .safe)
        let service = CleanupService()
        service.testScanHandler = { _ in [CleanupCategoryGroup(category: .userLogs, items: [item])] }
        let ready = expectation(description: "preview ready")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        var changes = 0
        let subscription = service.$groups.dropFirst().sink { _ in changes += 1 }
        service.setSelected(itemID: "one", selected: false)
        service.clearAllSelection()
        service.selectLowRiskOnly()
        service.selectLowRiskOnly()
        service.setCategorySelected(.userLogs, selected: true)
        XCTAssertEqual(changes, 1)
        service.clearAllSelection()
        XCTAssertEqual(changes, 2)
        withExtendedLifetime(subscription) {}
    }

    func testPreviewExpiryNotifiesWithoutRepeatedListUpdates() async {
        let item = CleanableItem(id: "expiry", name: "expiry.log", path: NSTemporaryDirectory() + "expiry.log",
                                 bytes: 12, category: .userLogs, isSelected: false, risk: .safe)
        let service = CleanupService()
        service.testScanHandler = { _ in [CleanupCategoryGroup(category: .userLogs, items: [item])] }
        let ready = expectation(description: "preview ready")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        service.setLastScanCompletedAtForTesting(Date().addingTimeInterval(-CleanupReusePolicy.cleanupTTL + 0.1))
        let expired = expectation(description: "expiry returns to the scan entry once")
        expired.assertForOverFulfill = true
        let subscription = service.$phase.dropFirst().sink {
            if case .idle = $0 { expired.fulfill() }
        }
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.preparationFailure, .expiredPreview)
        XCTAssertTrue(service.groups.isEmpty)
        withExtendedLifetime(subscription) {}
    }
}
