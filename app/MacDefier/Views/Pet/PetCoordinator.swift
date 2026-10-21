// Aggregates existing product signals into pet mood + banter.
// Does not reimplement scan/cleanup/monitor — only reads and presents.

import Combine
import Foundation
import SwiftUI
import MonitorKit
import CleanupKit

@MainActor
final class PetCoordinator: ObservableObject {
    @Published private(set) var mood: PetMood = .idle
    @Published var banterLine: String?

    /// Wired from overlay
    @Published var isChatOpen = false
    @Published var isAISending = false
    @Published var aiOff = false

    private let scan = DiagnosticScanService.shared
    private let cleanup = CleanupService.shared
    private weak var monitor: MonitorService?

    private var cancellables = Set<AnyCancellable>()
    private var banterLoopRunning = false
    private var banterLoopId = UUID()
    private var banterLoopTask: Task<Void, Never>?
    private var setupHintTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var banterDisplayId = UUID()
    private var lastBanterAt = Date.distantPast

    private var lastFindingKey: String?
    private var lastFindingAt = Date.distantPast
    private var monitorHighSince: Date?
    private var lastMonitorSpeakAt = Date.distantPast
    private var lastCleanupSpeakAt = Date.distantPast
    private var lastReportSignature: String = ""
    private var lastMood: PetMood = .idle
    /// 抑制监控 tick 导致的 mood 抖动（自定义宠换轨时会闪）
    private var lastMoodChangeAt = Date.distantPast
    private let moodMinHold: TimeInterval = 0.45

    /// DEBUG/test: fast banter (set false for production sparsity)
    var fastBanter: Bool = false

    private var hardCooldown: TimeInterval { fastBanter ? 18 : 55 }
    private var findingCooldown: TimeInterval { fastBanter ? 25 : 3 * 60 }
    private var monitorSpeakCooldown: TimeInterval { fastBanter ? 40 : 5 * 60 }
    private var cleanupSpeakCooldown: TimeInterval { fastBanter ? 40 : 5 * 60 }

    private let cpuHigh: Double = 0.88
    private let ramHigh: Double = 0.92
    private let diskFreeLowBytes: Double = 25 * 1_073_741_824
    private let monitorSustain: TimeInterval = 20
    private let cleanupBytesThreshold: UInt64 = 500 * 1024 * 1024

    func start(monitor: MonitorService) {
        self.monitor = monitor
        cancellables.removeAll()

        scan.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        cleanup.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        monitor.$snapshot
            .map { snapshot in
                let cpuBucket = Int((snapshot.cpu?.totalUsage ?? 0) * 20)
                let ramBucket = Int((snapshot.ram?.usage ?? 0) * 20)
                let diskTight = snapshot.disks.contains { $0.free < 25 * 1_073_741_824 || $0.usage >= 0.90 }
                return "\(cpuBucket)|\(ramBucket)|\(diskTight)"
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
        startBanterLoopIfNeeded()
        // 冷启动就关着 AI：一会儿冒一句填 Key（不闭眼，靠灰显）
        if aiOff {
            setupHintTask?.cancel()
            setupHintTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled, let self, self.aiOff, !self.isChatOpen else { return }
                self.announce(line: PetBanter.lineAISetup(language: PetBanterLanguage.resolve()))
            }
        }
    }

    func stop() {
        banterLoopRunning = false
        banterLoopId = UUID()
        banterLoopTask?.cancel()
        banterLoopTask = nil
        setupHintTask?.cancel()
        setupHintTask = nil
        displayTask?.cancel()
        displayTask = nil
        cancellables.removeAll()
        monitor = nil
    }

    /// Call when overlay bindings change (chat / AI).
    func setChatOpen(_ open: Bool) {
        isChatOpen = open
        if open { clearBanter() }
        refresh()
    }

    func setAISending(_ sending: Bool) {
        isAISending = sending
        refresh()
    }

