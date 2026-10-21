// DiagnosticScan — home findings with actionable CTAs (not chat walls).

import AppKit
import Foundation
import MonitorKit
import CleanupKit

enum FindingKind: String, Sendable {
    case monitor, cleanup, software, ok

    var title: String {
        switch self {
        case .monitor: return L10n.t("finding.kind.monitor")
        case .cleanup: return L10n.t("finding.kind.cleanup")
        case .software: return L10n.t("finding.kind.software")
        case .ok: return L10n.t("finding.kind.ok")
        }
    }
}

enum FindingSeverity: Int, Comparable, Sendable {
    case info = 0
    case warn = 1
    case high = 2

    static func < (l: FindingSeverity, r: FindingSeverity) -> Bool { l.rawValue < r.rawValue }

    var label: String {
        switch self {
        case .info: return L10n.t("finding.sev.info")
        case .warn: return L10n.t("finding.sev.warn")
        case .high: return L10n.t("finding.sev.high")
        }
    }
}

enum FindingAction: String, Sendable {
    case openMonitor
    case openCleanupAndScan   // 跳清理并开始扫
    case openSoftware
    case quitProcess          // 尝试结束进程（需 pid）
    case openMister
    case none
}

struct DiagnosticFinding: Identifiable, Sendable, Equatable {
    let id: String
    let kind: FindingKind
    let severity: FindingSeverity
    let title: String
    let detail: String
    let metric: String?
    let action: FindingAction
    let actionTitle: String
    /// 次要按钮（可选）
    let secondaryAction: FindingAction?
    let secondaryActionTitle: String?
    let processPID: Int?
    let processName: String?
    /// Deep link for uninstall (from AI actions)
    let appPath: String?
    let appBundleID: String?

    init(
        id: String = UUID().uuidString,
        kind: FindingKind,
        severity: FindingSeverity,
        title: String,
        detail: String,
        metric: String? = nil,
        action: FindingAction,
        actionTitle: String,
        secondaryAction: FindingAction? = nil,
        secondaryActionTitle: String? = nil,
        processPID: Int? = nil,
        processName: String? = nil,
        appPath: String? = nil,
        appBundleID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.metric = metric
        self.action = action
        self.actionTitle = actionTitle
        self.secondaryAction = secondaryAction
        self.secondaryActionTitle = secondaryActionTitle
        self.processPID = processPID
        self.processName = processName
        self.appPath = appPath
        self.appBundleID = appBundleID
    }
}

struct DiagnosticReport: Sendable {
    var findings: [DiagnosticFinding]
    var scannedAt: Date
    var junkBytes: UInt64
    /// 废纸篓单独体积（评分/预警用）
    var trashBytes: UInt64
    var largeApps: [(name: String, bytes: UInt64)]
    var summaryLine: String
    var aiNarrative: String?
    /// A bounded or failed directory walk supplies a lower bound, never an all-clear.
    var cleanupIsPartial: Bool = false
    var monitorEvidenceIsComplete: Bool = false
    /// Used only to invalidate an AI interpretation when its evidence changes.
    var monitorEvidenceFingerprint: String = ""

    static var empty: DiagnosticReport {
        DiagnosticReport(
            findings: [],
            scannedAt: .distantPast,
            junkBytes: 0,
            trashBytes: 0,
            largeApps: [],
            summaryLine: L10n.t("diag.not_scanned"),
            aiNarrative: nil
        )
    }

    var highCount: Int { findings.filter { $0.severity == .high }.count }
    var warnCount: Int { findings.filter { $0.severity == .warn }.count }
}

enum DiagnosticScanEngine {
    /// 废纸篓独立预警阈值（已删未清空，占磁盘）
    private static let trashWarnBytes: UInt64 = 200 * 1024 * 1024 // 200 MB
    private static let trashHighBytes: UInt64 = 1 * 1_073_741_824 // 1 GB

