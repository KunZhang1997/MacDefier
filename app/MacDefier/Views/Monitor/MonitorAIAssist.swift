// Monitor 近项 AI：Dashboard 一句 + 公网 IP 变更一句。
// 规则先出；AI 可选润色。关 AI 不影响监控展示。不系统通知、不杀进程、不恐吓。

import Combine
import Foundation
import MonitorKit

@MainActor
final class MonitorAIAssist: ObservableObject {
    static let shared = MonitorAIAssist()

    // MARK: - Dashboard 一句

    @Published private(set) var dashLine: String = ""
    @Published private(set) var dashUsedAI = false
    /// AI 句后资源明显变化 → 已退回规则句
    @Published private(set) var dashStaleNote: String?
    @Published private(set) var isDashLoading = false
    @Published private(set) var dashError: String?

    // MARK: - IP 变更一句

    @Published private(set) var ipTip: String?
    @Published private(set) var ipTipUsedAI = false
    @Published private(set) var isIPLoading = false
    /// 最近一次确认抖动的 to IP（用于 UI 高亮）
    @Published private(set) var ipTipTo: String?

    private weak var monitor: MonitorService?
    private var cancellables = Set<AnyCancellable>()
    private var dashTask: Task<Void, Never>?
    private var ipTask: Task<Void, Never>?
    private var lastDashFingerprint = ""
    private var lastDashAIAt = Date.distantPast
    private var lastAnnouncedChangeID: UUID?
    private var started = false

    private let announcedIPKey = "monitor.ai.lastAnnouncedPublicIP"
    private let announcedChangeIDKey = "monitor.ai.lastAnnouncedChangeID"
    private let dashAICooldown: TimeInterval = 90

    private init() {}

    var isConfigured: Bool {
        let s = AISettingsStore.load()
        return s.enabled && s.mode != .off && AIClient.resolveEndpoint(s) != nil
    }

    func start(monitor: MonitorService) {
        guard !started else { return }
        started = true
        self.monitor = monitor

        // 规则一句立刻出
        applyRuleDash(snapshot: monitor.snapshot)

        monitor.$snapshot
            .map { snapshot in
                let cpu = Int((snapshot.cpu?.totalUsage ?? 0) * 20)
                let ram = Int((snapshot.ram?.usage ?? 0) * 20)
                let diskFree = Int((snapshot.disks.primary ?? snapshot.disks.physical.first)?.free ?? 0) / 1_073_741_824
                let top = snapshot.topCPU.first.map { "\($0.name):\(Int($0.usage))" } ?? "-"
                let ipChange = snapshot.networkOverview.ipHistory.first?.id.uuidString ?? "-"
                return "\(cpu)|\(ram)|\(diskFree)|\(top)|\(ipChange)"
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.onSnapshotTick()
            }
            .store(in: &cancellables)

        // 冷启动：若有未播报的历史变更，只看「最新一条且 from 非空」
        checkIPChange(force: false)
    }

    func stop() {
        dashTask?.cancel()
        ipTask?.cancel()
        cancellables.removeAll()
        started = false
    }

    // MARK: - Public

