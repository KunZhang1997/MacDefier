import SwiftUI
import MonitorKit
import CleanupKit

struct MonitorCenterView: View {
    @EnvironmentObject private var monitor: MonitorService
    @ObservedObject private var nav = AppNavigator.shared
    @Binding var selectedTab: MonitorTab
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.chinese.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { timeline in
            content(at: timeline.date)
        }
    }

    private func content(at now: Date) -> some View {
        VStack(spacing: 0) {
            MDPageBar {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        detailPicker
                        Spacer(minLength: 12)
                        if selectedTab != .history { historyButton; intervalPicker }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        detailPicker
                        if selectedTab != .history { intervalPicker }
                    }
                }
            }
            .onAppear {
                MonitorAIAssist.shared.start(monitor: monitor)
            }

            ScrollView {
                Group {
                    switch selectedTab {
                    case .dashboard: MonitorDashboardPane(onOpenNetwork: { selectedTab = .network }, now: now)
                    case .cpu: MonitorCPUPane(now: now)
                    case .gpu: MonitorGPUPane()
                    case .ram: MonitorRAMPane(now: now)
                    case .disk: MonitorDiskPane()
                    case .sensors: MonitorSensorsPane()
                    case .network: MonitorNetworkPane()
                    case .history: MonitorHistoryPane(history: monitor.history)
                    }
                }
                .padding(.horizontal, MDTheme.pagePadding)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(MDTheme.content)
        .onDisappear { nav.clearMonitorFocus() }
        .onReceive(SoftwareService.shared.$cliTools) { tools in
            let entries = tools.flatMap { tool in tool.programPaths.map { ($0, tool.displayName) } }
            ProcessOwnerRegistry.replaceCLIInventory(Dictionary(entries, uniquingKeysWith: { first, _ in first }))
        }
    }

    private var historyButton: some View {
        Button { selectedTab = .history } label: {
            Label(L10n.t("monitor.tab.history"), systemImage: "clock.arrow.circlepath")
        }.accessibilityIdentifier("monitor.history.open")
    }

    private var intervalPicker: some View {
        Picker(L10n.t("workbench.refresh_interval"), selection: Binding(
            get: { monitor.refreshInterval },
            set: { monitor.setRefreshInterval($0) }
        )) {
            ForEach([1, 5, 30], id: \.self) { seconds in
                Text(L10n.t("workbench.refresh_seconds", seconds)).tag(seconds)
            }
        }
        .pickerStyle(.menu).fixedSize()
        .id("interval.\(appLanguageRaw)")
        .accessibilityIdentifier("monitor.refreshInterval")
    }

    private var detailPicker: some View {
        Picker(L10n.t("workbench.monitor_detail"), selection: $selectedTab) {
            ForEach(MonitorTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.menu).fixedSize()
        .id("detail.\(appLanguageRaw)")
        .accessibilityIdentifier("monitor.detailScope")
    }
}

// MARK: - Network (wireframe density)

struct MonitorNetworkPane: View {
    @EnvironmentObject private var monitor: MonitorService
    @ObservedObject private var monitorAI = MonitorAIAssist.shared
    /// 0 = 全部；3/5/7 = 近 N 天
    @AppStorage("ip.history.window.days") private var windowDays: Int = 3
    @State private var confirmClear = false

    private var ov: NetworkOverview { monitor.snapshot.networkOverview }
    private var d: NetworkConnectionDetails { ov.details }
    private var primary: NetworkInterfaceUsage? { ov.primary }
    private var windowedHistory: [IPHistoryEntry] {
        windowDays <= 0 ? ov.ipHistory : ov.ipHistory(inLastDays: windowDays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let tip = monitorAI.ipTip, !tip.isEmpty {
                ipChangeTipBanner(tip)
            }
            MDEqualSplit {
                overviewCard
            } right: {
                trafficCard
            }
            detailsCard
            ipHistoryCard
        }
        .onAppear {
            MonitorAIAssist.shared.start(monitor: monitor)
            monitorAI.refreshIPTip(preferAI: false)
        }
        .alert(L10n.t("monitor.clear_history_title"), isPresented: $confirmClear) {
            Button(L10n.t("monitor.cancel"), role: .cancel) {}
            Button(L10n.t("monitor.clear"), role: .destructive) {
                monitor.clearIPHistory()
            }
        } message: {
            Text(L10n.t("monitor.clear_history_body"))
        }
    }

