import AppKit
import Combine
import Foundation

public struct MonitorHistoryFrame: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { time }
    public var time: Date
    public var cpu: Double?
    public var memoryPressure: MemoryPressure?
    public var swapUsed: Double?
    public var swapRate: IORate?
    public var disk: IORate?
    public var topCPU: [TopProcess]
    public var topRAM: [TopProcess]
    public var diskProcesses: [ProcessDiskActivity]
    public var sensors: [SensorReading]
    public var gpu: [GPUInfo]
    public var sampledAt: [String: Date]
    public var gap: Bool

    public init(snapshot: MonitorSnapshot, time: Date = Date(), gap: Bool = false) {
        self.time = time; self.gap = gap
        cpu = !gap && snapshot.cpuIsFresh(at: time) ? snapshot.cpu?.totalUsage : nil
        let ram = !gap && snapshot.ramIsFresh(at: time) ? snapshot.ram : nil
        memoryPressure = ram?.pressure.value; swapUsed = ram?.swap.isAvailable == true ? ram?.swap.used : nil
        swapRate = ram?.swapRate
        let io = !gap && snapshot.diskActivity?.isFresh(at: time) == true ? snapshot.diskActivity : nil
        disk = io?.total; diskProcesses = io?.processes ?? []
        topCPU = !gap && snapshot.topCPUIsFresh(at: time) ? snapshot.topCPU : []
        topRAM = !gap && snapshot.topRAMIsFresh(at: time) ? snapshot.topRAM : []
        sensors = !gap && snapshot.sensorsAreFresh(at: time) ? snapshot.sensors : []
        gpu = !gap && snapshot.gpusAreFresh(at: time) ? snapshot.gpus : []
        sampledAt = [:]
        if cpu != nil { sampledAt["cpu"] = snapshot.cpu?.sampledAt }
        if ram != nil { sampledAt["ram"] = ram?.sampledAt }
        if io != nil { sampledAt["disk"] = io?.sampledAt }
        if !topCPU.isEmpty { sampledAt["topCPU"] = snapshot.topCPUSampledAt }
        if !topRAM.isEmpty { sampledAt["topRAM"] = snapshot.topRAMSampledAt }
        if !sensors.isEmpty { sampledAt["sensors"] = snapshot.sensorsSampledAt }
        if !gpu.isEmpty { sampledAt["gpu"] = snapshot.gpusSampledAt }
    }
}

public struct MonitorHistoryEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case manual, cpu, memory }
    public enum State: String, Codable, Sendable { case active, recovered, interrupted, marked }
    public var id = UUID()
    public var kind: Kind
    public var time: Date
    public var state: State
    public var endedAt: Date?
    public var frames: [MonitorHistoryFrame]
    public var captureUntil: Date { time.addingTimeInterval(300) }
}

public struct MonitorActionRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case observing, cancelled, rejected, unavailable, identityChanged, exited, stillRunning, interrupted
    }
    public var id = UUID()
    public var eventID: UUID
    public var target: MonitoredProcessIdentity
    public var time: Date
    public var outcome: Outcome
    public var wasAlreadyRecovered: Bool
    public var before: [MonitorHistoryFrame]
    public var after: [MonitorHistoryFrame] = []
    public var hasComparison: Bool {
        before.filter { !$0.gap && $0.cpu != nil }.count >= 4 && after.filter { !$0.gap && $0.cpu != nil }.count >= 4
    }
    public var cpuBefore: Double? { Self.average(before.compactMap(\.cpu)) }
    public var cpuAfter: Double? { Self.average(after.compactMap(\.cpu)) }
    public var diskBefore: IORate? { Self.averageIO(before.compactMap(\.disk)) }
    public var diskAfter: IORate? { Self.averageIO(after.compactMap(\.disk)) }
    private static func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    private static func averageIO(_ values: [IORate]) -> IORate? {
        guard values.count >= 4 else { return nil }
        return .init(read: average(values.map(\.read))!, write: average(values.map(\.write))!)
    }
}