    /// Dashboard 出现时：规则刷新；配了 AI 且冷却过了可自动润色一次。
    func refreshDashboard(preferAI: Bool, force: Bool = false) {
        guard let snap = monitor?.snapshot else { return }
        if force {
            dashUsedAI = false
            dashStaleNote = nil
        }
        applyRuleDash(snapshot: snap)
        guard preferAI, isConfigured, snap.hasFreshDiagnosticMetrics() else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastDashAIAt) < dashAICooldown { return }
        runDashAI(snapshot: snap)
    }

    func refreshIPTip(preferAI: Bool) {
        guard let ov = monitor?.snapshot.networkOverview,
              let entry = ov.ipHistory.first(where: { $0.from != nil && $0.to != nil }),
              let from = entry.from, let to = entry.to
        else { return }
        let rule = Self.ruleIPLine(from: from, to: to, place: entry.placeLabel)
        ipTip = preferAI && isConfigured ? (ipTip ?? rule) : rule
        if !preferAI { ipTipUsedAI = false }
        ipTipTo = to
        if preferAI, isConfigured {
            runIPAI(from: from, to: to, place: entry.placeLabel, rule: rule)
        } else {
            checkIPChange(force: false)
        }
    }

    // MARK: - Snapshot tick

    private func onSnapshotTick() {
        guard let snap = monitor?.snapshot else { return }
        let fp = dashFingerprint(snap)
        if fp != lastDashFingerprint {
            let previous = lastDashFingerprint
            lastDashFingerprint = fp
            guard !isDashLoading else { return }
            if dashUsedAI, !previous.isEmpty {
                // 负载档变了：丢掉过时 AI 句，回规则，避免「AI 乱变/说旧话」
                dashUsedAI = false
                dashStaleNote = L10n.t("monitor.ai.stale_note")
                dashLine = Self.ruleDashLine(snapshot: snap)
            } else {
                applyRuleDash(snapshot: snap)
            }
        }
        checkIPChange(force: false)
    }

    // MARK: - Rule dash

    private func applyRuleDash(snapshot: MonitorSnapshot) {
        let line = Self.ruleDashLine(snapshot: snapshot)
        if !dashUsedAI || dashLine.isEmpty {
            dashLine = line
            dashUsedAI = false
        }
    }

    static func ruleDashLine(snapshot s: MonitorSnapshot) -> String {
        let cpu = s.cpuIsFresh() ? (s.cpu?.totalUsage ?? 0) : 0
        let ram = s.ramIsFresh() ? (s.ram?.usage ?? 0) : 0
        let disk = s.systemDiskIsFresh() ? s.disks.first(where: DiagnosticScore.isSystemVolume) : nil
        let freeGB = disk.map { $0.free / 1_073_741_824 } ?? 999
        let diskUsage = disk?.usage ?? 0
        let top = s.topCPU.first
        let topName = top?.name ?? ""
        let topCPU = top?.usage ?? 0

        if freeGB < 25 || diskUsage >= 0.90 {
            let freeStr = disk.map {
                ByteCountFormatter.string(fromByteCount: Int64($0.free), countStyle: .file)
            } ?? "—"
            return L10n.t("monitor.rule.disk_full", freeStr)
        }
        if cpu >= 0.85 {
            if topCPU >= 15, !topName.isEmpty {
                return L10n.t("monitor.rule.cpu_busy_top", pct(cpu), topName)
            }
            return L10n.t("monitor.rule.cpu_busy", pct(cpu))
        }
        if s.ramIsFresh(), let pressure = s.ram?.pressure.value,
           pressure == .warning || pressure == .critical {
            if let r = s.topRAM.first, r.usage >= 10 {
                return L10n.t("monitor.rule.ram_pressure_top", L10n.t("memory.pressure.\(pressure.rawValue)"), r.name)
            }
            return L10n.t("monitor.rule.ram_pressure", L10n.t("memory.pressure.\(pressure.rawValue)"))
        }
        guard s.hasFreshCoreMetrics() else { return L10n.t("diag.find.metrics_unknown") }
        guard s.systemDiskIsFresh() else { return L10n.t("diag.find.storage_unknown") }
        if cpu >= 0.55 {
            if topCPU >= 8, !topName.isEmpty {
                return L10n.t("monitor.rule.load_top", topName, pct(cpu), pct(ram))
            }
            return L10n.t("monitor.rule.load", pct(cpu), pct(ram))
        }
        return L10n.t("monitor.rule.ok")
    }

    private static func pct(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }

    private func dashFingerprint(_ s: MonitorSnapshot) -> String {
        let cpu = Int((s.cpu?.totalUsage ?? 0) * 20) // 5% buckets
        let ram = Int((s.ram?.usage ?? 0) * 20)
        let free = Int(s.disks.first(where: DiagnosticScore.isSystemVolume)?.free ?? 0) / 1_073_741_824
        let top = s.topCPU.first.map { "\($0.name):\($0.usage)" } ?? "-"
        return "\(cpu)|\(ram)|\(free)|\(top)|\(s.ram?.pressure.value.rawValue ?? "unknown")|\(s.hasFreshDiagnosticMetrics())"
    }

    private func runDashAI(snapshot: MonitorSnapshot) {
        dashTask?.cancel()
        isDashLoading = true
        dashError = nil
        let rule = Self.ruleDashLine(snapshot: snapshot)
        if dashLine.isEmpty { dashLine = rule }
        let ctx = Self.contextBrief(snapshot: snapshot)
        let settings = AISettingsStore.load()
        let langRule = AppLanguage.current.aiLanguageRule

        dashTask = Task { @MainActor in
            defer { isDashLoading = false }
            do {
                let reply = try await AIClient.chat(
                    messages: [
                        AIMessage(role: .user, content: """
                        \(langRule)
                        Task: polish the draft into one natural sentence (≤55 Chinese chars or ≤20 English words).
                        Keep facts (numbers, process names); soft tone like a friend.
                        Forbidden: scare, virus, formalese, multi-sentence lists.
                        Draft: \(rule)
                        Context (optional, do not dump metrics):
                        \(ctx)
                        """)
                    ],
                    settings: settings,
                    intensity: .light,
                    systemExtra: """
                    \(langRule)
                    You polish MacDefier monitor status. Output one readable line only.
                    High load ≠ failure. No scare. Do not explain the polish.
                    """
                )
                guard !Task.isCancelled else { return }
                if let current = monitor?.snapshot,
                   !current.hasFreshDiagnosticMetrics() || dashFingerprint(current) != dashFingerprint(snapshot) {
                    dashLine = Self.ruleDashLine(snapshot: current)
                    dashUsedAI = false
                    return
                }
                var text = sanitizeOneLine(reply.content)
                if text.isEmpty { text = rule }
                dashLine = text
                dashUsedAI = true
                dashStaleNote = nil
                lastDashAIAt = Date()
                lastDashFingerprint = dashFingerprint(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                dashError = nil // 静默回退规则
                dashLine = rule
                dashUsedAI = false
                dashStaleNote = nil
            }
        }
    }

    // MARK: - IP change

    private func checkIPChange(force: Bool) {
        guard let ov = monitor?.snapshot.networkOverview else { return }
        // 最新一条「真抖动」（from → to）
        guard let entry = ov.ipHistory.first(where: { $0.from != nil && $0.to != nil }),
              let from = entry.from, let to = entry.to
        else { return }

        let changeKey = entry.id.uuidString
        let lastID = UserDefaults.standard.string(forKey: announcedChangeIDKey)
        let rule = Self.ruleIPLine(from: from, to: to, place: entry.placeLabel)

        // 页内常驻展示最新抖动句（不依赖是否新播报）
        if ipTip == nil || lastAnnouncedChangeID != entry.id {
            if lastID == changeKey {
                // 已播报过：只补展示，不重复宠/对话
                if ipTip == nil {
                    ipTip = rule
                    ipTipTo = to
                    ipTipUsedAI = false
                }
                lastAnnouncedChangeID = entry.id
                if !force { return }
            }
        }

        // 新变更 或 force：播报
        if lastID != changeKey || force {
            presentIPChange(entry: entry, from: from, to: to, preferAI: isConfigured || force)
        }
    }

    private func presentIPChange(entry: IPHistoryEntry, from: String, to: String, preferAI: Bool) {
        let rule = Self.ruleIPLine(from: from, to: to, place: entry.placeLabel)
        ipTip = rule
        ipTipTo = to
        ipTipUsedAI = false
        lastAnnouncedChangeID = entry.id

        UserDefaults.standard.set(entry.id.uuidString, forKey: announcedChangeIDKey)
        UserDefaults.standard.set(to, forKey: announcedIPKey)

        // 窗宠短气泡（不依赖 AI）
        NotificationCenter.default.post(
            name: .monitorIPExitChanged,
            object: nil,
            userInfo: ["line": rule, "to": to]
        )

        guard preferAI else { return }
        runIPAI(from: from, to: to, place: entry.placeLabel, rule: rule)
    }

    static func ruleIPLine(from: String, to: String, place: String?) -> String {
        if let p = place, !p.isEmpty {
            return L10n.t("monitor.rule.ip_place", to, p, from)
        }
        return L10n.t("monitor.rule.ip", from, to)
    }

    private func runIPAI(from: String, to: String, place: String?, rule: String) {
        ipTask?.cancel()
        isIPLoading = true
        let settings = AISettingsStore.load()
        let placeBit = place.map { "place=\($0)" } ?? ""
        let langRule = AppLanguage.current.aiLanguageRule
        ipTask = Task { @MainActor in
            defer { isIPLoading = false }
            do {
                let reply = try await AIClient.chat(
                    messages: [
                        AIMessage(role: .user, content: """
                        \(langRule)
                        Task: polish the draft into one natural sentence (≤50 words / ≤50 Chinese characters).
                        Keep from→to; casual tone; VPN/network change is normal.
                        Forbidden: hacked/virus/scare/officialese.
                        Draft: \(rule)
                        Extra: from=\(from) to=\(to) \(placeBit)
                        """)
                    ],
                    settings: settings,
                    intensity: .light,
                    systemExtra: "\(langRule) Monitor network polish. Output one readable line only. No scare."
                )
                guard !Task.isCancelled else { return }
                var text = sanitizeOneLine(reply.content)
                if text.isEmpty { text = rule }
                ipTip = text
                ipTipUsedAI = true
                NotificationCenter.default.post(
                    name: .monitorIPExitChanged,
                    object: nil,
                    userInfo: ["line": text, "to": to]
                )
            } catch {
                // 保持规则句
            }
        }
    }

    // MARK: - Helpers

    private static func contextBrief(snapshot s: MonitorSnapshot) -> String {
        var lines: [String] = []
        if s.cpuIsFresh(), let c = s.cpu {
            lines.append("CPU=\(String(format: "%.0f%%", c.totalUsage * 100))")
        }
        if s.ramIsFresh(), let r = s.ram {
            lines.append("RAM=\(String(format: "%.0f%%", r.usage * 100)) used=\(ByteCountFormatter.string(fromByteCount: Int64(r.used), countStyle: .memory))")
            lines.append("Memory pressure=\(r.pressure.value.rawValue); RAM used% alone does not show memory pressure.")
        }
        if s.systemDiskIsFresh(), let d = s.disks.first(where: DiagnosticScore.isSystemVolume) {
            lines.append("Disk free=\(ByteCountFormatter.string(fromByteCount: Int64(d.free), countStyle: .file)) usage=\(String(format: "%.0f%%", d.usage * 100))")
        }
        if let g = s.gpus.first {
            let u = g.utilization.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
            lines.append("GPU=\(g.model) util=\(u)")
        }
        let tops = s.topCPU.prefix(5).map { "\($0.name) \(String(format: "%.0f", $0.usage))%" }.joined(separator: ", ")
        if !tops.isEmpty { lines.append("TopCPU: \(tops)") }
        if let ip = s.networkOverview.details.publicIP {
            lines.append("PublicIP=\(ip) place=\(s.networkOverview.publicIPPlaceLabel ?? "-")")
        }
        return lines.joined(separator: "\n")
    }

    private func sanitizeOneLine(_ raw: String) -> String {
        var t = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["已思考完毕，见下方可展开的过程", "（已思考完毕，见下方可展开的过程）", "已思考完毕"] {
            t = t.replacingOccurrences(of: p, with: "")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // 取第一非空行，压成一句
        if let first = t.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            t = first
        }
        if t.count > 80 {
            t = String(t.prefix(78)) + "…"
        }
        return t
    }
}

extension Notification.Name {
    static let monitorIPExitChanged = Notification.Name("MacDefier.monitorIPExitChanged")
}
