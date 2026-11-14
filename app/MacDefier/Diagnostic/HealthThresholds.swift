// HealthThresholds — single source of truth for system load, memory pressure, and disk space thresholds.

import Foundation
import MonitorKit

enum HealthThresholds {
    /// CPU total usage [0...1]
    static let cpuHighUsage: Double = 0.85
    static let cpuWarnUsage: Double = 0.65

    /// System volume capacity thresholds
    static let systemDiskCriticalUsage: Double = 0.92
    static let systemDiskTightUsage: Double = 0.88
    static let systemDiskWarnUsage: Double = 0.85
    static let externalDiskInfoUsage: Double = 0.95

    static let systemDiskCriticalFreeBytes: Double = 20 * 1_000_000_000
    static let systemDiskTightFreeBytes: Double = 25 * 1_000_000_000

    /// Reclaimable junk / Trash thresholds (decimal bytes, matching `.file` display)
    static let junkHighBytes: UInt64 = 5 * 1_000_000_000
    static let junkWarnBytes: UInt64 = 1 * 1_000_000_000
    static let trashHighBytes: UInt64 = 1 * 1_000_000_000
    static let trashWarnBytes: UInt64 = 200 * 1_000_000

    static func isSystemVolume(_ disk: DiskVolume) -> Bool {
        disk.kind == .system || disk.path == "/"
    }

    static func isSystemDiskTight(_ disks: [DiskVolume]) -> Bool {
        guard let sys = disks.first(where: isSystemVolume),
              sys.total.isFinite, sys.total > 0,
              sys.free.isFinite, (0...sys.total).contains(sys.free) else { return false }
        return sys.usage >= systemDiskTightUsage || sys.free < systemDiskTightFreeBytes
    }

    static func isSystemDiskCritical(_ disk: DiskVolume) -> Bool {
        guard isSystemVolume(disk), disk.total.isFinite, disk.total > 0,
              disk.free.isFinite, (0...disk.total).contains(disk.free) else { return false }
        return disk.usage >= systemDiskCriticalUsage || disk.free < systemDiskCriticalFreeBytes
    }

    static func isMemoryPressureElevated(_ ram: RAMUsage?) -> Bool {
        guard let pressure = ram?.pressure.value else { return false }
        return pressure == .warning || pressure == .critical
    }
}
