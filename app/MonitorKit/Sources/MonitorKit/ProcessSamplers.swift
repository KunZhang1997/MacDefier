// In-process Darwin process CPU & RAM samplers via proc_listallpids + proc_pid_rusage.
// Eliminates periodic /usr/bin/top and /bin/ps subprocesses.

import AppKit
import Darwin
import Foundation

private final class ProcessOutputBox: @unchecked Sendable {
    let lock = NSLock()
    var data: Data?
}

private struct ProcessRunKey: Hashable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

private enum DarwinProcessInspector {
    static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        if mach_timebase_info(&info) != KERN_SUCCESS || info.denom == 0 {
            info.numer = 1
            info.denom = 1
        }
        return info
    }()

    static func machTicksToNanoseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(machTimebase.numer) / Double(machTimebase.denom)
    }

    static func listAllPIDs() -> [Int32] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimated) + 128)
        let actual = pids.withUnsafeMutableBytes { rawBuffer in
            proc_listallpids(rawBuffer.baseAddress, Int32(rawBuffer.count))
        }
        guard actual > 0 else { return [] }
        let count = min(Int(actual), pids.count)
        var result: [Int32] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let pid = pids[index]
            if pid > 0 {
                result.append(pid)
            }
        }
        return result
    }

    static func readBSDInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected else {
            return nil
        }
        return info
    }

    static func readRUsage(pid: Int32) -> rusage_info_current? {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        return rc == 0 ? usage : nil
    }

    static func fallbackCommandName(from bsd: proc_bsdinfo) -> String {
        let fullName = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
        if !fullName.isEmpty { return fullName }
        let comm = withUnsafeBytes(of: bsd.pbi_comm) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
        return comm.isEmpty ? "pid \(bsd.pbi_pid)" : comm
    }

    static func makeTopProcess(
        key: ProcessRunKey,
        fallbackName: String,
        usage: Double
    ) -> TopProcess? {
        if let identity = MonitoredProcessIdentity.read(pid: key.pid) {
            guard identity.startSeconds == key.startSeconds,
                  identity.startMicroseconds == key.startMicroseconds,
                  identity.isCurrent()
            else {
                return nil
            }
            var name = identity.ownerName
            if let app = NSRunningApplication(processIdentifier: key.pid),
               let localized = app.localizedName,
               !localized.isEmpty {
                name = localized
            }
            if (identity.executable.contains("com.apple.Virtua") || fallbackName.contains("com.apple.Virtua")),
               name.contains("Docker") {
                name = "Docker"
            }
            return TopProcess(pid: Int(key.pid), name: name, usage: usage, identity: identity)
        }

        // Fallback when proc_pidpath is unavailable for a process that still matches its BSD start time.
        guard let currentBSD = readBSDInfo(pid: key.pid),
              currentBSD.pbi_start_tvsec == key.startSeconds,
              currentBSD.pbi_start_tvusec == key.startMicroseconds
        else {
            return nil
        }
        var name = fallbackName
        if let app = NSRunningApplication(processIdentifier: key.pid),
           let localized = app.localizedName,
           !localized.isEmpty {
            name = localized
        }
        if fallbackName.contains("com.apple.Virtua"), name.contains("Docker") {
            name = "Docker"
        }
        return TopProcess(pid: Int(key.pid), name: name, usage: usage, identity: nil)
    }
}

public final class CPUProcessSampler: Sampler<[TopProcess]> {
    private struct CPUSnapshot {
        let machTicks: UInt64
        let ticksByProcess: [ProcessRunKey: (cpuTicks: UInt64, fallbackName: String)]
    }

    public var limit: Int
    private var previousSnapshot: CPUSnapshot?
    private let cancelLock = NSLock()
    private var coldStartWaiter: DispatchSemaphore?

    /// Cold-start measurement window used only on the very first read of a sampling session
    /// when no prior tick baseline exists yet. Subsequent ticks are single-pass delta reads.
    static let coldStartWindowSeconds: TimeInterval = 0.12

    public init(limit: Int = 8, interval: Int = 2, callback: @escaping ([TopProcess]?) -> Void = { _ in }) {
        self.limit = limit
        super.init(interval: interval, queueLabel: "com.macdefier.MonitorKit.CPUProcess", callback: callback)
    }

    public override func samplingDidStart() {
        previousSnapshot = nil
    }

