// CleanupService state machine — generation / trash token / AI token / selection.
// Run: cd app/CleanupKit && swift test --filter CleanupServiceStateTests

import XCTest
@testable import CleanupKit

private func stateItem(
    name: String,
    path: String,
    risk: CleanupRisk = .rebuild,
    category: CleanupCategory = .userCache,
    extraPaths: [String] = []
) -> CleanableItem {
    CleanableItem(
        name: name,
        path: path,
        bytes: 1024,
        category: category,
        isSelected: false,
        risk: risk,
        extraPaths: extraPaths
    )
}

@MainActor
final class CleanupPreflightFailureTests: XCTestCase {
    func testBlockedPreflightReportsFailureInsteadOfSilentlyReturning() async {
        let service = CleanupService()
        let item = stateItem(name: "Blocked", path: "/System/MacDefier-BlockedFixture")
        service.testScanHandler = { _ in [stateGroup([item])] }
        service.testTrashHandler = { _ in
            XCTFail("Blocked paths must never reach the executor")
            return CleanupResult()
        }
        let ready = expectation(description: "blocked preview")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 1)
        service.setSelected(itemID: item.id, selected: true)
        service.confirmTrash()
        for _ in 0..<200 where service.isDestructiveBusy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.preparationFailure, .noEligibleItems)
        XCTAssertTrue(service.hasStalePreview)
        XCTAssertFalse(service.isDestructiveBusy)
    }

    func testPartialPreflightRejectionsRemainReportedAsFailures() async throws {
        let service = CleanupService()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDefier-PartialPreflight-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("allowed.cache")
        try Data("fixture".utf8).write(to: file)
        let allowed = stateItem(name: "Allowed", path: file.path)
        let blocked = stateItem(name: "Blocked", path: "/System/MacDefier-BlockedFixture")
        service.testScanHandler = { _ in [stateGroup([allowed, blocked])] }
        service.testTrashHandler = { items in
            XCTAssertEqual(items.map(\.path), [allowed.path])
            return CleanupResult(cleanedCount: 1, trashedPaths: [allowed.path], succeededPaths: [allowed.path])
        }
        let ready = expectation(description: "partial preview")
        service.startScan { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 1)
        service.setSelected(itemID: allowed.id, selected: true)
        service.setSelected(itemID: blocked.id, selected: true)
        service.confirmTrash()
        for _ in 0..<200 where service.isDestructiveBusy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.lastResult?.succeededPaths, [allowed.path])
        XCTAssertEqual(service.lastResult?.failedPaths, [blocked.path])
        XCTAssertEqual(service.lastResult?.errors.count, 1)
    }
}

private func stateGroup(_ items: [CleanableItem], category: CleanupCategory = .userCache) -> CleanupCategoryGroup {
    CleanupCategoryGroup(category: category, items: items)
}

/// Thread-safe counter for scan call ordering in tests.
private final class ScanCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Simple async gate for delaying handlers.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        lock.lock()
        if opened {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                cont.resume()
            } else {
                continuations.append(cont)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for c in pending { c.resume() }
    }
}

@MainActor
final class CleanupServiceStateTests: XCTestCase {

