import XCTest
@testable import CleanupKit

final class ScanQualityTests: XCTestCase {
    func testEmptyPartialGroupSurvivesPreviewPreparation() throws {
        let result = try CleanupPreviewIndex.prepare([
            CleanupCategoryGroup(category: .largeAppData, items: [], isPartial: true),
            CleanupCategoryGroup(category: .userCache, items: [])
        ])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertTrue(result.groups[0].isPartial)
        XCTAssertEqual(result.groups[0].category, .largeAppData)
    }

    func testLowerBoundSurvivesPreviewAndIsShownAsSuch() throws {
        let item = CleanableItem(name: "partial", path: "/private/tmp/partial.cache", bytes: 4096,
                                category: .userCache, isSelected: false, sizeIsLowerBound: true)
        let prepared = try CleanupPreviewIndex.prepare([
            CleanupCategoryGroup(category: .userCache, items: [item], isPartial: true)
        ])
        let copy = try XCTUnwrap(prepared.groups.first?.items.first)
        XCTAssertTrue(copy.sizeIsLowerBound)
        XCTAssertTrue(copy.formattedSize.hasPrefix("≥ "))
        XCTAssertFalse(copy.isSelected)
    }

    func testCoordinatorCanRetainCancelledPartialResult() async {
        let coordinator = DiskScanCoordinator()
        let began = expectation(description: "scan acquired permit")
        let task = Task {
            await coordinator.withPermit(retainingCancelledResult: true) {
                began.fulfill()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return 7
            }
        }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        let partial = await task.value
        XCTAssertEqual(partial, 7)
        let next = await coordinator.withPermit { 8 }
        XCTAssertEqual(next, 8, "cancelled scan must release the shared permit")
    }

    @MainActor
    func testEmptyPartialScanRemainsVisibleInService() async {
        let service = CleanupService()
        service.testScanHandler = { _ in
            [CleanupCategoryGroup(category: .largeAppData, items: [], isPartial: true)]
        }
        let completed = expectation(description: "partial preview")
        service.startScan { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(service.phase, .preview)
        XCTAssertEqual(service.groups.count, 1)
        XCTAssertTrue(service.groups[0].isPartial)
        XCTAssertEqual(service.selectedCount, 0)
        service.reset()
    }
}