public struct MonitorHistoryArchive: Codable, Sendable {
    public var version = 1
    public var recent: [MonitorHistoryFrame] = []
    /// One sampled point per minute, explicitly not an average of the unobserved interval.
    public var minuteSamples: [MonitorHistoryFrame] = []
    public var events: [MonitorHistoryEvent] = []
    public var actions: [MonitorActionRecord] = []
    public var retentionHours: Int = 24
    public init() {}
    mutating func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-Double(retentionHours) * 3600)
        recent = Array(recent.filter { $0.time >= now.addingTimeInterval(-600) && $0.time <= now }.suffix(125))
        minuteSamples = Array(minuteSamples.filter { $0.time >= cutoff && $0.time <= now }.suffix(4320))
        events = Array(events.filter { $0.time >= cutoff && $0.time <= now }.suffix(48))
        actions = Array(actions.filter { $0.time >= cutoff && $0.time <= now }.suffix(48))
    }
}

struct SustainedCondition {
    var since: Date?
    var recoverySince: Date?
    var active = false
    mutating func consume(_ condition: Bool?, at time: Date) -> Bool? {
        guard let condition else { since = nil; recoverySince = nil; return nil }
        if !active {
            guard condition else { since = nil; return nil }
            if since == nil { since = time }
            if time.timeIntervalSince(since!) >= 20 { active = true; recoverySince = nil; return true }
        } else {
            guard !condition else { recoverySince = nil; return nil }
            if recoverySince == nil { recoverySince = time }
            if time.timeIntervalSince(recoverySince!) >= 20 { active = false; since = nil; return false }
        }
        return nil
    }
}

struct MonitorHistoryEngine {
    var archive = MonitorHistoryArchive()
    private var cpuRule = SustainedCondition()
    private var memoryRule = SustainedCondition()
    mutating func append(_ frame: MonitorHistoryFrame) -> Bool {
        if let previous = archive.recent.last, frame.time.timeIntervalSince(previous.time) > 15 || frame.time <= previous.time {
            interrupt(at: frame.time)
        }
        if frame.gap { interrupt(at: frame.time) }
        archive.recent.append(frame)
        for i in archive.events.indices where frame.time <= archive.events[i].captureUntil && frame.time > archive.events[i].time {
            archive.events[i].frames.append(frame)
            archive.events[i].frames = Array(archive.events[i].frames.suffix(125))
        }
        if archive.minuteSamples.last.map({ frame.time.timeIntervalSince($0.time) >= 60 }) ?? true {
            var compact = frame
            compact.topCPU = Array(compact.topCPU.prefix(3)); compact.topRAM = Array(compact.topRAM.prefix(3))
            compact.diskProcesses = Array(compact.diskProcesses.prefix(3))
            archive.minuteSamples.append(compact)
        }
        var triggered = false
        let cpu = frame.cpu.map { $0 >= 0.85 }
        let memory = frame.memoryPressure.flatMap { $0 == .unknown ? nil : $0 == .warning || $0 == .critical }
        if let active = cpuRule.consume(cpu, at: frame.time) { triggered = transition(.cpu, active: active, at: frame.time) || triggered }
        if let active = memoryRule.consume(memory, at: frame.time) { triggered = transition(.memory, active: active, at: frame.time) || triggered }
        // Missing source samples cannot support a continuing/recovered event.
        if cpu == nil { interrupt(kind: .cpu, at: frame.time); cpuRule = .init() }
        if memory == nil { interrupt(kind: .memory, at: frame.time); memoryRule = .init() }
        archive.prune(at: frame.time)
        return triggered
    }
    @discardableResult mutating func mark(at time: Date) -> UUID {
        let event = MonitorHistoryEvent(kind: .manual, time: time, state: .marked,
                                       frames: archive.recent.filter { $0.time >= time.addingTimeInterval(-300) })
        archive.events.append(event); archive.prune(at: time); return event.id
    }
    mutating func interrupt(at time: Date) {
        interrupt(kind: .cpu, at: time); interrupt(kind: .memory, at: time)
        cpuRule = .init(); memoryRule = .init()
        for i in archive.actions.indices where archive.actions[i].outcome == .observing { archive.actions[i].outcome = .interrupted }
    }
    private mutating func interrupt(kind: MonitorHistoryEvent.Kind, at time: Date) {
        for i in archive.events.indices where archive.events[i].kind == kind && archive.events[i].state == .active {
            archive.events[i].state = .interrupted; archive.events[i].endedAt = time
        }
    }
    private mutating func transition(_ kind: MonitorHistoryEvent.Kind, active: Bool, at time: Date) -> Bool {
        if active {
            archive.events.append(.init(kind: kind, time: time, state: .active,
                frames: archive.recent.filter { $0.time >= time.addingTimeInterval(-300) }))
        } else if let index = archive.events.lastIndex(where: { $0.kind == kind && $0.state == .active }) {
            archive.events[index].state = .recovered; archive.events[index].endedAt = time
        }
        return active
    }
}

