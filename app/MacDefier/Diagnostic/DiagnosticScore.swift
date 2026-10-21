// DiagnosticScore — finding-driven system score (方案 A).
// 从 100 扣「可解释、可行动」问题；非 (1 − 占用率) 平均。

import AppKit
import Foundation
import MonitorKit

struct DiagnosticScoreDeduction: Sendable, Equatable, Identifiable {
    enum Domain: String, Sendable {
        case load
        case space
        case memory
    }

    var id: String { "\(domain.rawValue)-\(reasonKey)-\(points)" }
    var domain: Domain
    var points: Int
    /// L10n key under diag.score.reason.*
    var reasonKey: String
}

struct DiagnosticScoreBreakdown: Sendable, Equatable {
    var total: Int?
    /// 100 − load 域扣分
    var loadScore: Int?
    /// 100 − space 域扣分
    var spaceScore: Int?
    /// 100 − memory 域扣分
    var memoryScore: Int?
    var includesCleanupScan: Bool
    var deductions: [DiagnosticScoreDeduction]

    var isComplete: Bool { total != nil }

    var statusKey: String {
        guard let total else { return "diag.status.incomplete" }
        if total >= 85 { return "diag.status.good" }
        if total >= 65 { return "diag.status.ok" }
        if total >= 40 { return "diag.status.tight" }
        return "diag.status.attention"
    }

    /// 扣分最大的最多 2 个 reason key（用于副文案）
    var topReasonKeys: [String] {
        deductions
            .sorted { $0.points > $1.points }
            .prefix(2)
            .map(\.reasonKey)
    }

    static let empty = DiagnosticScoreBreakdown(
        total: nil,
        loadScore: nil,
        spaceScore: nil,
        memoryScore: nil,
        includesCleanupScan: false,
        deductions: []
    )
}

/// 清理扫描侧输入；nil = 未扫，不扣 junk/trash/大软件
struct DiagnosticScoreCleanupInput: Sendable, Equatable {
    var junkBytes: UInt64
    var trashBytes: UInt64
    var largestAppBytes: UInt64
    var isPartial: Bool = false
}

enum DiagnosticScore {
    // MARK: - Thresholds (与 DiagnosticScanEngine 发现档对齐)

    private static let diskHighUsage = 0.92
    private static let diskWarnUsage = 0.85
    /// 仅系统根卷使用绝对空闲阈值（外置盘不用 20GB 规则）
    private static let diskFreeHighBytes: Double = 20 * 1_073_741_824

    private static let cpuHigh = 0.85
    private static let cpuWarn = 0.65
    private static let hogExtra = 70.0
    private static let loadCap = 16
    /// 清理类扣分上限，避免「可回收」制造恐慌
    private static let cleanupDeductionCap = 15

    /// 系统根卷：`.system` 或挂载点 `/`
    static func isSystemVolume(_ disk: DiskVolume) -> Bool {
        disk.kind == .system || disk.path == "/"
    }

    /// 系统盘是否偏紧（AI / 卸载 CTA 门控共用）
    static func isSystemDiskTight(_ disks: [DiskVolume]) -> Bool {
        guard let sys = disks.first(where: isSystemVolume), sys.total.isFinite, sys.total > 0,
              sys.free.isFinite, (0...sys.total).contains(sys.free) else { return false }
        return sys.usage >= 0.88 || sys.free < 25 * 1_073_741_824
    }

