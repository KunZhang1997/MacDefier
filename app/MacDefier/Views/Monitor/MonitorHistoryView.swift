import AppKit
import Charts
import CleanupKit
import MonitorKit
import SwiftUI

struct MonitorHistoryPane: View {
    @ObservedObject var history: MonitorHistoryRecorder
    @State private var selectedEventID: UUID?
    @State private var selectedTime: Date?
    @State private var showDay = false
    @State private var confirmClear = false
    @State private var exitTarget: MonitoredProcessIdentity?
    @State private var actionBusy = false
    @State private var resourceBusy = false
    private var event: MonitorHistoryEvent? { history.archive.events.first { $0.id == selectedEventID } }
    private var frames: [MonitorHistoryFrame] {
        event?.frames ?? (showDay ? history.archive.minuteSamples : history.archive.recent)
    }
    private var frame: MonitorHistoryFrame? {
        guard let selectedTime else { return frames.last(where: { !$0.gap }) }
        return frames.min { abs($0.time.timeIntervalSince(selectedTime)) < abs($1.time.timeIntervalSince(selectedTime)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if history.storageFailed {
                Label(L10n.t("history.storage_error"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(MDTheme.warning)
            }
            if let event {
                HStack {
                    Button { selectedEventID = nil; selectedTime = nil } label: {
                        Label(L10n.t("history.back"), systemImage: "chevron.left")
                    }
                    Text(L10n.t("history.kind.\(event.kind.rawValue)")).font(.headline)
                    Text(event.time, style: .time).monospacedDigit()
                    Spacer()
                    Text(L10n.t("history.state.\(event.state.rawValue)")).foregroundStyle(MDTheme.secondary)
                }
                Text(L10n.t("history.event_window")).font(.caption).foregroundStyle(MDTheme.secondary)
            } else {
                Picker(L10n.t("history.range"), selection: $showDay) {
                    Text(L10n.t("history.recent")).tag(false)
                    Text(L10n.t("history.retained")).tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 360)
            }
            if frames.contains(where: { !$0.gap }) {
                trends
                if let frame { sampleDetails(frame) }
            } else {
                ContentUnavailableView(L10n.t("history.empty"), systemImage: "clock.badge.questionmark",
                                       description: Text(L10n.t("history.empty_body")))
                    .frame(minHeight: 200)
            }
            if let event { actionRecords(event) }
            events
        }
        .alert(L10n.t("history.clear_title"), isPresented: $confirmClear) {
            Button(L10n.t("history.clear"), role: .destructive) { history.clear(); selectedEventID = nil; selectedTime = nil }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: { Text(L10n.t("history.clear_body")) }
        .alert(L10n.t("history.exit_title"), isPresented: Binding(get: { exitTarget != nil }, set: { if !$0 { exitTarget = nil } })) {
            if let target = exitTarget {
                Button(L10n.t("history.exit"), role: .destructive) { runExit(target) }
                Button(L10n.t("common.cancel"), role: .cancel) {
                    if let id = selectedEventID { history.recordAction(eventID: id, target: target, cancelled: true) }
                }
            }
        } message: {
            Text(L10n.t("history.exit_body", exitTarget?.ownerName ?? ""))
        }
        .alert(L10n.t("history.resource_busy"), isPresented: $resourceBusy) { Button(L10n.t("common.ok")) {} }
    }

    private var controls: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack { recordingToggle; Spacer(); markButton }
                    VStack(alignment: .leading) { recordingToggle; markButton }
                }
                Text(L10n.t("history.explanation")).font(.caption).foregroundStyle(MDTheme.secondary)
                HStack {
                    Picker(L10n.t("history.retention"), selection: Binding(get: { history.archive.retentionHours }, set: history.setRetentionHours)) {
                        ForEach([6, 24, 72], id: \.self) { Text(L10n.t("history.hours", $0)).tag($0) }
                    }.fixedSize()
                    Spacer()
                    Button(L10n.t("history.clear")) { confirmClear = true }
                        .disabled(!history.ready || history.archive.events.isEmpty && history.archive.recent.isEmpty)
                }
            }
        }
    }
    private var recordingToggle: some View {
        Toggle(L10n.t("history.record"), isOn: Binding(get: { history.enabled }, set: history.setEnabled))
            .toggleStyle(.switch).disabled(!history.ready).accessibilityIdentifier("monitor.history.record")
    }
    private var markButton: some View {
        Button { selectedEventID = history.mark(); selectedTime = nil } label: {
            Label(L10n.t("history.mark"), systemImage: "flag")
        }.disabled(!history.enabled).accessibilityIdentifier("monitor.history.mark")
    }
    private var trends: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                HistoryTrend(title: "CPU · %", frames: frames, selection: $selectedTime, color: MDTheme.chart1) { $0.cpu.map { $0 * 100 } }
                HistoryTrend(title: L10n.t("history.disk_rate"), frames: frames, selection: $selectedTime, color: MDTheme.chart3) { $0.disk.map { ($0.read + $0.write) / 1_048_576 } }
                HistoryTrend(title: L10n.t("history.swap_rate"), frames: frames, selection: $selectedTime, color: MDTheme.chart4) { $0.swapRate.map { ($0.read + $0.write) / 1_048_576 } }
                HistoryTrend(title: "GPU · %", frames: frames, selection: $selectedTime, color: MDTheme.chart2) { $0.gpu.compactMap(\.utilization).max().map { $0 * 100 } }
                HistoryTrend(title: L10n.t("history.temperature"), frames: frames, selection: $selectedTime, color: MDTheme.chart3) { $0.sensors.filter { $0.unit == "°C" }.map(\.value).max() }
                HistoryTrend(title: L10n.t("history.fan"), frames: frames, selection: $selectedTime, color: MDTheme.chart1) { $0.sensors.filter { $0.unit.lowercased() == "rpm" }.map(\.value).max() }
            }
            Text(L10n.t("history.chart_help")).font(.caption).foregroundStyle(MDTheme.secondary)
            Picker(L10n.t("history.sample"), selection: Binding(get: { frame?.time ?? Date.distantPast }, set: { selectedTime = $0 })) {
                ForEach(frames) { item in
                    Text(item.time.formatted(date: .omitted, time: .standard) + (item.gap ? " · " + L10n.t("history.gap") : "")).tag(item.time)
                }
            }.pickerStyle(.menu).fixedSize().accessibilityIdentifier("monitor.history.sample")
        }
    }
    private func sampleDetails(_ sample: MonitorHistoryFrame) -> some View {
        MDCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(sample.time.formatted(date: .abbreviated, time: .standard)).font(.headline)
                if sample.gap {
                    Text(L10n.t("history.gap"))
                } else {
                    LabeledContent(L10n.t("history.pressure"), value: L10n.t("history.pressure.\(sample.memoryPressure?.rawValue ?? "unknown")"))
                    LabeledContent(L10n.t("history.swap_used"), value: sample.swapUsed.map(historyBytes) ?? "—")
                    DisclosureGroup(L10n.t("history.sources")) {
                        ForEach(sample.sampledAt.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: sample.sampledAt[key]!.formatted(date: .omitted, time: .standard))
                        }
                        ForEach(sample.sensors) { sensor in
                            LabeledContent(sensor.name, value: String(format: "%.1f %@", sensor.value, sensor.unit))
                        }
                    }.font(.caption)
                    Divider()
                    Text(L10n.t("history.processes")).font(.headline)
                    Text(L10n.t("history.cpu_basis")).font(.caption).foregroundStyle(MDTheme.secondary)
                    ForEach(sample.topCPU) { process in
                        processRow(process.identity, name: process.name, value: String(format: "CPU %.1f%%", process.usage))
                    }
                    ForEach(sample.topRAM) { process in
                        processRow(process.identity, name: process.name, value: "RAM " + historyBytes(process.usage))
                    }
                    ForEach(sample.diskProcesses) { process in
                        processRow(process.identity, name: process.identity.ownerName,
                                   value: "↓ " + historyRate(process.rate.read) + "  ↑ " + historyRate(process.rate.write))
                    }
                    if sample.topCPU.isEmpty && sample.diskProcesses.isEmpty { Text(L10n.t("history.processes_empty")) }
                }
            }
        }
    }
    private func processRow(_ identity: MonitoredProcessIdentity?, name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(identity?.ownerName ?? name).font(.body.weight(.medium)).lineLimit(2)
                Spacer()
                Text(value).monospacedDigit().font(.caption)
                if let identity, identity.appPath != nil, event != nil {
                    Button(L10n.t("history.exit")) { exitTarget = identity }
                        .disabled(!history.enabled || actionBusy || history.archive.actions.contains { $0.outcome == .observing })
                }
            }
            if let identity {
                Text("PID \(identity.pid) · \(identity.executable)").font(.caption).foregroundStyle(MDTheme.secondary)
                    .lineLimit(2).textSelection(.enabled)
                if let path = identity.appPath {
                    Button(L10n.t("history.software")) {
                        AppNavigator.shared.focusSoftware(path: path, bundleID: identity.bundleID, name: identity.ownerName)
                    }.buttonStyle(.link)
                }
            } else { Text(L10n.t("history.identity_missing")).font(.caption).foregroundStyle(MDTheme.secondary) }
        }.padding(.vertical, 4)
    }
    private var events: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("history.events")).font(.headline)
                if history.archive.events.isEmpty { Text(L10n.t("history.no_events")).foregroundStyle(MDTheme.secondary) }
                ForEach(history.archive.events.reversed()) { event in
                    Button { selectedEventID = event.id; selectedTime = event.time } label: {
                        HStack {
                            Image(systemName: event.kind == .manual ? "flag" : "waveform.path.ecg")
                            Text(L10n.t("history.kind.\(event.kind.rawValue)"))
                            Text(event.time.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(L10n.t("history.state.\(event.state.rawValue)"))
                            Image(systemName: "chevron.right")
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
    private func actionRecords(_ event: MonitorHistoryEvent) -> some View {
        ForEach(history.archive.actions.filter { $0.eventID == event.id }.reversed()) { action in
            MDCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("history.action_title", action.target.ownerName)).font(.headline)
                    Text(L10n.t("history.outcome.\(action.outcome.rawValue)"))
                    Text(action.time.formatted(date: .abbreviated, time: .standard)).font(.caption)
                    if action.hasComparison {
                        LabeledContent("CPU", value: String(format: "%.1f%% → %.1f%%", (action.cpuBefore ?? 0) * 100, (action.cpuAfter ?? 0) * 100))
                        if let before = action.diskBefore, let after = action.diskAfter {
                            LabeledContent(L10n.t("history.disk_rate"), value: historyRate(before.read + before.write) + " → " + historyRate(after.read + after.write))
                        }
                    } else if action.outcome != .observing { Text(L10n.t("history.comparison_missing")).font(.caption) }
                    if action.wasAlreadyRecovered { Text(L10n.t("history.natural_recovery")).foregroundStyle(MDTheme.secondary) }
                    Text(L10n.t("history.comparison_scope")).font(.caption).foregroundStyle(MDTheme.secondary)
                }
            }
        }
    }
    private func runExit(_ target: MonitoredProcessIdentity) {
        guard let eventID = selectedEventID else { return }
        actionBusy = true
        Task { @MainActor in
            defer { actionBusy = false }
            guard let lease = await ResourceMutationCoordinator.shared.acquire(paths: [target.appPath ?? target.executable]) else {
                resourceBusy = true; return
            }
            history.recordAction(eventID: eventID, target: target, cancelled: false)
            // Keep the lease through the observation period; other entry points cannot mutate this app meanwhile.
            if history.archive.actions.last?.outcome == .observing { try? await Task.sleep(nanoseconds: 65_000_000_000) }
            await ResourceMutationCoordinator.shared.release(lease)
        }
    }
}

