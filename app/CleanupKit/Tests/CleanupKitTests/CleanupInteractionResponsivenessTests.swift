import Foundation
import XCTest
@testable import CleanupKit

@MainActor
final class CleanupInteractionResponsivenessTests: XCTestCase {
    private actor Requests {
        var batches: [[String]] = []
        func record(_ items: [CleanableItem]) { batches.append(items.map(\.id)) }
        func snapshot() -> [[String]] { batches }
    }

    private func fixture(count: Int) throws -> (URL, [CleanableItem]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDefierInteraction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let items = try (0..<count).map { index in
            let url = root.appendingPathComponent("Library/Caches/audit/entry-\(index)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return CleanableItem(id: "item-\(index)", name: "ChromeCache-\(index)",
                                path: url.path, bytes: 65536, category: .userCache,
                                isSelected: false, risk: .rebuild)
        }
        return (root, items)
    }

    private func load(_ items: [CleanableItem], into service: CleanupService) async {
        let groups = [CleanupCategoryGroup(category: .userCache, items: items)]
        service.testScanHandler = { _ in groups }
        await withCheckedContinuation { continuation in
            service.startScan { continuation.resume() }
        }
    }

    private func waitForCleanup(_ service: CleanupService) async throws {
        let deadline = Date().addingTimeInterval(20)
        while service.isDestructiveBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(service.isDestructiveBusy, "Isolated cleanup must complete within its watchdog")
    }

    func testCachedEligibilityMatchesPolicyForImmutableMetadata() {
        let names = ["ChromeCache", "pip", "com.apple.example", "DerivedData",
                     "history", "password", "manual-data", "discord"]
        for category in CleanupCategory.allCases {
            for risk in [CleanupRisk.safe, .rebuild, .caution, .skip] {
                for name in names {
                    var item = CleanableItem(name: name, path: "/tmp/audit/\(name)", bytes: 0,
                                             category: category, isSelected: false, risk: risk)
                    XCTAssertEqual(item.isLowRiskBulkEligible, CleanupRiskPolicy.isLowRiskBulkEligible(item))
                    item.isSelected.toggle()
                    XCTAssertEqual(item.isLowRiskBulkEligible, CleanupRiskPolicy.isLowRiskBulkEligible(item))
                }
            }
        }
    }

    func testRepeatedPreviewReadsStayWithinInteractionBudget() async throws {
        let (root, items) = try fixture(count: 200)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CleanupService()
        await load(items, into: service)
        defer { service.reset() }
        XCTAssertEqual(service.lowRiskCount, 200)
        let start = DispatchTime.now().uptimeNanoseconds
        var total = 0
        for _ in 0..<10 { total += service.lowRiskCount }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertEqual(total, 2000)
        print("INTERACTION_PERF stage=preview_reads count=200 repeats=10 elapsed_ms=\(elapsed)")
        XCTAssertLessThan(elapsed, 50, "Repeated UI reads must not rerun string-based risk rules")
        service.setCategorySelected(.userCache, selected: true)
        XCTAssertEqual(service.selectedCount, 200)
        service.setSelected(itemID: items[0].id, selected: false)
        XCTAssertEqual(service.selectedCount, 199)
        XCTAssertEqual(service.selectedBytes, UInt64(199 * 65536))
    }

    func testConfirmYieldsBeforePreflightAndFreezesSelection() async throws {
        let (root, items) = try fixture(count: 200)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CleanupService()
        let requests = Requests()
        await load(items, into: service)
        service.setCategorySelected(.userCache, selected: true)
        service.testTrashHandler = { selected in
            await requests.record(selected)
            return CleanupResult(cleanedCount: selected.count, trashedPaths: selected.map(\.path),
                                 succeededPaths: selected.map(\.path))
        }
        let start = DispatchTime.now().uptimeNanoseconds
        service.confirmTrash()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("INTERACTION_PERF stage=confirm_front_half count=200 elapsed_ms=\(elapsed)")
        XCTAssertLessThan(elapsed, 50, "Filesystem preflight must not block the UI actor")
        XCTAssertTrue(service.isDestructiveBusy)
        let generation = service.scanGeneration
        service.cancelScan()
        service.reset()
        XCTAssertFalse(service.startScan())
        XCTAssertEqual(service.scanGeneration, generation)
        service.clearAllSelection()
        service.confirmTrash()
        try await waitForCleanup(service)
        let batches = await requests.snapshot()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(Set(batches.first ?? []), Set(items.map(\.id)))
        XCTAssertEqual(service.lastResult?.cleanedCount, 200)
        XCTAssertTrue(items.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        service.reset()
    }

    func testChangedPreviewStillBlocksBackgroundPreflight() async throws {
        let (root, _) = try fixture(count: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for directory in [a, b] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0x41]).write(to: directory.appendingPathComponent("payload.cache"))
        }
        let link = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let item = CleanableItem(id: "changed", name: "ChromeCache", path: link.appendingPathComponent("payload.cache").path,
                                 bytes: 1, category: .userCache, isSelected: false, risk: .rebuild)
        let service = CleanupService(), requests = Requests()
        await load([item], into: service)
        service.setSelected(itemID: item.id, selected: true)
        service.testTrashHandler = { selected in
            await requests.record(selected)
            return CleanupResult()
        }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        service.confirmTrash()
        try await waitForCleanup(service)
        let batches = await requests.snapshot()
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(service.phase, .preview)
        XCTAssertTrue(service.hasStalePreview)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertTrue(service.frozenTrashPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: b.appendingPathComponent("payload.cache")), Data([0x41]))
        service.reset()
    }

    func testFailedCleanupThenFreshScanCanSucceed() async throws {
        let (root, items) = try fixture(count: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CleanupService(), requests = Requests()
        await load(items, into: service)
        service.setCategorySelected(.userCache, selected: true)
        service.testTrashHandler = { selected in
            await requests.record(selected)
            return CleanupResult(errors: ["Injected EACCES"], failedPaths: selected.map(\.path))
        }
        service.confirmTrash()
        try await waitForCleanup(service)
        XCTAssertEqual(service.lastResult?.cleanedCount, 0)
        XCTAssertEqual(service.lastResult?.freedBytes, 0)
        XCTAssertEqual(service.lastResult?.failedPaths.count, 3)
        XCTAssertEqual(service.allItems.count, 3)
        XCTAssertEqual(service.selectedCount, 0)
        await load(items, into: service)
        service.setCategorySelected(.userCache, selected: true)
        service.testTrashHandler = { selected in
            await requests.record(selected)
            return CleanupResult(cleanedCount: selected.count, trashedPaths: selected.map(\.path),
                                 succeededPaths: selected.map(\.path))
        }
        service.confirmTrash()
        try await waitForCleanup(service)
        XCTAssertEqual(service.lastResult?.cleanedCount, 3)
        XCTAssertTrue(service.allItems.isEmpty)
        let batches = await requests.snapshot()
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(items.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        service.reset()
    }
}