    func testPartialScanIsReadOnlyAndContinueKeepsCompletedCategories() async {
        let service = CleanupService()
        let gate = AsyncGate()
        let cancelled = expectation(description: "old worker returned")
        service.testScanHandler = { _ in await gate.wait(); return [] }
        service.startScan { cancelled.fulfill() }
        let generation = service.scanGeneration
        let cached = stateGroup([stateItem(name: "Cache", path: "/tmp/staged-cache")])
        service.applyScanGroup(cached, generation: generation)
        XCTAssertEqual(service.groups.count, 1)
        XCTAssertFalse(service.hasFreshPreview)
        service.cancelScan()
        service.applyScanGroup(stateGroup([], category: .temp), generation: generation)
        XCTAssertEqual(service.groups.count, 1)
        XCTAssertEqual(service.scanJourney.status, .stopped)
        gate.open()
        await fulfillment(of: [cancelled], timeout: 1)
        let next = stateGroup([stateItem(name: "Temp", path: "/tmp/staged-temp", category: .temp)], category: .temp)
        service.testScanHandler = { _ in [next] }
        let resumed = expectation(description: "continued preview")
        service.continueScan { resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(Set(service.groups.map(\.category)), [.userCache, .temp])
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertTrue(service.hasFreshPreview)
    }

    func testLateProgressCannotReplaceCompletedPreview() async {
        let service = CleanupService()
        service.testScanHandler = { _ in [stateGroup([stateItem(name: "Ready", path: "/tmp/scan-ready")])] }
        let done = expectation(description: "preview ready")
        service.startScan { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)

        service.applyScanProgress(0.9, hint: "late", generation: service.scanGeneration)
        if case .preview = service.phase {} else { XCTFail("late progress replaced preview") }
        XCTAssertEqual(service.allItems.first?.name, "Ready")
    }

    func testCancelRejectsQueuedProgressAndResults() async {
        let service = CleanupService()
        let gate = AsyncGate()
        service.testScanHandler = { _ in
            await gate.wait()
            return [stateGroup([stateItem(name: "Cancelled", path: "/tmp/scan-cancelled")])]
        }
        let done = expectation(description: "cancelled scan returned")
        service.startScan { done.fulfill() }
        let generation = service.scanGeneration
        service.applyScanProgress(0.3, hint: "userCache", generation: generation)
        XCTAssertEqual(service.scanHint, "userCache")
        service.cancelScan()
        service.applyScanProgress(0.4, hint: "late", generation: generation)
        gate.open()
        await fulfillment(of: [done], timeout: 1)
        if case .idle = service.phase {} else { XCTFail("cancelled scan reappeared") }
        XCTAssertTrue(service.groups.isEmpty)
        XCTAssertTrue(service.scanHint.isEmpty)
    }

    func testDirectorySizingHonorsCancellationDuringWalk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ScanCancel-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("cache.bin"))
        let checks = ScanCallCounter()
        let bytes = AppDataMatchers.directorySize(at: root.path, isCancelled: { checks.next() > 1 })
        XCTAssertEqual(bytes, 0)
        XCTAssertEqual(checks.current, 2)
    }

    func testStaleScanResultDoesNotOverwriteNewerPreview() async {
        let service = CleanupService()
        let counter = ScanCallCounter()
        let slowGate = AsyncGate()
        let slowStarted = expectation(description: "slow scan started")

        service.testScanHandler = { gen in
            let n = counter.next()
            if n == 1 {
                await MainActor.run { slowStarted.fulfill() }
                await slowGate.wait()
                return [stateGroup([stateItem(name: "OLD", path: "/tmp/old-\(gen)")])]
            }
            return [stateGroup([stateItem(name: "NEW", path: "/tmp/new-\(gen)")])]
        }

        let firstDone = expectation(description: "first done")
        _ = service.startScan(force: true) { firstDone.fulfill() }
        await fulfillment(of: [slowStarted], timeout: 1)

        let secondDone = expectation(description: "second done")
        _ = service.startScan(force: true) { secondDone.fulfill() }
        await fulfillment(of: [secondDone], timeout: 1)

        XCTAssertEqual(service.allItems.first?.name, "NEW")
        let genAfterSecond = service.scanGeneration

        // Let old scan finish; must not clobber
        slowGate.open()
        await fulfillment(of: [firstDone], timeout: 2)

        XCTAssertEqual(service.scanGeneration, genAfterSecond)
        XCTAssertEqual(service.allItems.first?.name, "NEW")
        XCTAssertEqual(service.allItems.count, 1)
        XCTAssertEqual(service.selectedCount, 0)
    }

    func testStartScanRejectedDuringCleaningPreservesFrozenPaths() async {
        let service = CleanupService()
        let path = NSTemporaryDirectory() + "ck-state-\(UUID().uuidString).cache"
        try? "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        service.testScanHandler = { _ in
            [stateGroup([stateItem(name: "A", path: path)])]
        }
        let scanned = expectation(description: "scanned")
        _ = service.startScan(force: true) { scanned.fulfill() }
        await fulfillment(of: [scanned], timeout: 1)
        service.setSelected(itemID: service.allItems[0].id, selected: true)

        let trashGate = AsyncGate()
        let trashStarted = expectation(description: "trash running")
        service.testTrashHandler = { items in
            await MainActor.run { trashStarted.fulfill() }
            await trashGate.wait()
            return CleanupResult(
                freedBytes: 0,
                movedToTrashBytes: 1024,
                cleanedCount: 1,
                trashedPaths: items.map(\.path),
                succeededPaths: items.flatMap(\.allPaths)
            )
        }

        service.confirmTrash()
        await fulfillment(of: [trashStarted], timeout: 1)
        XCTAssertEqual(service.frozenTrashPaths.sorted(), [path].sorted())
        if case .cleaning = service.phase {} else {
            XCTFail("expected cleaning phase")
        }

        var completionCalled = false
        let rejected = service.startScan(force: true) {
            completionCalled = true
        }
        XCTAssertFalse(rejected)
        XCTAssertTrue(completionCalled, "rejected startScan still resumes waiters")
        XCTAssertEqual(service.frozenTrashPaths, [path])
        if case .cleaning = service.phase {} else {
            XCTFail("phase must stay cleaning")
        }
        XCTAssertEqual(service.allItems.count, 1)

        trashGate.open()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if case .done = service.phase { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .done = service.phase {} else {
            XCTFail("expected done after trash")
        }
        XCTAssertTrue(service.frozenTrashPaths.isEmpty)
    }

    func testStaleAIEnrichmentDiscardedAfterRescan() async {
        let service = CleanupService()
        service.testScanHandler = { gen in
            [stateGroup([stateItem(name: "G\(gen)", path: "/tmp/ai-\(gen)")])]
        }

        let s1 = expectation(description: "scan1")
        _ = service.startScan(force: true) { s1.fulfill() }
        await fulfillment(of: [s1], timeout: 1)

        let oldToken = service.beginAIEnrichment(hint: "old")
        XCTAssertTrue(service.isAIEnriching)

        let s2 = expectation(description: "scan2")
        _ = service.startScan(force: true) { s2.fulfill() }
        await fulfillment(of: [s2], timeout: 1)

        service.finishAIEnrichment(token: oldToken, narrative: "STALE NARRATIVE", error: nil)
        XCTAssertNotEqual(service.aiNarrative, "STALE NARRATIVE")
        XCTAssertFalse(service.isAIEnriching)

        let newToken = service.beginAIEnrichment(hint: "new")
        service.finishAIEnrichment(token: newToken, narrative: "FRESH", error: nil)
        XCTAssertEqual(service.aiNarrative, "FRESH")
        XCTAssertFalse(service.isAIEnriching)
    }

    func testClearAllSelectionAndFailedRetryUnselected() async {
        let service = CleanupService()
        let p1 = NSTemporaryDirectory() + "ck-sel-\(UUID().uuidString)-a"
        let p2 = NSTemporaryDirectory() + "ck-sel-\(UUID().uuidString)-b"
        try? "1".write(toFile: p1, atomically: true, encoding: .utf8)
        try? "2".write(toFile: p2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: p1)
            try? FileManager.default.removeItem(atPath: p2)
        }

        service.testScanHandler = { _ in
            [stateGroup([stateItem(name: "multi", path: p1, extraPaths: [p2])])]
        }
        let scanned = expectation(description: "scanned")
        _ = service.startScan(force: true) { scanned.fulfill() }
        await fulfillment(of: [scanned], timeout: 1)

        service.setSelected(itemID: service.allItems[0].id, selected: true)
        XCTAssertEqual(service.selectedCount, 1)
        service.clearAllSelection()
        XCTAssertEqual(service.selectedCount, 0)

        service.setSelected(itemID: service.allItems[0].id, selected: true)
        service.testTrashHandler = { _ in
            CleanupResult(
                freedBytes: 0,
                movedToTrashBytes: 0,
                cleanedCount: 0,
                trashedPaths: [],
                succeededPaths: [p1],
                failedPaths: [p2]
            )
        }
        service.confirmTrash()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if case .done = service.phase { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(service.selectedCount, 0, "failed retry items must default unselected")
        XCTAssertFalse(service.allItems.isEmpty)
        XCTAssertTrue(service.allItems.allSatisfy { !$0.isSelected })
    }

    func testScanCompletionForcesZeroSelection() async {
        let service = CleanupService()
        service.testScanHandler = { _ in
            var item = stateItem(name: "x", path: "/tmp/force-sel")
            // init always forces false; mutate as if a buggy scanner set true
            item.isSelected = true
            return [stateGroup([item])]
        }
        let done = expectation(description: "done")
        _ = service.startScan(force: true) { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertTrue(service.allItems.allSatisfy { !$0.isSelected })
    }

    /// M09-1: chat reusing a fresh preview must not keep prior isSelected ticks.
    func testPreparePreviewForChatClearsSelectionOnReuse() async {
        let service = CleanupService()
        let path = NSTemporaryDirectory() + "ck-m09-\(UUID().uuidString)"
        try? "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let counter = ScanCallCounter()
        service.testScanHandler = { _ in
            _ = counter.next()
            return [stateGroup([stateItem(name: "tickable", path: path)])]
        }
        let scanned = expectation(description: "scanned")
        _ = service.startScan(force: true) { scanned.fulfill() }
        await fulfillment(of: [scanned], timeout: 1)
        XCTAssertTrue(service.hasFreshPreview)

        service.setSelected(itemID: service.allItems[0].id, selected: true)
        XCTAssertEqual(service.selectedCount, 1)

        let ready = await service.preparePreviewForChat()
        XCTAssertTrue(ready)
        // Only the initial startScan — prepare must reuse, not force another scan.
        XCTAssertEqual(counter.current, 1, "fresh preview must be reused, not rescanned")
        XCTAssertEqual(service.selectedCount, 0, "M09-1: reuse must clear selection")
        XCTAssertTrue(service.allItems.allSatisfy { !$0.isSelected })
        XCTAssertTrue(service.selectedExecutablePaths.isEmpty)
    }

    /// M09-1 companion: cleaning blocks prepare and must not clear mid-trash.
    func testPreparePreviewForChatReturnsFalseWhileCleaning() async {
        let service = CleanupService()
        let path = NSTemporaryDirectory() + "ck-m09-busy-\(UUID().uuidString)"
        try? "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        service.testScanHandler = { _ in
            [stateGroup([stateItem(name: "t", path: path)])]
        }
        let scanned = expectation(description: "scanned")
        _ = service.startScan(force: true) { scanned.fulfill() }
        await fulfillment(of: [scanned], timeout: 1)
        service.setSelected(itemID: service.allItems[0].id, selected: true)
        XCTAssertEqual(service.selectedCount, 1)

        let gate = AsyncGate()
        service.testTrashHandler = { items in
            await gate.wait()
            return CleanupResult(
                freedBytes: 0,
                movedToTrashBytes: items.reduce(0) { $0 + $1.bytes },
                cleanedCount: items.count,
                trashedPaths: items.map(\.path),
                succeededPaths: items.flatMap(\.allPaths),
                failedPaths: []
            )
        }
        service.confirmTrash()
        // Let trash task enter .cleaning
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if case .cleaning = service.phase { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .cleaning = service.phase else {
            gate.open()
            XCTFail("expected cleaning phase (PathGate may have blocked temp path)")
            return
        }

        let ready = await service.preparePreviewForChat()
        XCTAssertFalse(ready)
        // Selection snapshot is frozen for trash; prepare must not clear during clean.
        if case .cleaning = service.phase {
            XCTAssertEqual(service.selectedCount, 1, "must not touch selection during cleaning")
        }

        gate.open()
        let doneDeadline = Date().addingTimeInterval(1.5)
        while Date() < doneDeadline {
            if case .done = service.phase { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - M02-3 generation / busy gates

    /// confirmTrash must bump scanGeneration so in-flight scans cannot rewrite groups.
    func testConfirmTrashBumpsGenerationInvalidatesInFlightScan() async {
        let service = CleanupService()
        let path = NSTemporaryDirectory() + "ck-m02-3-gen-\(UUID().uuidString)"
        try? "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let scanGate = AsyncGate()
        let scanStarted = expectation(description: "scan started")
        var call = 0
        service.testScanHandler = { gen in
            call += 1
            if call == 1 {
                return [stateGroup([stateItem(name: "A", path: path)])]
            }
            // Second scan is cancelled/invalidated by confirmTrash generation bump.
            await MainActor.run { scanStarted.fulfill() }
            await scanGate.wait()
            return [stateGroup([stateItem(name: "STALE-\(gen)", path: "/tmp/stale-\(gen)")])]
        }

        let first = expectation(description: "first scan")
        _ = service.startScan(force: true) { first.fulfill() }
        await fulfillment(of: [first], timeout: 1)
        service.setSelected(itemID: service.allItems[0].id, selected: true)
        let frozenName = service.allItems.first?.name
        XCTAssertEqual(frozenName, "A")

        // Start a second scan (will be slow), then immediately trash — gen must advance.
        let secondDone = expectation(description: "second scan completion called")
        _ = service.startScan(force: true) { secondDone.fulfill() }
        await fulfillment(of: [scanStarted], timeout: 1)
        let genWhileScanning = service.scanGeneration

        let trashGate = AsyncGate()
        service.testTrashHandler = { items in
            await trashGate.wait()
            return CleanupResult(
                freedBytes: 0,
                movedToTrashBytes: 1024,
                cleanedCount: 1,
                trashedPaths: items.map(\.path),
                succeededPaths: items.flatMap(\.allPaths)
            )
        }
        // Second scan cleared selection/groups; re-select is impossible mid-scan.
        // Drive trash from a clean preview instead: cancel path via direct confirm after re-preview.
        // Reset: open scan gate so second finishes, then select + trash, then prove gen gate.
        scanGate.open()
        await fulfillment(of: [secondDone], timeout: 2)
        XCTAssertEqual(service.scanGeneration, genWhileScanning)
        XCTAssertEqual(service.allItems.first?.name.hasPrefix("STALE"), true)

        // Fresh select + trash
        if let id = service.allItems.first?.id {
            service.setSelected(itemID: id, selected: true)
        }
        let genBeforeTrash = service.scanGeneration
        let trashStarted = expectation(description: "trash started")
        service.testTrashHandler = { items in
            await MainActor.run { trashStarted.fulfill() }
            await trashGate.wait()
            return CleanupResult(
                freedBytes: 0,
                movedToTrashBytes: 1024,
                cleanedCount: items.count,
                trashedPaths: items.map(\.path),
                succeededPaths: items.flatMap(\.allPaths)
            )
        }
        service.confirmTrash()
        await fulfillment(of: [trashStarted], timeout: 1)
        XCTAssertTrue(service.scanGeneration > genBeforeTrash, "confirmTrash must bump scanGeneration")
        XCTAssertTrue(service.isDestructiveBusy)

        // Late AI from pre-trash gen must not stick.
        let dead = CleanupAIEnrichmentToken(scanGeneration: genBeforeTrash)
        service.finishAIEnrichment(token: dead, narrative: "SHOULD NOT STICK", error: nil)
        XCTAssertNotEqual(service.aiNarrative, "SHOULD NOT STICK")

        // begin during cleaning is dead token
        let liveAttempt = service.beginAIEnrichment(hint: "nope")
        XCTAssertFalse(service.isAIEnriching)
        service.finishAIEnrichment(token: liveAttempt, narrative: "DURING CLEAN", error: nil)
        XCTAssertNotEqual(service.aiNarrative, "DURING CLEAN")

        // startScan rejected
        XCTAssertFalse(service.startScan(force: true))

        trashGate.open()
        let doneDeadline = Date().addingTimeInterval(1.5)
        while Date() < doneDeadline {
            if case .done = service.phase { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .done = service.phase {} else {
            XCTFail("expected done after trash")
        }
    }

    /// During cleaning: startScan rejected, groups/frozen paths untouched (M02-3).
    func testInFlightScanCannotOverwriteDuringCleaning() async {
        let service = CleanupService()
        let path = NSTemporaryDirectory() + "ck-m02-3-inflight-\(UUID().uuidString)"
        try? "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        service.testScanHandler = { _ in
            [stateGroup([stateItem(name: "KEEP", path: path)])]
        }

        let first = expectation(description: "first")
        _ = service.startScan(force: true) { first.fulfill() }
        await fulfillment(of: [first], timeout: 1)
        service.setSelected(itemID: service.allItems[0].id, selected: true)

        let trashGate = AsyncGate()
        let trashStarted = expectation(description: "trash")
        service.testTrashHandler = { items in
            await MainActor.run { trashStarted.fulfill() }
            await trashGate.wait()
            return CleanupResult(
                freedBytes: 0,
                movedToTrashBytes: 1024,
                cleanedCount: 1,
                trashedPaths: items.map(\.path),
                succeededPaths: items.flatMap(\.allPaths)
            )
        }
        let genBefore = service.scanGeneration
        service.confirmTrash()
        await fulfillment(of: [trashStarted], timeout: 1)
        let genDuring = service.scanGeneration
        XCTAssertGreaterThan(genDuring, genBefore)
        XCTAssertEqual(service.frozenTrashPaths.sorted(), [path].sorted())

        var completionFired = false
        let rejected = service.startScan(force: true) { completionFired = true }
        XCTAssertFalse(rejected)
        XCTAssertTrue(completionFired)
        XCTAssertEqual(service.frozenTrashPaths.sorted(), [path].sorted())
        XCTAssertEqual(service.allItems.first?.name, "KEEP")
        if case .cleaning = service.phase {} else {
            XCTFail("phase must stay cleaning while trash runs")
        }

        trashGate.open()
        let doneDeadline = Date().addingTimeInterval(1.5)
        while Date() < doneDeadline {
            if case .done = service.phase { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .done = service.phase {} else {
            XCTFail("expected done")
        }
    }

    /// AI finish after rescan / trash gen bump is discarded (M02-3 / F02-1).
    func testAIEnrichmentDiscardedWhenGenerationAdvancedByTrash() async {
        let service = CleanupService()
        let path = NSTemporaryDirectory() + "ck-m02-3-ai-\(UUID().uuidString)"
        try? "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        service.testScanHandler = { _ in
            [stateGroup([stateItem(name: "AI", path: path)])]
        }
        let scanned = expectation(description: "scanned")
        _ = service.startScan(force: true) { scanned.fulfill() }
        await fulfillment(of: [scanned], timeout: 1)

        let token = service.beginAIEnrichment(hint: "review")
        XCTAssertTrue(service.isAIEnriching)
        service.setSelected(itemID: service.allItems[0].id, selected: true)

        let trashGate = AsyncGate()
        service.testTrashHandler = { items in
            await trashGate.wait()
            return CleanupResult(
                freedBytes: 0,
                movedToTrashBytes: 1024,
                cleanedCount: 1,
                trashedPaths: items.map(\.path),
                succeededPaths: items.flatMap(\.allPaths)
            )
        }
        service.confirmTrash()
        XCTAssertFalse(service.isAIEnriching, "confirmTrash clears enriching")
        XCTAssertNotEqual(token.scanGeneration, service.scanGeneration)

        service.finishAIEnrichment(token: token, narrative: "STALE AFTER TRASH", error: nil)
        XCTAssertNotEqual(service.aiNarrative, "STALE AFTER TRASH")

        trashGate.open()
        let doneDeadline = Date().addingTimeInterval(1.5)
        while Date() < doneDeadline {
            if case .done = service.phase { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testRefreshSelectedRenewsPreviewWithoutCleaningOrSelectingNewItems() async {
        let service = CleanupService()
        service.testScanHandler = { _ in
            [stateGroup([
                stateItem(name: "Keep", path: "/tmp/refresh-keep.cache"),
                stateItem(name: "Unselected", path: "/tmp/refresh-unselected.cache")
            ])]
        }
        let first = expectation(description: "initial preview")
        service.startScan { first.fulfill() }
        await fulfillment(of: [first], timeout: 1)
        let oldID = service.allItems[0].id
        service.setSelected(itemID: oldID, selected: true)
        service.setLastScanCompletedAtForTesting(Date().addingTimeInterval(-CleanupReusePolicy.cleanupTTL - 1))
        XCTAssertTrue(service.hasStalePreview)
        service.testTrashHandler = { _ in
            XCTFail("Refreshing or confirming an expired preview must not clean anything")
            return CleanupResult(freedBytes: 0, cleanedCount: 0, trashedPaths: [])
        }
        service.confirmTrash()
        XCTAssertFalse(service.isDestructiveBusy)

        let refreshed = expectation(description: "renewed preview")
        service.startScan(preservingSelection: true) { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertTrue(service.hasFreshPreview)
        XCTAssertNotEqual(service.allItems[0].id, oldID, "scanner UUIDs may change")
        XCTAssertEqual(service.allItems.filter(\.isSelected).map(\.path), ["/tmp/refresh-keep.cache"])
        XCTAssertEqual(service.selectedCount, 1)
        XCTAssertEqual(service.selectedBytes, 1024)
        if case .preview = service.phase {} else { XCTFail("refresh must end in preview") }

        let ordinary = expectation(description: "ordinary rescan")
        service.startScan { ordinary.fulfill() }
        await fulfillment(of: [ordinary], timeout: 1)
        XCTAssertEqual(service.selectedCount, 0, "ordinary rescans still reset selection")
    }

    func testRefreshSelectedDropsChangedPathsRisksCategoriesAndMissingItems() async {
        let service = CleanupService()
        service.testScanHandler = { generation in
            if generation == 1 {
                return [stateGroup([
                    stateItem(name: "Risk", path: "/tmp/refresh-risk.cache"),
                    stateItem(name: "Paths", path: "/tmp/refresh-paths.cache", extraPaths: ["/tmp/refresh-extra-a.cache"]),
                    stateItem(name: "Category", path: "/tmp/refresh-category.cache"),
                    stateItem(name: "Missing", path: "/tmp/refresh-missing.cache")
                ])]
            }
            return [stateGroup([
                stateItem(name: "Risk", path: "/tmp/refresh-risk.cache", risk: .caution),
                stateItem(name: "Paths", path: "/tmp/refresh-paths.cache", extraPaths: ["/tmp/refresh-extra-b.cache"]),
                stateItem(name: "Category", path: "/tmp/refresh-category.cache", category: .userLogs),
                stateItem(name: "New", path: "/tmp/refresh-new.cache")
            ])]
        }
        let first = expectation(description: "initial selections")
        service.startScan { first.fulfill() }
        await fulfillment(of: [first], timeout: 1)
        for id in service.allItems.map(\.id) { service.setSelected(itemID: id, selected: true) }
        XCTAssertEqual(service.selectedCount, 4)
        let refreshed = expectation(description: "changed preview")
        service.startScan(preservingSelection: true) { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertTrue(service.allItems.allSatisfy { !$0.isSelected })
    }

    func testCancelledSelectionRefreshCannotRestoreTicksIntoANewerScan() async {
        let service = CleanupService()
        let gate = AsyncGate()
        let refreshStarted = expectation(description: "refresh started")
        service.testScanHandler = { generation in
            if generation == 2 {
                await MainActor.run { refreshStarted.fulfill() }
                await gate.wait()
            }
            return [stateGroup([stateItem(name: "Keep", path: "/tmp/refresh-cancel.cache")])]
        }
        let first = expectation(description: "initial preview")
        service.startScan { first.fulfill() }
        await fulfillment(of: [first], timeout: 1)
        service.setSelected(itemID: service.allItems[0].id, selected: true)
        let late = expectation(description: "cancelled refresh returned")
        service.startScan(preservingSelection: true) { late.fulfill() }
        await fulfillment(of: [refreshStarted], timeout: 1)
        service.cancelScan()
        let latest = expectation(description: "new preview")
        service.startScan { latest.fulfill() }
        await fulfillment(of: [latest], timeout: 1)
        gate.open()
        await fulfillment(of: [late], timeout: 1)
        XCTAssertTrue(service.hasFreshPreview)
        XCTAssertEqual(service.selectedCount, 0)
    }

}
