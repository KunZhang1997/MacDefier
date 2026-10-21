// Adapted from Stats Modules/RAM/readers.swift UsageReader (MIT)
// Copyright (c) 2019 Serhiy Mytrovtsiy.

import Foundation
import Darwin

public final class RAMUsageSampler: Sampler<RAMUsage> {
    private var swapRates = CounterRateTracker<Int>()
    public override func samplingDidStart() { swapRates = .init() }
    private var totalSize: Double = 0

    public override func setup() {
        var stats = host_basic_info()
        var count = UInt32(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(mach_host_self(), HOST_BASIC_INFO, $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            totalSize = Double(stats.max_mem)
        }
    }

    public override func read() {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, totalSize > 0 else {
            publish(nil)
            return
        }

        let page = Double(vm_page_size)
        let active = Double(stats.active_count) * page
        let speculative = Double(stats.speculative_count) * page
        let inactive = Double(stats.inactive_count) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let purgeable = Double(stats.purgeable_count) * page
        let external = Double(stats.external_page_count) * page
        let swapins = Int64(stats.swapins)
        let swapouts = Int64(stats.swapouts)

        let used = active + inactive + speculative + wired + compressed - purgeable - external
        let free = totalSize - used

        let pressure = Self.readPressure()
        let swap = Self.readSwap()

        var value = RAMUsage(
            total: totalSize,
            used: used,
            free: free,
            active: active,
            inactive: inactive,
            wired: wired,
            compressed: compressed,
            app: used - wired - compressed,
            cache: purgeable + external,
            swap: swap,
            pressure: pressure,
            swapins: swapins,
            swapouts: swapouts,
            sampledAt: Date()
        )
        value.swapRate = swapRates.sample(key: 0, read: UInt64(stats.swapins), write: UInt64(stats.swapouts), time: ProcessInfo.processInfo.systemUptime).map { IORate(read: $0.read * page, write: $0.write * page) }
        value.freshnessLimit = max(15, Double(interval) * 2)
        publish(value)
    }

    typealias SysctlRead = (String, UnsafeMutableRawPointer, inout Int) -> Int32

    private static func readSysctl(_ name: String, _ value: UnsafeMutableRawPointer, _ size: inout Int) -> Int32 {
        sysctlbyname(name, value, &size, nil, 0)
    }

    static func readPressure(using read: SysctlRead = readSysctl) -> MemoryPressureInfo {
        var size = MemoryLayout<Int32>.size
        var level: Int32 = 0
        let result = read("kern.memorystatus_vm_pressure_level", &level, &size)
        guard result == 0, size == MemoryLayout<Int32>.size else { return .init() }
        let value: MemoryPressure
        switch level {
        case 1: value = .normal
        case 2: value = .warning
        case 4: value = .critical
        default: value = .unknown
        }
        return .init(level: Int(level), value: value)
    }

    static func readSwap(using read: SysctlRead = readSysctl) -> SwapUsage {
        var size = MemoryLayout<xsw_usage>.size
        var swap = xsw_usage()
        let result = read("vm.swapusage", &swap, &size)
        guard result == 0, size == MemoryLayout<xsw_usage>.size,
              swap.xsu_used <= swap.xsu_total, swap.xsu_avail <= swap.xsu_total else { return .init() }
        return .init(total: Double(swap.xsu_total), used: Double(swap.xsu_used),
                     free: Double(swap.xsu_avail), isAvailable: true)
    }
}