private struct HistoryTrend: View {
    let title: String
    let frames: [MonitorHistoryFrame]
    @Binding var selection: Date?
    let color: Color
    let value: (MonitorHistoryFrame) -> Double?
    private struct Point: Identifiable { let time: Date; let value: Double; let segment: Int; var id: Date { time } }
    private var points: [Point] {
        var result: [Point] = []; var segment = 0; var previous: Date?
        for frame in frames {
            // Minute-sampled retained history deliberately draws points only.
            if let previous, frame.time.timeIntervalSince(previous) > 15 { segment += 1 }
            previous = frame.time
            guard !frame.gap, let number = value(frame), number.isFinite else { segment += 1; continue }
            result.append(Point(time: frame.time, value: number, segment: segment))
        }
        return result
    }
    var body: some View {
        MDCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if points.isEmpty {
                    Text(L10n.t("history.metric_unavailable")).font(.caption).foregroundStyle(MDTheme.secondary).frame(height: 90)
                } else {
                    Chart {
                        ForEach(points) { point in
                        LineMark(x: .value("Time", point.time), y: .value(title, point.value), series: .value("Segment", point.segment))
                            .foregroundStyle(color)
                        PointMark(x: .value("Time", point.time), y: .value(title, point.value)).symbolSize(8).foregroundStyle(color)
                        }
                        if let selection { RuleMark(x: .value("Time", selection)).foregroundStyle(.secondary.opacity(0.4)) }
                    }
                    .chartXSelection(value: $selection).chartYScale(domain: .automatic(includesZero: true))
                    .frame(height: 100).accessibilityLabel(title)
                }
            }
        }
    }
}

