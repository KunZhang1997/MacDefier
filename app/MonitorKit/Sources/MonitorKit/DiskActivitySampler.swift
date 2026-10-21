// proc_pid_rusage and IOKit Statistics access adapted from Stats Modules/Disk/readers.swift (MIT).
// Copyright (c) 2019 Serhiy Mytrovtsiy. See app/NOTICE.
// MacDefier adds monotonic time, process-start identity, unavailable states and restart/reset handling.
import Darwin
import Foundation
import IOKit

public struct IORate: Codable, Equatable, Sendable {
    public var read: Double
    public var write: Double
}
public struct ProcessDiskActivity: Codable, Equatable, Sendable, Identifiable {
    public var identity: MonitoredProcessIdentity
    public var rate: IORate
    public var id: String { identity.id }
}
public struct DeviceDiskActivity: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt64
    public var name: String
    public var rate: IORate?
}
public struct DiskActivity: Codable, Equatable, Sendable {
    public var sampledAt: Date
    public var devices: [DeviceDiskActivity]
    public var processes: [ProcessDiskActivity]
    public var readableProcesses: Int
    public var unavailableProcesses: Int
    public var total: IORate? {
        guard !devices.isEmpty, devices.allSatisfy({ $0.rate != nil }) else { return nil }
        return devices.reduce(IORate(read: 0, write: 0)) {
            IORate(read: $0.read + ($1.rate?.read ?? 0), write: $0.write + ($1.rate?.write ?? 0))
        }
    }
    public func isFresh(at now: Date) -> Bool { (0...15).contains(now.timeIntervalSince(sampledAt)) }
}

struct CounterRateTracker<Key: Hashable> {
    struct Sample { var read: UInt64; var write: UInt64; var time: Double }
    var previous: [Key: Sample] = [:]
    mutating func sample(key: Key, read: UInt64, write: UInt64, time: Double) -> IORate? {
        defer { previous[key] = Sample(read: read, write: write, time: time) }
        guard let old = previous[key], time > old.time, time - old.time <= 30,
              read >= old.read, write >= old.write else { return nil }
        return IORate(read: Double(read - old.read) / (time - old.time),
                      write: Double(write - old.write) / (time - old.time))
    }
    mutating func retain(_ keys: Set<Key>) { previous = previous.filter { keys.contains($0.key) } }
}

public final class DiskActivitySampler: Sampler<DiskActivity> {
    private var processes = CounterRateTracker<String>()
    private var devices = CounterRateTracker<UInt64>()
    public override func samplingDidStart() { processes = .init(); devices = .init() }
    public override func read() {
        let now = ProcessInfo.processInfo.systemUptime
        var result: [ProcessDiskActivity] = []
        var seen = Set<String>()
        var unavailable = 0
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { publish(nil); return }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(max(0, min(Int(actual), pids.count))) where pid > 0 {
            guard shouldContinueCurrentRead else { return }
            guard let identity = MonitoredProcessIdentity.read(pid: pid) else { unavailable += 1; continue }
            var usage = rusage_info_current()
            let code = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            // An exited/replaced process must not contribute a counter to the previous identity.
            guard code == 0, identity.isCurrent() else { unavailable += 1; continue }
            seen.insert(identity.id)
            if let rate = processes.sample(key: identity.id, read: usage.ri_diskio_bytesread,
                                           write: usage.ri_diskio_byteswritten, time: now), rate.read + rate.write > 0 {
                result.append(.init(identity: identity, rate: rate))
            }
        }
        processes.retain(seen)
        result.sort { $0.rate.read + $0.rate.write > $1.rate.read + $1.rate.write }
        publish(.init(sampledAt: Date(), devices: readDevices(time: now), processes: Array(result.prefix(8)),
                      readableProcesses: seen.count, unavailableProcesses: unavailable))
    }

    private static func physicalMediaName(_ driver: io_registry_entry_t) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let protocolInfo = IORegistryEntrySearchCFProperty(driver, kIOServicePlane, "Protocol Characteristics" as CFString,
                kCFAllocatorDefault, options) as? [String: Any],
              let location = protocolInfo["Physical Interconnect Location"] as? String,
              location != "Virtual", protocolInfo["Physical Interconnect"] as? String != "Virtual Interface" else { return nil }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOMedia") != 0,
                  IORegistryEntryCreateCFProperty(child, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool == true,
                  let bsd = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(child, &name)
            return "\(String(cString: name)) · \(bsd)"
        }
        return nil
    }

    private func readDevices(time: Double) -> [DeviceDiskActivity] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            devices = .init(); return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [DeviceDiskActivity] = []
        var seen = Set<UInt64>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Skip image-backed storage and empty readers. A whole IOMedia child is the
            // unit counted once, independent of APFS volumes mounted above it.
            guard let mediaName = Self.physicalMediaName(service) else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let read = stats["Bytes (Read)"] as? NSNumber,
                  let write = stats["Bytes (Write)"] as? NSNumber else { continue }
            guard seen.insert(id).inserted else { continue }
            result.append(.init(id: id, name: mediaName,
                                rate: devices.sample(key: id, read: read.uint64Value, write: write.uint64Value, time: time)))
        }
        devices.retain(seen)
        return result.sorted { $0.id < $1.id }
    }
}
