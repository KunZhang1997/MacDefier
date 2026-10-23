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
        XCTAssertFalse(service.hasStalePreview)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertNil(service.lastScanCompletedAt)
        XCTAssertEqual(service.preparationFailure, .changedTargets)
        XCTAssertGreaterThan(service.scanGeneration, generation)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertEqual(service.selectedBytes, 0)
        XCTAssertTrue(service.allItems.allSatisfy { !$0.isSelected })
        XCTAssertTrue(service.groups.isEmpty, "Changed snapshots return to the scan entry")
        XCTAssertFalse(service.isDestructiveBusy)
        XCTAssertNil(service.lastResult)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}


private actor CleanupReturnGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class CleanupPreviewReturnTests: XCTestCase {
    private var root: URL!
    private var file: URL!
    private var service: CleanupService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDefier-preview-return-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("fixture.cache")
        try Data("untouched fixture".utf8).write(to: file)
        service = CleanupService()
        service.testTrashHandler = { _ in
            XCTFail("Returning to a preview must never start cleanup")
            return CleanupResult()
        }
    }

    override func tearDownWithError() throws {
        service.reset()
        service = nil
        if root.lastPathComponent.hasPrefix("MacDefier-preview-return-") {
            try FileManager.default.removeItem(at: root)
        }
    }

    private var fixtureGroup: CleanupCategoryGroup {
        let item = CleanableItem(id: "return-fixture", name: "fixture.cache", path: file.path,
                                 bytes: 17, category: .userCache, isSelected: false, risk: .rebuild)
        return CleanupCategoryGroup(category: .userCache, items: [item])
    }

    private func scan() async {
        let group = fixtureGroup
        service.testScanHandler = { _ in [group] }
        let ready = expectation(description: "preview ready")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        service.setSelected(itemID: "return-fixture", selected: true)
        XCTAssertTrue(service.canEditSelection)
    }

    func testValidReturnKeepsSelectionAndDoesNotRepublishResults() async {
        await scan()
        let generation = service.scanGeneration
        let completedAt = service.lastScanCompletedAt
        var groupChanges = 0
        let subscription = service.$groups.dropFirst().sink { _ in groupChanges += 1 }
        let reused = await service.reconcilePreviewOnReturn()
        XCTAssertTrue(reused)
        XCTAssertEqual(service.phase, .preview)
        XCTAssertTrue(service.canEditSelection)
        XCTAssertEqual(service.selectedCount, 1)
        XCTAssertEqual(service.selectedBytes, 17)
        XCTAssertEqual(service.scanGeneration, generation)
        XCTAssertEqual(service.lastScanCompletedAt, completedAt)
        XCTAssertEqual(groupChanges, 0)
        withExtendedLifetime(subscription) {}
    }

    func testUnrelatedMutationAndNormalDirectoryChangesKeepSelection() async throws {
        let directoryItem = CleanableItem(id: "directory", name: "fixture directory", path: root.path,
                                         bytes: 17, category: .userCache, isSelected: false, risk: .rebuild)
        let group = CleanupCategoryGroup(category: .userCache, items: [directoryItem])
        service.testScanHandler = { _ in [group] }
        let ready = expectation(description: "directory preview")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        service.setSelected(itemID: "directory", selected: true)
        // A new file changes the directory mtime, but not its scan identity.
        try Data("new".utf8).write(to: root.appendingPathComponent("new.cache"))
        await service.invalidateAfterResourceChange(paths: [root.path + "-unrelated/file"])
        let reused = await service.reconcilePreviewOnReturn()
        XCTAssertTrue(reused)
        XCTAssertEqual(service.selectedCount, 1)
        XCTAssertNil(service.preparationFailure)
    }

    func testExpiredReturnClearsDisabledResultsAndRetainsReason() async {
        await scan()
        service.setLastScanCompletedAtForTesting(Date().addingTimeInterval(-CleanupReusePolicy.cleanupTTL - 1))
        let reused = await service.reconcilePreviewOnReturn()
        XCTAssertFalse(reused)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.preparationFailure, .expiredPreview)
        XCTAssertTrue(service.groups.isEmpty)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertEqual(service.totalBytes, 0)
    }

    func testMissingTargetWithoutProductEventReturnsToRescan() async throws {
        await scan()
        try FileManager.default.removeItem(at: file)
        let reused = await service.reconcilePreviewOnReturn()
        XCTAssertFalse(reused)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.preparationFailure, .changedTargets)
        XCTAssertTrue(service.groups.isEmpty)
        XCTAssertEqual(service.selectedCount, 0)
    }

    func testReplacedTargetWithoutProductEventReturnsToRescan() async throws {
        await scan()
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original.cache"))
        try Data("replacement".utf8).write(to: file)
        let reused = await service.reconcilePreviewOnReturn()
        XCTAssertFalse(reused)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.preparationFailure, .changedTargets)
        XCTAssertTrue(service.groups.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
    }

    func testReturnAndMutationDoNotCancelScanButAffectedResultRequiresRescan() async {
        let group = fixtureGroup
        let gate = CleanupReturnGate()
        let started = expectation(description: "scan started")
        service.testScanHandler = { _ in
            started.fulfill()
            await gate.wait()
            return [group]
        }
        let finished = expectation(description: "scan finished normally")
        service.startScan { finished.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        let generation = service.scanGeneration
        let reused = await service.reconcilePreviewOnReturn()
        XCTAssertFalse(reused)
        await service.invalidateAfterResourceChange(paths: [file.path])
        XCTAssertEqual(service.scanGeneration, generation)
        if case .scanning = service.phase {} else { XCTFail("scan must continue") }
        await gate.open()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.preparationFailure, .changedTargets)
        XCTAssertTrue(service.groups.isEmpty)
    }

    func testReturnAndMutationDoNotAlterInFlightCleanup() async throws {
        await scan()
        let gate = CleanupReturnGate()
        let started = expectation(description: "fake executor started")
        service.testTrashHandler = { _ in
            started.fulfill()
            await gate.wait()
            return CleanupResult()
        }
        service.confirmTrash()
        await fulfillment(of: [started], timeout: 3)
        let generation = service.scanGeneration
        let frozen = service.frozenTrashPaths
        let reused = await service.reconcilePreviewOnReturn()
        XCTAssertFalse(reused)
        await service.invalidateAfterResourceChange(paths: [file.path])
        XCTAssertTrue(service.isDestructiveBusy)
        XCTAssertEqual(service.scanGeneration, generation)
        XCTAssertEqual(service.frozenTrashPaths, frozen)
        XCTAssertEqual(service.selectedCount, 1)
        let finished = expectation(description: "fake executor finished")
        let subscription = service.$phase.sink {
            if case .done = $0 { finished.fulfill() }
        }
        await gate.open()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(service.isDestructiveBusy)
        XCTAssertEqual(try Data(contentsOf: file), Data("untouched fixture".utf8))
        withExtendedLifetime(subscription) {}
    }

    func testLateReturnValidationCannotDiscardANewerScan() async {
        await scan()
        let gate = CleanupReturnGate()
        let started = expectation(description: "return validation started")
        service.testPreviewValidationHandler = {
            started.fulfill()
            await gate.wait()
            return false
        }
        let returning = Task { await service.reconcilePreviewOnReturn() }
        await fulfillment(of: [started], timeout: 3)
        let fresh = expectation(description: "new scan ready")
        service.startScan { fresh.fulfill() }
        await fulfillment(of: [fresh], timeout: 3)
        service.setSelected(itemID: "return-fixture", selected: true)
        let generation = service.scanGeneration
        await gate.open()
        let reused = await returning.value
        XCTAssertFalse(reused)
        XCTAssertEqual(service.phase, .preview)
        XCTAssertEqual(service.scanGeneration, generation)
        XCTAssertEqual(service.selectedCount, 1)
        XCTAssertNil(service.preparationFailure)
    }
}
