import XCTest
@testable import MonitorKit

final class MonitorDemandPolicyTests: XCTestCase {
    func testMenuBarPanelRunsEverySamplerWithHiddenMainWindow() {
        var state = MonitorDemandState()
        state.menuBarPanelVisible = true
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), Set(MonitorSamplerID.allCases))
        XCTAssertEqual(MonitorDemandPolicy.interval(for: .cpuLoad, state: state, foregroundInterval: 1), 1)
        XCTAssertEqual(MonitorDemandPolicy.interval(for: .gpus, state: state, foregroundInterval: 1), 3)
        XCTAssertEqual(MonitorDemandPolicy.interval(for: .battery, state: state, foregroundInterval: 1), 15)
    }

    func testClosingPanelPreservesEveryIndependentDemand() {
        var state = MonitorDemandState()
        state.menuBarPanelVisible = true
        state.menuBarCPU = true
        state.menuBarRAM = true
        state.diagnosticDemandCount = 1
        state.menuBarPanelVisible = false
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), [.cpuLoad, .ram, .topCPU, .disks, .network])
        state.diagnosticDemandCount = 0
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), [.cpuLoad, .ram])
        state.menuBarCPU = false
        state.menuBarRAM = false
        XCTAssertTrue(MonitorDemandPolicy.activeSamplers(for: state).isEmpty)
        state.mainWindowVisible = true
        state.monitorPageVisible = true
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), Set(MonitorSamplerID.allCases))
    }

    func testVisibleMonitorPageRunsEverySampler() {
        var state = MonitorDemandState()
        state.mainWindowVisible = true
        state.monitorPageVisible = true

        XCTAssertEqual(
            MonitorDemandPolicy.activeSamplers(for: state),
            Set(MonitorSamplerID.allCases)
        )
    }

    func testVisibleMainWindowOnAnotherRouteDoesNotRunFullSampling() {
        var state = MonitorDemandState()
        state.mainWindowVisible = true
        state.monitorPageVisible = false

        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), [.cpuLoad, .ram, .disks, .network])
        XCTAssertEqual(MonitorDemandPolicy.interval(for: .cpuLoad, state: state, foregroundInterval: 1), 5)
        XCTAssertFalse(MonitorDemandPolicy.activeSamplers(for: state).contains(.topCPU))
        XCTAssertFalse(MonitorDemandPolicy.activeSamplers(for: state).contains(.sensors))
    }

    func testWorkbenchSamplingStopsWhenWindowCloses() {
        var state = MonitorDemandState(mainWindowVisible: true)
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state).count, 4)
        state.mainWindowVisible = false
        XCTAssertTrue(MonitorDemandPolicy.activeSamplers(for: state).isEmpty)
    }

    func testLeavingMonitorRetainsOnlyWorkbenchMetrics() {
        var state = MonitorDemandState(mainWindowVisible: true, monitorPageVisible: true)
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state).count, MonitorSamplerID.allCases.count)
        state.monitorPageVisible = false
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), [.cpuLoad, .ram, .disks, .network])
    }

    func testHiddenWindowDoesNotRunFullSamplingForRememberedMonitorRoute() {
        var state = MonitorDemandState()
        state.mainWindowVisible = false
        state.monitorPageVisible = true

        XCTAssertTrue(MonitorDemandPolicy.activeSamplers(for: state).isEmpty)
    }

    func testClosedWindowWithStaticMenuBarStopsSampling() {
        let state = MonitorDemandState(mainWindowVisible: false)

        XCTAssertTrue(MonitorDemandPolicy.activeSamplers(for: state).isEmpty)
    }

    func testClosedWindowSamplesOnlySelectedMenuMetricsAtFiveSeconds() {
        var state = MonitorDemandState()
        state.mainWindowVisible = false
        state.menuBarCPU = true

        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), [.cpuLoad])
        XCTAssertEqual(
            MonitorDemandPolicy.interval(for: .cpuLoad, state: state, foregroundInterval: 1),
            5
        )

        state.menuBarRAM = true
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), [.cpuLoad, .ram])
    }

    func testDiagnosticDemandExcludesHeavyUnneededSamplers() {
        var state = MonitorDemandState()
        state.diagnosticDemandCount = 1

        XCTAssertEqual(
            MonitorDemandPolicy.activeSamplers(for: state),
            [.cpuLoad, .ram, .topCPU, .disks, .network]
        )
        XCTAssertFalse(MonitorDemandPolicy.activeSamplers(for: state).contains(.topRAM))
        XCTAssertFalse(MonitorDemandPolicy.activeSamplers(for: state).contains(.gpus))
        XCTAssertFalse(MonitorDemandPolicy.activeSamplers(for: state).contains(.sensors))
    }
}
