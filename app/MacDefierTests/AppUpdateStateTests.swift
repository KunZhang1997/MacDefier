import XCTest
@testable import MacDefier

final class AppUpdateStateTests: XCTestCase {
    func testStageVisibilityProgressBoundsAndTerminalGuards() {
        var state = AppUpdateState()
        XCTAssertEqual(state.stage, .idle)
        XCTAssertFalse(state.stage.isBusy)
        XCTAssertFalse(state.stage.isTerminal)

        for hidden in [AppUpdateStage.idle, .probing, .current, .unavailable, .cancelled, .development] {
            XCTAssertFalse(hidden.showsControl, "unknown, silent, current and unsupported states stay hidden")
        }
        for visible in [
            AppUpdateStage.available("0.18"),
            .checking,
            .downloading(nil),
            .preparing(nil),
            .waitingToInstall,
            .installing,
            .failed
        ] {
            XCTAssertTrue(visible.showsControl, "available updates and explicit user action show controls")
        }

        state.setStage(.probing)
        XCTAssertTrue(state.stage.isBusy)
        XCTAssertFalse(state.stage.isCancellable)
        XCTAssertFalse(state.stage.showsControl)

        state.setStage(.available("0.18"))
        XCTAssertFalse(state.stage.isBusy)
        XCTAssertTrue(state.stage.showsControl)

        state.begin()
        XCTAssertEqual(state.stage, .checking)
        XCTAssertTrue(state.stage.isBusy)
        XCTAssertTrue(state.stage.isCancellable)

        state.beginDownload()
        XCTAssertEqual(state.stage, .downloading(nil))
        state.expectBytes(1_000)
        state.receiveBytes(0)
        XCTAssertEqual(state.stage, .downloading(nil))
        state.receiveBytes(1)
        XCTAssertEqual(state.stage, .downloading(0))
        let before = state.stage
        state.receiveBytes(1)
        XCTAssertEqual(state.stage, before)

        state.beginDownload()
        state.receiveBytes(25)
        XCTAssertEqual(state.stage, .downloading(nil))
        state.expectBytes(100)
        XCTAssertEqual(state.stage, .downloading(25))
        state.expectBytes(200)
        XCTAssertEqual(state.stage, .downloading(12))
        state.expectBytes(0)
        XCTAssertEqual(state.stage, .downloading(nil))
        state.expectBytes(50)
        XCTAssertEqual(state.stage, .downloading(50))

        state.beginDownload()
        state.expectBytes(UInt64.max)
        state.receiveBytes(UInt64.max - 1)
        XCTAssertEqual(state.stage, .downloading(99))
        state.receiveBytes(100)
        XCTAssertEqual(state.stage, .downloading(100))

        state.beginDownload()
        state.expectBytes(50)
        state.receiveBytes(100)
        XCTAssertEqual(state.stage, .downloading(100))

        state.beginDownload()
        state.receiveBytes(1)
        XCTAssertEqual(state.stage, .downloading(nil))
        state.expectBytes(10)
        XCTAssertEqual(state.stage, .downloading(10))

        state.prepare()
        XCTAssertEqual(state.stage, .preparing(nil))
        XCTAssertTrue(state.stage.isBusy)
        XCTAssertFalse(state.stage.isCancellable)
        state.extractionProgress(0.256)
        XCTAssertEqual(state.stage, .preparing(25))
        state.extractionProgress(-Double.greatestFiniteMagnitude)
        XCTAssertEqual(state.stage, .preparing(0))
        state.extractionProgress(Double.greatestFiniteMagnitude)
        XCTAssertEqual(state.stage, .preparing(100))
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            state.extractionProgress(invalid)
            XCTAssertEqual(state.stage, .preparing(nil))
        }

        state.setStage(.waitingToInstall)
        XCTAssertTrue(state.stage.isBusy)
        XCTAssertTrue(state.stage.isCancellable)
        XCTAssertFalse(state.stage.isTerminal)

        state.setStage(.installing)
        XCTAssertTrue(state.stage.isBusy)
        XCTAssertFalse(state.stage.isCancellable)
        XCTAssertFalse(state.stage.isTerminal)

        for terminal in [AppUpdateStage.current, .unavailable, .failed, .cancelled, .development] {
            state.setStage(terminal)
            XCTAssertTrue(state.stage.isTerminal)
            XCTAssertFalse(state.stage.isBusy)
            XCTAssertFalse(state.stage.isCancellable)
        }

        state.setStage(.cancelled)
        state.expectBytes(10)
        state.receiveBytes(UInt64.max)
        state.extractionProgress(0.5)
        XCTAssertEqual(state.stage, .cancelled)

        state.begin()
        state.receiveBytes(10)
        XCTAssertEqual(state.stage, .checking)
        state.beginDownload()
        state.expectBytes(100)
        XCTAssertEqual(state.stage, .downloading(nil))

        state.setStage(.downloading(Int.max))
        XCTAssertEqual(state.stage, .downloading(100))
        state.setStage(.preparing(Int.min))
        XCTAssertEqual(state.stage, .preparing(0))
    }
}
