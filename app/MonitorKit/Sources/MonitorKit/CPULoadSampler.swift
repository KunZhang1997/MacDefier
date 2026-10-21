// Adapted from Stats Modules/CPU/readers.swift LoadReader (MIT)
// Copyright (c) 2019 Serhiy Mytrovtsiy.
// Removed: Store, SystemKit cores, NextLog, Kit.Reader.

import Foundation
import Darwin

public final class CPULoadSampler: Sampler<CPULoad> {
    private var cpuInfo: processor_info_array_t!
    private var prevCpuInfo: processor_info_array_t?
    private var numCpuInfo: mach_msg_type_number_t = 0
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private var numCPUs: UInt32 = 0
    private let lock = NSLock()
    private var previousInfo = host_cpu_load_info()
    private var hasHyperthreadingCores = false
    private var response = CPULoad()
    private var numCPUsU: natural_t = 0
    private var usagePerCore: [Double] = []
    /// 首帧只建基线不发布：首次差值基于开机累计计数，曲线会显示历史均值
    private var hasBaseline = false
    /// When false, averages sibling HT threads (Stats default).
    public var showHyperthreadedCores: Bool = false

    public override func setup() {
        hasHyperthreadingCores = Sysctl.byName("hw.physicalcpu") != Sysctl.byName("hw.logicalcpu")
        var mib: [Int32] = [CTL_HW, HW_NCPU]
        var size = MemoryLayout<UInt32>.size
        let status = sysctl(&mib, 2, &numCPUs, &size, nil, 0)
        if status != 0 {
            numCPUs = 1
        }
    }

    public override func samplingDidStart() {
        hasBaseline = false
        previousInfo = host_cpu_load_info()
        response = CPULoad()
        if let previous = prevCpuInfo {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previous),
                          vm_size_t(MemoryLayout<integer_t>.stride * Int(numPrevCpuInfo)))
        }
        prevCpuInfo = nil
        numPrevCpuInfo = 0
        publish(nil)
    }

    public override func read() {
        let result: kern_return_t = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUsU,
            &cpuInfo,
            &numCpuInfo
        )

        if result == KERN_SUCCESS {
            lock.lock()
            usagePerCore = []

            for i in 0 ..< Int32(numCPUs) {
                let inUse: Int32
                let total: Int32
                if let prevCpuInfo {
                    // 内核 tick 为 32 位，须 wrapping 减法（与下方 host_cpu_load_info 的 &- 一致）
                    let u = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        &- prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                    let s = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        &- prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                    let n = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                        &- prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                    let idle = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                        &- prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                    inUse = u &+ s &+ n
                    total = inUse &+ idle
                } else {
                    inUse = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        &+ cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        &+ cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                    total = inUse &+ cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                }
                if total != 0 {
                    usagePerCore.append(Double(inUse) / Double(total))
                }
            }
            lock.unlock()

            if showHyperthreadedCores || !hasHyperthreadingCores {
                response.usagePerCore = usagePerCore
            } else {
                response.usagePerCore = []
                var i = 0
                while i < usagePerCore.count / 2 {
                    let a = i * 2
                    if usagePerCore.indices.contains(a), usagePerCore.indices.contains(a + 1) {
                        response.usagePerCore.append((usagePerCore[a] + usagePerCore[a + 1]) / 2)
                    }
                    i += 1
                }
            }

            if let prevCpuInfo {
                let prevSize = MemoryLayout<integer_t>.stride * Int(numPrevCpuInfo)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevSize))
            }
            prevCpuInfo = cpuInfo
            numPrevCpuInfo = numCpuInfo
            cpuInfo = nil
            numCpuInfo = 0
        }

        guard let cpuInfoHost = hostCPULoadInfo() else {
            hasBaseline = false
            publish(nil)
            return
        }

        let delta = Self.deltaLoad(current: cpuInfoHost, previous: previousInfo)
        previousInfo = cpuInfoHost
        // 首帧只建基线不发布
        if !hasBaseline {
            hasBaseline = true
            return
        }
        guard let delta else { publish(nil); return }
        response.systemLoad = delta.systemLoad
        response.userLoad = delta.userLoad
        response.idleLoad = delta.idleLoad
        response.totalUsage = delta.totalUsage
        response.sampledAt = Date()
        response.freshnessLimit = max(15, Double(interval) * 2)
        publish(response)
    }

    static func deltaLoad(current: host_cpu_load_info, previous: host_cpu_load_info) -> CPULoad? {
        let user = Double(current.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(current.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(current.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(current.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        var value = CPULoad()
        value.systemLoad = system / total
        value.userLoad = (user + nice) / total
        value.idleLoad = idle / total
        value.totalUsage = value.systemLoad + value.userLoad
        return value
    }

    private func hostCPULoadInfo() -> host_cpu_load_info? {
        let count = MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var info = host_cpu_load_info()
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info
    }
}

public final class CPUAverageLoadSampler: Sampler<CPUAverageLoad> {
    public override func read() {
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) != -1 {
            publish(CPUAverageLoad(load1: load[0], load5: load[1], load15: load[2]))
        }
    }
}
