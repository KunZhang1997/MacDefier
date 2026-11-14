import Darwin
import Foundation
import XCTest
@testable import MonitorKit

final class ProcessOutputTests: XCTestCase {
    func testOutputLargerThanPipeCapacityIsDrainedWithoutDeadlock() throws {
        let (process, pipe) = try launch("/bin/dd", ["if=/dev/zero", "bs=65536", "count=4"])
        defer { stopFixture(process) }

        let output = readProcessOutput(from: pipe.fileHandleForReading, process: process, timeout: 2)

        XCTAssertEqual(output?.count, 262_144)
        XCTAssertFalse(process.isRunning)
    }

    func testNonzeroExitDoesNotPublishPartialOutput() throws {
        let (process, pipe) = try launch("/bin/sh", ["-c", "printf partial; exit 7"])
        defer { stopFixture(process) }

        XCTAssertNil(readProcessOutput(from: pipe.fileHandleForReading, process: process, timeout: 2))
        XCTAssertEqual(process.terminationStatus, 7)
    }

    func testClosedReadHandleReturnsNilWithoutAnException() throws {
        let (process, pipe) = try launch("/usr/bin/true")
        defer { stopFixture(process) }
        try pipe.fileHandleForReading.close()

        XCTAssertNil(readProcessOutput(from: pipe.fileHandleForReading, process: process, timeout: 1))
    }

    func testTimeoutKillsProcessThatIgnoresTerminationWithOpenOutput() throws {
        let (process, pipe) = try launchIgnoringTermination(closeOutput: false)
        defer { stopFixture(process) }
        let started = ContinuousClock.now

        XCTAssertNil(readProcessOutput(from: pipe.fileHandleForReading, process: process, timeout: 0.05))

        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertTrue(waitForExit(process), "Timeout must stop the child, not only return to the sampler")
    }

    func testTimeoutKillsProcessEvenWhenItAlreadyClosedOutput() throws {
        let (process, pipe) = try launchIgnoringTermination(closeOutput: true)
        defer { stopFixture(process) }
        let started = ContinuousClock.now

        XCTAssertNil(readProcessOutput(from: pipe.fileHandleForReading, process: process, timeout: 0.05))

        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertTrue(waitForExit(process), "EOF must not prevent escalation to SIGKILL")
    }

    func testExitedRootDoesNotWaitForeverForAnotherProcessHoldingThePipe() throws {
        let pipe = Pipe()
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["30"]
        let writer = FileHandle(fileDescriptor: dup(pipe.fileHandleForWriting.fileDescriptor), closeOnDealloc: true)
        holder.standardOutput = writer
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        try writer.close()
        defer { stopFixture(holder) }

        let root = Process()
        root.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        root.standardOutput = pipe
        root.standardError = FileHandle.nullDevice
        try root.run()
        defer { stopFixture(root) }
        let started = ContinuousClock.now

        XCTAssertNil(readProcessOutput(from: pipe.fileHandleForReading, process: root, timeout: 0.1))

        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertTrue(holder.isRunning, "The helper must not kill unrelated processes just because they share a pipe")
    }

