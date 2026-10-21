import Foundation
import XCTest
@testable import MonitorKit

private final class BlockingSampler: Sampler<Int> {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let countLock = NSLock()
    private var storedReadCount = 0

    var readCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return storedReadCount
    }

    override func read() {
        countLock.lock()
        storedReadCount += 1
        let value = storedReadCount
        countLock.unlock()
        entered.signal()
        release.wait()
        publish(value)
    }
}

final class SamplerLifecycleTests: XCTestCase {
    func testQueuedPublicationCannotCrossStopAndRestart() {
        let first = expectation(description: "first generation publishes")
        let second = expectation(description: "second generation publishes")
        let sampler = PublicationFixtureSampler(interval: 60)
        let lock = NSLock()
        var publications: [(UInt64, Date)] = []
        sampler.publicationCallback = { _, generation, sampledAt in
            lock.lock()
            publications.append((generation, sampledAt))
            let count = publications.count
            lock.unlock()
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
        }
        sampler.start()
        wait(for: [first], timeout: 1)
        lock.lock()
        let old = publications[0]
        lock.unlock()
        XCTAssertTrue(sampler.isPublicationCurrent(old.0))
        sampler.stop()
        XCTAssertFalse(sampler.isPublicationCurrent(old.0), "An already queued MainActor delivery is invalid after stop")
        sampler.start()
        wait(for: [second], timeout: 1)
        lock.lock()
        let current = publications[1]
        lock.unlock()
        XCTAssertFalse(sampler.isPublicationCurrent(old.0), "Reopening must not make a prior publication valid again")
        XCTAssertTrue(sampler.isPublicationCurrent(current.0))
        XCTAssertGreaterThanOrEqual(current.1, old.1)
        sampler.stop()
    }

    func testTicksCoalesceToOnePendingRead() {
        let sampler = BlockingSampler(interval: 60)
        sampler.start()
        XCTAssertEqual(sampler.entered.wait(timeout: .now() + 1), .success)

        for _ in 0..<20 { sampler.requestRead() }
        sampler.release.signal()
        XCTAssertEqual(sampler.entered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(sampler.readCount, 2)

        sampler.stop()
        sampler.release.signal()
    }

    func testStopSuppressesInFlightPublish() {
        let published = expectation(description: "stopped sampler must not publish")
        published.isInverted = true
        let sampler = BlockingSampler(interval: 60) { _ in published.fulfill() }
        sampler.start()
        XCTAssertEqual(sampler.entered.wait(timeout: .now() + 1), .success)

        sampler.stop()
        sampler.release.signal()

        wait(for: [published], timeout: 0.2)
        XCTAssertNil(sampler.value)
    }
}

private final class PublicationFixtureSampler: Sampler<Int> {
    override func read() { publish(1) }
}