    func setAIOff(_ off: Bool) {
        let turnedOff = off && !aiOff
        aiOff = off
        refresh()
        // 刚关掉时说一句：去填 API Key（眼睛仍睁着，靠灰显区分）
        if turnedOff, !isChatOpen {
            let lang = PetBanterLanguage.resolve()
            announce(line: PetBanter.lineAISetup(language: lang))
        }
    }

    func refresh() {
        updateMonitorPressureClock()
        let next = resolveMood()
        let old = lastMood
        if next != mood {
            // 扫描/对话开始可立刻切；其余至少 hold 0.45s，避免 alert↔idle 抖
            let urgent = next == .scan || next == .talk
                || mood == .scan || mood == .talk
            let held = Date().timeIntervalSince(lastMoodChangeAt) >= moodMinHold
            if urgent || held || old == next {
                mood = next
                lastMood = next
                lastMoodChangeAt = Date()
                if old != next {
                    onMoodChanged(from: old, to: next)
                }
            }
        }
        maybeAnnounceOnReportChange()
    }

    // MARK: - Mood

    func resolveMood() -> PetMood {
        // AI 关：不进 sleep（闭眼）；灰显在 DefierPetView.dimmed，表情仍跟扫描/对话/诊断
        if scan.isScanning || cleanup.phase.isBusy { return .scan }
        if isAISending { return .talk }
        if !isChatOpen {
            if scan.report.highCount > 0 { return .alert }
            if isMonitorPressureActive { return .alert }
            if AppNavigator.shared.pendingUninstallPath != nil { return .alert }
        }
        if isChatOpen { return .happy }
        return .idle
    }

    private var isMonitorPressureActive: Bool {
        guard let since = monitorHighSince else { return false }
        return Date().timeIntervalSince(since) >= monitorSustain
    }

    private func updateMonitorPressureClock() {
        guard let snap = monitor?.snapshot else {
            monitorHighSince = nil
            return
        }
        let cpu = snap.cpu?.totalUsage ?? 0
        let ram = snap.ram?.usage ?? 0
        let diskTight = snap.disks.contains { $0.free < diskFreeLowBytes || $0.usage >= 0.90 }
        let high = cpu >= cpuHigh || ram >= ramHigh || diskTight
        if high {
            if monitorHighSince == nil { monitorHighSince = Date() }
        } else {
            monitorHighSince = nil
        }
    }

    // MARK: - Banter loop

