// PathReclaimDeduper + scan TTL (Batch 5).

import Combine
import XCTest
@testable import CleanupKit

private actor TTLTrashRecorder {
    private(set) var callCount = 0
    func record() { callCount += 1 }
}

final class PathReclaimDeduperTests: XCTestCase {
    func testParentCoversChildBytesOnce() {
        let parent = "/Users/x/Library/Caches/Google"
        let child = "/Users/x/Library/Caches/Google/Chrome"
        let total = PathReclaimDeduper.uniqueReclaimableBytes([
            .init(path: parent, bytes: 1_000),
            .init(path: child, bytes: 400)
        ])
        XCTAssertEqual(total, 1_000, "parent covers child — count once")
    }

    func testSiblingPathsSum() {
        let a = "/Users/x/Library/Caches/A"
        let b = "/Users/x/Library/Caches/B"
        let total = PathReclaimDeduper.uniqueReclaimableBytes([
            .init(path: a, bytes: 100),
            .init(path: b, bytes: 200)
        ])
        XCTAssertEqual(total, 300)
    }

    func testNonOverlappingPathsDropsChild() {
        let paths = PathReclaimDeduper.nonOverlappingPaths([
            "/tmp/root",
            "/tmp/root/child",
            "/tmp/other"
        ])
        XCTAssertTrue(paths.contains("/tmp/root") || paths.contains(PathGate.normalize("/tmp/root")))
        XCTAssertFalse(paths.contains { $0.hasSuffix("/child") })
        XCTAssertEqual(paths.count, 2)
    }

    func testLargeSiblingSetRemainsComplete() {
        let paths = (0..<10_000).map { "/Users/x/Library/Caches/item-\($0)" }
        let result = PathReclaimDeduper.nonOverlappingPaths(paths)
        XCTAssertEqual(result.count, paths.count)
    }

    func testRawLexicalSiblingCannotSplitParentSubtree() {
        let result = PathReclaimDeduper.nonOverlappingPaths([
            "/tmp/a",
            "/tmp/a-foo",
            "/tmp/a/child"
        ])
        XCTAssertEqual(Set(result), Set(["/tmp/a", "/tmp/a-foo"]))
    }

    @MainActor
    func testHasFreshPreviewRequiresTimestamp() async {
        let service = CleanupService()
        service.testScanHandler = { _ in
            [CleanupCategoryGroup(
                category: .userCache,
                items: [
                    CleanableItem(
                        name: "c",
                        path: "/tmp/ttl-test",
                        bytes: 1,
                        category: .userCache,
                        isSelected: false,
                        risk: .rebuild
                    )
                ]
            )]
        }
        let done = expectation(description: "scan")
        _ = service.startScan(force: true) { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(service.hasFreshPreview)
        XCTAssertNotNil(service.lastScanCompletedAt)
        XCTAssertEqual(service.totalBytes, 1)
        service.setSelected(itemID: service.allItems[0].id, selected: true)
        XCTAssertEqual(service.selectedBytes, 1)
        XCTAssertEqual(service.selectedCount, 1)
        service.clearAllSelection()
        XCTAssertEqual(service.selectedBytes, 0)
        XCTAssertEqual(service.selectedCount, 0)

        // 模拟过期
        // lastScanCompletedAt is private(set) — use force path: nil stamp means stale via policy
        // Inject via reflection not available; test policy directly
        XCTAssertFalse(CleanupReusePolicy.isFresh(nil, ttl: CleanupReusePolicy.cleanupTTL))
        XCTAssertFalse(CleanupReusePolicy.isFresh(Date().addingTimeInterval(-11 * 60), ttl: CleanupReusePolicy.cleanupTTL))
        XCTAssertTrue(CleanupReusePolicy.isFresh(Date(), ttl: CleanupReusePolicy.cleanupTTL))
    }

    @MainActor
    func testConfirmTrashBlockedWhenStale() async {
        let service = CleanupService()
        let path = NSTemporaryDirectory() + "ttl-stale-\(UUID().uuidString)"
        try? "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        service.testScanHandler = { _ in
            [CleanupCategoryGroup(
                category: .userCache,
                items: [
                    CleanableItem(
                        name: "c",
                        path: path,
                        bytes: 1,
                        category: .userCache,
                        isSelected: false,
                        risk: .rebuild
                    )
                ]
            )]
        }
        let done = expectation(description: "scan")
        _ = service.startScan(force: true) { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        service.setSelected(itemID: service.allItems[0].id, selected: true)
        XCTAssertTrue(service.hasFreshPreview)

        // An expired confirmation never invokes the executor. Returning then
        // discards the snapshot instead of leaving a disabled preview behind.
        service.setLastScanCompletedAtForTesting(Date().addingTimeInterval(-11 * 60))
        XCTAssertFalse(service.hasFreshPreview)
        let recorder = TTLTrashRecorder()
        service.testTrashHandler = { _ in
            await recorder.record()
            return CleanupResult(cleanedCount: 1, trashedPaths: [path], succeededPaths: [path])
        }
        service.confirmTrash()
        let reusable = await service.reconcilePreviewOnReturn()
        XCTAssertFalse(reusable)
        let staleCalls = await recorder.callCount
        XCTAssertEqual(staleCalls, 0, "stale preview must not run trash")
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.preparationFailure, .expiredPreview)
        XCTAssertTrue(service.groups.isEmpty, "expired rows must not remain disabled")
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertEqual(service.selectedBytes, 0)
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), "x")

        // Only a new scan and new user selection can make confirmation ready.
        let rescanned = expectation(description: "fresh fixture scanned again")
        XCTAssertTrue(service.startScan(force: true) { rescanned.fulfill() })
        await fulfillment(of: [rescanned], timeout: 1)
        XCTAssertTrue(service.hasFreshPreview)
        XCTAssertEqual(service.selectedCount, 0, "rescan must not restore expired consent")
        service.confirmTrash()
        await Task.yield()
        let unselectedCalls = await recorder.callCount
        XCTAssertEqual(unselectedCalls, 0, "fresh but unselected preview must not run trash")
        service.setSelected(itemID: service.allItems[0].id, selected: true)
        let cleaned = expectation(description: "explicit fresh confirmation completed")
        let subscription = service.$phase.sink {
            if case .done = $0 { cleaned.fulfill() }
        }
        service.confirmTrash()
        await fulfillment(of: [cleaned], timeout: 1)
        let freshCalls = await recorder.callCount
        XCTAssertEqual(freshCalls, 1, "fresh, explicitly selected preview may reach the fake executor")
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), "x", "the fake executor must leave the fixture intact")
        withExtendedLifetime(subscription) {}
        service.reset()
    }
}