    /// hog 提示只针对可解析的第三方 App：系统进程/后台守护不给「结束进程」入口
    private static func isUserAppProcess(pid: Int) -> Bool {
        guard let pid32 = pid_t(exactly: pid) else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid32) else { return false }
        if let bid = app.bundleIdentifier?.lowercased() {
            if bid.hasPrefix("com.apple.") { return false }
            if bid == "com.macdefier.app" || bid.hasPrefix("com.macdefier.") { return false }
        }
        // Never offer quit for our own process
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return false }
        if let path = app.bundleURL?.path, path.localizedCaseInsensitiveContains("MacDefier.app") {
            return false
        }
        return true
    }

    static func buildReport(
        snapshot: MonitorSnapshot,
        junkBytes: UInt64,
        trashBytes: UInt64 = 0,
        apps: [InstalledApp],
        appSizesAvailable: Bool = true,
        cleanupIsPartial: Bool = false,
        now: Date = Date()
    ) -> DiagnosticReport {
        var findings: [DiagnosticFinding] = []

        let openMon = L10n.t("diag.act.open_monitor")
        let goClean = L10n.t("diag.act.cleanup_scan")

        if !snapshot.hasFreshCoreMetrics(at: now) {
            findings.append(DiagnosticFinding(
                id: "monitor-incomplete", kind: .monitor, severity: .info,
                title: L10n.t("diag.find.metrics_unknown"),
                detail: L10n.t("diag.find.metrics_unknown_detail"),
                action: .openMonitor, actionTitle: openMon
            ))
        }
        if !snapshot.systemDiskIsFresh(at: now) {
            findings.append(DiagnosticFinding(
                id: "storage-incomplete", kind: .monitor, severity: .info,
                title: L10n.t("diag.find.storage_unknown"),
                detail: L10n.t("diag.find.storage_unknown_detail"),
                action: .openMonitor, actionTitle: openMon
            ))
        }

        if snapshot.cpuIsFresh(at: now), let cpu = snapshot.cpu {
            let pct = cpu.totalUsage * 100
            if pct >= 85 {
                let sep = AppLanguage.current.isEnglish ? ", " : "、"
                let top = snapshot.topCPU.prefix(3).map { "\($0.name) \(String(format: "%.0f", $0.usage))%" }.joined(separator: sep)
                findings.append(DiagnosticFinding(
                    id: "cpu-high",
                    kind: .monitor,
                    severity: .high,
                    title: L10n.t("diag.find.cpu_high"),
                    detail: top.isEmpty
                        ? L10n.t("diag.find.cpu_high_detail", Int(pct))
                        : L10n.t("diag.find.cpu_high_detail_top", Int(pct), top),
                    metric: String(format: "%.0f%%", pct),
                    action: .openMonitor,
                    actionTitle: openMon
                ))
            } else if pct >= 65 {
                findings.append(DiagnosticFinding(
                    id: "cpu-warn",
                    kind: .monitor,
                    severity: .warn,
                    title: L10n.t("diag.find.cpu_high"),
                    detail: L10n.t("diag.find.cpu_warn_detail", Int(pct)),
                    metric: String(format: "%.0f%%", pct),
                    action: .openMonitor,
                    actionTitle: openMon
                ))
            }
        }

        if snapshot.ramIsFresh(at: now), let ram = snapshot.ram {
            let pct = ram.usage * 100
            let used = ByteCountFormatter.string(fromByteCount: Int64(ram.used), countStyle: .memory)
            let total = ByteCountFormatter.string(fromByteCount: Int64(ram.total), countStyle: .memory)
            switch ram.pressure.value {
            case .critical:
                findings.append(DiagnosticFinding(
                    id: "ram-critical",
                    kind: .monitor,
                    severity: .high,
                    title: L10n.t("diag.find.ram_crit"),
                    detail: L10n.t("diag.find.ram_crit_detail", used, total),
                    metric: String(format: "%.0f%%", pct),
                    action: .openMonitor,
                    actionTitle: openMon
                ))
            case .warning:
                findings.append(DiagnosticFinding(
                    id: "ram-warning",
                    kind: .monitor,
                    severity: .warn,
                    title: L10n.t("diag.find.ram_warn"),
                    detail: L10n.t("diag.find.ram_warn_detail", used, total),
                    metric: String(format: "%.0f%%", pct),
                    action: .openMonitor,
                    actionTitle: openMon
                ))
            case .normal, .unknown:
                break
            }
        }

        let disksToJudge = snapshot.disks.physical.isEmpty ? snapshot.disks : snapshot.disks.physical
        for disk in disksToJudge where snapshot.systemDiskIsFresh(at: now) {
            let pct = disk.usage * 100
            let free = ByteCountFormatter.string(fromByteCount: Int64(disk.free), countStyle: .file)
            let used = ByteCountFormatter.string(fromByteCount: Int64(disk.used), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(disk.total), countStyle: .file)
            let label = "\(disk.name) (\(disk.localizedKindLabel))"
            let isSystem = DiagnosticScore.isSystemVolume(disk)

            if isSystem {
                // 系统根卷：可用 20GB 绝对阈值 + 高使用率 → 系统危急
                if pct >= 92 || disk.free < 20 * 1_073_741_824 {
                    findings.append(DiagnosticFinding(
                        id: "disk-high-\(disk.id)",
                        kind: .cleanup,
                        severity: .high,
                        title: L10n.t("diag.find.disk_tight", label),
                        detail: L10n.t("diag.find.disk_tight_detail", used, total, free),
                        metric: String(format: "%.0f%%", pct),
                        action: .openCleanupAndScan,
                        actionTitle: goClean
                    ))
                } else if pct >= 85 {
                    findings.append(DiagnosticFinding(
                        id: "disk-warn-\(disk.id)",
                        kind: .cleanup,
                        severity: .warn,
                        title: L10n.t("diag.find.disk_warn", label),
                        detail: L10n.t("diag.find.disk_warn_detail", used, total, free),
                        metric: String(format: "%.0f%%", pct),
                        action: .openCleanupAndScan,
                        actionTitle: goClean
                    ))
                }
            } else {
                // 外置盘：仅按使用率中性提醒，不用 20GB 绝对阈值制造系统危急
                if pct >= 95 {
                    findings.append(DiagnosticFinding(
                        id: "disk-ext-\(disk.id)",
                        kind: .monitor,
                        severity: .info,
                        title: L10n.t("diag.find.disk_external", label),
                        detail: L10n.t("diag.find.disk_external_detail", used, total, free),
                        metric: String(format: "%.0f%%", pct),
                        action: .openMonitor,
                        actionTitle: openMon
                    ))
                } else if pct >= 90 {
                    findings.append(DiagnosticFinding(
                        id: "disk-ext-\(disk.id)",
                        kind: .monitor,
                        severity: .info,
                        title: L10n.t("diag.find.disk_external_warn", label),
                        detail: L10n.t("diag.find.disk_external_detail", used, total, free),
                        metric: String(format: "%.0f%%", pct),
                        action: .openMonitor,
                        actionTitle: openMon
                    ))
                }
            }
        }

        let nonTrashJunk = junkBytes - min(junkBytes, trashBytes)
        if cleanupIsPartial {
            let size = ByteCountFormatter.string(fromByteCount: Int64(junkBytes), countStyle: .file)
            findings.append(DiagnosticFinding(
                id: "cleanup-incomplete", kind: .cleanup, severity: .info,
                title: L10n.t("diag.find.cleanup_partial"),
                detail: L10n.t("diag.find.cleanup_partial_detail"),
                metric: L10n.t("diag.metric.at_least", size),
                action: .openCleanupAndScan, actionTitle: goClean
            ))
        }
        if !cleanupIsPartial, nonTrashJunk >= 5 * 1_073_741_824 {
            let sz = ByteCountFormatter.string(fromByteCount: Int64(nonTrashJunk), countStyle: .file)
            findings.append(DiagnosticFinding(
                id: "junk-high",
                kind: .cleanup,
                severity: .high,
                title: L10n.t("diag.find.junk_large"),
                detail: L10n.t("diag.find.junk_large_detail", sz),
                metric: sz,
                action: .openCleanupAndScan,
                actionTitle: goClean
            ))
        } else if !cleanupIsPartial, nonTrashJunk >= 1 * 1_073_741_824 {
            let sz = ByteCountFormatter.string(fromByteCount: Int64(nonTrashJunk), countStyle: .file)
            findings.append(DiagnosticFinding(
                id: "junk-warn",
                kind: .cleanup,
                severity: .warn,
                title: L10n.t("diag.find.junk_some"),
                detail: L10n.t("diag.find.junk_some_detail", sz),
                metric: sz,
                action: .openCleanupAndScan,
                actionTitle: goClean
            ))
        }

        if !cleanupIsPartial, trashBytes >= trashHighBytes {
            let sz = ByteCountFormatter.string(fromByteCount: Int64(trashBytes), countStyle: .file)
            findings.append(DiagnosticFinding(
                id: "trash-bin",
                kind: .cleanup,
                severity: .high,
                title: L10n.t("diag.find.trash_high"),
                detail: L10n.t("diag.find.trash_high_detail", sz),
                metric: sz,
                action: .openCleanupAndScan,
                actionTitle: goClean
            ))
        } else if !cleanupIsPartial, trashBytes >= trashWarnBytes {
            let sz = ByteCountFormatter.string(fromByteCount: Int64(trashBytes), countStyle: .file)
            findings.append(DiagnosticFinding(
                id: "trash-bin",
                kind: .cleanup,
                severity: .warn,
                title: L10n.t("diag.find.trash_warn"),
                detail: L10n.t("diag.find.trash_warn_detail", sz),
                metric: sz,
                action: .openCleanupAndScan,
                actionTitle: goClean
            ))
        }

        let largeSorted = appSizesAvailable ? apps.sorted { $0.totalBytes > $1.totalBytes } : []
        let topLarge = Array(largeSorted.prefix(5))
        // 仅系统盘紧张 + 已测体积 才提示大 App（信息级，非卸载恐吓）
        let disksForTight = snapshot.disks.physical.isEmpty ? snapshot.disks : snapshot.disks.physical
        let diskTight = snapshot.systemDiskIsFresh(at: now) && DiagnosticScore.isSystemDiskTight(disksForTight)
        if diskTight, appSizesAvailable, let biggest = largeSorted.first, biggest.totalBytes >= 8 * 1_073_741_824 {
            let size = ByteCountFormatter.string(fromByteCount: Int64(biggest.totalBytes), countStyle: .file)
            let detail: String
            if let split = biggest.formattedSizeDetail {
                detail = L10n.t("diag.find.big_app_detail_split", biggest.name, size, split)
            } else {
                detail = L10n.t("diag.find.big_app_detail", biggest.name, size)
            }
            findings.append(DiagnosticFinding(
                id: "app-space-\(biggest.bundleIdentifier)",
                kind: .software,
                severity: .info,
                title: L10n.t("diag.find.big_app", biggest.name),
                detail: detail,
                metric: size,
                action: .openSoftware,
                actionTitle: L10n.t("diag.act.open_software"),
                appPath: biggest.path,
                appBundleID: biggest.bundleIdentifier
            ))
        }

        if snapshot.cpuIsFresh(at: now), let hog = snapshot.topCPU.first, hog.usage >= 70, isUserAppProcess(pid: hog.pid) {
            let usageStr = String(format: "%.0f", hog.usage)
            findings.append(DiagnosticFinding(
                id: "proc-\(hog.pid)",
                kind: .monitor,
                severity: hog.usage >= 85 ? .high : .warn,
                title: L10n.t("diag.find.proc_hog", hog.name),
                detail: L10n.t("diag.find.proc_hog_detail", usageStr, hog.pid),
                metric: String(format: "%.0f%%", hog.usage),
                action: .quitProcess,
                actionTitle: L10n.t("diag.act.quit_proc"),
                secondaryAction: .openMonitor,
                secondaryActionTitle: openMon,
                processPID: hog.pid,
                processName: hog.name
            ))
        }

        findings.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.kind.rawValue < $1.kind.rawValue
        }

        if findings.isEmpty {
            findings.append(DiagnosticFinding(
                id: "ok-all-clear",
                kind: .ok,
                severity: .info,
                title: L10n.t("diag.find.ok"),
                detail: L10n.t("diag.find.ok_detail"),
                action: .openMister,
                actionTitle: L10n.t("diag.act.ask_mister")
            ))
        }

        let high = findings.filter { $0.severity == .high }.count
        let warn = findings.filter { $0.severity == .warn }.count
        // D01 v0.1：统一三态口径「正常 / 偏卡 / 空间紧」
        let summary = Self.statusSummaryLine(findings: findings, high: high, warn: warn)

        return DiagnosticReport(
            findings: findings,
            scannedAt: Date(),
            junkBytes: junkBytes,
            trashBytes: trashBytes,
            // 对外/给 AI 的大应用体积用 totalBytes（包+严格相关数据），避免只报壳体积
            largeApps: topLarge.map { ($0.name, $0.totalBytes) },
            summaryLine: summary,
            aiNarrative: nil,
            cleanupIsPartial: cleanupIsPartial,
            monitorEvidenceIsComplete: snapshot.hasFreshDiagnosticMetrics(at: now),
            monitorEvidenceFingerprint: evidenceFingerprint(snapshot, at: now)
        )
    }

    /// Reuse the disk walk, but judge current telemetry again. Never retain a stale all-clear or AI interpretation.
    static func refreshReport(
        _ previous: DiagnosticReport,
        snapshot: MonitorSnapshot,
        apps: [InstalledApp],
        preserveAI: Bool = true,
        now: Date = Date()
    ) -> DiagnosticReport {
        var rebuilt = buildReport(
            snapshot: snapshot, junkBytes: previous.junkBytes, trashBytes: previous.trashBytes,
            apps: apps, appSizesAvailable: false, cleanupIsPartial: previous.cleanupIsPartial, now: now
        )
        rebuilt.scannedAt = previous.scannedAt
        if preserveAI, rebuilt.monitorEvidenceIsComplete, !rebuilt.cleanupIsPartial,
           previous.monitorEvidenceFingerprint == rebuilt.monitorEvidenceFingerprint {
            rebuilt.aiNarrative = previous.aiNarrative
            let aiFindings = previous.findings.filter { $0.id.hasPrefix("ai-") }
            if !aiFindings.isEmpty {
                let aiTitles = Set(aiFindings.map(\.title))
                rebuilt.findings = aiFindings + rebuilt.findings.filter { !aiTitles.contains($0.title) }
                let base = statusSummaryLine(findings: rebuilt.findings, high: rebuilt.highCount, warn: rebuilt.warnCount)
                rebuilt.summaryLine = L10n.t("diag.summary.ai_rules", base, aiFindings.count,
                                           max(0, rebuilt.findings.count - aiFindings.count))
            }
        }
        return rebuilt
    }

    private static func evidenceFingerprint(_ snapshot: MonitorSnapshot, at now: Date) -> String {
        let cpu = snapshot.cpuIsFresh(at: now) ? snapshot.cpu.map { String(Int($0.totalUsage * 20)) } ?? "?" : "?"
        let ram = snapshot.ramIsFresh(at: now)
            ? snapshot.ram.map { "\($0.pressure.value.rawValue):\($0.swap.isAvailable):\(Int($0.usage * 10))" } ?? "?"
            : "?"
        let disks = snapshot.disks.physical.isEmpty ? snapshot.disks : snapshot.disks.physical
        let disk = snapshot.systemDiskIsFresh(at: now)
            ? disks.map { "\($0.id):\(Int($0.usage * 20)):\($0.free < 25 * 1_073_741_824)" }.sorted().joined(separator: ",")
            : "?"
        let hog = snapshot.cpuIsFresh(at: now) ? snapshot.topCPU.first.map { "\($0.pid):\(Int($0.usage / 10))" } ?? "" : ""
        return "\(cpu)|\(ram)|\(disk)|\(hog)"
    }

    /// 首页三态：正常 · 偏卡 · 空间紧（中性词，不恐吓）
    static func statusSummaryLine(findings: [DiagnosticFinding], high: Int, warn: Int) -> String {
        let stress = findings.contains {
            $0.kind == .monitor && ($0.severity == .high || $0.severity == .warn)
        }
        // “空间紧” describes actual capacity only. Reclaimable cache or Trash
        // findings remain useful cards but must not imply the disk is tight.
        let space = findings.contains {
            $0.id.hasPrefix("disk-")
                || ($0.kind == .cleanup
                    && ($0.title.localizedCaseInsensitiveContains("disk")
                        || $0.title.localizedCaseInsensitiveContains("space")
                        || $0.title.contains("磁盘空间")))
        }
        // 优先级：监控压力 → 偏卡；否则空间类 → 空间紧；其余 high → 偏卡。
        // 不可用「any high」盖掉磁盘紧张（否则「磁盘空间紧张」会误成「偏卡」）。
        let word: String
        if stress {
            word = L10n.t("status.slow")
        } else if space {
            word = L10n.t("status.space")
        } else if high > 0 {
            word = L10n.t("status.slow")
        } else if findings.contains(where: { ["monitor-incomplete", "cleanup-incomplete", "storage-incomplete"].contains($0.id) }) {
            word = L10n.t("status.incomplete")
        } else {
            word = L10n.t("status.ok")
        }
        if high > 0 {
            if warn > 0 {
                return L10n.t("status.summary.priority_warn", word, high, warn)
            }
            return L10n.t("status.summary.priority", word, high)
        }
        if warn > 0 {
            return L10n.t("status.summary.warn", word, warn)
        }
        if word == L10n.t("status.ok") {
            return L10n.t("status.summary.ok")
        }
        return word
    }

    static func contextText(for report: DiagnosticReport, snapshot: MonitorSnapshot) -> String {
        var lines: [String] = []
        lines.append(AIClient.monitorSnapshotTextSync(snapshot))
        lines.append("可清理粗算（缓存/日志等可再生；不含大体积应用数据盘点）：\(ByteCountFormatter.string(fromByteCount: Int64(report.junkBytes), countStyle: .file))")
        if report.cleanupIsPartial {
            lines.append("清理盘点未完成：以上体积仅为下限，不能据此判断无垃圾或空间正常。")
        }
        if !report.largeApps.isEmpty {
            lines.append("大体积应用：" + report.largeApps.map {
                "\($0.name) \(ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file))"
            }.joined(separator: "；"))
        }
        lines.append("规则发现：")
        for f in report.findings.prefix(12) {
            lines.append("- [\(f.severity.label)/\(f.kind.title)] \(f.title)：\(f.detail)")
        }
        return lines.joined(separator: "\n")
    }

    /// 去掉 ** 等 markdown，方便卡片展示（JSON 残片见 DefierActionParser.userVisibleProse）
    static func plainText(_ markdownish: String) -> String {
        DefierActionParser.userVisibleProse(markdownish)
    }
}

