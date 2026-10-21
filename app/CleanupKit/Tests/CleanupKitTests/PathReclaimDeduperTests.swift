// PathReclaimDeduper + scan TTL (Batch 5).

import XCTest
@testable import CleanupKit

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

        // 注入过期时间：confirmTrash 不得调用 executor
        service.setLastScanCompletedAtForTesting(Date().addingTimeInterval(-11 * 60))
        XCTAssertFalse(service.hasFreshPreview)
        var trashCalled = false
        service.testTrashHandler = { _ in
            trashCalled = true
            return CleanupResult(cleanedCount: 1, trashedPaths: [path], succeededPaths: [path])
        }
        service.confirmTrash()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(trashCalled, "stale preview must not run trash")
        if case .preview = service.phase {} else {
            XCTFail("phase must stay preview when confirm rejected as stale")
        }

        // 新鲜时间可执行
        service.setLastScanCompletedAtForTesting(Date())
        XCTAssertTrue(service.hasFreshPreview)
        service.confirmTrash()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if case .done = service.phase { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(trashCalled, "fresh preview may trash")
    }
}
