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
    case openAITools          // 跳 AI 工具专项页
    case openSoftware
    case openSoftwareServices // 跳 AI 工具 → 后台服务
    case quitProcess          // 尝试结束进程（需 pid）
    case quitAutomatedBrowser // 尝试结束后台自动化/调试浏览器实例
    case shutdownSimulators   // 关闭后台 Booted iOS 模拟器
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
    let processIdentity: MonitoredProcessIdentity?
    /// Deep link for uninstall (from AI actions)
    let appPath: String?
    let appBundleID: String?
    let serviceFocusLabel: String?

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
        processIdentity: MonitoredProcessIdentity? = nil,
        appPath: String? = nil,
        appBundleID: String? = nil,
        serviceFocusLabel: String? = nil
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
        self.processIdentity = processIdentity
        self.appPath = appPath
        self.appBundleID = appBundleID
        self.serviceFocusLabel = serviceFocusLabel
    }
}

struct DiagnosticReport: Sendable {
    var findings: [DiagnosticFinding]
    var scannedAt: Date
    var junkBytes: UInt64
    /// 废纸篓单独体积（评分/预警用）
    var trashBytes: UInt64
    var largeApps: [(name: String, bytes: UInt64)]
    var retainedProcessFamilies: [ProcessFamilySummary] = []
    var retainedUserServices: [UserLaunchAgentItem] = []
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
    private static let trashWarnBytes: UInt64 = HealthThresholds.trashWarnBytes
    private static let trashHighBytes: UInt64 = HealthThresholds.trashHighBytes

    /// hog 提示只针对可安全正常退出的前台第三方 App（与 MonitoredApplicationExit 严格一致）
    private static func isUserAppProcess(pid: Int) -> Bool {
        DefierActionGuard.isSafeToQuit(pid: pid)
    }

