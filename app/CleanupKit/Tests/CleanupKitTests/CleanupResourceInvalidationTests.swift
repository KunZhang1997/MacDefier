import Combine
import Foundation
import XCTest
@testable import CleanupKit

@MainActor
final class CleanupResourceInvalidationTests: XCTestCase {
    func testResourceNotificationInvalidatesFreshPreviewAndClearsSelectionWithoutDeletion() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupInvalidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("fixture.cache")
        let original = Data("untouched fixture".utf8)
        try original.write(to: file)

        let item = CleanableItem(name: "Fixture cache", path: file.path, bytes: UInt64(original.count),
                                 category: .userCache, isSelected: false, risk: .rebuild)
        let group = CleanupCategoryGroup(category: .userCache, items: [item])
        let service = CleanupService()
        service.testScanHandler = { _ in [group] }
        service.testTrashHandler = { _ in
            XCTFail("A resource notification must never trigger cleanup")
            return CleanupResult()
        }
        let previewReady = expectation(description: "fixture preview ready")
        XCTAssertTrue(service.startScan { previewReady.fulfill() })
        await fulfillment(of: [previewReady], timeout: 2)
        service.setSelected(itemID: item.id, selected: true)
        XCTAssertTrue(service.hasFreshPreview)
        XCTAssertEqual(service.selectedCount, 1)
        XCTAssertGreaterThan(service.selectedBytes, 0)
        let generation = service.scanGeneration

        let invalidated = expectation(description: "cross-surface resource event delivered")
        let subscription = service.$lastScanCompletedAt.dropFirst().filter { $0 == nil }.sink { _ in
            invalidated.fulfill()
        }
        // Publish the same product notification emitted by AI/uninstall executors.
        // This fixture deliberately does not execute any mutation first.
        CleanupResourceEvents.publish(paths: [file.path])
        await fulfillment(of: [invalidated], timeout: 2)
        withExtendedLifetime(subscription) {}

        XCTAssertFalse(service.hasFreshPreview)
        XCTAssertTrue(service.hasStalePreview)
        XCTAssertNil(service.lastScanCompletedAt)
        XCTAssertEqual(service.preparationFailure, .changedTargets)
        XCTAssertGreaterThan(service.scanGeneration, generation)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertEqual(service.selectedBytes, 0)
        XCTAssertTrue(service.allItems.allSatisfy { !$0.isSelected })
        XCTAssertEqual(service.allItems.map(\.id), [item.id], "Keep rows visible for an explicit refresh")
        XCTAssertFalse(service.isDestructiveBusy)
        XCTAssertNil(service.lastResult)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
