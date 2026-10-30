import Combine
import Foundation
import XCTest
@testable import CleanupKit

// All inventory and sizing operations are injected. These paths are identifiers,
// not real app bundles; no test enumerates Applications or writes scan history.
private func queueApp(_ name: String) -> InstalledApp {
    InstalledApp(name: name, bundleIdentifier: "invalid.fixture.\(name)",
                 path: "/not-a-real-volume/SoftwareSizeFixture/\(name).app", version: "1",
                 bytes: 0, isSystemLocation: false, canTrashAppBundle: false,
                 sizeState: .pending)
}

private func measuredApp(_ app: InstalledApp, bytes: UInt64) -> InstalledApp {
    InstalledApp(name: app.name, bundleIdentifier: app.bundleIdentifier,
                 path: app.path, version: app.version, bytes: bytes,
                 isSystemLocation: app.isSystemLocation, canTrashAppBundle: app.canTrashAppBundle,
                 sizeState: .measured)
}

private final class SizeQueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let ready = opened
            if !ready { waiters.append(continuation) }
            lock.unlock()
            if ready { continuation.resume() }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class SizeQueueRecorder: @unchecked Sendable {
    struct Snapshot {
        var inventoryCalls = 0
        var paths: [String] = []
        var active = 0
        var maximumActive = 0
        var ranOnMainThread = false
        var cancelledHandlers = 0
    }
    private let lock = NSLock()
    private var state = Snapshot()

    func inventory() {
        lock.lock()
        state.inventoryCalls += 1
        state.ranOnMainThread = state.ranOnMainThread || Thread.isMainThread
        lock.unlock()
    }

    @discardableResult
    func begin(_ app: InstalledApp) -> Int {
        lock.lock()
        defer { lock.unlock() }
        state.paths.append(app.path)
        state.active += 1
        state.maximumActive = max(state.maximumActive, state.active)
        state.ranOnMainThread = state.ranOnMainThread || Thread.isMainThread
        return state.paths.filter { $0 == app.path }.count
    }

    func end(cancelled: Bool) {
        lock.lock()
        state.active -= 1
        if cancelled { state.cancelledHandlers += 1 }
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

@MainActor
final class SoftwareSizeQueueTests: XCTestCase {
    private enum WaitFailure: Error { case timedOut }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail(description, file: file, line: line)
                throw WaitFailure.timedOut
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testRefreshAutomaticallyMeasuresEveryAppIncludingZeroBytes() async throws {
        let service = SoftwareService()
        defer { service.cancelInventoryWork() }
        let apps = [queueApp("Empty"), queueApp("One"), queueApp("Two")]
        let recorder = SizeQueueRecorder()
        service.testInventoryHandler = { recorder.inventory(); return apps }
        service.testSizeHandler = { app in
            recorder.begin(app)
            defer { recorder.end(cancelled: Task.isCancelled) }
            return measuredApp(app, bytes: app.name == "Empty" ? 0 : 4096)
        }
        let metadataReady = expectation(description: "metadata ready")
        service.refresh { metadataReady.fulfill() }
        await fulfillment(of: [metadataReady], timeout: 3)
        try await waitUntil("all app sizes finish automatically") {
            service.completedSizeCount == apps.count && !service.isSizingApps
        }
        XCTAssertEqual(service.apps.map(\.sizeState), [.measured, .measured, .measured])
        XCTAssertEqual(service.apps.first(where: { $0.name == "Empty" })?.totalBytes, 0)
        XCTAssertEqual(Set(recorder.snapshot.paths), Set(apps.map(\.path)))
        XCTAssertEqual(recorder.snapshot.paths.count, apps.count)
        XCTAssertFalse(service.isLoading)
    }

    func testSizingIsSerialOffMainThreadAndMetadataDoesNotWaitForIt() async throws {
        let service = SoftwareService()
        let gate = SizeQueueGate()
        defer { service.cancelInventoryWork(); gate.open() }
        let apps = (0..<8).map { queueApp("App\($0)") }
        let recorder = SizeQueueRecorder()
        service.testInventoryHandler = { recorder.inventory(); return apps }
        service.testSizeHandler = { app in
            recorder.begin(app)
            defer { recorder.end(cancelled: Task.isCancelled) }
            await gate.wait()
            return measuredApp(app, bytes: 128)
        }
        let metadataReady = expectation(description: "metadata completes before sizes")
        service.refresh { metadataReady.fulfill() }
        await fulfillment(of: [metadataReady], timeout: 3)
        try await waitUntil("first size begins") { recorder.snapshot.active == 1 }
        XCTAssertFalse(service.isLoading)
        XCTAssertTrue(service.isSizingApps)
        XCTAssertEqual(service.apps.count, apps.count)
        XCTAssertEqual(service.completedSizeCount, 0)
        XCTAssertEqual(recorder.snapshot.paths.count, 1)
        gate.open()
        try await waitUntil("serial queue completes") {
            service.completedSizeCount == apps.count && !service.isSizingApps
        }
        XCTAssertEqual(recorder.snapshot.maximumActive, 1)
        XCTAssertEqual(recorder.snapshot.paths, apps.map(\.path))
        XCTAssertFalse(recorder.snapshot.ranOnMainThread)
    }

    func testCancelledOldSizeCannotOverwriteNewRefreshAtSamePath() async throws {
        let service = SoftwareService()
        let oldGate = SizeQueueGate()
        defer { service.cancelInventoryWork(); oldGate.open() }
        let app = queueApp("SamePath")
        let oldStarted = expectation(description: "old size starts")
        let oldReturned = expectation(description: "cancelled handler returns late")
        service.testInventoryHandler = { [app] }
        service.testSizeHandler = { app in
            oldStarted.fulfill()
            await oldGate.wait() // Deliberately ignores cancellation to test the generation gate.
            oldReturned.fulfill()
            return measuredApp(app, bytes: 111)
        }
        service.refresh()
        await fulfillment(of: [oldStarted], timeout: 3)
        service.cancelInventoryWork()
        XCTAssertFalse(service.isSizingApps)
        service.testSizeHandler = { measuredApp($0, bytes: 999) }
        service.refresh()
        let stalePublish = expectation(description: "old size must never publish")
        stalePublish.isInverted = true
        let subscription = service.$apps.sink { apps in
            if apps.contains(where: { $0.bytes == 111 }) { stalePublish.fulfill() }
        }
        defer { subscription.cancel() }
        oldGate.open()
        await fulfillment(of: [oldReturned], timeout: 3)
        try await waitUntil("new generation is measured") {
            service.apps.first?.bytes == 999 && !service.isSizingApps
        }
        await fulfillment(of: [stalePublish], timeout: 0.2)
        XCTAssertEqual(service.apps.first?.bytes, 999)
        XCTAssertEqual(service.completedSizeCount, 1)
        XCTAssertFalse(service.isSizingApps)
    }

    func testFreshRefreshResumesPendingSizesWithoutEnumeratingAgain() async throws {
        let service = SoftwareService()
        let gate = SizeQueueGate()
        defer { service.cancelInventoryWork(); gate.open() }
        let apps = [queueApp("Done"), queueApp("Interrupted"), queueApp("Waiting")]
        let recorder = SizeQueueRecorder()
        let interruptedStarted = expectation(description: "second item begins")
        let interruptedReturned = expectation(description: "cancelled second item returns")
        service.testInventoryHandler = { recorder.inventory(); return apps }
        service.testSizeHandler = { app in
            let attempt = recorder.begin(app)
            defer { recorder.end(cancelled: Task.isCancelled) }
            if app.name == "Interrupted", attempt == 1 {
                interruptedStarted.fulfill()
                await gate.wait()
                interruptedReturned.fulfill()
            }
            return measuredApp(app, bytes: 64)
        }
        service.refresh()
        await fulfillment(of: [interruptedStarted], timeout: 3)
        XCTAssertEqual(service.completedSizeCount, 1)
        XCTAssertTrue(service.hasFreshInventory)
        service.cancelInventoryWork()
        gate.open()
        await fulfillment(of: [interruptedReturned], timeout: 3)
        let resumed = expectation(description: "fresh metadata reused")
        service.refresh(force: false) { resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 3)
        try await waitUntil("pending sizes resume") {
            service.completedSizeCount == apps.count && !service.isSizingApps
        }
        XCTAssertEqual(recorder.snapshot.inventoryCalls, 1)
        XCTAssertEqual(recorder.snapshot.paths.filter { $0 == apps[0].path }.count, 1)
        XCTAssertEqual(recorder.snapshot.paths.filter { $0 == apps[1].path }.count, 2)
        XCTAssertEqual(recorder.snapshot.paths.filter { $0 == apps[2].path }.count, 1)
    }

    func testLoadSizeDoesNotCancelMetadataEnumeration() async throws {
        let service = SoftwareService()
        let gate = SizeQueueGate()
        defer { service.cancelInventoryWork(); gate.open() }
        let app = queueApp("MetadataPending")
        let recorder = SizeQueueRecorder()
        let metadataStarted = expectation(description: "metadata starts")
        let metadataReady = expectation(description: "metadata finishes once")
        service.testInventoryHandler = {
            recorder.inventory()
            metadataStarted.fulfill()
            await gate.wait()
            XCTAssertFalse(Task.isCancelled, "loadSize must not cancel inventory")
            return [app]
        }
        service.testSizeHandler = { app in
            recorder.begin(app)
            defer { recorder.end(cancelled: Task.isCancelled) }
            return measuredApp(app, bytes: 512)
        }
        service.refresh { metadataReady.fulfill() }
        await fulfillment(of: [metadataStarted], timeout: 3)
        service.loadSize(for: app)
        XCTAssertTrue(service.isLoading)
        XCTAssertTrue(recorder.snapshot.paths.isEmpty)
        gate.open()
        await fulfillment(of: [metadataReady], timeout: 3)
        try await waitUntil("automatic size follows metadata") {
            service.completedSizeCount == 1 && !service.isSizingApps
        }
        XCTAssertEqual(recorder.snapshot.inventoryCalls, 1)
        XCTAssertEqual(recorder.snapshot.paths, [app.path])
    }

    func testLoadSizeDoesNotRestartOrCancelActiveAllAppQueue() async throws {
        let service = SoftwareService()
        let gate = SizeQueueGate()
        defer { service.cancelInventoryWork(); gate.open() }
        let apps = [queueApp("First"), queueApp("Second"), queueApp("Third")]
        let recorder = SizeQueueRecorder()
        let firstStarted = expectation(description: "first size starts")
        service.testInventoryHandler = { recorder.inventory(); return apps }
        service.testSizeHandler = { app in
            recorder.begin(app)
            defer { recorder.end(cancelled: Task.isCancelled) }
            if app.path == apps[0].path {
                firstStarted.fulfill()
                await gate.wait()
            }
            return measuredApp(app, bytes: 256)
        }
        service.refresh()
        await fulfillment(of: [firstStarted], timeout: 3)
        service.loadSize(for: apps[1])
        service.loadSize(for: apps[0])
        service.resumeSizeCalculation()
        XCTAssertEqual(recorder.snapshot.paths, [apps[0].path])
        gate.open()
        try await waitUntil("existing queue finishes all apps") {
            service.completedSizeCount == apps.count && !service.isSizingApps
        }
        XCTAssertEqual(recorder.snapshot.paths, apps.map(\.path))
        XCTAssertEqual(recorder.snapshot.cancelledHandlers, 0)
        XCTAssertEqual(recorder.snapshot.maximumActive, 1)
    }

    func testPartialAndUnavailableAreTerminalAndDoNotRetryForever() async throws {
        let service = SoftwareService()
        defer { service.cancelInventoryWork() }
        let apps = [queueApp("Partial"), queueApp("Missing"), queueApp("MeasuredZero")]
        let recorder = SizeQueueRecorder()
        service.testInventoryHandler = { recorder.inventory(); return apps }
        service.testSizeHandler = { app in
            recorder.begin(app)
            defer { recorder.end(cancelled: Task.isCancelled) }
            if app.name == "Missing" { return nil }
            if app.name == "Partial" {
                return InstalledApp(name: app.name, bundleIdentifier: app.bundleIdentifier,
                                    path: app.path, version: app.version, bytes: 1024,
                                    isSystemLocation: false, canTrashAppBundle: false,
                                    sizeState: .partial)
            }
            return measuredApp(app, bytes: 0)
        }
        service.refresh()
        try await waitUntil("all terminal states finish") {
            service.completedSizeCount == apps.count && !service.isSizingApps
        }
        XCTAssertEqual(service.apps.map(\.sizeState), [.partial, .unavailable, .measured])
        service.resumeSizeCalculation()
        XCTAssertFalse(service.isSizingApps)
        XCTAssertEqual(recorder.snapshot.paths.count, apps.count)
    }
}