    public override func read() {
        guard limit > 0 else {
            publish([])
            return
        }
        guard shouldContinueCurrentRead else { return }

        guard let current = captureSnapshot() else {
            publish(nil)
            return
        }
        guard shouldContinueCurrentRead else { return }

        let baseline: CPUSnapshot
        let latest: CPUSnapshot

        if let prev = previousSnapshot,
           current.machTicks > prev.machTicks,
           DarwinProcessInspector.machTicksToNanoseconds(current.machTicks - prev.machTicks) <= 60_000_000_000 {
            baseline = prev
            latest = current
        } else {
            // Cold start (or stale baseline after long pause): take a short second in-process snapshot
            // so the very first publication already carries accurate CPU% without spawning /bin/ps.
            let waiter = DispatchSemaphore(value: 0)
            setColdStartWaiter(waiter)
            _ = waiter.wait(timeout: .now() + Self.coldStartWindowSeconds)
            clearColdStartWaiter(waiter)
            guard shouldContinueCurrentRead else { return }
            guard let second = captureSnapshot(), second.machTicks > current.machTicks else {
                previousSnapshot = current
                publish(nil)
                return
            }
            baseline = current
            latest = second
        }

        previousSnapshot = latest
        let wallNs = DarwinProcessInspector.machTicksToNanoseconds(latest.machTicks - baseline.machTicks)
        guard wallNs > 0 else {
            publish([])
            return
        }

        var candidates: [(key: ProcessRunKey, fallbackName: String, usage: Double)] = []
        candidates.reserveCapacity(latest.ticksByProcess.count)
        for (key, entry) in latest.ticksByProcess {
            guard let prevEntry = baseline.ticksByProcess[key],
                  entry.cpuTicks >= prevEntry.cpuTicks
            else {
                continue
            }
            let deltaTicks = entry.cpuTicks - prevEntry.cpuTicks
            let cpuNs = DarwinProcessInspector.machTicksToNanoseconds(deltaTicks)
            let pct = max(0, (cpuNs / wallNs) * 100.0)
            candidates.append((key: key, fallbackName: entry.fallbackName, usage: pct))
        }

        candidates.sort {
            if $0.usage != $1.usage { return $0.usage > $1.usage }
            return $0.key.pid < $1.key.pid
        }

        var processes: [TopProcess] = []
        processes.reserveCapacity(min(limit, candidates.count))
        for candidate in candidates {
            guard shouldContinueCurrentRead else { return }
            if let top = DarwinProcessInspector.makeTopProcess(
                key: candidate.key,
                fallbackName: candidate.fallbackName,
                usage: candidate.usage
            ) {
                processes.append(top)
                if processes.count >= limit {
                    break
                }
            }
        }
        publish(processes)
    }

    public override func cancelCurrentRead() {
        cancelLock.lock()
        let waiter = coldStartWaiter
        cancelLock.unlock()
        waiter?.signal()
    }

    private func setColdStartWaiter(_ waiter: DispatchSemaphore) {
        cancelLock.lock()
        coldStartWaiter = waiter
        cancelLock.unlock()
    }

    private func clearColdStartWaiter(_ waiter: DispatchSemaphore) {
        cancelLock.lock()
        if coldStartWaiter === waiter {
            coldStartWaiter = nil
        }
        cancelLock.unlock()
    }

    private func captureSnapshot() -> CPUSnapshot? {
        let pids = DarwinProcessInspector.listAllPIDs()
        guard !pids.isEmpty else { return nil }
        let machTicks = mach_absolute_time()
        var map: [ProcessRunKey: (cpuTicks: UInt64, fallbackName: String)] = [:]
        map.reserveCapacity(pids.count)

        for pid in pids {
            guard shouldContinueCurrentRead else { return nil }
            guard let bsdBefore = DarwinProcessInspector.readBSDInfo(pid: pid),
                  let usage = DarwinProcessInspector.readRUsage(pid: pid),
                  let bsdAfter = DarwinProcessInspector.readBSDInfo(pid: pid),
                  bsdBefore.pbi_start_tvsec == bsdAfter.pbi_start_tvsec,
                  bsdBefore.pbi_start_tvusec == bsdAfter.pbi_start_tvusec
            else {
                continue
            }
            let key = ProcessRunKey(
                pid: pid,
                startSeconds: bsdAfter.pbi_start_tvsec,
                startMicroseconds: bsdAfter.pbi_start_tvusec
            )
            let totalTicks = usage.ri_user_time &+ usage.ri_system_time
            map[key] = (
                cpuTicks: totalTicks,
                fallbackName: DarwinProcessInspector.fallbackCommandName(from: bsdAfter)
            )
        }
        return CPUSnapshot(machTicks: machTicks, ticksByProcess: map)
    }
}