    static func evaluate(
        snapshot: MonitorSnapshot,
        cleanup: DiagnosticScoreCleanupInput?,
        now: Date = Date()
    ) -> DiagnosticScoreBreakdown {
        var loadPts = 0
        var spacePts = 0
        var memPts = 0
        var items: [DiagnosticScoreDeduction] = []

        // —— 磁盘：仅系统根卷参与「系统空间危急」主扣分 ——
        let disks = snapshot.disks.physical.isEmpty ? snapshot.disks : snapshot.disks.physical
        let diskAvailable = snapshot.systemDiskIsFresh(at: now)
        if diskAvailable, let sys = disks.first(where: isSystemVolume) {
            if sys.usage >= diskHighUsage || sys.free < diskFreeHighBytes {
                spacePts += 35
                items.append(.init(domain: .space, points: 35, reasonKey: "disk_high"))
            } else if sys.usage >= diskWarnUsage {
                spacePts += 18
                items.append(.init(domain: .space, points: 18, reasonKey: "disk_warn"))
            }
        }
        // 外置盘：不按 20GB 绝对阈值扣系统分（中性提醒在 findings，不进总分恐吓）

        // —— 内存压力（不用 used%）——
        let cpuAvailable = snapshot.cpuIsFresh(at: now)
        let ramAvailable = snapshot.ramIsFresh(at: now)
            && snapshot.ram?.pressure.value != .unknown && snapshot.ram?.swap.isAvailable == true
        if snapshot.ramIsFresh(at: now), let ram = snapshot.ram {
            switch ram.pressure.value {
            case .critical:
                memPts += 25
                items.append(.init(domain: .memory, points: 25, reasonKey: "ram_critical"))
            case .warning:
                memPts += 12
                items.append(.init(domain: .memory, points: 12, reasonKey: "ram_warn"))
            case .normal, .unknown:
                break
            }
        }

        // —— CPU / hog ——
        var cpuPts = 0
        if cpuAvailable, let cpu = snapshot.cpu {
            let u = cpu.totalUsage
            if u >= cpuHigh {
                cpuPts += 12
                items.append(.init(domain: .load, points: 12, reasonKey: "cpu_high"))
            } else if u >= cpuWarn {
                cpuPts += 6
                items.append(.init(domain: .load, points: 6, reasonKey: "cpu_warn"))
            }
        }
        if cpuAvailable, snapshot.topCPUIsFresh(at: now), let hog = snapshot.topCPU.first, hog.usage >= hogExtra, isUserAppProcess(pid: hog.pid) {
            let extra = min(4, max(0, loadCap - cpuPts))
            if extra > 0 {
                cpuPts += extra
                items.append(.init(domain: .load, points: extra, reasonKey: "cpu_hog"))
            }
        }
        loadPts = min(loadCap, cpuPts)

        // —— 清理扫描：可解释分档扣分 + 上限（产品：保留清理部分但 breakdown 诚实）——
        var includesCleanup = false
        includesCleanup = cleanup != nil
        if let cleanup, !cleanup.isPartial {
            var cleanupPts = 0
            let junk = cleanup.junkBytes
            if junk >= 5 * 1_073_741_824 {
                let p = 8
                cleanupPts += p
                items.append(.init(domain: .space, points: p, reasonKey: "junk_high"))
            } else if junk >= 1 * 1_073_741_824 {
                let p = 4
                cleanupPts += p
                items.append(.init(domain: .space, points: p, reasonKey: "junk_warn"))
            }
            let trash = cleanup.trashBytes
            if trash >= 1 * 1_073_741_824 {
                let p = 6
                cleanupPts += p
                items.append(.init(domain: .space, points: p, reasonKey: "trash_high"))
            } else if trash >= 200 * 1_024 * 1_024 {
                let p = 3
                cleanupPts += p
                items.append(.init(domain: .space, points: p, reasonKey: "trash_warn"))
            }
            // 大软件体量不单独重扣（大≠问题）；仅作信息
            _ = cleanup.largestAppBytes
            spacePts += min(cleanupDeductionCap, cleanupPts)
        }

        let totalDeduction = loadPts + spacePts + memPts
        let total = max(0, min(100, 100 - totalDeduction))

        return DiagnosticScoreBreakdown(
            total: cpuAvailable && ramAvailable && diskAvailable && cleanup?.isPartial != true ? total : nil,
            loadScore: cpuAvailable ? max(0, min(100, 100 - loadPts)) : nil,
            spaceScore: diskAvailable && cleanup?.isPartial != true ? max(0, min(100, 100 - spacePts)) : nil,
            memoryScore: ramAvailable ? max(0, min(100, 100 - memPts)) : nil,
            includesCleanupScan: includesCleanup,
            deductions: items.sorted { $0.points > $1.points }
        )
    }

    /// 首页：有新鲜扫描则带 junk/trash/大软件；否则仅实时部分分
    static func evaluateLive(
        snapshot: MonitorSnapshot,
        report: DiagnosticReport,
        hasFreshScan: Bool
    ) -> DiagnosticScoreBreakdown {
        let cleanup: DiagnosticScoreCleanupInput?
        if hasFreshScan || report.cleanupIsPartial, report.scannedAt != .distantPast {
            cleanup = DiagnosticScoreCleanupInput(
                junkBytes: report.junkBytes,
                trashBytes: report.trashBytes,
                largestAppBytes: report.largeApps.map(\.bytes).max() ?? 0,
                isPartial: report.cleanupIsPartial
            )
        } else {
            cleanup = nil
        }
        return evaluate(snapshot: snapshot, cleanup: cleanup)
    }

    private static func isUserAppProcess(pid: Int) -> Bool {
        guard let pid32 = pid_t(exactly: pid) else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid32) else { return false }
        if let bid = app.bundleIdentifier?.lowercased(), bid.hasPrefix("com.apple.") { return false }
        if app == NSRunningApplication.current { return false }
        return true
    }
}