    static func buildReport(
        snapshot: MonitorSnapshot,
        junkBytes: UInt64,
        trashBytes: UInt64 = 0,
        apps: [InstalledApp],
        appSizesAvailable: Bool = true,
        cleanupIsPartial: Bool = false,
        retainedFamilies: [ProcessFamilySummary] = [],
        userServices: [UserLaunchAgentItem] = [],
        retainedScannedAt: Date = .distantPast,
        now: Date = Date()
    ) -> DiagnosticReport {
        var findings: [DiagnosticFinding] = []

        let openMon = L10n.t("diag.act.open_monitor")
        let goClean = L10n.t("diag.act.cleanup_scan")

        let effectiveFamilies: [ProcessFamilySummary] = {
            if snapshot.processFamiliesAreFresh(at: now) {
                return snapshot.processFamilies
            }
            if snapshot.hasFreshDiagnosticMetrics(at: now),
               ScanReusePolicy.isFresh(retainedScannedAt, ttl: ScanReusePolicy.diagnosticTTL) {
                return retainedFamilies
            }
            return []
        }()

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
            if cpu.totalUsage >= HealthThresholds.cpuHighUsage {
                let sep = AppLanguage.current.isEnglish ? ", " : "、"
                let top = snapshot.topCPUIsFresh(at: now)
                    ? snapshot.topCPU.prefix(3).map { "\($0.name) \(String(format: "%.0f", $0.usage))%" }.joined(separator: sep)
                    : ""
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
            } else if cpu.totalUsage >= HealthThresholds.cpuWarnUsage {
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
            let disksForSwap = snapshot.disks.physical.isEmpty ? snapshot.disks : snapshot.disks.physical
            let sysTight = snapshot.systemDiskIsFresh(at: now) && HealthThresholds.isSystemDiskTight(disksForSwap)
            let swapStr = ByteCountFormatter.string(fromByteCount: Int64(ram.swap.used), countStyle: .memory)
            let sysFree = disksForSwap.first(where: DiagnosticScore.isSystemVolume)
                .map { ByteCountFormatter.string(fromByteCount: Int64($0.free), countStyle: .file) } ?? "—"
            let hasHighSwapCombo = ram.swap.isAvailable
                && sysTight
                && ram.swap.used >= HealthThresholds.swapElevatedBytes
                && (ram.swap.used >= HealthThresholds.swapHighComboBytes
                    || (disksForSwap.first(where: DiagnosticScore.isSystemVolume).map(HealthThresholds.isSystemDiskCritical) ?? false))

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
                    actionTitle: openMon,
                    secondaryAction: sysTight ? .openCleanupAndScan : nil,
                    secondaryActionTitle: sysTight ? goClean : nil
                ))
            case .warning:
                if ram.swap.isAvailable, sysTight, ram.swap.used >= HealthThresholds.swapElevatedBytes {
                    findings.append(DiagnosticFinding(
                        id: "ram-warning",
                        kind: .monitor,
                        severity: hasHighSwapCombo ? .high : .warn,
                        title: L10n.t("diag.find.swap_disk_combo"),
                        detail: L10n.t("diag.find.swap_disk_combo_detail", swapStr, sysFree),
                        metric: swapStr,
                        action: .openMonitor,
                        actionTitle: openMon,
                        secondaryAction: .openCleanupAndScan,
                        secondaryActionTitle: goClean
                    ))
                } else {
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
                }
            case .normal:
                if ram.swap.isAvailable {
                    if sysTight && ram.swap.used >= HealthThresholds.swapElevatedBytes {
                        findings.append(DiagnosticFinding(
                            id: "swap-disk-combo",
                            kind: .monitor,
                            severity: hasHighSwapCombo ? .high : .warn,
                            title: L10n.t("diag.find.swap_disk_combo"),
                            detail: L10n.t("diag.find.swap_disk_combo_detail", swapStr, sysFree),
                            metric: swapStr,
                            action: .openMonitor,
                            actionTitle: openMon,
                            secondaryAction: .openCleanupAndScan,
                            secondaryActionTitle: goClean
                        ))
                    } else if ram.swap.used >= HealthThresholds.swapHeavyStandaloneBytes {
                        findings.append(DiagnosticFinding(
                            id: "swap-elevated",
                            kind: .monitor,
                            severity: .warn,
                            title: L10n.t("diag.find.swap_elevated"),
                            detail: L10n.t("diag.find.swap_elevated_detail", swapStr, used, total),
                            metric: swapStr,
                            action: .openMonitor,
                            actionTitle: openMon
                        ))
                    }
                }
            case .unknown:
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
                // 系统根卷：可用空间绝对阈值 + 高使用率 → 系统危急
                if HealthThresholds.isSystemDiskCritical(disk) {
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
                } else if disk.usage >= HealthThresholds.systemDiskWarnUsage {
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
                if disk.usage >= HealthThresholds.externalDiskInfoUsage {
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
        if !cleanupIsPartial, nonTrashJunk >= HealthThresholds.junkHighBytes {
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
        } else if !cleanupIsPartial, nonTrashJunk >= HealthThresholds.junkWarnBytes {
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

        let automatedBrowserPIDs = Set(effectiveFamilies.filter { $0.kind == .automatedBrowser }.compactMap(\.rootPID))
        var reportedSingleHogPID: Int?
        var reportedSingleHogAppPath: String?
        if snapshot.cpuIsFresh(at: now),
           snapshot.topCPUIsFresh(at: now),
           let hog = snapshot.topCPU.first,
           hog.usage >= 70,
           !automatedBrowserPIDs.contains(hog.pid),
           isUserAppProcess(pid: hog.pid) {
            reportedSingleHogPID = hog.pid
            reportedSingleHogAppPath = hog.identity?.appPath
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
                processName: hog.name,
                processIdentity: hog.identity
            ))
        }

        // WindowServer compositing pressure (either via fresh topCPU or effectiveFamilies)
        let wsFromTop = (snapshot.cpuIsFresh(at: now) && snapshot.topCPUIsFresh(at: now))
            ? snapshot.topCPU.first(where: { $0.name == "WindowServer" })?.usage
            : nil
        let wsFromFamilies = effectiveFamilies.first(where: { $0.id == "sys:WindowServer" })?.cpuUsage
        let wsCPU = max(wsFromTop ?? 0, wsFromFamilies ?? 0)
        if wsCPU >= HealthThresholds.windowServerWarnCPU {
            let pctStr = String(format: "%.0f", wsCPU)
            findings.append(DiagnosticFinding(
                id: "windowserver-high",
                kind: .monitor,
                severity: wsCPU >= HealthThresholds.windowServerHighCPU ? .high : .warn,
                title: L10n.t("diag.find.windowserver_high"),
                detail: L10n.t("diag.find.windowserver_high_detail", pctStr),
                metric: "\(pctStr)%",
                action: .openMonitor,
                actionTitle: openMon
            ))
        }

        // Process family rollup findings (Simulator, Automated Browser, Multi-process App Hogs)
        if !effectiveFamilies.isEmpty {
            let ramStrained = snapshot.ramIsFresh(at: now) && (
                snapshot.ram?.pressure.value == .warning
                    || snapshot.ram?.pressure.value == .critical
                    || (snapshot.ram?.swap.isAvailable == true && (snapshot.ram?.swap.used ?? 0) >= HealthThresholds.swapElevatedBytes)
                    || (snapshot.ram?.usage ?? 0) >= 0.82
            )
            let nameSep = AppLanguage.current.isEnglish ? ", " : "、"

            for family in effectiveFamilies {
                switch family.kind {
                case .iosSimulator:
                    let hasActiveSim = family.hasActiveSimulatedOS || !family.bootedSimulators.isEmpty
                    guard hasActiveSim,
                          (family.footprintBytes >= HealthThresholds.simulatorNoticeBytes || !family.bootedSimulators.isEmpty)
                    else {
                        continue
                    }
                    let memStr = ByteCountFormatter.string(fromByteCount: Int64(family.footprintBytes), countStyle: .memory)
                    let devNames = family.bootedSimulators.map(\.name).joined(separator: nameSep)
                    let detail = devNames.isEmpty
                        ? L10n.t("diag.find.sim_running_detail", family.processCount, memStr)
                        : L10n.t("diag.find.sim_running_named_detail", devNames, family.processCount, memStr)
                    findings.append(DiagnosticFinding(
                        id: "simulator-running",
                        kind: .monitor,
                        severity: ramStrained ? .warn : .info,
                        title: L10n.t("diag.find.sim_running"),
                        detail: detail,
                        metric: memStr,
                        action: .shutdownSimulators,
                        actionTitle: L10n.t("diag.act.shutdown_sim"),
                        secondaryAction: .openMonitor,
                        secondaryActionTitle: openMon
                    ))

                case .automatedBrowser:
                    guard family.footprintBytes >= HealthThresholds.automatedBrowserNoticeBytes
                            || family.cpuUsage >= HealthThresholds.automatedBrowserNoticeCPU,
                          let rootPID = family.rootPID
                    else {
                        continue
                    }
                    let memStr = ByteCountFormatter.string(fromByteCount: Int64(family.footprintBytes), countStyle: .memory)
                    let hint = family.automationHint ?? "automation"
                    let supervisor = UserLaunchAgentService.findSupervisorService(forPID: rootPID, in: userServices)
                    let detail = supervisor.map {
                        L10n.t("diag.find.auto_browser_supervised_detail", hint, family.processCount, memStr, $0.displayName)
                    } ?? L10n.t("diag.find.auto_browser_detail", hint, family.processCount, memStr)
                    findings.append(DiagnosticFinding(
                        id: "auto-browser-\(rootPID)",
                        kind: .monitor,
                        severity: (ramStrained || family.cpuUsage >= 30) ? .warn : .info,
                        title: L10n.t("diag.find.auto_browser", family.name),
                        detail: detail,
                        metric: memStr,
                        action: .quitAutomatedBrowser,
                        actionTitle: L10n.t("diag.act.quit_auto_browser"),
                        secondaryAction: supervisor != nil ? .openSoftwareServices : .openMonitor,
                        secondaryActionTitle: supervisor != nil ? L10n.t("act.open_services") : openMon,
                        processPID: rootPID,
                        processName: family.name,
                        processIdentity: family.rootIdentity,
                        serviceFocusLabel: supervisor?.label
                    ))

                case .userApp:
                    if let bid = family.bundleID?.lowercased(),
                       bid == "com.macdefier.app" || bid.hasPrefix("com.macdefier.") {
                        continue
                    }
                    let alreadyReportedCPU = (family.rootPID != nil && family.rootPID == reportedSingleHogPID)
                        || (reportedSingleHogAppPath != nil && family.appPath == reportedSingleHogAppPath)
                    let canQuit = family.rootPID.map(isUserAppProcess) ?? false
                    if !alreadyReportedCPU, family.processCount > 1, family.cpuUsage >= HealthThresholds.familyCPUHogUsage {
                        let cpuStr = String(format: "%.0f", family.cpuUsage)
                        findings.append(DiagnosticFinding(
                            id: "family-cpu-\(family.id)",
                            kind: .monitor,
                            severity: family.cpuUsage >= HealthThresholds.familyCPUHighUsage ? .high : .warn,
                            title: L10n.t("diag.find.family_cpu_hog", family.name),
                            detail: L10n.t("diag.find.family_cpu_hog_detail", family.processCount, cpuStr),
                            metric: "\(cpuStr)%",
                            action: canQuit ? .quitProcess : .openMonitor,
                            actionTitle: canQuit ? L10n.t("diag.act.quit_proc") : openMon,
                            secondaryAction: canQuit ? .openMonitor : nil,
                            secondaryActionTitle: canQuit ? openMon : nil,
                            processPID: canQuit ? family.rootPID : nil,
                            processName: family.name,
                            processIdentity: canQuit ? family.rootIdentity : nil
                        ))
                    }
                    if ramStrained, family.footprintBytes >= HealthThresholds.familyRAMHogWhenStrainedBytes {
                        let memStr = ByteCountFormatter.string(fromByteCount: Int64(family.footprintBytes), countStyle: .memory)
                        findings.append(DiagnosticFinding(
                            id: "family-ram-\(family.id)",
                            kind: .monitor,
                            severity: .warn,
                            title: L10n.t("diag.find.family_ram_hog", family.name),
                            detail: L10n.t("diag.find.family_ram_hog_detail", family.processCount, memStr),
                            metric: memStr,
                            action: .openMonitor,
                            actionTitle: openMon,
                            secondaryAction: canQuit ? .quitProcess : nil,
                            secondaryActionTitle: canQuit ? L10n.t("diag.act.quit_proc") : nil,
                            processPID: canQuit ? family.rootPID : nil,
                            processName: family.name,
                            processIdentity: canQuit ? family.rootIdentity : nil
                        ))
                    }

                case .systemService, .cliOrDaemon:
                    break
                }
            }
        }

        let brokenAgents = userServices.filter { !$0.targetExistsOnDisk }
        if !brokenAgents.isEmpty {
            let names = brokenAgents.prefix(2).map(\.displayName).joined(separator: AppLanguage.current.isEnglish ? ", " : "、")
            findings.append(DiagnosticFinding(
                id: "orphan-launch-agent",
                kind: .cleanup,
                severity: .info,
                title: L10n.t("diag.find.orphan_agent", brokenAgents.count),
                detail: L10n.t("diag.find.orphan_agent_detail", names),
                action: .openSoftwareServices,
                actionTitle: L10n.t("act.open_services"),
                serviceFocusLabel: brokenAgents.first?.label
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
            retainedProcessFamilies: effectiveFamilies,
            retainedUserServices: userServices,
            summaryLine: summary,
            aiNarrative: nil,
            cleanupIsPartial: cleanupIsPartial,
            monitorEvidenceIsComplete: snapshot.hasFreshDiagnosticMetrics(at: now),
            monitorEvidenceFingerprint: evidenceFingerprint(snapshot, families: effectiveFamilies, findings: findings, at: now)
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
            snapshot: snapshot,
            junkBytes: previous.junkBytes,
            trashBytes: previous.trashBytes,
            apps: apps,
            appSizesAvailable: false,
            cleanupIsPartial: previous.cleanupIsPartial,
            retainedFamilies: previous.retainedProcessFamilies,
            userServices: previous.retainedUserServices,
            retainedScannedAt: previous.scannedAt,
            now: now
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

    /// Threshold-banded fingerprint so minor telemetry jitter (e.g. 2% idle CPU changes) never wipes fresh AI output.
    private static func evidenceFingerprint(
        _ snapshot: MonitorSnapshot,
        families: [ProcessFamilySummary],
        findings: [DiagnosticFinding],
        at now: Date
    ) -> String {
        let cpuBand: String = {
            guard snapshot.cpuIsFresh(at: now), let u = snapshot.cpu?.totalUsage else { return "?" }
            if u >= HealthThresholds.cpuHighUsage { return "high" }
            if u >= HealthThresholds.cpuWarnUsage { return "warn" }
            return "ok"
        }()
        let ramBand: String = {
            guard snapshot.ramIsFresh(at: now), let r = snapshot.ram else { return "?" }
            let swapBand: Int
            if !r.swap.isAvailable { swapBand = -1 }
            else if r.swap.used >= HealthThresholds.swapHeavyStandaloneBytes { swapBand = 3 }
            else if r.swap.used >= HealthThresholds.swapHighComboBytes { swapBand = 2 }
            else if r.swap.used >= HealthThresholds.swapElevatedBytes { swapBand = 1 }
            else { swapBand = 0 }
            return "\(r.pressure.value.rawValue):\(swapBand)"
        }()
        let disks = snapshot.disks.physical.isEmpty ? snapshot.disks : snapshot.disks.physical
        let diskBand: String = snapshot.systemDiskIsFresh(at: now)
            ? disks.filter(DiagnosticScore.isSystemVolume).map { d in
                if HealthThresholds.isSystemDiskCritical(d) { return "\(d.id):crit" }
                if HealthThresholds.isSystemDiskTight([d]) { return "\(d.id):tight" }
                if d.usage >= HealthThresholds.systemDiskWarnUsage { return "\(d.id):warn" }
                return "\(d.id):ok"
            }.sorted().joined(separator: ",")
            : "?"
        let ruleIDs = findings
            .filter { !$0.id.hasPrefix("ai-") && $0.kind != .ok }
            .map(\.id)
            .sorted()
            .joined(separator: ",")
        let activeSim = families.contains { $0.kind == .iosSimulator && ($0.hasActiveSimulatedOS || !$0.bootedSimulators.isEmpty) }
        return "\(cpuBand)|\(ramBand)|\(diskBand)|\(activeSim)|\(ruleIDs)"
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
        let isEN = AppLanguage.current.isEnglish
        var lines: [String] = []
        lines.append(AIClient.monitorSnapshotTextSync(snapshot, fallbackFamilies: report.retainedProcessFamilies))
        let junkStr = ByteCountFormatter.string(fromByteCount: Int64(report.junkBytes), countStyle: .file)
        lines.append(isEN
            ? "Estimated rebuildable caches/logs (excluding large app data): \(junkStr)"
            : "可清理粗算（缓存/日志等可再生；不含大体积应用数据盘点）：\(junkStr)")
        if report.cleanupIsPartial {
            lines.append(isEN
                ? "Cleanup estimate is partial (lower bound only; do not assume storage is all clear)."
                : "清理盘点未完成：以上体积仅为下限，不能据此判断无垃圾或空间正常。")
        }
        if !report.largeApps.isEmpty {
            let sep = isEN ? "; " : "；"
            let joined = report.largeApps.map {
                "\($0.name) \(ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file))"
            }.joined(separator: sep)
            lines.append(isEN ? "Large apps: \(joined)" : "大体积应用：\(joined)")
        }
        let activeKeepAlive = report.retainedUserServices.filter { $0.runState == .running && $0.isKeepAlive }
        if !activeKeepAlive.isEmpty {
            let sep = isEN ? "; " : "；"
            let joined = activeKeepAlive.prefix(6).map { svc in
                let pStr = svc.pid.map { " PID \($0)" } ?? ""
                return "\(svc.displayName) [\(svc.label)\(pStr)]"
            }.joined(separator: sep)
            lines.append(isEN
                ? "Active auto-respawning user LaunchAgents (KeepAlive): \(joined)"
                : "正在运行且自动复活的用户后台服务（KeepAlive）：\(joined)")
        }
        lines.append(isEN ? "Rule findings:" : "规则发现：")
        for f in report.findings.prefix(12) {
            lines.append("- [\(f.severity.label)/\(f.kind.title)] \(f.title): \(f.detail)")
        }
        return lines.joined(separator: "\n")
    }

    /// 去掉 ** 等 markdown，方便卡片展示（JSON 残片见 DefierActionParser.userVisibleProse）
    static func plainText(_ markdownish: String) -> String {
        DefierActionParser.userVisibleProse(markdownish)
    }
}

extension AIClient {
    static func monitorSnapshotTextSync(_ s: MonitorSnapshot, fallbackFamilies: [ProcessFamilySummary] = []) -> String {
        let isEN = AppLanguage.current.isEnglish
        let sep = isEN ? "; " : "；"
        var lines: [String] = []
        let now = Date()
        if s.cpuIsFresh(at: now), let c = s.cpu {
            lines.append(String(format: isEN ? "CPU usage ~%.0f%%" : "CPU 占用约 %.0f%%", c.totalUsage * 100))
        }
        if s.ramIsFresh(at: now), let r = s.ram {
            let usedStr = ByteCountFormatter.string(fromByteCount: Int64(r.used), countStyle: .memory)
            let totalStr = ByteCountFormatter.string(fromByteCount: Int64(r.total), countStyle: .memory)
            let compStr = ByteCountFormatter.string(fromByteCount: Int64(r.compressed), countStyle: .memory)
            lines.append(String(
                format: isEN ? "Memory ~%.0f%% (%@ / %@)" : "内存约 %.0f%%（%@ / %@）",
                r.usage * 100,
                usedStr,
                totalStr
            ))
            lines.append(isEN ? "Memory pressure: \(r.pressure.value.rawValue)" : "内存压力：\(r.pressure.value.rawValue)")
            lines.append(isEN ? "Compressed memory: \(compStr)" : "压缩内存：\(compStr)")
            if r.swap.isAvailable {
                let swapStr = ByteCountFormatter.string(fromByteCount: Int64(r.swap.used), countStyle: .memory)
                lines.append(isEN ? "Swap: \(swapStr)" : "Swap：\(swapStr)")
            } else {
                lines.append(isEN ? "Swap: unavailable (do not treat as zero)" : "Swap：读取不可用，不能视为零")
            }
        }
        if !s.hasFreshDiagnosticMetrics(at: now) {
            lines.append(isEN
                ? "Monitoring evidence is incomplete or stale; do not declare the system healthy."
                : "监控证据不足：CPU/内存/系统磁盘数据缺失、过期或读取失败，不能据此判断系统正常。")
        }
        if s.systemDiskIsFresh(at: now) {
            for d in s.disks.prefix(8) {
                let freeStr = ByteCountFormatter.string(fromByteCount: Int64(d.free), countStyle: .file)
                lines.append(String(
                    format: isEN ? "Volume · %@ (%@) ~%.0f%%, %@ free" : "磁盘 · %@（%@）约 %.0f%%，剩余 %@",
                    d.name,
                    d.localizedKindLabel,
                    d.usage * 100,
                    freeStr
                ))
            }
        }
        if s.cpuIsFresh(at: now), s.topCPUIsFresh(at: now), !s.topCPU.isEmpty {
            let top = s.topCPU.prefix(5).map { "\($0.name) \(String(format: "%.0f", $0.usage))%" }.joined(separator: sep)
            lines.append("Top CPU: \(top)")
        }
        let families = s.processFamiliesAreFresh(at: now) ? s.processFamilies : fallbackFamilies
        if !families.isEmpty {
            let topFam = families.prefix(5).map { fam -> String in
                let mem = ByteCountFormatter.string(fromByteCount: Int64(fam.footprintBytes), countStyle: .memory)
                switch fam.kind {
                case .iosSimulator:
                    let devs = fam.bootedSimulators.map(\.name).joined(separator: "/")
                    let suffix = devs.isEmpty ? "" : "[\(devs)]"
                    return isEN
                        ? "\(fam.name)\(suffix) (\(fam.processCount) procs · \(mem))"
                        : "\(fam.name)\(suffix)（\(fam.processCount)进程 · \(mem)）"
                case .automatedBrowser:
                    let hint = fam.automationHint ?? "auto"
                    let pidNote = fam.rootPID.map { " PID \($0)" } ?? ""
                    return isEN
                        ? "\(fam.name) automated instance[\(hint)]\(pidNote) (\(fam.processCount) procs · \(mem))"
                        : "\(fam.name) 后台调试实例[\(hint)]\(pidNote)（\(fam.processCount)进程 · \(mem)）"
                default:
                    return isEN
                        ? "\(fam.name) (\(fam.processCount) procs · \(mem))"
                        : "\(fam.name)（\(fam.processCount)进程 · \(mem)）"
                }
            }.joined(separator: sep)
            if !topFam.isEmpty {
                lines.append(isEN ? "Top App Families by Memory: \(topFam)" : "软件进程族内存合账 Top：\(topFam)")
            }
        }
        return lines.isEmpty ? (isEN ? "(Monitoring data not ready yet)" : "（监控数据尚未就绪）") : lines.joined(separator: "\n")
    }
}