extension AIClient {
    static func monitorSnapshotTextSync(_ s: MonitorSnapshot) -> String {
        var lines: [String] = []
        let now = Date()
        if s.cpuIsFresh(at: now), let c = s.cpu {
            lines.append(String(format: "CPU 占用约 %.0f%%", c.totalUsage * 100))
        }
        if s.ramIsFresh(at: now), let r = s.ram {
            lines.append(String(
                format: "内存约 %.0f%%（%@ / %@）",
                r.usage * 100,
                ByteCountFormatter.string(fromByteCount: Int64(r.used), countStyle: .memory),
                ByteCountFormatter.string(fromByteCount: Int64(r.total), countStyle: .memory)
            ))
            lines.append("内存压力：\(r.pressure.value.rawValue)")
            lines.append(r.swap.isAvailable
                ? "Swap：\(ByteCountFormatter.string(fromByteCount: Int64(r.swap.used), countStyle: .memory))"
                : "Swap：读取不可用，不能视为零")
        }
        if !s.hasFreshDiagnosticMetrics(at: now) {
            lines.append("监控证据不足：CPU/内存/系统磁盘数据缺失、过期或读取失败，不能据此判断系统正常。")
        }
        if !s.systemDiskIsFresh(at: now) {
            // no-op
        } else {
            for d in s.disks.prefix(8) {
                lines.append(String(
                    format: "磁盘 · %@（%@）约 %.0f%%，剩余 %@",
                    d.name,
                    d.localizedKindLabel,
                    d.usage * 100,
                    ByteCountFormatter.string(fromByteCount: Int64(d.free), countStyle: .file)
                ))
            }
        }
        if s.cpuIsFresh(at: now), !s.topCPU.isEmpty {
            let top = s.topCPU.prefix(5).map { "\($0.name) \(String(format: "%.0f", $0.usage))%" }.joined(separator: "；")
            lines.append("Top CPU：\(top)")
        }
        return lines.isEmpty ? "（监控数据尚未就绪）" : lines.joined(separator: "\n")
    }
}