public final class RAMProcessSampler: Sampler<[TopProcess]> {
    public var limit: Int

    public init(limit: Int = 8, interval: Int = 3, callback: @escaping ([TopProcess]?) -> Void = { _ in }) {
        self.limit = limit
        super.init(interval: interval, queueLabel: "com.macdefier.MonitorKit.RAMProcess", callback: callback)
    }

    public override func read() {
        guard limit > 0 else {
            publish([])
            return
        }
        guard shouldContinueCurrentRead else { return }

        let pids = DarwinProcessInspector.listAllPIDs()
        guard !pids.isEmpty else {
            publish(nil)
            return
        }

        var candidates: [(key: ProcessRunKey, fallbackName: String, usage: Double)] = []
        candidates.reserveCapacity(pids.count)

        for pid in pids {
            guard shouldContinueCurrentRead else { return }
            guard let bsdBefore = DarwinProcessInspector.readBSDInfo(pid: pid),
                  let usage = DarwinProcessInspector.readRUsage(pid: pid),
                  let bsdAfter = DarwinProcessInspector.readBSDInfo(pid: pid),
                  bsdBefore.pbi_start_tvsec == bsdAfter.pbi_start_tvsec,
                  bsdBefore.pbi_start_tvusec == bsdAfter.pbi_start_tvusec
            else {
                continue
            }
            let key = ProcessRunKey(
                pid: pid,
                startSeconds: bsdAfter.pbi_start_tvsec,
                startMicroseconds: bsdAfter.pbi_start_tvusec
            )
            candidates.append((
                key: key,
                fallbackName: DarwinProcessInspector.fallbackCommandName(from: bsdAfter),
                usage: Double(usage.ri_phys_footprint)
            ))
        }

        guard shouldContinueCurrentRead else { return }
        candidates.sort {
            if $0.usage != $1.usage { return $0.usage > $1.usage }
            return $0.key.pid < $1.key.pid
        }

        var processes: [TopProcess] = []
        processes.reserveCapacity(min(limit, candidates.count))
        for candidate in candidates {
            guard shouldContinueCurrentRead else { return }
            if let top = DarwinProcessInspector.makeTopProcess(
                key: candidate.key,
                fallbackName: candidate.fallbackName,
                usage: candidate.usage
            ) {
                processes.append(top)
                if processes.count >= limit {
                    break
                }
            }
        }
        publish(processes)
    }
}

/// Draining concurrently prevents an unexpected amount of output from filling the pipe before exit.
func readProcessOutput(
    from handle: FileHandle,
    process: Process,
    timeout: TimeInterval
) -> Data? {
    let output = ProcessOutputBox()
    let drain = DispatchGroup()
    drain.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { drain.leave() }
        // Use the throwing API and keep ownership of the handle in this closure.
        // The caller may time out and return while this read is still draining;
        // closing the handle from the caller used to raise an Objective-C
        // NSFileHandle exception here and abort the whole app.
        do {
            let data = try handle.readToEnd() ?? Data()
            output.lock.lock()
            output.data = data
            output.lock.unlock()
        } catch {
            output.lock.lock()
            output.data = nil
            output.lock.unlock()
        }
    }

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    defer { process.terminationHandler = nil }

    if process.isRunning, timeout > 0 {
        _ = exited.wait(timeout: .now() + timeout)
    }
    guard !process.isRunning else {
        process.terminate()
        // EOF is independent of process exit: a child can close stdout and
        // continue running, including after ignoring SIGTERM. Always bound its
        // termination grace period and escalate based on process liveness.
        if process.isRunning {
            _ = exited.wait(timeout: .now() + 0.5)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 0.2)
        }
        _ = drain.wait(timeout: .now() + 0.5)
        return nil
    }

    guard drain.wait(timeout: .now() + 0.5) == .success else { return nil }
    output.lock.lock()
    let result = output.data
    output.lock.unlock()
    return process.terminationStatus == 0 ? result : nil
}
