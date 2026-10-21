import XCTest
import Darwin
@testable import MonitorKit

final class ActivityHistoryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func frame(_ seconds: Double, cpu: Double? = 0.2, pressure: MemoryPressure = .normal, gap: Bool = false) -> MonitorHistoryFrame {
        let time = epoch.addingTimeInterval(seconds)
        var snapshot = MonitorSnapshot()
        if let cpu { var load = CPULoad(sampledAt: time); load.totalUsage = cpu; snapshot.cpu = load }
        snapshot.ram = RAMUsage(total: 100, used: 30, free: 70, pressure: .init(value: pressure), sampledAt: time)
        return .init(snapshot: snapshot, time: time, gap: gap)
    }
    func testRateUsesElapsedTimeAndRejectsResetsPIDReuseAndSleepGap() {
        var rates = CounterRateTracker<String>()
        XCTAssertNil(rates.sample(key: "42:start1", read: 100, write: 200, time: 10))
        XCTAssertEqual(rates.sample(key: "42:start1", read: 200, write: 400, time: 15), IORate(read: 20, write: 40))
        XCTAssertNil(rates.sample(key: "42:start2", read: 10_000, write: 10_000, time: 20))
        XCTAssertNil(rates.sample(key: "42:start1", read: 0, write: 0, time: 20))
        XCTAssertNil(rates.sample(key: "42:start1", read: 100, write: 100, time: 55))
        XCTAssertNil(rates.sample(key: "42:start1", read: 200, write: 200, time: 54))
        rates.retain([]); XCTAssertTrue(rates.previous.isEmpty)
    }
    func testSingleSpikeDoesNotBecomeEventAndRecoveryMustPersist() {
        var engine = MonitorHistoryEngine()
        _ = engine.append(frame(0, cpu: 0.99)); _ = engine.append(frame(5))
        XCTAssertTrue(engine.archive.events.isEmpty)
        for s in stride(from: 10, through: 30, by: 5) { _ = engine.append(frame(Double(s), cpu: 0.9)) }
        XCTAssertEqual(engine.archive.events.count, 1)
        XCTAssertEqual(engine.archive.events[0].state, .active)
        _ = engine.append(frame(35)); _ = engine.append(frame(40, cpu: 0.9))
        XCTAssertEqual(engine.archive.events[0].state, .active)
        for s in stride(from: 45, through: 65, by: 5) { _ = engine.append(frame(Double(s))) }
        XCTAssertEqual(engine.archive.events[0].state, .recovered)
        XCTAssertEqual(engine.archive.events[0].endedAt, epoch.addingTimeInterval(65))
    }
    func testMissingReadOrGapCannotBridgeSustainedCondition() {
        var engine = MonitorHistoryEngine()
        for s in [0,5,10] { _ = engine.append(frame(Double(s), cpu: 0.99)) }
        _ = engine.append(frame(15, cpu: nil))
        for s in [20,25,30] { _ = engine.append(frame(Double(s), cpu: 0.99)) }
        XCTAssertTrue(engine.archive.events.isEmpty)
        _ = engine.append(frame(80, cpu: 0.99))
        XCTAssertTrue(engine.archive.events.isEmpty)
        for s in [85,90,95,100] { _ = engine.append(frame(Double(s), cpu: 0.99)) }
        _ = engine.append(frame(105, gap: true))
        XCTAssertEqual(engine.archive.events.first?.state, .interrupted)
    }
    func testMemoryPressureUsesPressureNotOccupancyAndUnknownInterrupts() {
        var engine = MonitorHistoryEngine()
        for s in stride(from: 0, through: 20, by: 5) { _ = engine.append(frame(Double(s), pressure: .warning)) }
        XCTAssertEqual(engine.archive.events.first?.kind, .memory)
        _ = engine.append(frame(25, pressure: .unknown))
        XCTAssertEqual(engine.archive.events.first?.state, .interrupted)
    }
    func testManualWindowKeepsFiveMinutesEachSideAndTenMinuteRing() {
        var engine = MonitorHistoryEngine()
        for s in stride(from: 0, through: 600, by: 5) { _ = engine.append(frame(Double(s))) }
        let id = engine.mark(at: epoch.addingTimeInterval(600))
        for s in stride(from: 605, through: 1000, by: 5) { _ = engine.append(frame(Double(s))) }
        let event = engine.archive.events.first { $0.id == id }!
        XCTAssertEqual(event.frames.first?.time, epoch.addingTimeInterval(300))
        XCTAssertEqual(event.frames.last?.time, epoch.addingTimeInterval(900))
        XCTAssertEqual(event.frames.count, 121)
        XCTAssertEqual(engine.archive.recent.first?.time, epoch.addingTimeInterval(400))
        XCTAssertLessThanOrEqual(engine.archive.minuteSamples.count, 17)
    }
    func testRetentionBoundsAndRestartInterruptsOpenEventsAndActions() {
        var engine = MonitorHistoryEngine()
        for s in stride(from: 0, through: 20, by: 5) { _ = engine.append(frame(Double(s), cpu: 0.99)) }
        engine.interrupt(at: epoch.addingTimeInterval(30))
        XCTAssertEqual(engine.archive.events.first?.state, .interrupted)
        engine.archive.retentionHours = 6
        engine.archive.prune(at: epoch.addingTimeInterval(7 * 3600))
        XCTAssertTrue(engine.archive.events.isEmpty)
        XCTAssertTrue(engine.archive.recent.isEmpty)
    }
    func testStaleSourceBecomesUnavailableRatherThanZero() {
        var snapshot = MonitorSnapshot()
        var load = CPULoad(sampledAt: epoch); load.totalUsage = 0.7; snapshot.cpu = load
        let result = MonitorHistoryFrame(snapshot: snapshot, time: epoch.addingTimeInterval(16))
        XCTAssertNil(result.cpu)
        XCTAssertNil(result.disk)
        XCTAssertNil(result.sampledAt["cpu"])
    }
    func testRecordingDemandSurvivesHiddenWindowButNotSleep() {
        var state = MonitorDemandState()
        state.historyEnabled = true
        XCTAssertEqual(MonitorDemandPolicy.activeSamplers(for: state), [.cpuLoad,.ram,.topCPU,.topRAM,.diskActivity,.gpus,.sensors])
        XCTAssertEqual(MonitorDemandPolicy.interval(for: .cpuLoad, state: state, foregroundInterval: 30), 5)
        XCTAssertEqual(MonitorDemandPolicy.interval(for: .topCPU, state: state, foregroundInterval: 1), 10)
        state.historyBoosted = true
        XCTAssertEqual(MonitorDemandPolicy.interval(for: .diskActivity, state: state, foregroundInterval: 30), 2)
        state.mainWindowVisible = true; state.monitorPageVisible = true
        XCTAssertEqual(MonitorDemandPolicy.interval(for: .cpuLoad, state: state, foregroundInterval: 1), 1)
        state.mainWindowVisible = false; state.monitorPageVisible = false
        state.sleeping = true
        XCTAssertTrue(MonitorDemandPolicy.activeSamplers(for: state).isEmpty)
        state.sleeping = false; state.historyEnabled = false
        XCTAssertTrue(MonitorDemandPolicy.activeSamplers(for: state).isEmpty)
    }
    func testStorageRoundTripAndInvalidSchemaAreNotSilentlyAccepted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = MonitorHistoryStorage(url: dir.appendingPathComponent("history.json"))
        var engine = MonitorHistoryEngine()
        _ = engine.append(frame(0)); engine.mark(at: epoch)
        try await storage.save(engine.archive)
        let restored = try await storage.load()
        XCTAssertEqual(restored.events, engine.archive.events)
        XCTAssertEqual(restored.recent, engine.archive.recent)
        var bad = engine.archive; bad.version = 999
        try await storage.save(bad)
        do { _ = try await storage.load(); XCTFail("Unknown schema accepted") } catch { }
    }
    func testProcessIdentityAndExactCLIPathOwnership() throws {
        let identity = try XCTUnwrap(MonitoredProcessIdentity.read(pid: getpid()))
        XCTAssertTrue(identity.isCurrent())
        var changed = identity; changed.startSeconds += 1
        XCTAssertFalse(changed.isCurrent())
        XCTAssertNil(MonitoredProcessIdentity.read(pid: Int32.max))
        ProcessOwnerRegistry.replaceCLIInventory(["/private/tmp/tools/foo": "Foo"])
        XCTAssertEqual(ProcessOwnerRegistry.owner(for: "/private/tmp/tools/foo/bin/foo"), "Foo")
        XCTAssertNil(ProcessOwnerRegistry.owner(for: "/private/tmp/tools/foobar/bin/foo"))
        ProcessOwnerRegistry.replaceCLIInventory([:])
    }
    @MainActor func testQuitRejectsSelfChangedIdentityAndCommandLineProcess() throws {
        let identity = try XCTUnwrap(MonitoredProcessIdentity.read(pid: getpid()))
        XCTAssertEqual(MonitoredApplicationExit.request(identity), .unavailable)
        var changed = identity; changed.startSeconds += 1
        XCTAssertEqual(MonitoredApplicationExit.request(changed), .identityChanged)
    }
    func testComparisonRequiresEnoughFreshSamples() throws {
        let identity = try XCTUnwrap(MonitoredProcessIdentity.read(pid: getpid()))
        var action = MonitorActionRecord(eventID: UUID(), target: identity, time: epoch, outcome: .exited,
                                         wasAlreadyRecovered: true, before: [frame(0)])
        action.after = [frame(30)]
        XCTAssertFalse(action.hasComparison)
        action.before = [0,5,10,15].map { frame(Double($0), cpu: 0.8) }
        action.after = [30,35,40,45].map { frame(Double($0), cpu: 0.2) }
        XCTAssertTrue(action.hasComparison)
        XCTAssertEqual(action.cpuBefore!, 0.8, accuracy: 0.001)
        XCTAssertEqual(action.cpuAfter!, 0.2, accuracy: 0.001)
    }
    @MainActor func testRecorderPersistsEventWithHiddenWindowAndStopsItsDemand() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacDefier-history-" + UUID().uuidString)
        let suite = "com.macdefier.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let recorder = MonitorHistoryRecorder(directory: dir, defaults: defaults)
        let service = MonitorService(history: recorder)
        for _ in 0..<100 where !recorder.ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(recorder.ready)
        recorder.setEnabled(true)
        XCTAssertEqual(service.samplingMode, .recording)
        try await Task.sleep(nanoseconds: 5_500_000_000)
        XCTAssertTrue(recorder.archive.recent.contains { !$0.gap })
        let id = try XCTUnwrap(recorder.mark())
        recorder.setEnabled(false)
        XCTAssertEqual(service.samplingMode, .stopped)
        await recorder.finishRecording()
        let disk = try await MonitorHistoryStorage(url: dir.appendingPathComponent("monitor-history.json")).load()
        XCTAssertTrue(disk.events.contains { $0.id == id })
        XCTAssertTrue(disk.recent.last?.gap == true)
    }
    @MainActor func testCorruptHistoryIsPreservedUntilExplicitClear() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacDefier-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("monitor-history.json")
        let original = Data("unreadable-original".utf8)
        try original.write(to: file)
        let suite = "com.macdefier.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let recorder = MonitorHistoryRecorder(directory: dir, defaults: defaults)
        let service = MonitorService(history: recorder)
        for _ in 0..<100 where !recorder.ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(recorder.storageFailed)
        await recorder.finishRecording()
        XCTAssertEqual(try Data(contentsOf: file), original)
        recorder.clear()
        await recorder.finishRecording()
        XCTAssertNoThrow(try JSONDecoder().decode(MonitorHistoryArchive.self, from: Data(contentsOf: file)))
        XCTAssertEqual(service.samplingMode, .stopped)
    }
    func testStorageBudgetTrimsOldEventsBeforeWritingUnreadableOversizeArchive() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = MonitorHistoryStorage(url: dir.appendingPathComponent("history.json"))
        var value = MonitorHistoryArchive()
        var largeFrame = frame(0)
        largeFrame.topCPU = [.init(pid: 42, name: String(repeating: "x", count: 1_000_000), usage: 2)]
        value.events = (0..<18).map { .init(kind: .manual, time: epoch.addingTimeInterval(Double($0)), state: .marked, frames: [largeFrame]) }
        let stored = try await storage.save(value)
        XCTAssertLessThan(stored.events.count, value.events.count)
        XCTAssertEqual(stored.events.last?.id, value.events.last?.id)
        XCTAssertLessThanOrEqual(try Data(contentsOf: storage.url).count, 16_000_000)
        _ = try await storage.load()
    }
    func testLiveDiskWriterIsAttributedToItsStableIdentity() throws {
        guard ProcessInfo.processInfo.environment["MACDEFIER_RUN_LIVE_IO_TEST"] == "1" else {
            throw XCTSkip("Opt-in live probe writes only a temporary 24 MiB fixture")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MacDefier-io-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,sys,time,fcntl\nf=open(sys.argv[1],'wb',buffering=0)\nfcntl.fcntl(f.fileno(),48,1)\ntime.sleep(2)\nfor i in range(6):\n f.write(b'x'*4194304);os.fsync(f.fileno());time.sleep(1)\ntime.sleep(2)\nf.close()", file.path]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let found = expectation(description: "Writer appears with physical write delta")
        let sampler = DiskActivitySampler(interval: 1)
        var fulfilled = false
        sampler.callback = { value in
            if !fulfilled, let match = value?.processes.first(where: { $0.identity.pid == process.processIdentifier && $0.rate.write > 0 }) {
                fulfilled = true
                print("LIVE_IO pid=\(match.identity.pid) owner=\(match.identity.ownerName) bytesPerSecond=\(match.rate.write) devices=\(value?.devices.count ?? 0)")
                found.fulfill()
            }
        }
        sampler.start(); defer { sampler.stop() }
        wait(for: [found], timeout: 15)
    }
}