    func testCancellationDuringReadReturnsWithoutTheFullTimeout() throws {
        let (process, pipe) = try launch("/bin/sleep", ["30"])
        defer { stopFixture(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            if process.isRunning { process.terminate() }
        }
        let started = ContinuousClock.now

        XCTAssertNil(readProcessOutput(from: pipe.fileHandleForReading, process: process, timeout: 5))

        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertFalse(process.isRunning)
    }

    func testCPUProcessSamplerPublishesActualProcessOutput() {
        let published = expectation(description: "ps output")
        let sampler = CPUProcessSampler(limit: 3, interval: 60) { processes in
            guard let processes, !processes.isEmpty else { return }
            XCTAssertLessThanOrEqual(processes.count, 3)
            published.fulfill()
        }
        defer { sampler.stop() }

        sampler.start()
        wait(for: [published], timeout: 5)
    }

    func testRAMProcessSamplerPublishesActualProcessOutput() {
        let published = expectation(description: "in-process RAM footprint output")
        let sampler = RAMProcessSampler(limit: 3, interval: 60) { processes in
            guard let processes, !processes.isEmpty else { return }
            XCTAssertLessThanOrEqual(processes.count, 3)
            XCTAssertGreaterThan(processes[0].usage, 0)
            if processes.count >= 2 {
                XCTAssertGreaterThanOrEqual(processes[0].usage, processes[1].usage)
            }
            published.fulfill()
        }
        defer { sampler.stop() }

        sampler.start()
        wait(for: [published], timeout: 6)
    }

    func testRAMProcessSamplerFindsCurrentProcessFootprintInProcess() {
        let selfPID = Int(getpid())
        let published = expectation(description: "current process RAM footprint")
        let sampler = RAMProcessSampler(limit: 1_000, interval: 60) { processes in
            guard let processes, let mine = processes.first(where: { $0.pid == selfPID }) else { return }
            // XCTest runner footprint is at least multiple MBs.
            XCTAssertGreaterThan(mine.usage, 1_000_000)
            XCTAssertNotNil(mine.identity)
            published.fulfill()
        }
        defer { sampler.stop() }

        sampler.start()
        wait(for: [published], timeout: 5)
    }

    func testCPUProcessSamplerSteadyStateDeltaReflectsActiveBurn() {
        let selfPID = Int(getpid())
        let firstSample = expectation(description: "cold-start CPU sample")
        let secondSample = expectation(description: "steady-state delta CPU sample")
        let logicalCores = max(1, ProcessInfo.processInfo.activeProcessorCount)

        final class BurnFlag: @unchecked Sendable {
            let lock = NSLock()
            var active = true
            var sampleCount = 0
        }
        let flag = BurnFlag()

        // Spin one background worker thread so current process burns ~1 core during delta window.
        DispatchQueue.global(qos: .userInitiated).async {
            var acc: UInt64 = 1
            while true {
                flag.lock.lock()
                let keepGoing = flag.active
                flag.lock.unlock()
                if !keepGoing { break }
                for i in 1...10_000 {
                    acc = acc &* 2862933555777941757 &+ UInt64(i)
                }
                withExtendedLifetime(acc) {}
            }
        }
        defer {
            flag.lock.lock()
            flag.active = false
            flag.lock.unlock()
        }

        var samplerRef: CPUProcessSampler?
        let sampler = CPUProcessSampler(limit: 1_000, interval: 60) { processes in
            guard let processes, !processes.isEmpty else { return }
            flag.lock.lock()
            flag.sampleCount += 1
            let count = flag.sampleCount
            flag.lock.unlock()

            if count == 1 {
                firstSample.fulfill()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
                    samplerRef?.requestRead()
                }
            } else if count == 2 {
                if let mine = processes.first(where: { $0.pid == selfPID }) {
                    XCTAssertGreaterThan(mine.usage, 15.0, "Active burn must register non-trivial CPU% via mach_timebase_info")
                    XCTAssertLessThanOrEqual(mine.usage, Double(logicalCores) * 120.0, "CPU% must stay within core-count scale")
                } else {
                    XCTFail("Expected current process in steady-state CPU sample")
                }
                secondSample.fulfill()
            }
        }
        samplerRef = sampler
        defer { sampler.stop() }

        sampler.start()
        wait(for: [firstSample, secondSample], timeout: 5)
    }

    func testHostSummaryStorageLabelUsesDecimalBytes() {
        let disk = DiskVolume(
            name: "Macintosh HD",
            path: "/",
            bsdName: "disk3s1s1",
            total: 500_000_000_000,
            free: 200_000_000_000,
            removable: false,
            kind: .system
        )
        let summary = HostSummary.read(disks: [disk])
        let expected = ByteCountFormatter.string(fromByteCount: 500_000_000_000, countStyle: .file)
        XCTAssertEqual(summary.storageLabel, expected)
    }

    private func launch(_ executable: String, _ arguments: [String] = []) throws -> (Process, Pipe) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, pipe)
    }

    private func launchIgnoringTermination(closeOutput: Bool) throws -> (Process, Pipe) {
        let process = Process()
        let pipe = Pipe()
        let ready = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; \(closeOutput ? "exec 1>&-;" : "") printf R >&2; exec /bin/sleep 30"]
        process.standardOutput = pipe
        process.standardError = ready
        try process.run()
        // Confirm the ignored TERM disposition is installed before starting the timeout.
        XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 1), Data("R".utf8))
        return (process, pipe)
    }

    private func waitForExit(_ process: Process) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(0.5))
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private func stopFixture(_ process: Process) {
        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        XCTAssertTrue(waitForExit(process), "Fixture process did not exit after SIGKILL")
    }
}