struct MonitorDiskActivityCard: View {
    @EnvironmentObject private var monitor: MonitorService
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { timeline in
            MDCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("history.disk_activity")).font(.headline)
                    if let activity = monitor.snapshot.diskActivity, activity.isFresh(at: timeline.date) {
                        HStack {
                            LabeledContent(L10n.t("history.read"), value: activity.total.map { historyRate($0.read) } ?? "—")
                            LabeledContent(L10n.t("history.write"), value: activity.total.map { historyRate($0.write) } ?? "—")
                        }
                        ForEach(activity.processes) { process in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(process.identity.ownerName)
                                    Text("PID \(process.identity.pid)").font(.caption).foregroundStyle(MDTheme.secondary)
                                }
                                Spacer()
                                Text("↓ " + historyRate(process.rate.read) + "   ↑ " + historyRate(process.rate.write)).monospacedDigit()
                            }
                        }
                        if activity.processes.isEmpty { Text(L10n.t("history.disk_idle")).foregroundStyle(MDTheme.secondary) }
                        Text(L10n.t("history.io_coverage", activity.readableProcesses, activity.unavailableProcesses))
                            .font(.caption).foregroundStyle(MDTheme.secondary)
                    } else { Text(L10n.t("history.metric_unavailable")).foregroundStyle(MDTheme.secondary) }
                    Text(L10n.t("history.io_scope")).font(.caption).foregroundStyle(MDTheme.secondary)
                }
            }
        }
    }
}

private func historyBytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max / 2), max(0, value))), countStyle: .memory)
}
private func historyRate(_ value: Double) -> String { historyBytes(value) + "/s" }
