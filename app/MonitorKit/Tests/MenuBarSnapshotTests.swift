import Foundation
import IOKit.ps
import XCTest
@testable import MonitorKit

final class MenuBarSnapshotTests: XCTestCase {
    func testAggregateCommitDoesNotRefreshAuxiliarySamples() {
        let now = Date()
        let primary = NetworkInterfaceUsage(interface: "en0", bytesInPerSec: 0, bytesOutPerSec: 0, isPrimary: true)
        let snapshot = MonitorSnapshot(topCPU: [.init(pid: 1, name: "app", usage: 10)],
            topRAM: [.init(pid: 1, name: "app", usage: 1024)],
            networkOverview: .init(primary: primary), gpus: [.init(model: "GPU", utilization: 0)],
            sensors: [.init(key: "F0Ac", name: "Fan", value: 0, unit: "RPM", group: "Fans")], updatedAt: now)
        XCTAssertFalse(snapshot.topCPUIsFresh(at: now))
        XCTAssertFalse(snapshot.topRAMIsFresh(at: now))
        XCTAssertFalse(snapshot.networkIsFresh(at: now))
        XCTAssertFalse(snapshot.gpusAreFresh(at: now))
        XCTAssertFalse(snapshot.sensorsAreFresh(at: now))
        XCTAssertFalse(snapshot.batteryIsFresh(at: now))
    }

    func testMeasuredZeroAndUnavailableRemainDifferent() {
        let now = Date()
        let primary = NetworkInterfaceUsage(interface: "en0", bytesInPerSec: 0, bytesOutPerSec: 0, isPrimary: true)
        var snapshot = MonitorSnapshot(networkOverview: .init(primary: primary),
            gpus: [.init(model: "GPU", utilization: 0)],
            sensors: [.init(key: "F0Ac", name: "Fan", value: 0, unit: "RPM", group: "Fans")],
            topCPUSampledAt: now, topRAMSampledAt: now, networkSampledAt: now,
            gpusSampledAt: now, sensorsSampledAt: now,
            battery: .init(isPresent: true, charge: 0, sampledAt: now))
        XCTAssertTrue(snapshot.topCPUIsFresh(at: now), "An actual empty process result can be fresh")
        XCTAssertTrue(snapshot.topRAMIsFresh(at: now))
        XCTAssertTrue(snapshot.networkIsFresh(at: now), "Measured idle traffic is not an unavailable probe")
        XCTAssertTrue(snapshot.gpusAreFresh(at: now))
        XCTAssertTrue(snapshot.sensorsAreFresh(at: now), "A stopped fan can report a measured zero")
        XCTAssertTrue(snapshot.batteryIsFresh(at: now), "A measured empty battery is not unknown")
        snapshot.gpus[0].utilization = .nan
        snapshot.sensors[0].value = .infinity
        snapshot.networkOverview.primary?.bytesInPerSec = -.infinity
        snapshot.battery?.charge = 1.1
        XCTAssertFalse(snapshot.networkIsFresh(at: now))
        XCTAssertFalse(snapshot.gpusAreFresh(at: now))
        XCTAssertFalse(snapshot.sensorsAreFresh(at: now))
        XCTAssertFalse(snapshot.batteryIsFresh(at: now))
    }