    private func startBanterLoopIfNeeded() {
        guard !banterLoopRunning else { return }
        banterLoopRunning = true
        let loopId = banterLoopId
        let initial = fastBanter ? Double.random(in: 3...5) : Double.random(in: PetBanter.initialDelayRange)
        banterLoopTask?.cancel()
        banterLoopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(initial * 1_000_000_000))
            guard let self else { return }
            while !Task.isCancelled, self.banterLoopRunning, loopId == self.banterLoopId {
                self.trySpeak(force: false)
                let wait = self.fastBanter ? 20.0 : Double.random(in: PetBanter.attemptIntervalRange)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func onMoodChanged(from old: PetMood, to new: PetMood) {
        guard old != new else { return }
        guard new == .alert || new == .scan else { return }
        let p = fastBanter ? 1.0 : PetBanter.moodAnnounceProbability
        guard Double.random(in: 0...1) < p else { return }
        trySpeak(force: false)
    }

    func trySpeak(force: Bool) {
        guard !isChatOpen else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastBanterAt) >= hardCooldown else { return }
        if !force {
            let p = fastBanter ? 1.0 : PetBanter.speakProbability
            guard Double.random(in: 0...1) < p else { return }
        }

        let lang = PetBanterLanguage.resolve()
        let line: String
        var markFinding: String?
        var markCleanup = false
        var markMonitor = false

        if let finding = topFinding(), canSpeakFinding(finding, now: now) {
            line = PetBanter.line(forFinding: finding, language: lang)
            markFinding = finding.id
        } else if aiOff {
            // AI 关：优先提示去设置填 Key，而不是「打盹」
            line = PetBanter.lineAISetup(language: lang)
        } else if cleanup.totalBytes >= cleanupBytesThreshold,
                  now.timeIntervalSince(lastCleanupSpeakAt) >= cleanupSpeakCooldown {
            line = PetBanter.lineCleanup(bytes: cleanup.totalBytes, language: lang)
            markCleanup = true
        } else if isMonitorPressureActive,
                  now.timeIntervalSince(lastMonitorSpeakAt) >= monitorSpeakCooldown {
            line = PetBanter.lineMonitorPressure(
                cpu: monitor?.snapshot.cpu?.totalUsage ?? 0,
                ram: monitor?.snapshot.ram?.usage ?? 0,
                language: lang
            )
            markMonitor = true
        } else if let name = AppNavigator.shared.pendingUninstallName
                    ?? AppNavigator.shared.pendingUninstallPath.map({ _ in "应用" }) {
            line = PetBanter.linePendingUninstall(name: name, language: lang)
        } else {
            line = PetBanter.line(
                for: mood,
                highFindings: scan.report.highCount,
                language: lang
            )
        }

        let id = UUID()
        banterDisplayId = id
        lastBanterAt = now
        if let fid = markFinding {
            lastFindingKey = fid
            lastFindingAt = now
        }
        if markCleanup { lastCleanupSpeakAt = now }
        if markMonitor { lastMonitorSpeakAt = now }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            banterLine = line
        }
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PetBanter.displayDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.banterDisplayId == id else { return }
            withAnimation(.easeOut(duration: 0.45)) {
                self.banterLine = nil
            }
        }
    }

    func clearBanter() {
        displayTask?.cancel()
        displayTask = nil
        withAnimation(.easeOut(duration: 0.15)) {
            banterLine = nil
        }
    }

    /// 监控等外部信号：强制一句短气泡（同文案冷却内不重复刷）。
    func announce(line: String) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard !isChatOpen else { return }
        if banterLine == t { return }
        let now = Date()
        // IP 类提示允许比闲聊更密，但仍防抖
        guard now.timeIntervalSince(lastBanterAt) >= min(hardCooldown, 12) || banterLine == nil else {
            // 覆盖当前气泡
            showBanter(t)
            return
        }
        showBanter(t)
    }

    private func showBanter(_ line: String) {
        let id = UUID()
        banterDisplayId = id
        lastBanterAt = Date()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            banterLine = line
        }
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PetBanter.displayDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.banterDisplayId == id else { return }
            withAnimation(.easeOut(duration: 0.45)) {
                self.banterLine = nil
            }
        }
    }

    // MARK: - Finding helpers

    private func topFinding() -> DiagnosticFinding? {
        scan.report.findings
            .filter { $0.severity == .high || $0.severity == .warn }
            .sorted { $0.severity > $1.severity }
            .first
    }

    private func canSpeakFinding(_ f: DiagnosticFinding, now: Date) -> Bool {
        if lastFindingKey == f.id {
            return now.timeIntervalSince(lastFindingAt) >= findingCooldown
        }
        // Different finding: still respect a short global finding gap
        return now.timeIntervalSince(lastFindingAt) >= min(findingCooldown, hardCooldown)
    }

    private func maybeAnnounceOnReportChange() {
        let sig = scan.report.findings.map(\.id).joined(separator: ",")
            + "|\(scan.report.highCount)|\(scan.isScanning)"
        guard sig != lastReportSignature else { return }
        let prev = lastReportSignature
        lastReportSignature = sig
        let finishedScan = prev.hasSuffix("|true") && !scan.isScanning
        if finishedScan, scan.report.highCount > 0 || scan.report.warnCount > 0 {
            trySpeak(force: true)
        }
    }
}
