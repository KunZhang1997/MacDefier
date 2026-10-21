import XCTest
@testable import CleanupKit

final class ProcessRunnerTests: XCTestCase {
    func testAsyncCommandsReturnOutputAndExitStatusAcrossWorkers() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for code in 0..<12 {
                group.addTask {
                    await Task.yield()
                    let result = try await ProcessRunner.run(
                        ["/bin/sh", "-c", "printf out; printf err >&2; exit \(code)"],
                        timeout: 2
                    )
                    XCTAssertEqual(result.exitCode, Int32(code))
                    XCTAssertEqual(result.stdoutString, "out")
                    XCTAssertEqual(result.stderrString, "err")
                    XCTAssertFalse(result.timedOut)
                }
            }
            try await group.waitForAll()
        }
    }

    func testAsyncTimeoutReturnsAfterRootExitsWithInheritedPipeOpen() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(
            ["/bin/sh", "-c", "(sleep 3) & exit 0"], timeout: 0.1
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testAsyncCancellationReturnsWithoutWaitingForCommandTimeout() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(["/bin/sh", "-c", "sleep 10"], timeout: 5)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testCapturesBothStreamsWithoutBlocking() throws {
        let result = try ProcessRunner.runSync(
            ["/bin/sh", "-c", "printf out; printf err >&2"],
            timeout: 2
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdoutString, "out")
        XCTAssertEqual(result.stderrString, "err")
    }

    func testAsyncOutputIsBoundedWhileBothPipesContinueDraining() async throws {
        let result = try await ProcessRunner.run(
            ["/bin/sh", "-c", "i=0; while [ $i -lt 12000 ]; do printf abcdefghij; printf 1234567890 >&2; i=$((i+1)); done"],
            timeout: 5,
            outputLimits: ProcessOutputLimits(stdoutBytes: 1024, stderrBytes: 512)
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.stdout.count, 1024)
        XCTAssertEqual(result.stderr.count, 512)
    }

    func testSyncOverflowCannotBecomeSuccessfulInventory() throws {
        let result = try ProcessRunner.runSync(
            ["/usr/bin/printf", "abcdef"], timeout: 2,
            outputLimits: ProcessOutputLimits(stdoutBytes: 3, stderrBytes: 0)
        )
        XCTAssertEqual(result.stdoutString, "abc")
        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertFalse(result.succeeded)
    }

    func testExactLimitIsNotTruncated() throws {
        let result = try ProcessRunner.runSync(
            ["/usr/bin/printf", "abc"], timeout: 2,
            outputLimits: ProcessOutputLimits(stdoutBytes: 3)
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.outputLimitExceeded)
    }

    func testNoisyProcessRemainsCancellableAfterOverflow() async throws {
        let task = Task {
            try await ProcessRunner.run(["/usr/bin/yes"], timeout: 5,
                outputLimits: ProcessOutputLimits(stdoutBytes: 16))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertEqual(result.stdout.count, 16)
    }

    func testTimeoutIsReported() throws {
        let result = try ProcessRunner.runSync(
            ["/bin/sh", "-c", "sleep 10"],
            timeout: 0.05
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func testTimeoutStillAppliesAfterRootExitsWithInheritedPipeOpen() throws {
        let started = Date()
        let result = try ProcessRunner.runSync(
            ["/bin/sh", "-c", "(sleep 3) & exit 0"],
            timeout: 0.1
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(elapsed, 1.5, "runner must not wait for a detached descendant to close stdout")
    }
}
