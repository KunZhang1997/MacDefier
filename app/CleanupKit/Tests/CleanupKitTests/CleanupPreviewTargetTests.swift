import XCTest
@testable import CleanupKit

private actor PreviewTargetGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
final class CleanupPreviewTargetTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var first: URL!
    private var second: URL!
    private var alias: URL!
    private var service: CleanupService!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("MacDefier-preview-target-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        first = root.appendingPathComponent("first")
        second = root.appendingPathComponent("second")
        alias = root.appendingPathComponent("current")
        for directory in [first!, second!] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 65, count: 32).write(to: directory.appendingPathComponent("payload.cache"))
        }
        try fm.createSymbolicLink(at: alias, withDestinationURL: first)
        service = CleanupService()
    }

    override func tearDownWithError() throws {
        service.reset()
        service = nil
        // Only this test's UUID-owned fixture is removable.
        if let root, root.lastPathComponent.hasPrefix("MacDefier-preview-target-") {
            try fm.removeItem(at: root)
        }
    }

    private var requested: String { alias.appendingPathComponent("payload.cache").path }
    private var firstFile: URL { first.appendingPathComponent("payload.cache") }
    private var secondFile: URL { second.appendingPathComponent("payload.cache") }

    private func candidate(path: String? = nil, extras: [String] = []) -> CleanableItem {
        CleanableItem(id: "candidate", name: "payload.cache", path: path ?? requested,
                      bytes: 32, category: .userCache, isSelected: false, risk: .rebuild,
                      extraPaths: extras)
    }

    private func scan(_ item: CleanableItem, preservingSelection: Bool = false) async {
        service.testScanHandler = { _ in [CleanupCategoryGroup(category: .userCache, items: [item])] }
        let ready = expectation(description: "preview ready")
        service.startScan(force: true, preservingSelection: preservingSelection) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertTrue(service.hasFreshPreview)
    }

    private func retarget() throws {
        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(at: alias, withDestinationURL: second)
        XCTAssertTrue(PathGate.isSafeToTrash(requested), "Both targets are allowed fixture paths")
        XCTAssertEqual(PathGate.normalize(requested), secondFile.path)
    }

    private func waitForCleanup() async {
        let deadline = Date().addingTimeInterval(3)
        while service.isDestructiveBusy, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(service.isDestructiveBusy, "cleanup must settle within the fixture deadline")
    }

    /// Exercise the real facade's authorization and result handling. Replace only
    /// the OS Trash side effect with a move inside the UUID-owned fixture.
    private func installIsolatedMover() {
        let fixtureRoot = root!
        service.testTrashHandler = { items in
            var result = CleanupResult()
            for item in items {
                for path in item.allPaths {
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    guard resolved.hasPrefix(fixtureRoot.path + "/") else {
                        result.failedPaths.append(path)
                        result.errors.append("fixture boundary refused")
                        continue
                    }
                    do {
                        let destination = fixtureRoot.appendingPathComponent("recycled-" + UUID().uuidString)
                        try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: destination)
                        result.succeededPaths.append(path)
                    } catch {
                        result.failedPaths.append(path)
                        result.errors.append("fixture move failed")
                    }
                }
                if item.allPaths.allSatisfy({ result.succeededPaths.contains($0) }) {
                    result.trashedPaths.append(item.path)
                    result.cleanedCount += 1
                }
            }
            return result
        }
    }

    func testRetargetedIntermediateSymlinkIsNotExecutable() async throws {
        await scan(candidate())
        service.setSelected(itemID: "candidate", selected: true)
        let oldTargets = service.selectedExecutablePaths
        try retarget()
        let newTargets = service.selectedExecutablePaths
        print("AUDIT case=retarget-preflight before_count=\(oldTargets.count) after_count=\(newTargets.count) gate_allows_new=true")
        XCTAssertEqual(oldTargets, [firstFile.path])
        XCTAssertTrue(newTargets.isEmpty, "An old preview must not authorize a different allowed target")
    }

    func testRetargetBeforeConfirmPreservesUnpreviewedDataAndExpiresPreview() async throws {
        await scan(candidate())
        service.setSelected(itemID: "candidate", selected: true)
        try retarget()
        installIsolatedMover()
        service.confirmTrash()
        await waitForCleanup()
        let firstExists = fm.fileExists(atPath: firstFile.path)
        let secondExists = fm.fileExists(atPath: secondFile.path)
        print("AUDIT case=retarget-confirm first_exists=\(firstExists) unpreviewed_exists=\(secondExists) submitted_successes=\(service.lastResult?.succeededPaths.count ?? 0)")
        XCTAssertTrue(firstExists)
        XCTAssertTrue(secondExists, "The newly pointed-to file was never previewed or approved")
        XCTAssertTrue(service.hasStalePreview, "User must be prompted through the existing rescan flow")
        XCTAssertEqual(service.selectedCount, 0)
    }

    func testRetargetedExtraPathStopsWholeConfirmation() async throws {
        await scan(candidate(path: firstFile.path, extras: [requested]))
        service.setSelected(itemID: "candidate", selected: true)
        try retarget()
        installIsolatedMover()
        service.confirmTrash()
        await waitForCleanup()
        XCTAssertTrue(fm.fileExists(atPath: firstFile.path))
        XCTAssertTrue(fm.fileExists(atPath: secondFile.path))
        XCTAssertTrue(service.hasStalePreview)
    }

    func testUnchangedTargetCompletesAndSecondScanStillWorks() async throws {
        await scan(candidate())
        service.setSelected(itemID: "candidate", selected: true)
        installIsolatedMover()
        service.confirmTrash()
        await waitForCleanup()
        XCTAssertEqual(service.lastResult?.cleanedCount, 1)
        XCTAssertFalse(fm.fileExists(atPath: firstFile.path))
        XCTAssertTrue(fm.fileExists(atPath: secondFile.path))
        XCTAssertEqual(service.lastResult?.freedBytes, 0)

        try retarget()
        await scan(candidate())
        XCTAssertEqual(service.selectedCount, 0)
        service.setSelected(itemID: "candidate", selected: true)
        service.confirmTrash()
        await waitForCleanup()
        XCTAssertEqual(service.lastResult?.cleanedCount, 1)
        XCTAssertFalse(fm.fileExists(atPath: secondFile.path))
    }

    func testRescanDoesNotRestoreSelectionForChangedTarget() async throws {
        await scan(candidate())
        service.setSelected(itemID: "candidate", selected: true)
        try retarget()
        await scan(candidate(), preservingSelection: true)
        XCTAssertEqual(service.selectedCount, 0)
        service.setSelected(itemID: "candidate", selected: true)
        XCTAssertEqual(service.selectedExecutablePaths, [secondFile.path], "New explicit approval may use the new target")
    }

    func testFailureKeepsDataAndReportsNoSuccess() async {
        await scan(candidate())
        service.setSelected(itemID: "candidate", selected: true)
        service.testTrashHandler = { items in
            CleanupResult(errors: ["injected EACCES"], failedPaths: items.flatMap(\.allPaths))
        }
        service.confirmTrash()
        await waitForCleanup()
        XCTAssertEqual(service.lastResult?.cleanedCount, 0)
        XCTAssertEqual(service.lastResult?.failedPaths.count, 1)
        XCTAssertEqual(service.lastResult?.freedBytes, 0)
        XCTAssertTrue(fm.fileExists(atPath: firstFile.path))
        XCTAssertEqual(service.selectedCount, 0)
    }

    func testCancelledScanArrivingLateCannotReplaceNewPreview() async {
        let gate = PreviewTargetGate()
        let started = expectation(description: "old scan started")
        let finished = expectation(description: "old scan settled")
        let old = candidate()
        service.testScanHandler = { _ in
            started.fulfill()
            await gate.wait()
            return [CleanupCategoryGroup(category: .userCache, items: [old])]
        }
        service.startScan { finished.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        service.cancelScan()
        await scan(candidate(path: secondFile.path))
        await gate.open()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(service.allItems.map(\.path), [secondFile.path])
        XCTAssertEqual(service.selectedCount, 0)
        XCTAssertTrue(service.hasFreshPreview)
    }
}