/// Serial I/O; atomic replacement. Histories stay local and never include process arguments or file contents.
final class MonitorHistoryStorage: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.macdefier.history.storage", qos: .utility)
    init(url: URL) { self.url = url }
    func load() async throws -> MonitorHistoryArchive {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [url] in
                do {
                    guard FileManager.default.fileExists(atPath: url.path) else { continuation.resume(returning: .init()); return }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size < 32_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                    let value = try JSONDecoder().decode(MonitorHistoryArchive.self, from: Data(contentsOf: url))
                    guard value.version == 1, [6,24,72].contains(value.retentionHours) else { throw CocoaError(.fileReadCorruptFile) }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    @discardableResult func save(_ value: MonitorHistoryArchive) async throws -> MonitorHistoryArchive {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MonitorHistoryArchive, Error>) in
            queue.async { [url] in
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    var bounded = value
                    var encoded = try JSONEncoder().encode(bounded)
                    // Enforce the same on-disk budget we promise to read. Time/count caps alone
                    // do not bound nested event frames or long executable paths.
                    while encoded.count > 16_000_000 {
                        if bounded.events.count > 1 { bounded.events.removeFirst() }
                        else if bounded.actions.count > 1 { bounded.actions.removeFirst() }
                        else if bounded.minuteSamples.count > 60 { bounded.minuteSamples.removeFirst(min(60, bounded.minuteSamples.count - 60)) }
                        else { throw CocoaError(.fileWriteOutOfSpace) }
                        encoded = try JSONEncoder().encode(bounded)
                    }
                    try encoded.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    continuation.resume(returning: bounded)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor public final class MonitorHistoryRecorder: ObservableObject {
    @Published public private(set) var archive = MonitorHistoryArchive()
    @Published public private(set) var enabled = false
    @Published public private(set) var ready = false
    @Published public private(set) var storageFailed = false
    private weak var monitor: MonitorService?
    private var engine = MonitorHistoryEngine()
    private var timer: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveRevision = 0
    private var archiveRevision = 0
    private var sleeping = false
    private var storageWritable = true
    private var observers: [NSObjectProtocol] = []
    private var boostUntil = Date.distantPast
    private var lastSave = Date.distantPast
    private let defaults: UserDefaults
    private let storage: MonitorHistoryStorage
    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.macdefier.monitor")
        storage = .init(url: base.appendingPathComponent("monitor-history.json"))
    }
    deinit {
        timer?.cancel(); saveTask?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func attach(_ monitor: MonitorService) {
        self.monitor = monitor
        Task { [weak self] in
            guard let self else { return }
            do { engine.archive = try await storage.load() } catch { storageFailed = true; storageWritable = false }
            engine.archive.prune(at: Date()); engine.interrupt(at: Date()); archive = engine.archive
            ready = true
            setEnabled(defaults.bool(forKey: "monitor.history.enabled"))
        }
        for (name, sleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(sleep) }
            })
        }
    }
    public func setEnabled(_ value: Bool) {
        guard ready else { return }
        enabled = value; defaults.set(value, forKey: "monitor.history.enabled")
        timer?.cancel(); timer = nil
        if !value { appendGap(); persist() }
        updateDemand()
        if value {
            appendGap()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.tick()
                }
            }
        }
    }
    public func setRetentionHours(_ hours: Int) {
        guard [6,24,72].contains(hours), ready else { return }
        engine.archive.retentionHours = hours; engine.archive.prune(at: Date()); publish(); persist()
    }
    public func finishRecording() async {
        timer?.cancel(); timer = nil
        if enabled { appendGap() }
        monitor?.setHistoryDemand(false, boosted: false)
        // Await queued persistence before the final write so app termination cannot discard the latest event/action.
        if let saveTask { await saveTask.value }
        guard storageWritable else { return }
        do { engine.archive = try await storage.save(engine.archive); publish() } catch { storageFailed = true }
    }
    public func clear() {
        guard ready else { return }
        storageWritable = true
        let retention = engine.archive.retentionHours
        engine = .init(); engine.archive.retentionHours = retention
        boostUntil = .distantPast; publish(); updateDemand(); persist()
    }
    @discardableResult public func mark() -> UUID? {
        guard enabled, ready, !sleeping else { return nil }
        let id = engine.mark(at: Date()); boostUntil = Date().addingTimeInterval(60)
        publish(); updateDemand(); persist(); return id
    }
    public func recordAction(eventID: UUID, target: MonitoredProcessIdentity, cancelled: Bool) {
        guard ready, enabled, !sleeping, !archive.actions.contains(where: { $0.outcome == .observing }),
              let event = archive.events.first(where: { $0.id == eventID }) else { return }
        let now = Date()
        let outcome: MonitorActionRecord.Outcome
        if cancelled { outcome = .cancelled }
        else {
            switch MonitoredApplicationExit.request(target) {
            case .requested: outcome = .observing
            case .identityChanged: outcome = .identityChanged
            case .unavailable: outcome = .unavailable
            case .rejected: outcome = .rejected
            }
        }
        engine.archive.actions.append(.init(eventID: eventID, target: target, time: now, outcome: outcome,
            wasAlreadyRecovered: event.state == .recovered,
            before: archive.recent.filter { $0.time >= now.addingTimeInterval(-30) && !$0.gap }))
        if outcome == .observing { boostUntil = now.addingTimeInterval(65) }
        publish(); updateDemand(); persist()
    }
    private func setSleeping(_ value: Bool) {
        sleeping = value
        if enabled { appendGap(); persist() }
        monitor?.setSystemSleeping(value)
        updateDemand()
    }
    private func appendGap() {
        _ = engine.append(.init(snapshot: .init(), gap: true)); publish()
    }
    private func tick() {
        guard enabled, !sleeping, let monitor else { return }
        let now = Date()
        let frame = MonitorHistoryFrame(snapshot: monitor.snapshot, time: now)
        let triggered = engine.append(frame)
        if triggered { boostUntil = now.addingTimeInterval(60) }
        for i in engine.archive.actions.indices where engine.archive.actions[i].outcome == .observing {
            let elapsed = now.timeIntervalSince(engine.archive.actions[i].time)
            if elapsed >= 30 && elapsed <= 65 { engine.archive.actions[i].after.append(frame) }
            if elapsed >= 60 {
                let target = engine.archive.actions[i].target
                if let current = MonitoredProcessIdentity.read(pid: target.pid) {
                    engine.archive.actions[i].outcome = current.id == target.id ? .stillRunning : .identityChanged
                } else {
                    engine.archive.actions[i].outcome = kill(target.pid, 0) == -1 && errno == ESRCH ? .exited : .unavailable
                }
            }
        }
        publish(); updateDemand()
        if triggered || now.timeIntervalSince(lastSave) >= 30 { persist() }
    }
    private func updateDemand() { monitor?.setHistoryDemand(enabled && !sleeping, boosted: Date() < boostUntil) }
    private func publish() { archiveRevision += 1; archive = engine.archive }
    private func persist() {
        guard storageWritable else { return }
        lastSave = Date(); saveRevision += 1
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let revision = saveRevision
                let stateRevision = archiveRevision
                do {
                    let saved = try await storage.save(engine.archive)
                    if stateRevision == archiveRevision { engine.archive = saved; publish() }
                    storageFailed = false
                } catch { storageFailed = true }
                if revision == saveRevision { break }
            }
            saveTask = nil
        }
    }
}
