import Darwin
import Foundation
import XCTest
@testable import MonitorKit

final class MemorySamplingTests: XCTestCase {
    func testDiskCapacityMissingIsNotMeasuredZero() {
        XCTAssertNil(DiskCapacitySampler.validFreeCapacity(total: 100, important: nil, basic: nil))
        XCTAssertEqual(DiskCapacitySampler.validFreeCapacity(total: 100, important: nil, basic: 0), 0)
        XCTAssertEqual(DiskCapacitySampler.validFreeCapacity(total: 100, important: -1, basic: 20), 20)
        XCTAssertNil(DiskCapacitySampler.validFreeCapacity(total: .nan, important: 0, basic: 0))
        XCTAssertNil(DiskCapacitySampler.validFreeCapacity(total: 100, important: .infinity, basic: 101))
    }

    func testCPUZeroTickWindowIsUnknown() {
        var previous = host_cpu_load_info()
        previous.cpu_ticks = (10, 20, 30, 0)
        XCTAssertNil(CPULoadSampler.deltaLoad(current: previous, previous: previous))
        var current = previous
        current.cpu_ticks = (20, 30, 60, 0)
        XCTAssertEqual(CPULoadSampler.deltaLoad(current: current, previous: previous)?.totalUsage, 0.4)
    }

    func testSamplingGenerationResetsBaselineOnResume() {
        let first = expectation(description: "first generation")
        let next = expectation(description: "resume generation")
        let sampler = BaselineFixtureSampler(interval: 60)
        sampler.callback = { value in
            if value == 1 { first.fulfill() }
            if value == 2 { next.fulfill() }
        }
        sampler.start()
        wait(for: [first], timeout: 1)
        sampler.pause()
        sampler.start()
        wait(for: [next], timeout: 1)
        sampler.stop()
    }

    func testDiskFreshnessCannotUseAggregateTimestampOrExternalFallback() {
        let now = Date()
        let disk = DiskVolume(name: "System", path: "/", total: 100, free: 40, kind: .system)
        XCTAssertFalse(MonitorSnapshot(disks: [disk], updatedAt: now).systemDiskIsFresh(at: now))
        XCTAssertTrue(MonitorSnapshot(disks: [disk], disksSampledAt: now).systemDiskIsFresh(at: now))
        let usb = DiskVolume(name: "USB", path: "/Volumes/USB", total: 100, free: 40, kind: .external)
        XCTAssertFalse(MonitorSnapshot(disks: [usb], disksSampledAt: now).systemDiskIsFresh(at: now))
    }

    func testFreshnessAllowsConfiguredThirtySecondSampling() {
        let now = Date()
        var cpu = CPULoad(sampledAt: now.addingTimeInterval(-30))
        cpu.freshnessLimit = 60
        XCTAssertTrue(MonitorSnapshot(cpu: cpu).cpuIsFresh(at: now))
        XCTAssertFalse(MonitorSnapshot(cpu: cpu).cpuIsFresh(at: now.addingTimeInterval(31)))
    }

    func testPressureFailureCannotBecomeNormalOrUsePartiallyWrittenLevel() {
        let pressure = RAMUsageSampler.readPressure { _, pointer, _ in
            pointer.storeBytes(of: Int32(4), as: Int32.self)
            return -1
        }
        XCTAssertEqual(pressure.value, .unknown)
    }

    func testPressureRequiresExpectedSizeAndKnownKernelLevel() {
        for level in [Int32(0), 3, 8] {
            let pressure = RAMUsageSampler.readPressure { _, pointer, _ in
                pointer.storeBytes(of: level, as: Int32.self)
                return 0
            }
            XCTAssertEqual(pressure.value, .unknown)
        }
        let truncated = RAMUsageSampler.readPressure { _, pointer, size in
            pointer.storeBytes(of: Int32(1), as: Int32.self)
            size = 1
            return 0
        }
        XCTAssertEqual(truncated.value, .unknown)
        let cases: [(Int32, MemoryPressure)] = [(1, .normal), (2, .warning), (4, .critical)]
        for (level, expected) in cases {
            let pressure = RAMUsageSampler.readPressure { _, pointer, _ in
                pointer.storeBytes(of: level, as: Int32.self)
                return 0
            }
            XCTAssertEqual(pressure.value, expected)
        }
    }

    func testSwapFailureIsDifferentFromMeasuredZero() {
        let failed = RAMUsageSampler.readSwap { _, _, _ in -1 }
        XCTAssertFalse(failed.isAvailable)
        let empty = RAMUsageSampler.readSwap { _, _, _ in 0 }
        XCTAssertTrue(empty.isAvailable)
        XCTAssertEqual(empty.used, 0)
        let malformed = RAMUsageSampler.readSwap { _, pointer, _ in
            var value = xsw_usage()
            value.xsu_used = 1
            pointer.storeBytes(of: value, as: xsw_usage.self)
            return 0
        }
        XCTAssertFalse(malformed.isAvailable)
    }

    func testAggregateTimestampCannotRefreshRetainedSamples() {
        let now = Date(timeIntervalSince1970: 10_000)
        var cpu = CPULoad(sampledAt: now.addingTimeInterval(-16))
        cpu.totalUsage = 0.2
        let ram = RAMUsage(total: 100, used: 90, free: 10,
                           swap: .init(isAvailable: true), pressure: .init(level: 1, value: .normal), sampledAt: now)
        let snapshot = MonitorSnapshot(cpu: cpu, ram: ram, updatedAt: now)
        XCTAssertFalse(snapshot.cpuIsFresh(at: now))
        XCTAssertTrue(snapshot.ramIsFresh(at: now))
        XCTAssertFalse(snapshot.hasFreshCoreMetrics(at: now))
    }

    func testCoreCompletenessRequiresKnownPressureAndSwapButNotLowUsage() {
        let now = Date()
        var cpu = CPULoad(sampledAt: now)
        cpu.totalUsage = 0.2
        var ram = RAMUsage(total: 100, used: 99, free: 1,
                           swap: .init(isAvailable: true), pressure: .init(level: 1, value: .normal), sampledAt: now)
        XCTAssertTrue(MonitorSnapshot(cpu: cpu, ram: ram).hasFreshCoreMetrics(at: now))
        ram.pressure = .init()
        XCTAssertFalse(MonitorSnapshot(cpu: cpu, ram: ram).hasFreshCoreMetrics(at: now))
        ram.pressure = .init(level: 1, value: .normal)
        ram.swap = .init()
        XCTAssertFalse(MonitorSnapshot(cpu: cpu, ram: ram).hasFreshCoreMetrics(at: now))
        XCTAssertFalse(MonitorSnapshot().hasFreshCoreMetrics(at: now))
    }

    func testFutureAndDefaultSamplesAreNotFresh() {
        let now = Date()
        XCTAssertFalse(MonitorSnapshot(cpu: .init()).cpuIsFresh(at: now))
        XCTAssertFalse(MonitorSnapshot(cpu: .init(sampledAt: now.addingTimeInterval(1))).cpuIsFresh(at: now))
    }
}

private final class BaselineFixtureSampler: Sampler<Int> {
    private var epoch = 0
    override func samplingDidStart() { epoch += 1 }
    override func read() { publish(epoch) }
}