    func testRestartClearsOnlyRestartedSeriesAndKeepsIPHistory() {
        let now = Date()
        let primary = NetworkInterfaceUsage(interface: "en0", bytesInPerSec: 10, isPrimary: true)
        var snapshot = MonitorSnapshot(cpu: .init(sampledAt: now), ram: .init(total: 100, used: 50, free: 50, sampledAt: now),
            topCPU: [.init(pid: 1, name: "app", usage: 10)], network: [primary],
            networkOverview: .init(primary: primary, history: [.init(downBytesPerSec: 10, upBytesPerSec: 1)],
                                   ipHistory: [.init(from: "old", to: "new")], sampledAt: now),
            gpus: [.init(model: "GPU", utilization: 0.2)], dashCPUSeries: [0.5], dashRAMSeries: [0.5], dashGPUSeries: [0.2],
            topCPUSampledAt: now, networkSampledAt: now, gpusSampledAt: now)
        snapshot.prepareForSamplingRestart([.gpus, .network, .topCPU])
        XCTAssertEqual(snapshot.dashCPUSeries, [0.5], "An independently running menu metric keeps its continuous history")
        XCTAssertEqual(snapshot.dashRAMSeries, [0.5])
        XCTAssertTrue(snapshot.dashGPUSeries.isEmpty)
        XCTAssertTrue(snapshot.networkOverview.history.isEmpty)
        XCTAssertEqual(snapshot.networkOverview.ipHistory.count, 1)
        XCTAssertNil(snapshot.networkOverview.primary)
        XCTAssertFalse(snapshot.topCPUIsFresh(at: now))
        XCTAssertFalse(snapshot.networkIsFresh(at: now))
        XCTAssertFalse(snapshot.gpusAreFresh(at: now))
        snapshot.prepareForSamplingRestart([.cpuLoad, .ram])
        XCTAssertNil(snapshot.cpu)
        XCTAssertNil(snapshot.ram)
        XCTAssertTrue(snapshot.dashCPUSeries.isEmpty)
        XCTAssertTrue(snapshot.dashRAMSeries.isEmpty)
    }

    func testAuxiliaryFreshnessExpiresAndRejectsFutureTimestamp() {
        let now = Date()
        var snapshot = MonitorSnapshot(gpus: [.init(model: "GPU")], topCPUSampledAt: now,
            gpusSampledAt: now, battery: .init(isPresent: false, sampledAt: now))
        XCTAssertTrue(snapshot.gpusAreFresh(at: now), "Model availability does not invent a utilization number")
        XCTAssertTrue(snapshot.batteryIsFresh(at: now), "Confirmed desktop absence is a fresh result")
        XCTAssertFalse(snapshot.topCPUIsFresh(at: now.addingTimeInterval(16)))
        XCTAssertFalse(snapshot.gpusAreFresh(at: now.addingTimeInterval(16)))
        XCTAssertFalse(snapshot.batteryIsFresh(at: now.addingTimeInterval(16)))
        snapshot.gpusSampledAt = now.addingTimeInterval(1)
        XCTAssertFalse(snapshot.gpusAreFresh(at: now))
    }

    func testBatteryPublicDictionaryParsingPreservesUnknownAndAbsence() {
        let now = Date()
        XCTAssertNil(BatteryUsageSampler.parsePowerSources(nil))
        XCTAssertEqual(BatteryUsageSampler.parsePowerSources([], sampledAt: now)?.isPresent, false)
        XCTAssertEqual(BatteryUsageSampler.parsePowerSources([[kIOPSTypeKey: kIOPSUPSType]])?.isPresent, false)
        XCTAssertNil(BatteryUsageSampler.parsePowerSources([[kIOPSTypeKey: "Unrecognized"]]))
        let base: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
                                  kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 80,
                                  kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
                                  kIOPSTimeToEmptyKey: 90, kIOPSTimeToFullChargeKey: 30]
        let battery = BatteryUsageSampler.parsePowerSources([base], sampledAt: now)
        XCTAssertEqual(battery?.charge, 0.5)
        XCTAssertEqual(battery?.timeToEmptyMinutes, 90)
        XCTAssertNil(battery?.timeToFullMinutes)
        var malformed = base
        malformed[kIOPSMaxCapacityKey] = 0
        malformed[kIOPSTimeToEmptyKey] = -1
        XCTAssertNil(BatteryUsageSampler.parsePowerSources([malformed])?.charge)
        XCTAssertNil(BatteryUsageSampler.parsePowerSources([malformed])?.timeToEmptyMinutes)
        malformed[kIOPSCurrentCapacityKey] = true
        XCTAssertNil(BatteryUsageSampler.parsePowerSources([malformed])?.charge)
        var charging = base
        charging[kIOPSIsChargingKey] = true
        charging[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        XCTAssertEqual(BatteryUsageSampler.parsePowerSources([charging])?.timeToFullMinutes, 30)
        XCTAssertNil(BatteryUsageSampler.parsePowerSources([charging])?.timeToEmptyMinutes)
    }
}