    private func ipChangeTipBanner(_ tip: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: monitorAI.ipTipUsedAI ? "sparkles" : "network")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MDTheme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitorAI.ipTipUsedAI ? L10n.t("monitor.ip.tip_ai") : L10n.t("monitor.ip.tip_change"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.accent)
                MDAIClampedText(tip, maxHeight: 72)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MDTheme.label)
            }
            Spacer(minLength: 0)
            if monitorAI.isIPLoading {
                ProgressView().controlSize(.mini)
            } else if monitorAI.isConfigured {
                Button(L10n.t("monitor.ai.scan")) {
                    monitorAI.refreshIPTip(preferAI: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MDTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var overviewCard: some View {
        MDCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L10n.t("monitor.net.overview"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(d.mediaLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(MDTheme.tertiary)
                }

                HStack(alignment: .center, spacing: 18) {
                    // 无已知链路容量时不画假百分比（有线/未知 rate 不再默认 1G）
                    let hasLinkCap = (d.linkSpeedBps ?? 0) > 0 || (d.transmitRateMbps ?? 0) > 0
                    MDRing(
                        progress: hasLinkCap ? ov.bandwidthUsage : 0,
                        lineWidth: 10,
                        size: 120,
                        tint: Color(hex: 0x5AC8FA),
                        center: hasLinkCap ? String(format: "%.0f%%", ov.bandwidthUsage * 100) : "—",
                        caption: L10n.t("monitor.net.bandwidth")
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        metricBar(
                            title: L10n.t("monitor.net.download"),
                            value: Format.rate(primary?.bytesInPerSec),
                            progress: barProgress(primary?.bytesInPerSec, cap: d.linkSpeedBps),
                            showBar: (d.linkSpeedBps ?? 0) > 0,
                            tint: MDTheme.chart1
                        )
                        metricBar(
                            title: L10n.t("monitor.net.upload"),
                            value: Format.rate(primary?.bytesOutPerSec),
                            progress: barProgress(primary?.bytesOutPerSec, cap: d.linkSpeedBps),
                            showBar: (d.linkSpeedBps ?? 0) > 0,
                            tint: MDTheme.chart4
                        )
                        metricBar(
                            title: L10n.t("monitor.net.signal"),
                            value: d.rssi.map { "\($0) dBm" } ?? "—",
                            progress: rssiProgress(d.rssi),
                            tint: MDTheme.success
                        )
                        metricBar(
                            title: L10n.t("monitor.net.link_speed"),
                            value: linkSpeedText,
                            progress: linkSpeedProgress,
                            tint: Color(hex: 0x5AC8FA)
                        )
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var trafficCard: some View {
        MDCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("monitor.net.traffic"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MDTheme.secondary)
                            .textCase(.uppercase)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Format.rate(ov.totalThroughput).replacingOccurrences(of: "/s", with: ""))
                                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            Text(L10n.t("monitor.net.last_ns", min(60, max(1, ov.history.count))))
                                .font(.system(size: 12))
                                .foregroundStyle(MDTheme.secondary)
                        }
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        legendDot(MDTheme.chart1, L10n.t("monitor.net.download"))
                        legendDot(MDTheme.chart4, L10n.t("monitor.net.upload"))
                    }
                }

                DualLineChart(
                    down: ov.history.map(\.downBytesPerSec),
                    up: ov.history.map(\.upBytesPerSec),
                    downColor: MDTheme.chart1,
                    upColor: MDTheme.chart4
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 160)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailsCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L10n.t("monitor.net.details"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(localizedLinkKind(d.linkKind))
                        .font(.system(size: 12))
                        .foregroundStyle(MDTheme.tertiary)
                }
                .padding(.bottom, 8)

                detail("SSID", d.ssid ?? "—")
                detail(L10n.t("monitor.net.security"), d.security ?? "—")
                detail(L10n.t("monitor.net.band"), d.band ?? "—")
                detail(L10n.t("monitor.net.channel"), d.channel ?? "—")
                detail("RSSI", d.rssi.map { "\($0) dBm" } ?? "—")
                detail(L10n.t("monitor.net.noise"), d.noise.map { "\($0) dBm" } ?? "—")
                detail(L10n.t("monitor.net.phy"), d.phyMode ?? "—")
                detail(L10n.t("monitor.net.tx_rate"), d.transmitRateMbps.map { String(format: "%.0f Mbps", $0) } ?? "—")
                detail(L10n.t("monitor.net.local_ip"), d.localIPv4 ?? primary?.ip ?? "—")
                detail(L10n.t("monitor.net.public_ip"), publicIPDetailLine, last: false)
                detail(L10n.t("monitor.net.location"), ov.publicIPPlaceLabel ?? (d.publicIP == nil ? "—" : L10n.t("monitor.net.resolving")))
                detail(L10n.t("monitor.net.mac"), d.mac ?? "—")
                detail(L10n.t("monitor.net.gateway"), d.gateway ?? "—")
                detail("DNS", d.dns.isEmpty ? "—" : d.dns.joined(separator: " / "), last: true)
            }
        }
    }

    private var publicIPDetailLine: String {
        // 三态：关闭 / 查询中 / 已确认 — 关闭时不得显示「探测中」
        let enabled = UserDefaults.standard.object(forKey: NetworkUsageSampler.publicIPLookupDefaultsKey) as? Bool ?? false
        if !enabled {
            return L10n.t("monitor.ip.lookup_off")
        }
        if let ip = d.publicIP, !ip.isEmpty {
            return ip
        }
        return L10n.t("monitor.ip.probing")
    }

    private var ipHistoryCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(L10n.t("monitor.ip.exit_title"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    windowChips
                    Button {
                        confirmClear = true
                    } label: {
                        Text(L10n.t("monitor.clear_history_btn"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MDTheme.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MDTheme.surfaceInset, in: Capsule())
                            .overlay(Capsule().stroke(MDTheme.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("monitor.ip.clear_help"))
                }
                .padding(.bottom, 10)

                // Current stable row
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.t("monitor.ip.current_short"))
                            .font(.system(size: 12))
                            .foregroundStyle(MDTheme.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(d.publicIP ?? L10n.t("monitor.ip.wait_confirm"))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(MDTheme.label)
                            .textSelection(.enabled)
                        Spacer()
                        Text(ov.publicIPPlaceLabel ?? (d.publicIP == nil ? "" : L10n.t("monitor.ip.city_unknown")))
                            .font(.system(size: 12))
                            .foregroundStyle(MDTheme.tertiary)
                    }
                    HStack {
                        Text(L10n.t("monitor.ip.stable_prefix", Format.stableDuration(since: ov.publicIPConfirmedSince)))
                            .font(.system(size: 11))
                            .foregroundStyle(MDTheme.tertiary)
                        Spacer()
                        Text(L10n.t("monitor.ip.self_built"))
                            .font(.system(size: 10))
                            .foregroundStyle(MDTheme.tertiary)
                    }
                }
                .padding(.vertical, 8)

                MDRowSeparator(leading: 0)
                    .padding(.vertical, 4)

                if windowedHistory.isEmpty {
                    HStack(alignment: .top) {
                        Text(emptyHistoryTitle)
                            .font(.system(size: 13))
                            .foregroundStyle(MDTheme.secondary)
                        Spacer()
                        if let ip = d.publicIP {
                            Text(L10n.t("monitor.ip.exit_ip", ip))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(MDTheme.tertiary)
                        }
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(Array(windowedHistory.enumerated()), id: \.element.id) { idx, e in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(Format.dayTime(e.date))
                                    .font(.system(size: 13))
                                    .foregroundStyle(MDTheme.label)
                                    .frame(minWidth: 88, alignment: .leading)
                                Spacer(minLength: 8)
                                Text(historyText(e))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(MDTheme.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            if let sub = historySubtitle(e) {
                                Text(sub)
                                    .font(.system(size: 11))
                                    .foregroundStyle(MDTheme.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 8)
                        if idx < windowedHistory.count - 1 {
                            MDRowSeparator(leading: 0)
                        }
                    }
                }
            }
        }
    }

    private var windowChips: some View {
        HStack(spacing: 0) {
            ForEach([(3, L10n.t("monitor.ip.window_3d")), (5, L10n.t("monitor.ip.window_5d")), (7, L10n.t("monitor.ip.window_7d")), (0, L10n.t("monitor.ip.window_all"))], id: \.0) { days, title in
                Button {
                    windowDays = days
                } label: {
                    Text(title)
                        .font(.system(size: 10, weight: windowDays == days ? .semibold : .regular))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(windowDays == days ? MDTheme.surface : Color.clear)
                        )
                        .foregroundStyle(windowDays == days ? MDTheme.label : MDTheme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(MDTheme.surfaceInset))
        .overlay(Capsule().stroke(MDTheme.border, lineWidth: 0.5))
    }

    private var emptyHistoryTitle: String {
        if windowDays <= 0 {
            return L10n.t("monitor.ip.empty_all")
        }
        return L10n.t("monitor.ip.empty_window", windowDays)
    }

    private func localizeIPNote(_ note: String) -> String {
        if note == "first_confirm" || note == "首次确认" {
            return L10n.t("monitor.ip.note_first")
        }
        return note
    }

    private func localizedLinkKind(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "Network" || t == "网络" { return L10n.t("monitor.net.kind") }
        return t
    }

    private func historyText(_ e: IPHistoryEntry) -> String {
        if let note = e.note, e.from == nil, let to = e.to { return "\(to) · \(localizeIPNote(note))" }
        if let note = e.note, e.to == nil { return localizeIPNote(note) }
        if let from = e.from, let to = e.to { return "\(from) → \(to)" }
        if let to = e.to { return to }
        return e.note.map { localizeIPNote($0) } ?? "—"
    }

    private func historySubtitle(_ e: IPHistoryEntry) -> String? {
        var parts: [String] = []
        if let p = e.placeLabel { parts.append(p) }
        if let ssid = e.ssid, !ssid.isEmpty { parts.append(ssid) }
        else if let iface = e.interfaceName, !iface.isEmpty { parts.append(iface) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var linkSpeedText: String {
        if let mbps = d.transmitRateMbps, mbps > 0 {
            if mbps >= 1000 { return String(format: "%.1f Gbps", mbps / 1000) }
            return String(format: "%.0f Mbps", mbps)
        }
        if let bps = d.linkSpeedBps {
            let mbps = bps * 8 / 1_000_000
            if mbps >= 1000 { return String(format: "%.1f Gbps", mbps / 1000) }
            return String(format: "%.0f Mbps", mbps)
        }
        return "—"
    }

    private var linkSpeedProgress: Double {
        // 未知协商速率：进度 0（条上仍显示「—」），不再假 40%
        guard let mbps = d.transmitRateMbps, mbps > 0 else { return 0 }
        return min(1, mbps / 2400)
    }

    private func rssiProgress(_ rssi: Int?) -> Double {
        guard let rssi else { return 0 }
        // -30 excellent … -90 poor
        return max(0, min(1, Double(rssi + 90) / 60))
    }

    /// 链路容量未知时不假设 20/50 MB/s；返回 0 且 UI 可隐藏条。
    private func barProgress(_ rate: Double?, cap: Double?) -> Double {
        guard let rate, let cap, cap > 0 else { return 0 }
        return min(1, rate / cap)
    }

    private func metricBar(
        title: String,
        value: String,
        progress: Double,
        showBar: Bool = true,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(MDTheme.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MDTheme.label)
            }
            // 容量未知：只显示字节速率，不画假百分比条
            if showBar {
                MDProgressBar(progress: progress, tint: tint, height: 5)
            }
        }
    }

    private func detail(_ k: String, _ v: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(k)
                    .font(.system(size: 13))
                    .foregroundStyle(MDTheme.secondary)
                    .frame(width: 88, alignment: .leading)
                Spacer(minLength: 12)
                Text(v)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(MDTheme.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 9)
            if !last {
                MDRowSeparator(leading: 0)
            }
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(MDTheme.secondary)
        }
    }
}

// MARK: - Dual line chart

struct DualLineChart: View {
    var down: [Double]
    var up: [Double]
    var downColor: Color
    var upColor: Color

    var body: some View {
        // Fixed-height chart; avoid unconstrained GeometryReader layout thrash.
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 1, h > 1 else { return }
            let maxV = max(down.max() ?? 0, up.max() ?? 0, 1)

            for i in 1...3 {
                let y = h * CGFloat(i) / 4
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: w, y: y))
                context.stroke(grid, with: .color(MDTheme.separator), lineWidth: 1)
            }

            context.stroke(
                linePath(values: down, maxV: maxV, w: w, h: h),
                with: .color(downColor),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                linePath(values: up, maxV: maxV, w: w, h: h),
                with: .color(upColor),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 160)
        .layoutPriority(1)
        .clipped()
    }

    private func linePath(values: [Double], maxV: Double, w: CGFloat, h: CGFloat) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            for (i, v) in values.enumerated() {
                let x = w * CGFloat(i) / CGFloat(values.count - 1)
                let y = h - (CGFloat(v / maxV) * (h - 8) + 4)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }
}

/// 三线综合占用（CPU/RAM/GPU）— Dashboard 对齐线框
struct TripleLineChart: View {
    var cpu: [Double]
    var ram: [Double]
    var gpu: [Double]
    var cpuColor: Color = MDTheme.chart1
    var ramColor: Color = MDTheme.chart2
    var gpuColor: Color = MDTheme.chart3

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 1, h > 1 else { return }
            let maxV = max(cpu.max() ?? 0, ram.max() ?? 0, gpu.max() ?? 0, 1)

            for i in 1...3 {
                let y = h * CGFloat(i) / 4
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: w, y: y))
                context.stroke(grid, with: .color(MDTheme.separator), lineWidth: 1)
            }

            context.stroke(path(cpu, maxV, w, h), with: .color(cpuColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            context.stroke(path(ram, maxV, w, h), with: .color(ramColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            context.stroke(path(gpu, maxV, w, h), with: .color(gpuColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
        .layoutPriority(1)
        .clipped()
    }

    private func path(_ values: [Double], _ maxV: Double, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            for (i, v) in values.enumerated() {
                let x = w * CGFloat(i) / CGFloat(values.count - 1)
                let y = h - (CGFloat(min(1, v / maxV)) * (h - 10) + 5)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }
}

// MARK: - Other panes (keep denser chrome)

// MARK: - Shared process list with native hairlines

private struct MDTopProcessList<P: Identifiable>: View {
    let processes: [P]
    let name: (P) -> String
    let detail: (P) -> String
    let value: (P) -> String
    var highlight: (P) -> Bool = { _ in false }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(processes.enumerated()), id: \.element.id) { idx, p in
                MDProcessRow(name: name(p), detail: detail(p), value: value(p))
                    .padding(.horizontal, 4)
                    .background(highlight(p) ? MDTheme.surfaceSelected : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                if idx < processes.count - 1 {
                    MDRowSeparator(leading: 38)
                }
            }
        }
    }
}

struct MonitorDashboardPane: View {
    @EnvironmentObject private var monitor: MonitorService
    @ObservedObject private var monitorAI = MonitorAIAssist.shared
    var onOpenNetwork: () -> Void = {}
    var now: Date = Date()
    @AppStorage("ip.history.window.days") private var windowDays: Int = 3

    private var s: MonitorSnapshot { monitor.snapshot }
    private var cpu: CPULoad? { s.cpuIsFresh(at: now) ? s.cpu : nil }
    private var ram: RAMUsage? { s.ramIsFresh(at: now) ? s.ram : nil }
    private var systemDisk: DiskVolume? {
        s.systemDiskIsFresh(at: now) ? s.disks.first(where: DiagnosticScore.isSystemVolume) : nil
    }
    private var ov: NetworkOverview { s.networkOverview }
    private var windowed: [IPHistoryEntry] {
        windowDays <= 0 ? ov.ipHistory : ov.ipHistory(inLastDays: windowDays)
    }

    private var compositeUsage: Double? {
        guard let c = cpu?.totalUsage, let r = ram?.usage else { return nil }
        // GPU 利用率未接时不要当 0 参与均值（会把综合占用假压低）
        if let g = s.gpus.first?.utilization {
            return min(1, (c + r + g) / 3)
        }
        return min(1, (c + r) / 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 0) 状态一句：规则秒出；配 AI 可润色（AI 盘点）
            dashStatusStrip

            // 1) KPI 四卡 — 对齐线框 kpi-grid + footer · 同行等高
            HStack(alignment: .top, spacing: 12) {
                dashKPI(
                    "CPU",
                    Format.percent(cpu?.totalUsage),
                    cpu?.totalUsage,
                    MDTheme.chart1,
                    footer: cpuFooter
                )
                dashKPI(
                    "GPU",
                    s.gpus.first?.utilization.map { Format.percent($0) } ?? "—",
                    s.gpus.first?.utilization,
                    MDTheme.chart3,
                    footer: gpuFooter
                )
                dashKPI(
                    L10n.t("diag.kpi.memory"),
                    ramValueLabel,
                    ram?.usage,
                    MDTheme.chart2,
                    footer: ramFooter
                )
                dashKPI(
                    L10n.t("diag.kpi.disk"),
                    diskValueLabel,
                    systemDisk?.usage,
                    MDTheme.chart3,
                    footer: diskFooter
                )
            }
            .fixedSize(horizontal: false, vertical: true)

            // 2) 综合占用 | 本机硬件摘要
            MDEqualSplit {
                compositeChartCard
            } right: {
                hostSummaryCard
            }

            // 3) 公网出口 · 抖动
            ipExitSummaryCard

            // 4) Top 进程
            MDCard {
                VStack(alignment: .leading, spacing: 8) {
                    MDSectionTitle(title: L10n.t("monitor.top_cpu"), meta: L10n.t("monitor.top_by_cpu"))
                    MDTopProcessList(
                        processes: Array(s.topCPU.prefix(8)),
                        name: { $0.name },
                        detail: { "PID \($0.pid)" },
                        value: { String(format: "%.1f%%", $0.usage) }
                    )
                }
            }
        }
        .onAppear {
            MonitorAIAssist.shared.start(monitor: monitor)
            monitorAI.refreshDashboard(preferAI: monitorAI.isConfigured, force: false)
        }
    }

    // MARK: Dashboard 状态一句

    private var dashStatusStrip: some View {
        let line = monitorAI.dashLine.isEmpty || !s.hasFreshDiagnosticMetrics(at: now)
            ? MonitorAIAssist.ruleDashLine(snapshot: s)
            : monitorAI.dashLine
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: monitorAI.dashUsedAI ? "sparkles" : "gauge.with.dots.needle.67percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.accent)
                Text(monitorAI.dashUsedAI ? L10n.t("monitor.ai_review") : L10n.t("monitor.live"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.accent)
                if monitorAI.isDashLoading {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 4)
                if monitorAI.isConfigured {
                    Button {
                        monitorAI.refreshDashboard(preferAI: true, force: true)
                    } label: {
                        Text(L10n.t("monitor.ai.scan"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(monitorAI.isDashLoading)
                }
            }

            MDAIClampedText(line)
                .font(.system(size: 12.5))
                .foregroundStyle(MDTheme.label)

            if let note = monitorAI.dashStaleNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(MDTheme.tertiary)
            }

        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MDTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: KPI helpers

    private var cpuFooter: String {
        let cores = s.host.cpuCoreLabel
        let n = s.topCPU.filter { $0.usage >= 1 }.count
        return L10n.t("monitor.kpi.active", cores, n)
    }

    private var gpuFooter: String {
        if let m = s.gpus.first?.model, !m.isEmpty {
            if let u = s.gpus.first?.utilization {
                return u < 0.05 ? L10n.t("monitor.kpi.idle", m) : m
            }
            return L10n.t("monitor.kpi.util_na", m)
        }
        return s.host.gpuCoreLabel == "—" ? L10n.t("monitor.kpi.gpu_enum") : s.host.gpuCoreLabel
    }

    private var ramValueLabel: String {
        guard let r = ram else { return "—" }
        let usedGB = r.used / 1_073_741_824
        let totalGB = r.total / 1_073_741_824
        if totalGB >= 1 {
            return String(format: "%.1f / %.0f GB", usedGB, totalGB)
        }
        return Format.percent(r.usage)
    }

    private var ramFooter: String {
        guard let r = ram else { return "—" }
        return L10n.t("monitor.kpi.used_pct", r.usage * 100)
    }

    private var diskValueLabel: String {
        guard let d = systemDisk else { return "—" }
        let usedGB = d.used / 1_073_741_824
        if usedGB >= 1000 { return String(format: "%.1f TB", usedGB / 1000) }
        return String(format: "%.0f GB", usedGB)
    }

    private var diskFooter: String {
        guard let d = systemDisk else { return "—" }
        let totalGB = d.total / 1_073_741_824
        let totalStr: String
        if totalGB >= 1000 { totalStr = L10n.t("monitor.kpi.total_tb", totalGB / 1000) }
        else { totalStr = L10n.t("monitor.kpi.total_gb", totalGB) }
        let extra = max(0, s.disks.count - 1)
        if extra > 0 { return L10n.t("monitor.disk.extra_vols", d.localizedKindLabel, totalStr, extra) }
        return "\(d.localizedKindLabel) · \(totalStr)"
    }

    // MARK: 综合占用

    private var compositeChartCard: some View {
        MDCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("monitor.composite"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MDTheme.secondary)
                            .textCase(.uppercase)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(compositeUsage.map { String(format: "%.0f", $0 * 100) } ?? "—")
                                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            Text(L10n.t("monitor.composite.unit"))
                                .font(.system(size: 12))
                                .foregroundStyle(MDTheme.secondary)
                        }
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        legendDot(MDTheme.chart1, "CPU")
                        legendDot(MDTheme.chart2, L10n.t("diag.kpi.memory"))
                        legendDot(MDTheme.chart3, "GPU")
                    }
                }

                TripleLineChart(
                    cpu: s.dashCPUSeries,
                    ram: s.dashRAMSeries,
                    gpu: s.dashGPUSeries
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 180)

                HStack {
                    Text("-60s").font(.system(size: 10)).foregroundStyle(MDTheme.tertiary)
                    Spacer()
                    Text(L10n.t("monitor.chart.now")).font(.system(size: 10)).foregroundStyle(MDTheme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 本机硬件

    private var hostSummaryCard: some View {
        MDCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("monitor.host.title"))
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.bottom, 8)

                // 只显示：MacBook Pro · 14 英寸 / M1 Pro（不显示 MacBookPro18,1）
                hostRow(L10n.t("monitor.host.model"), s.host.modelName)
                hostRow(L10n.t("monitor.host.chip"), s.host.chip)
                hostRow(L10n.t("monitor.host.cpu_cores"), s.host.cpuCoreLabel)
                hostRow(L10n.t("monitor.host.gpu"), s.host.gpuCoreLabel)
                hostRow(L10n.t("monitor.host.memory"), s.host.memoryLabel)
                hostRow(L10n.t("monitor.host.storage"), s.host.storageLabel)
                hostRow(L10n.t("monitor.host.macos"), s.host.macos)
                hostRow(L10n.t("monitor.host.uptime"), Format.uptime(seconds: s.host.uptimeSeconds), last: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hostRow(_ k: String, _ v: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(k)
                    .font(.system(size: 13))
                    .foregroundStyle(MDTheme.secondary)
                    .frame(width: 72, alignment: .leading)
                Spacer(minLength: 8)
                Text(v)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(MDTheme.label)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .padding(.vertical, 7)
            if !last {
                MDRowSeparator(leading: 0)
            }
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(MDTheme.secondary)
        }
    }

    // MARK: IP 摘要

    private var ipExitSummaryCard: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L10n.t("monitor.ip.title"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(windowDays <= 0 ? L10n.t("monitor.ip.all_self") : L10n.t("monitor.ip.window_self", windowDays))
                        .font(.system(size: 12))
                        .foregroundStyle(MDTheme.tertiary)
                }
                .padding(.bottom, 8)

                summaryRow(L10n.t("monitor.ip.current"), currentIPLine)
                MDRowSeparator(leading: 0)
                summaryRow(
                    windowDays <= 0 ? L10n.t("monitor.ip.retained") : L10n.t("monitor.ip.window", windowDays),
                    jitterCountLine
                )
                MDRowSeparator(leading: 0)
                summaryRow(L10n.t("monitor.ip.last"), lastChangeLine)

                HStack {
                    Spacer(minLength: 8)
                    Button {
                        onOpenNetwork()
                    } label: {
                        Text(L10n.t("monitor.ip.open_network"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MDTheme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(MDTheme.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
            }
        }
    }

    private var currentIPLine: String {
        guard let ip = ov.details.publicIP else { return L10n.t("monitor.ip.probing") }
        let stable = Format.stableDuration(since: ov.publicIPConfirmedSince)
        if let place = ov.publicIPPlaceLabel {
            return L10n.t("monitor.ip.stable_line", ip, place, stable)
        }
        return L10n.t("monitor.ip.stable_line_no_place", ip, stable)
    }

    private var jitterCountLine: String {
        let n = windowed.filter { $0.from != nil }.count
        if n == 0 {
            return windowDays <= 0 ? L10n.t("monitor.ip.no_jitter") : L10n.t("monitor.ip.no_jitter_window")
        }
        if let last = windowed.first {
            return L10n.t("monitor.ip.jitter_n_last", n, Format.dayTime(last.date))
        }
        return L10n.t("monitor.ip.jitter_n", n)
    }

    private var lastChangeLine: String {
        guard let e = windowed.first(where: { $0.from != nil }) ?? windowed.first else {
            return windowDays <= 0 ? "—" : L10n.t("monitor.ip.no_change_window")
        }
        if let from = e.from, let to = e.to {
            var s = "\(from) → \(to)"
            if let p = e.placeLabel { s += " · \(p)" }
            return s
        }
        if let to = e.to {
            var s = to
            if let note = e.note { s += " · \(note)" }
            if let p = e.placeLabel { s += " · \(p)" }
            return s
        }
        return e.note ?? "—"
    }

    private func summaryRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k)
                .font(.system(size: 13))
                .foregroundStyle(MDTheme.secondary)
                .frame(width: 72, alignment: .leading)
            Text(v)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(MDTheme.label)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }

    private func dashKPI(_ title: String, _ value: String, _ progress: Double?, _ tint: Color, footer: String) -> some View {
        MDCard(padding: 14, fillHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MDTheme.secondary)
                Text(value)
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MDTheme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let progress {
                    MDProgressBar(progress: progress, tint: tint)
                } else {
                    MDProgressBar(progress: 0, tint: MDTheme.tertiary)
                        .opacity(0.35)
                }
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(MDTheme.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MonitorCPUPane: View {
    @EnvironmentObject private var monitor: MonitorService
    @ObservedObject private var nav = AppNavigator.shared
    var now: Date = Date()
    private var cpu: CPULoad? { monitor.snapshot.cpuIsFresh(at: now) ? monitor.snapshot.cpu : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MDEqualSplit {
                MDCard(fillHeight: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        MDSectionTitle(title: L10n.t("monitor.cpu.overall"))
                        HStack {
                            MDRing(progress: cpu?.totalUsage ?? 0, size: 110, tint: MDTheme.chart1, center: Format.percent(cpu?.totalUsage), caption: L10n.t("monitor.cpu.usage"))
                            VStack(alignment: .leading, spacing: 8) {
                                row(L10n.t("monitor.cpu.system"), Format.percent(cpu?.systemLoad))
                                row(L10n.t("monitor.cpu.user"), Format.percent(cpu?.userLoad))
                                row(L10n.t("monitor.cpu.idle"), Format.percent(cpu?.idleLoad))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } right: {
                MDCard(fillHeight: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        MDSectionTitle(title: L10n.t("monitor.cpu.per_core"))
                        if let cores = cpu?.usagePerCore, !cores.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                                ForEach(Array(cores.enumerated()), id: \.offset) { idx, v in
                                    VStack(spacing: 4) {
                                        Text("C\(idx)").font(.system(size: 10)).foregroundStyle(MDTheme.tertiary)
                                        Text(String(format: "%.0f%%", v * 100)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        MDProgressBar(progress: v, tint: MDTheme.chart1, height: 3)
                                    }
                                    .padding(8)
                                    .background(MDTheme.surfaceInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            MDCard {
                VStack(alignment: .leading, spacing: 8) {
                    MDSectionTitle(title: L10n.t("monitor.top_cpu"))
                    MDTopProcessList(
                        processes: Array(monitor.snapshot.topCPU.prefix(10)),
                        name: { $0.name },
                        detail: { "PID \($0.pid)" },
                        value: { String(format: "%.1f%%", $0.usage) },
                        highlight: { nav.monitorFocusPID == $0.pid }
                    )
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundStyle(MDTheme.secondary)
            Spacer()
            Text(v).font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }
}

struct MonitorRAMPane: View {
    @EnvironmentObject private var monitor: MonitorService
    @ObservedObject private var nav = AppNavigator.shared
    var now: Date = Date()
    private var ram: RAMUsage? { monitor.snapshot.ramIsFresh(at: now) ? monitor.snapshot.ram : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MDCard {
                VStack(alignment: .leading, spacing: 12) {
                    MDSectionTitle(title: L10n.t("monitor.ram.title"))
                    HStack {
                        MDRing(progress: ram?.usage ?? 0, size: 110, tint: MDTheme.chart2, center: Format.percent(ram?.usage), caption: L10n.t("monitor.ram.used"))
                        VStack(alignment: .leading, spacing: 8) {
                            row(L10n.t("monitor.ram.used"), Format.bytes(ram?.used))
                            row(L10n.t("monitor.ram.total"), Format.bytes(ram?.total))
                            row(L10n.t("workbench.memory_app"), Format.bytes(ram?.app))
                            row(L10n.t("workbench.memory_wired"), Format.bytes(ram?.wired))
                            row(L10n.t("workbench.memory_compressed"), Format.bytes(ram?.compressed))
                            row(L10n.t("monitor.ram.pressure"), L10n.t("memory.pressure.\(monitor.snapshot.ramIsFresh() ? (ram?.pressure.value.rawValue ?? "unknown") : "unknown")"))
                            row(L10n.t("workbench.memory_swap"), monitor.snapshot.ramIsFresh() && ram?.swap.isAvailable == true
                                ? Format.bytes(ram?.swap.used) : "—")
                        }
                    }
                }
            }
            MDCard {
                VStack(alignment: .leading, spacing: 8) {
                    MDSectionTitle(title: L10n.t("monitor.ram.top"))
                    MDTopProcessList(
                        processes: Array(monitor.snapshot.topRAM.prefix(10)),
                        name: { $0.name },
                        detail: { "PID \($0.pid)" },
                        value: { Format.bytes($0.usage) },
                        highlight: { nav.monitorFocusPID == $0.pid }
                    )
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundStyle(MDTheme.secondary)
            Spacer()
            Text(v).font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }
}

struct MonitorDiskPane: View {
    @EnvironmentObject private var monitor: MonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonitorDiskActivityCard()
            if !monitor.snapshot.disks.isEmpty {
                Text(L10n.t("monitor.disk.note_dmg"))
                    .font(.system(size: 11))
                    .foregroundStyle(MDTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(monitor.snapshot.disks) { d in
                MDCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(d.name).font(.system(size: 15, weight: .semibold))
                            Text(d.localizedKindLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(d.kind.isVirtual ? MDTheme.tertiary : MDTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    (d.kind.isVirtual ? MDTheme.tertiary : MDTheme.accent).opacity(0.12),
                                    in: Capsule()
                                )
                            if d.removable {
                                Text(L10n.t("monitor.disk.ejectable"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(MDTheme.tertiary)
                            }
                            Spacer()
                            Text(Format.percent(d.usage))
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MDTheme.accent)
                        }
                        MDProgressBar(
                            progress: d.usage,
                            tint: d.kind.isVirtual
                                ? MDTheme.tertiary
                                : (d.usage > 0.85 ? MDTheme.warning : MDTheme.chart1)
                        )
                        row(L10n.t("monitor.disk.type"), diskTypeLine(d))
                        row(L10n.t("monitor.disk.path"), d.path)
                        row(L10n.t("monitor.disk.used_total"), "\(Format.bytes(d.used)) / \(Format.bytes(d.total))")
                        row(L10n.t("monitor.disk.free"), Format.bytes(d.free))
                        if !d.bsdName.isEmpty {
                            row(L10n.t("monitor.disk.device"), d.bsdName)
                        }
                    }
                }
            }
            if monitor.snapshot.disks.isEmpty {
                MDCard { Text(L10n.t("monitor.disk.empty")).foregroundStyle(MDTheme.secondary).padding(.vertical, 20) }
            }
        }
    }

    private func diskTypeLine(_ d: DiskVolume) -> String {
        var parts = [d.localizedKindLabel]
        if !d.protocolName.isEmpty { parts.append(d.protocolName) }
        if d.path == "/" { parts.append(L10n.t("monitor.disk.boot")) }
        return parts.joined(separator: " · ")
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundStyle(MDTheme.secondary)
            Spacer()
            Text(v).font(.system(size: 12).monospacedDigit())
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct MonitorGPUPane: View {
    @EnvironmentObject private var monitor: MonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.snapshot.gpus.isEmpty {
                MDCard { Text(L10n.t("monitor.gpu.empty")).foregroundStyle(MDTheme.secondary).padding(.vertical, 20) }
            } else {
                ForEach(monitor.snapshot.gpus) { g in
                    MDCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(g.model).font(.system(size: 15, weight: .semibold))
                            row(L10n.t("monitor.gpu.vendor"), g.vendor ?? "—")
                            row(L10n.t("monitor.gpu.util"), g.utilization.map { Format.percent($0) } ?? "—")
                        }
                    }
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundStyle(MDTheme.secondary)
            Spacer()
            Text(v).font(.system(size: 12).monospacedDigit())
        }
    }
}

struct MonitorSensorsPane: View {
    @EnvironmentObject private var monitor: MonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.snapshot.sensors.isEmpty {
                MDCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "thermometer.medium").font(.system(size: 28)).foregroundStyle(MDTheme.secondary)
                        if monitor.snapshot.sensorsAvailable {
                            Text(L10n.t("monitor.sensors.empty_title")).font(.system(size: 15, weight: .semibold))
                            Text(L10n.t("monitor.sensors.empty_body"))
                                .font(.system(size: 13)).foregroundStyle(MDTheme.secondary)
                        } else {
                            Text(L10n.t("monitor.sensors.no_smc_title")).font(.system(size: 15, weight: .semibold))
                            Text(L10n.t("monitor.sensors.no_smc_body"))
                                .font(.system(size: 13)).foregroundStyle(MDTheme.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                }
            } else {
                MDCard {
                    VStack(alignment: .leading, spacing: 8) {
                        MDSectionTitle(title: L10n.t("monitor.sensors.temp_title"), meta: L10n.t("monitor.sensors.count", monitor.snapshot.sensors.count))
                        ForEach(monitor.snapshot.sensors) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(.system(size: 13, weight: .medium))
                                    Text("\(s.group) · \(s.key)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(MDTheme.tertiary)
                                }
                                Spacer()
                                Text(String(format: "%.1f %@", s.value, s.unit))
                                    .font(.system(size: 13).monospacedDigit())
                            }
                            if s.id != monitor.snapshot.sensors.last?.id {
                                MDRowSeparator(leading: 0)
                            }
                        }
                    }
                }
            }
        }
    }
}
