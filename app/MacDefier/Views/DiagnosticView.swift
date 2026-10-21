import SwiftUI
import AppKit
import Combine
import MonitorKit
import CleanupKit

/// Findings first; read-only live detail stays visible below the diagnosis.
struct DiagnosticView: View {
    @EnvironmentObject private var monitor: MonitorService
    @StateObject private var scan = DiagnosticScanService.shared
    /// Drive re-localization of baked finding strings when Settings language changes.
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw: String = AppLanguage.chinese.rawValue

    var onOpenMonitor: (DiagnosticFinding?) -> Void
    var onOpenCleanupAndScan: (DiagnosticFinding?) -> Void
    var onOpenSoftware: (DiagnosticFinding?) -> Void
    var onOpenMister: () -> Void

    @State private var aiSettings = AISettingsStore.load()
    @State private var quitMessage: String?

    private var aiConfigured: Bool {
        AIClient.resolveEndpoint(aiSettings) != nil && aiSettings.enabled && aiSettings.mode != .off
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MDTheme.sectionSpacing) {
                header
                pendingOverview
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.t("workbench.live_details"))
                            .font(.headline)
                            .accessibilityIdentifier("diagnostic.liveDetails")
                        Spacer()
                        Text(L10n.t("workbench.live_monitor_hint"))
                            .font(.caption).foregroundStyle(MDTheme.secondary)
                    }
                    WorkbenchLiveReadings()
                    overviewAndReasons
                }
            }
            .mdScrollPageTop()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            aiSettings = AISettingsStore.load()
            // Always resolve finding copy into current UI language (scan may have been Chinese).
            scan.relocalizeForCurrentLanguage(monitor: monitor)
            // 结果不新鲜（含首次 / 超过 TTL）自动规则重扫；不打 AI、不耗 API。
            // Manual refresh and optional AI review remain in the diagnosis menu.
            if !scan.hasFreshResult, !scan.isScanning {
                Task { await scan.scan(monitor: monitor, useAI: false, force: false) }
            }
        }
        .onChange(of: appLanguageRaw) { _, _ in
            scan.relocalizeForCurrentLanguage(monitor: monitor)
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // Age existing samples without keeping background samplers or directory walks alive.
            if !scan.isScanning { scan.relocalizeForCurrentLanguage(monitor: monitor) }
        }
        .alert(L10n.t("diag.quit_process"), isPresented: Binding(
            get: { quitMessage != nil },
            set: { if !$0 { quitMessage = nil } }
        )) {
            Button(L10n.t("common.ok"), role: .cancel) { quitMessage = nil }
        } message: {
            Text(quitMessage ?? "")
        }
    }

    // MARK: - Header（问候、状态与次要操作菜单）

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            accountAvatar

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("diag.hello", LocalIdentity.shortName))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MDTheme.label)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if scan.isScanning {
                ProgressView().controlSize(.small)
                Text(scan.phaseHint).font(.caption).foregroundStyle(MDTheme.secondary)
            } else if scan.report.scannedAt != .distantPast {
                Text(scan.report.scannedAt, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit()).foregroundStyle(MDTheme.secondary)
                    .help(L10n.t("workbench.last_diagnosis"))
            }

            Menu {
                Button(L10n.t("common.rescan")) {
                    Task { await scan.scan(monitor: monitor, useAI: false, force: true) }
                }
                if aiConfigured {
                    Button(L10n.t("common.ai_review")) {
                        Task { await scan.scan(monitor: monitor, useAI: true, force: true) }
                    }
                }
            } label: {
                Label(L10n.t("workbench.diagnosis_options"), systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).labelsHidden().fixedSize()
            .accessibilityIdentifier("diagnostic.options")
            .disabled(scan.isScanning)
        }
    }

    /// 真头像才画圆；拿不到不画剪影/字母（禁 monogram 假头像）
    @ViewBuilder
    private var accountAvatar: some View {
        if let img = LocalIdentity.accountImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .overlay(Circle().stroke(MDTheme.border.opacity(0.35), lineWidth: 0.5))
        }
    }

    // MARK: - Findings

    private var pendingOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(scan.isScanning && scan.report.scannedAt == .distantPast
                 ? L10n.t("common.scanning")
                 : scan.report.findings.filter { $0.kind != .ok }.isEmpty
                    ? statusTitle
                    : L10n.t("workbench.diagnosis_count", scan.report.findings.filter { $0.kind != .ok }.count))
                .font(.system(size: 22, weight: .bold))
                .accessibilityIdentifier("diagnostic.summary")
            findingsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = scan.lastError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(MDTheme.warning)
                    .lineLimit(2)
            }

            if scan.report.findings.isEmpty && !scan.isScanning {
                MDCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scan.report.scannedAt == .distantPast
                             ? L10n.t("diag.empty_never")
                             : L10n.t("diag.empty_round"))
                            .font(.system(size: 13))
                            .foregroundStyle(MDTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // U5：按 kind 归组，同类一张卡
                VStack(spacing: 8) {
                    ForEach(groupedFindings, id: \.kind) { group in
                        findingGroupCard(group)
                    }
                }
            }
        }
    }

    /// 组顺序：组内最高严重度优先，同级 monitor → cleanup → software → ok
    private var groupedFindings: [(kind: FindingKind, items: [DiagnosticFinding])] {
        let order: [FindingKind] = [.monitor, .cleanup, .software, .ok]
        let dict = Dictionary(grouping: scan.report.findings, by: \.kind)
        return order.compactMap { kind -> (FindingKind, [DiagnosticFinding])? in
            guard let items = dict[kind], !items.isEmpty else { return nil }
            return (kind, items)
        }
        .sorted { a, b in
            let sa = a.items.map(\.severity).max() ?? .info
            let sb = b.items.map(\.severity).max() ?? .info
            if sa != sb { return sa > sb }
            let ia = order.firstIndex(of: a.kind) ?? 99
            let ib = order.firstIndex(of: b.kind) ?? 99
            return ia < ib
        }
    }

    private func findingGroupCard(_ group: (kind: FindingKind, items: [DiagnosticFinding])) -> some View {
        MDCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(group.kind.title)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MDTheme.surfaceInset, in: Capsule())
                        .foregroundStyle(MDTheme.secondary)
                    Text(L10n.t("diag.group.count", group.items.count))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(MDTheme.tertiary)
                    Spacer(minLength: 8)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, f in
                        findingRow(f)
                        if idx < group.items.count - 1 {
                            MDRowSeparator(leading: 0)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 组内一行：严重度 + 标题/具体原因 + 指标 + 明确主动作
    private func findingRow(_ f: DiagnosticFinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: f.severity == .info ? "info.circle" : "exclamationmark.circle")
                    .foregroundStyle(severityColor(f.severity))
                    .accessibilityLabel(f.severity.label)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(f.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)

                        if f.id.hasPrefix("ai-") {
                            Text(L10n.t("common.ai"))
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(MDTheme.surfaceInset, in: Capsule())
                                .foregroundStyle(MDTheme.accent)
                                .help(L10n.t("diag.source_ai_help"))
                        }
                    }

                    if !f.detail.isEmpty {
                        Text(f.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(MDTheme.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    if let m = f.metric {
                        Text(m)
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(severityColor(f.severity))
                    }
                    HStack(spacing: 8) {
                        if f.action != .none {
                            Button(f.actionTitle) { runAction(f.action, finding: f) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                        let secondaryActions = rowSecondaryActions(f)
                        if !secondaryActions.isEmpty {
                            Menu {
                                ForEach(secondaryActions) { item in
                                    Button(item.title) { runAction(item.action, finding: f) }
                                }
                            } label: {
                                Label(L10n.t("workbench.finding_options", f.title), systemImage: "ellipsis")
                            }
                            .menuStyle(.borderlessButton).labelsHidden().fixedSize()
                        }
                    }
                }
                .layoutPriority(1)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct RowAction: Identifiable {
        var id: String { title }
        let title: String
        let action: FindingAction
    }

    private func rowSecondaryActions(_ f: DiagnosticFinding) -> [RowAction] {
        guard let action = f.secondaryAction,
              let title = f.secondaryActionTitle,
              action != f.action else { return [] }
        return [RowAction(title: title, action: action)]
    }

    // MARK: - Score and live signals

    private var overviewAndReasons: some View {
        MDEqualSplit(spacing: 8) {
            MDCard(padding: 12, fillHeight: true) {
                VStack(alignment: .leading, spacing: 12) {
                    MDSectionTitle(title: L10n.t("diag.score.title"))
                        .help(scoreMeta)
                    HStack(spacing: 16) {
                        MDRing(
                            progress: Double(scoreBreakdown.total ?? 0) / 100,
                            lineWidth: 8,
                            size: 96,
                            tint: overallTint,
                            center: scoreBreakdown.total.map(String.init) ?? "—",
                            caption: statusTitle
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            scoreLine(name: L10n.t("diag.score.load"), score: scoreBreakdown.loadScore.map(Double.init), tint: MDTheme.chart2)
                            scoreLine(name: L10n.t("diag.score.space"), score: scoreBreakdown.spaceScore.map(Double.init), tint: MDTheme.chart3)
                            scoreLine(name: L10n.t("diag.score.memory"), score: scoreBreakdown.memoryScore.map(Double.init), tint: MDTheme.chart1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } right: {
            MDCard(padding: 12, fillHeight: true) {
                VStack(alignment: .leading, spacing: 8) {
                    MDSectionTitle(title: L10n.t("diag.live.title"))
                    ForEach(liveHints, id: \.self) { line in
                        Text("· \(line)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(MDTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Actions

    private func runAction(_ action: FindingAction, finding: DiagnosticFinding) {
        switch action {
        case .openMonitor: onOpenMonitor(finding)
        case .openCleanupAndScan: onOpenCleanupAndScan(finding)
        case .openSoftware: onOpenSoftware(finding)
        case .quitProcess: quitProcess(pid: finding.processPID, name: finding.processName)
        case .openMister: onOpenMister()
        case .none: break
        }
    }

    private func quitProcess(pid: Int?, name: String?) {
        guard let pid else {
            quitMessage = L10n.t("diag.quit.no_pid")
            return
        }
        // 与聊天路径同一道闸：系统进程 / 本应用 / 无效 PID 一律不杀
        guard DefierActionGuard.isSafeToQuit(pid: pid) else {
            quitMessage = L10n.t("diag.quit.blocked")
            return
        }
        guard let pid32 = pid_t(exactly: pid) else {
            quitMessage = L10n.t("diag.quit.blocked")
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid32),
              let identity = MonitoredProcessIdentity.read(pid: pid32) else {
            quitMessage = L10n.t("diag.quit.gone", name ?? "\(pid)")
            return
        }
        // 确认框显示当前进程名（防 PID 复用误杀）；terminate 失败不再自动 SIGKILL
        let shown = app.localizedName ?? name ?? "PID \(pid)"
        let alert = NSAlert()
        alert.messageText = L10n.t("diag.quit.confirm", shown)
        alert.informativeText = L10n.t("diag.quit.confirm_body")
        alert.addButton(withTitle: L10n.t("diag.quit.confirm_ok"))
        alert.addButton(withTitle: L10n.t("diag.quit.confirm_cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if MonitoredApplicationExit.request(identity) == .requested {
            quitMessage = L10n.t("diag.quit.sent", shown, pid)
        } else {
            quitMessage = L10n.t("diag.quit.fail", shown)
        }
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await scan.scan(monitor: monitor, useAI: false, force: true)
        }
    }

    // MARK: - Metrics / copy

    private func severityColor(_ s: FindingSeverity) -> Color {
        switch s {
        case .high: return MDTheme.danger
        case .warn: return MDTheme.warning
        case .info: return MDTheme.secondary
        }
    }

    private var statusTitle: String {
        L10n.t(scoreBreakdown.statusKey)
    }

    private var liveHints: [String] {
        var lines: [String] = []
        if monitor.snapshot.cpuIsFresh(), let c = monitor.snapshot.cpu, c.totalUsage > 0.7 { lines.append(L10n.t("diag.live.cpu")) }
        if monitor.snapshot.ramIsFresh(), let r = monitor.snapshot.ram {
            switch r.pressure.value {
            case .critical, .warning:
                lines.append(L10n.t("diag.live.ram_pressure", r.pressure.value.rawValue))
            case .normal, .unknown:
                break
            }
        }
        for d in monitor.snapshot.disks.physical where d.usage > 0.85 {
            lines.append(L10n.t("diag.live.disk", d.name, d.localizedKindLabel))
        }
        if !monitor.snapshot.hasFreshCoreMetrics() { lines.append(L10n.t("diag.find.metrics_unknown")) }
        if !monitor.snapshot.systemDiskIsFresh() { lines.append(L10n.t("diag.find.storage_unknown")) }
        if scan.report.cleanupIsPartial { lines.append(L10n.t("diag.find.cleanup_partial")) }
        if lines.isEmpty { lines.append(L10n.t("diag.live.calm")) }
        return lines
    }

    /// 方案 A：发现驱动扣分；未扫 = 仅实时部分分
    private var scoreBreakdown: DiagnosticScoreBreakdown {
        DiagnosticScore.evaluateLive(
            snapshot: monitor.snapshot,
            report: scan.report,
            hasFreshScan: scan.hasFreshResult
        )
    }

    private var scoreMeta: String {
        if scan.report.cleanupIsPartial { return L10n.t("diag.find.cleanup_partial_detail") }
        if !monitor.snapshot.systemDiskIsFresh() { return L10n.t("diag.find.storage_unknown_detail") }
        if !scoreBreakdown.isComplete { return L10n.t("diag.find.metrics_unknown_detail") }
        if scoreBreakdown.includesCleanupScan {
            return L10n.t("diag.score.meta_full")
        }
        return L10n.t("diag.score.meta_partial")
    }

    private var overallTint: Color {
        guard let s = scoreBreakdown.total else { return MDTheme.secondary }
        if s >= 85 { return MDTheme.success }
        if s >= 65 { return MDTheme.warning }
        if s >= 40 { return MDTheme.warning }
        return MDTheme.danger
    }
    private func scoreLine(name: String, score: Double?, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(MDTheme.secondary)
                .lineLimit(1)
                .frame(width: 56, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(MDTheme.surfaceInset)
                    if let score {
                        Capsule().fill(tint).frame(width: max(4, g.size.width * score / 100))
                    }
                }
            }
            .frame(height: 6)
            Text(score.map { String(Int($0)) } ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(MDTheme.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}
