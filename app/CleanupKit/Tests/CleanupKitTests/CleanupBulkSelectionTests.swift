import Combine
import XCTest
@testable import CleanupKit

/// Selection-only fixtures: no real scan, cleanup confirmation, or filesystem mutation.
@MainActor
final class CleanupBulkSelectionTests: XCTestCase {
    private actor ScanGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private func item(_ id: String, category: CleanupCategory = .userLogs,
                      risk: CleanupRisk = .safe, bytes: UInt64 = 10) -> CleanableItem {
        CleanableItem(id: id, name: id,
                      path: NSTemporaryDirectory() + "MacDefier-bulk-selection-virtual/" + id,
                      bytes: bytes, category: category, isSelected: false, risk: risk)
    }

    private func load(_ groups: [CleanupCategoryGroup]) async -> CleanupService {
        let service = CleanupService()
        service.testScanHandler = { _ in groups }
        service.testTrashHandler = { _ in
            XCTFail("Changing selection must never invoke cleanup")
            return CleanupResult()
        }
        let ready = expectation(description: "injected preview ready")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 20)
        XCTAssertTrue(service.canEditSelection)
        XCTAssertEqual(service.selectedCount, 0, "A scan must remain initially unselected")
        return service
    }

    func testSelectAllIncludesCautionAndTrashButExcludesProtectedItems() async {
        let service = await load([
            CleanupCategoryGroup(category: .userLogs, items: [item("safe"), item("rebuild", risk: .rebuild),
                item("caution", risk: .caution), item("blocked", risk: .skip)]),
            CleanupCategoryGroup(category: .trash, items: [item("trash", category: .trash, risk: .caution)]),
            CleanupCategoryGroup(category: .aiApps, items: [item("ai-protected", category: .aiApps, risk: .skip)])
        ])
        defer { service.reset() }

        service.setAllSelected(true)
        XCTAssertEqual(Set(service.allItems.filter(\.isSelected).map(\.id)), ["safe", "rebuild", "caution", "trash"])
        XCTAssertEqual(service.selectedCount, 4)
        XCTAssertEqual(service.selectedBytes, 40)
        XCTAssertEqual(service.selectableCount, 4)
        XCTAssertTrue(service.allSelectableSelected)
        XCTAssertEqual(service.phase, .preview)
        XCTAssertNil(service.lastResult)
        XCTAssertFalse(service.lastIncludedPermanentTrash, "Selecting Trash is not permanent-delete confirmation")

        service.setAllSelected(false)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertEqual(service.selectedBytes, 0)
        XCTAssertFalse(service.allSelectableSelected)
    }

    func testCategorySelectionDoesNotChangeOtherCategories() async {
        let service = await load([
            CleanupCategoryGroup(category: .userLogs, items: [item("log"), item("caution", risk: .caution), item("skip", risk: .skip)]),
            CleanupCategoryGroup(category: .trash, items: [item("trash", category: .trash, risk: .caution)])
        ])
        defer { service.reset() }
        service.setSelected(itemID: "trash", selected: true)

        service.setAllSelected(true, in: .userLogs)
        XCTAssertEqual(Set(service.allItems.filter(\.isSelected).map(\.id)), ["log", "caution", "trash"])
        service.setAllSelected(false, in: .userLogs)
        XCTAssertEqual(service.allItems.filter(\.isSelected).map(\.id), ["trash"])
        service.setAllSelected(true, in: .wallpaper)
        XCTAssertEqual(service.allItems.filter(\.isSelected).map(\.id), ["trash"])
        service.setAllSelected(false, in: .trash)
        XCTAssertEqual(service.selectedCount, 0)
    }

    func testExpiredPreviewRejectsBulkChangesButInternalClearStillWorks() async {
        let service = await load([CleanupCategoryGroup(category: .userLogs, items: [item("one"), item("two")])])
        defer { service.reset() }
        service.setSelected(itemID: "one", selected: true)
        service.setLastScanCompletedAtForTesting(Date().addingTimeInterval(-CleanupReusePolicy.cleanupTTL - 1))
        XCTAssertFalse(service.canEditSelection)

        service.setAllSelected(true)
        service.setAllSelected(false, in: .userLogs)
        XCTAssertEqual(service.allItems.filter(\.isSelected).map(\.id), ["one"])
        service.clearAllSelection()
        XCTAssertEqual(service.selectedCount, 0, "Invalidation must still clear a stale selection")
    }

    func testPartialScanAndStoppedPreviewRejectBulkSelection() async {
        let group = CleanupCategoryGroup(category: .userLogs, items: [item("partial")], isPartial: true)
        let gate = ScanGate()
        let service = CleanupService()
        service.testScanHandler = { _ in
            await gate.wait()
            return [group]
        }
        service.testTrashHandler = { _ in
            XCTFail("Selection must not invoke cleanup")
            return CleanupResult()
        }
        let finished = expectation(description: "cancelled injected scan finished")
        service.startScan { finished.fulfill() }
        service.applyScanGroup(group, generation: service.scanGeneration)
        XCTAssertFalse(service.canEditSelection)
        XCTAssertTrue(service.phase.isBusy)
        XCTAssertEqual(service.allItems.count, 1)

        service.setAllSelected(true)
        XCTAssertFalse(service.allItems[0].isSelected)
        service.cancelScan()
        XCTAssertFalse(service.canEditSelection)
        service.setAllSelected(true, in: .userLogs)
        XCTAssertFalse(service.allItems[0].isSelected)
        await gate.open()
        await fulfillment(of: [finished], timeout: 20)
        service.reset()
    }

    func testAIEnrichmentRejectsBulkSelectionChanges() async {
        let service = await load([CleanupCategoryGroup(category: .userLogs, items: [item("one"), item("two")])])
        defer { service.reset() }
        service.setSelected(itemID: "one", selected: true)
        service.beginAIEnrichment()
        XCTAssertTrue(service.hasFreshPreview)
        XCTAssertFalse(service.canEditSelection)

        service.setAllSelected(true, in: .userLogs)
        service.setAllSelected(false)
        XCTAssertEqual(service.allItems.filter(\.isSelected).map(\.id), ["one"])
        // Reset instead of finishAIEnrichment: this test must not persist an AI scan record.
    }

    func testLegacyLowRiskSelectionKeepsItsNarrowMeaning() async {
        let service = await load([CleanupCategoryGroup(category: .userLogs,
            items: [item("safe"), item("caution", risk: .caution), item("skip", risk: .skip)])])
        defer { service.reset() }
        service.selectLowRiskOnly()
        XCTAssertEqual(service.allItems.filter(\.isSelected).map(\.id), ["safe"])
        service.clearAllSelection()
        service.setCategorySelected(.userLogs, selected: true)
        XCTAssertEqual(service.allItems.filter(\.isSelected).map(\.id), ["safe"])
        service.setSelected(itemID: "caution", selected: true)
        service.selectLowRiskOnly()
        XCTAssertEqual(Set(service.allItems.filter(\.isSelected).map(\.id)), ["safe", "caution"])
    }

    func testLargeBulkSelectionUsesOnePublicationAndRepeatedActionsAreNoOps() async {
        let count = 2_000
        let items = (0..<count).map { item("bulk-\($0)", risk: $0.isMultiple(of: 2) ? .safe : .caution, bytes: 1024) }
        let service = await load([CleanupCategoryGroup(category: .userLogs, items: items)])
        defer { service.reset() }
        var changes = 0
        let subscription = service.$groups.dropFirst().sink { _ in changes += 1 }
        let started = DispatchTime.now().uptimeNanoseconds

        service.setAllSelected(true)
        XCTAssertEqual(service.selectedCount, count)
        XCTAssertEqual(service.selectedBytes, UInt64(count * 1024))
        XCTAssertEqual(changes, 1)
        service.setAllSelected(true)
        service.setAllSelected(true, in: .userLogs)
        XCTAssertEqual(changes, 1)
        service.setAllSelected(false)
        service.setAllSelected(false)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertEqual(service.selectedBytes, 0)

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print("PERF_BULK_SELECTION items=\(count) five_actions_ms=\(elapsed)")
        XCTAssertLessThan(elapsed, 250, "Bulk selection must not perform per-row live filesystem probes")
        withExtendedLifetime(subscription) {}
    }
}
