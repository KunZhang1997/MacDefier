import SwiftUI
import AppKit
import MonitorKit

/// One snapshot drives the entire panel. Presentation/demand belongs to MenuBarController.
struct MenuBarPanelView: View {
    @ObservedObject var monitor: MonitorService
    @ObservedObject private var diagnosticScan = DiagnosticScanService.shared
    let height: CGFloat
    let navigate: (AppRoute, MonitorTab?) -> Void
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.chinese.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @State private var processMetric = ProcessMetric.memory
    @State private var openedAt = Date()

    private enum ProcessMetric: String, CaseIterable { case memory, cpu }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            panel(snapshot: monitor.snapshot, now: context.date)
        }
        .frame(width: 360, height: height)
        .background(MDTheme.content)
        .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
        .environment(\.locale, L10n.locale)
        .id(language)
        .transaction { $0.animation = nil }
    }

    private func panel(snapshot: MonitorSnapshot, now: Date) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    header(snapshot, now: now)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        cpuCard(snapshot, now: now)
                        memoryCard(snapshot, now: now)
                        diskCard(snapshot, now: now)
                        networkCard(snapshot, now: now)
                        gpuCard(snapshot, now: now)
                        fanCard(snapshot, now: now)
                    }
                    batteryRow(snapshot, now: now)
                    processes(snapshot, now: now)
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
            Divider()
            footer
        }
    }

    private func header(_ s: MonitorSnapshot, now: Date) -> some View {
        let score = DiagnosticScore.evaluateLive(
            snapshot: s,
            report: diagnosticScan.report,
            hasFreshScan: diagnosticScan.hasFreshResult
        )
        let reasonSeparator = AppLanguage.current.isEnglish ? ", " : "、"
        let reasons = score.topReasonKeys.map { L10n.t("diag.score.reason.\($0)") }.joined(separator: reasonSeparator)
        let scoreExplanation = reasons.isEmpty ? L10n.t("menupanel.score_help") : L10n.t("diag.score.mainly", reasons)
        let tint = score.total.map { $0 >= 85 ? Color.green : Color.orange } ?? Color.secondary
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: score.total == nil ? "gauge.with.dots.needle.50percent" : "sun.max.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(score.total.map(String.init) ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .help(scoreExplanation)
                VStack(alignment: .leading, spacing: 2) {
                    Text(score.total == nil ? waiting(now) : L10n.t(score.statusKey))
                        .font(.system(size: 12, weight: .semibold))
                    Text(reasons.isEmpty ? L10n.t("menupanel.live_status") : scoreExplanation)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button { navigate(.settings, nil) } label: {
                    Image(systemName: "gearshape").font(.system(size: 14))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("route.settings"))
                .help(L10n.t("route.settings"))
            }
            HStack(spacing: 5) {
                chip(s.host.chip)
                chip(s.host.memoryLabel)
                chip(s.host.macos)
                Spacer(minLength: 0)
                Text(s.host.uptimeLabel)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(L10n.t("monitor.host.uptime"))
                    .accessibilityLabel(L10n.t("monitor.host.uptime") + " " + s.host.uptimeLabel)
            }
        }
        .padding(.bottom, 3)
    }

    private func cpuCard(_ s: MonitorSnapshot, now: Date) -> some View {
        let cpu = s.cpuIsFresh(at: now) ? s.cpu : nil
        let topProcess = s.topCPUIsFresh(at: now) ? s.topCPU.first : nil
        let loadBadge = s.averageLoad.map { String(format: "1m %.1f", $0.load1) }
        return metricCard(title: "CPU", icon: "cpu", tint: .mint,
                          badge: temperature("CPU", s, now) ?? loadBadge, tab: .cpu) {
            metricValue(cpu.map { percent($0.totalUsage) })
            CoreBars(values: cpu?.usagePerCore ?? [], tint: .mint).frame(height: 24)
            caption(topProcess.map { "\($0.name) · \(String(format: "%.0f%%", $0.usage))" }
                    ?? cpu.map { L10n.t("menupanel.cores", $0.usagePerCore.count) } ?? waiting(now))
        }
    }

    private func gpuCard(_ s: MonitorSnapshot, now: Date) -> some View {
        let gpu = s.gpusAreFresh(at: now) ? s.gpus.first : nil
        let usage = gpu?.utilization.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        return metricCard(title: "GPU", icon: "square.3.layers.3d", tint: .orange, badge: temperature("GPU", s, now), tab: .gpu) {
            metricValue(usage.map(percent))
            PanelSparkline(values: usage == nil ? [] : s.dashGPUSeries, tint: .orange, maximum: 1)
                .frame(height: 24)
            caption(usage == nil ? L10n.t("menupanel.unavailable") : (gpu?.model ?? s.host.chip))
        }
    }

    private func memoryCard(_ s: MonitorSnapshot, now: Date) -> some View {
        let ram = s.ramIsFresh(at: now) ? s.ram : nil
        let topProcess = s.topRAMIsFresh(at: now) ? s.topRAM.first : nil
        let pressure = ram?.pressure.value ?? .unknown
        let tint: Color = pressure == .critical ? .red : pressure == .warning ? .orange : .mint
        return metricCard(title: L10n.t("menupanel.memory"), icon: "memorychip", tint: tint,
                          badge: L10n.t("memory.pressure.\(pressure.rawValue)"), tab: .ram) {
            metricValue(ram.map { percent($0.usage) })
            PanelSparkline(values: ram == nil ? [] : s.dashRAMSeries, tint: tint, maximum: 1)
                .frame(height: 24)
            caption(topProcess.map { "\($0.name) · \(bytes($0.usage))" }
                    ?? ram.map { "\(bytes($0.used)) / \(bytes($0.total))" } ?? waiting(now))
        }
    }

    private func diskCard(_ s: MonitorSnapshot, now: Date) -> some View {
        let disk = s.systemDiskIsFresh(at: now) ? s.disks.first(where: DiagnosticScore.isSystemVolume) : nil
        return metricCard(title: L10n.t("menupanel.free_space"), icon: "internaldrive", tint: .blue,
                          badge: disk.map {
                              let gb = $0.total / 1_073_741_824
                              return gb >= 1024 ? String(format: "%.1f TB", gb / 1024) : String(format: "%.0f GB", gb)
                          }, tab: .disk) {
            metricValue(disk.map { bytes($0.free) })
            PanelFill(value: disk?.usage, tint: .blue).frame(height: 24)
            caption(disk.map { L10n.t("menupanel.disk_used", percent($0.usage)) } ?? waiting(now))
        }
    }

    private func networkCard(_ s: MonitorSnapshot, now: Date) -> some View {
        let overview = s.networkIsFresh(at: now) ? s.networkOverview : nil
        let network = overview?.primary
        let connectionName = overview?.details.ssid ?? overview?.details.mediaLabel
        return metricCard(title: L10n.t("menupanel.network"), icon: "network", tint: .cyan,
                          badge: connectionName, tab: .network) {
            metricValue(network.map { "↓ " + bytes($0.bytesInPerSec) + "/s" }, size: 20)
            PanelSparkline(values: network == nil ? [] : (overview?.history.map(\.downBytesPerSec) ?? []),
                           tint: .cyan, maximum: nil).frame(height: 24)
            caption(network.map { "↑ \(bytes($0.bytesOutPerSec))/s · \($0.displayName)" } ?? waiting(now))
        }
    }

    private func fanCard(_ s: MonitorSnapshot, now: Date) -> some View {
        let fans = s.sensorsAreFresh(at: now) ? s.sensors.filter { $0.unit.lowercased() == "rpm" && $0.value.isFinite } : []
        let rpm = fans.map(\.value).max()
        return metricCard(title: L10n.t("menupanel.fan"), icon: "fan", tint: .purple,
                          badge: fans.isEmpty ? nil : L10n.t("menupanel.read_only"), tab: .sensors) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                metricValue(rpm.map { String(format: "%.0f", $0) })
                if rpm != nil { Text("RPM").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 4) {
                Image(systemName: "waveform.path").font(.system(size: 11))
                Text(L10n.t("menupanel.fan_reading")).font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .frame(height: 24)
            caption(fans.isEmpty ? L10n.t("menupanel.no_fan_reading") : L10n.t("menupanel.fans", fans.count))
        }
    }

    @ViewBuilder
    private func batteryRow(_ s: MonitorSnapshot, now: Date) -> some View {
        if !(s.batteryIsFresh(at: now) && s.battery?.isPresent == false) {
            let battery = s.batteryIsFresh(at: now) ? s.battery : nil
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("menupanel.battery")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        metricValue(battery?.charge.map(percent))
                        Text(batteryStatus(battery)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 3)
                    if let charge = battery?.charge {
                        Circle().trim(from: 0, to: min(1, max(0, charge)))
                            .stroke(Color.mint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    Image(systemName: battery?.isCharging == true ? "bolt.fill" : "battery.100percent")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .accessibilityElement(children: .combine)
        }
    }

    private func processes(_ s: MonitorSnapshot, now: Date) -> some View {
        let fresh = processMetric == .memory ? s.topRAMIsFresh(at: now) : s.topCPUIsFresh(at: now)
        let rows = fresh ? Array((processMetric == .memory ? s.topRAM : s.topCPU).prefix(5)) : []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("menupanel.top_processes"))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker(L10n.t("menupanel.process_metric"), selection: $processMetric) {
                    Text(L10n.t("menupanel.memory")).tag(ProcessMetric.memory)
                    Text("CPU").tag(ProcessMetric.cpu)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 128)
                .controlSize(.mini)
            }
            if rows.isEmpty {
                Text(fresh ? L10n.t("menupanel.no_processes") : waiting(now))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 102, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { process in
                        HStack(spacing: 7) {
                            if let icon = processIcon(process.pid) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "terminal")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16, height: 16)
                            }
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 5)
                            Text(processMetric == .memory ? bytes(process.usage) : String(format: "%.1f%%", process.usage))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                        .frame(height: 21)
                        .help("\(process.name) · PID \(process.pid)")
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(11)
        .background(cardBackground)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Button { navigate(.cleanup, nil) } label: {
                Image(systemName: "trash").frame(width: 28, height: 26)
            }
            .accessibilityLabel(L10n.t("route.cleanup"))
            .help(L10n.t("route.cleanup"))
            Button { navigate(.diskMap, nil) } label: {
                Image(systemName: "square.grid.2x2").frame(width: 28, height: 26)
            }
            .accessibilityLabel(L10n.t("diskmap.title"))
            .help(L10n.t("diskmap.title"))
            Spacer()
            Button { navigate(.monitor, .dashboard) } label: {
                HStack(spacing: 6) {
                    Text(L10n.t("menupanel.open_monitor"))
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5).frame(height: 26)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func metricCard<Content: View>(title: String, icon: String, tint: Color, badge: String?,
                                            tab: MonitorTab, @ViewBuilder content: () -> Content) -> some View {
        Button { navigate(.monitor, tab) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: icon).foregroundStyle(tint)
                    Text(title).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let badge, !badge.isEmpty, badge != "—" {
                        Text(badge).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(L10n.t("menupanel.open_detail", title))
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.t("menupanel.open_detail", title))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(MDTheme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MDTheme.subtleBorder, lineWidth: 0.5)
            }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }

    private func metricValue(_ value: String?, size: CGFloat = 23) -> some View {
        Text(value ?? "—").font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(.primary)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func waiting(_ now: Date) -> String {
        L10n.t(now.timeIntervalSince(openedAt) < 12 ? "menupanel.measuring" : "menupanel.unavailable")
    }

    private func temperature(_ group: String, _ s: MonitorSnapshot, _ now: Date) -> String? {
        guard s.sensorsAreFresh(at: now),
              let value = s.sensors.filter({ $0.group == group && $0.unit == "°C" && $0.value.isFinite }).map(\.value).max()
        else { return nil }
        return String(format: "%.0f°C", value)
    }

    private func batteryStatus(_ battery: BatteryInfo?) -> String {
        guard let battery else { return L10n.t("menupanel.unavailable") }
        if battery.isCharging == true { return L10n.t("menupanel.charging") }
        if battery.isOnACPower == true {
            return L10n.t((battery.charge ?? 0) >= 0.99 ? "menupanel.charged" : "menupanel.ac_power")
        }
        if let minutes = battery.timeToEmptyMinutes, minutes > 0 {
            return L10n.t("menupanel.remaining", minutes / 60, minutes % 60)
        }
        return L10n.t(battery.isOnACPower == false ? "menupanel.on_battery" : "menupanel.unavailable")
    }

    private func processIcon(_ pid: Int) -> NSImage? {
        guard let pid32 = pid_t(exactly: pid),
              let app = NSRunningApplication(processIdentifier: pid32) else { return nil }
        return app.icon
    }

    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    private func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}

private struct CoreBars: View {
    let values: [Double]
    let tint: Color
    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.prefix(32).enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tint.gradient)
                        .frame(height: max(1, proxy.size.height * min(1, max(0, value.isFinite ? value : 0))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

private struct PanelFill: View {
    let value: Double?
    let tint: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                if let value {
                    Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, value)))
                }
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

private struct PanelSparkline: View {
    let values: [Double]
    let tint: Color
    let maximum: Double?
    var body: some View {
        Canvas { context, size in
            let points = Array(values.suffix(60))
            guard points.count > 1, points.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
            let ceiling = max(0.001, maximum ?? points.max() ?? 1)
            var line = Path()
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: size.width * Double(index) / Double(points.count - 1),
                                    y: 2 + (size.height - 4) * (1 - min(1, value / ceiling)))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.25), tint.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}
