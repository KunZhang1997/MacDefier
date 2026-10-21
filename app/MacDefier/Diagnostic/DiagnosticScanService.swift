import Foundation
import Combine
import MonitorKit
import CleanupKit

/// Chat / pet entry result: module owns prompts; callers only display + navigate.
struct DiagnosticChatResult: Sendable {
    var summary: String
    var actions: [DefierAction]
    var report: DiagnosticReport
    var errorHint: String?
    /// True when another scan was already running.
    var wasBusy: Bool

    var asModuleResult: ModuleChatResult {
        ModuleChatResult(
            summary: summary,
            actions: actions,
            errorHint: errorHint,
            wasBusy: wasBusy
        )
    }

    static func busy(current: DiagnosticReport) -> DiagnosticChatResult {
        DiagnosticChatResult(
            summary: L10n.t("diag.busy"),
            actions: [],
            report: current,
            errorHint: nil,
            wasBusy: true
        )
    }
}

@MainActor
final class DiagnosticScanService: ObservableObject {
    static let shared = DiagnosticScanService()

    @Published private(set) var isScanning = false
    @Published private(set) var phaseHint = ""
    @Published private(set) var report: DiagnosticReport = .empty
    @Published private(set) var lastError: String?
    /// When AI enrichment last finished for the current report.
    @Published private(set) var lastAICompletedAt: Date?

    private let junkScanner = JunkScanner()
    /// Bumps when a new scan starts; older in-flight scans must not clobber UI.
    private var scanGeneration = 0
    /// Apps from last rules scan — needed to rebuild finding copy when language changes.
    private var lastScanApps: [InstalledApp] = []
    /// Language raw value when `report` titles were last resolved.
    private var reportLanguageRaw: String = ""

    init(initialReport: DiagnosticReport = .empty) {
        report = initialReport
        reportLanguageRaw = AppLanguage.current.rawValue
    }

    /// Fresh enough to show again without re-scanning (rules + optional AI already on report).
    var hasFreshResult: Bool {
        ScanReusePolicy.isFresh(report.scannedAt, ttl: ScanReusePolicy.diagnosticTTL)
            && !report.findings.isEmpty
    }

    /// Refresh live conclusions and language while reusing the disk walk.
    func relocalizeForCurrentLanguage(monitor: MonitorService) {
        refreshCachedReport(snapshot: monitor.snapshot)
    }

    func refreshCachedReport(snapshot: MonitorSnapshot, now: Date = Date()) {
        let lang = AppLanguage.current.rawValue
        if report.scannedAt == .distantPast {
            let emptyLine = L10n.t("diag.not_scanned")
            if report.summaryLine != emptyLine {
                report.summaryLine = emptyLine
            }
            reportLanguageRaw = lang
            return
        }

        let findingsLookWrongLanguage: Bool = {
            let sample = report.findings.prefix(8).map { $0.title + $0.detail }.joined()
                + report.summaryLine
            let hasCJK = sample.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            if AppLanguage.current.isEnglish { return hasCJK }
            // Chinese UI but copy is pure ASCII English (no CJK) after an EN scan
            if !AppLanguage.current.isEnglish, !sample.isEmpty, !hasCJK,
               sample.range(of: #"[A-Za-z]{4,}"#, options: .regularExpression) != nil {
                return true
            }
            return false
        }()

        let refreshed = DiagnosticScanEngine.refreshReport(
            report, snapshot: snapshot, apps: lastScanApps,
            preserveAI: reportLanguageRaw == lang && !findingsLookWrongLanguage, now: now
        )
        if refreshed.findings != report.findings || refreshed.summaryLine != report.summaryLine
            || refreshed.aiNarrative != report.aiNarrative
            || refreshed.monitorEvidenceFingerprint != report.monitorEvidenceFingerprint {
            report = refreshed
        }
        reportLanguageRaw = lang
    }

    /// Full diagnostic pipeline (rules + optional module AI prompt). Same path for home page and chat.
    /// - Parameter force: user-initiated rescan; ignore TTL.
    /// Concurrent requests are allowed (no cross-module disk lock). A newer scan's generation
    /// wins when writing `report` / finishing UI state.
    @discardableResult
    func scan(monitor: MonitorService, useAI: Bool, force: Bool = false) async -> DiagnosticChatResult {
        let monitorDemand = monitor.beginDiagnosticSampling()
        defer { monitor.endDiagnosticSampling(monitorDemand) }
        // Reuse recent result — no disk walk, no API. User can force with 重新扫描 / AI 盘点.
        if !force, hasFreshResult {
            await Self.waitForCoreSamples(monitor: monitor)
            relocalizeForCurrentLanguage(monitor: monitor)
            var actions = report.findings.compactMap { Self.defierAction(from: $0) }
            if actions.isEmpty {
                actions = Self.defaultNavigationActions(junkBytes: report.junkBytes)
            }
            return DiagnosticChatResult(
                summary: Self.chatSummary(for: report),
                actions: Array(actions.prefix(6)),
                report: report,
                errorHint: nil,
                wasBusy: false
            )
        }

        scanGeneration += 1
        let gen = scanGeneration
        isScanning = true
        lastError = nil
        lastAICompletedAt = nil
        var rawAI: String?
        var chatActions: [DefierAction] = []
        phaseHint = L10n.t("diag.phase.monitor")

        phaseHint = L10n.t("diag.phase.junk")
        // 诊断页只用轻量粗算，禁止跑清理页完整 Junk 扫描（大文件/孤儿/开发者类）
        let groups = await junkScanner.scan(profile: .diagnosticLite) { [weak self] _, hint in
            Task { @MainActor in
                guard let self, self.scanGeneration == gen else { return }
                if hint.isEmpty {
                    self.phaseHint = L10n.t("diag.phase.junk")
                } else {
                    self.phaseHint = ScanProgressL10n.localize(hint)
                }
            }
        }

        // Superseded by a newer scan — leave UI to the newer one; return current report without busy toast.
        if gen != scanGeneration {
            return DiagnosticChatResult(
                summary: Self.chatSummary(for: report),
                actions: report.findings.compactMap { Self.defierAction(from: $0) },
                report: report,
                errorHint: nil,
                wasBusy: false
            )
        }

        let junkBytes = groups
            .filter { $0.category != .largeAppData }
            .reduce(UInt64(0)) { $0 + $1.totalBytes }
        let trashBytes = groups
            .filter { $0.category == .trash }
            .reduce(UInt64(0)) { $0 + $1.totalBytes }
        let cleanupIsPartial = groups.contains { $0.isPartial }

        guard !Task.isCancelled else {
            if gen == scanGeneration {
                phaseHint = ""
                isScanning = false
            }
            return DiagnosticChatResult(
                summary: L10n.t("chat.stopped"),
                actions: [],
                report: report,
                errorHint: nil,
                wasBusy: false
            )
        }

        phaseHint = L10n.t("diag.phase.apps")
        // 首页诊断禁止 computeSize:true：会对每个 App 做 du + 关联数据体积，本机可卡数分钟。
        // 大体积提示在磁盘不紧时本来也不强调；需要精细体积走「软件」页。
        let apps = await Task.detached(priority: .userInitiated) {
            AppInventory.fetchInstalledApps(computeSize: false)
        }.value

        if gen != scanGeneration {
            return DiagnosticChatResult(
                summary: Self.chatSummary(for: report),
                actions: report.findings.compactMap { Self.defierAction(from: $0) },
                report: report,
                errorHint: nil,
                wasBusy: false
            )
        }

        guard !Task.isCancelled else {
            if gen == scanGeneration {
                phaseHint = ""
                isScanning = false
            }
            return DiagnosticChatResult(
                summary: L10n.t("chat.stopped"),
                actions: [],
                report: report,
                errorHint: nil,
                wasBusy: false
            )
        }

        phaseHint = L10n.t("diag.phase.pack")
        await Self.waitForCoreSamples(monitor: monitor)
        guard gen == scanGeneration, !Task.isCancelled else {
            if gen == scanGeneration { phaseHint = ""; isScanning = false }
            return DiagnosticChatResult(summary: Self.chatSummary(for: self.report), actions: [],
                                        report: self.report, errorHint: nil, wasBusy: false)
        }
        // 重取快照：扫描几十秒间 CPU/内存早已变化，finding 应反映现状而非扫描开始时的旧值
        let liveSnapshot = monitor.snapshot
        var report = DiagnosticScanEngine.buildReport(
            snapshot: liveSnapshot,
            junkBytes: junkBytes,
            trashBytes: trashBytes,
            apps: apps,
            appSizesAvailable: false,
            cleanupIsPartial: cleanupIsPartial
        )
        // A 收口：无论规则是否「有问题」，都保证有人话结论 + 可点下一步
        report = Self.ensureUserFacingFindings(report, junkBytes: junkBytes, trashBytes: trashBytes)

        // AI 路径：规则 findings 已有；再让 AI 产出「可点行动卡」并优先展示（失败则纯规则）
        // 提示词仅在此模块维护；聊天不得复制另写一套。
        if useAI, report.monitorEvidenceIsComplete, !report.cleanupIsPartial {
            phaseHint = L10n.t("diag.phase.ai")
            let settings = AISettingsStore.load()
            if AIClient.resolveEndpoint(settings) != nil, settings.enabled, settings.mode != .off {
                let ctx = DiagnosticScanEngine.contextText(for: report, snapshot: liveSnapshot)
                // 未测体积时不发 0 B；仅 name|bundleID（M06-3）
                let appLines = apps.prefix(15).map { app -> String in
                    if app.totalBytes > 0 {
                        return "\(app.name)|\(app.bundleIdentifier)|\(app.formattedSize)"
                    }
                    return "\(app.name)|\(app.bundleIdentifier)"
                }.joined(separator: "\n")
                let disksForTight = liveSnapshot.disks.physical.isEmpty
                    ? liveSnapshot.disks
                    : liveSnapshot.disks.physical
                let diskTight = DiagnosticScore.isSystemDiskTight(disksForTight)
                let lang = AppLanguage.current
                let prompt = """
                Analysis and suggestions only — never delete files or claim cleanup/uninstall done.
                Output defier-json actions (no long essay).
                summary = one friendly sentence; max 5 actions; title/detail casual.
                Even if nothing urgent, give 1–2 clickable actions (open_monitor / cleanup) + a human summary.

                \(lang.aiLanguageRule)

                【Diagnostic bounds】
                - Focus: slowness, memory/CPU stress, truly tight disk, reclaimable junk/Trash.
                - Large apps alone are not problems — no uninstall for size-only; not priority alerts.
                - uninstall only if rules already suggest it or disk is tight — copy must say optional/preview.
                - If disk not tight: no uninstall for large apps; open_monitor / cleanup / open_diagnostic only.
                - Disk tight now: \(lang.yesNo(diskTight)).
                - cleanup/uninstall buttons = open preview only.
                - Only names/bundleIDs from the lists; no invented paths/GB.

                【Rule findings】
                \(ctx)

                【Apps name|bundle|size (no paths)】
                \(appLines)
                """
                do {
                    let reply = try await AIClient.chat(
                        messages: [AIMessage(role: .user, content: prompt)],
                        settings: settings,
                        intensity: .standard,
                        systemExtra: ctx
                    )
                    rawAI = reply.content
                    if !reply.actions.isEmpty {
                        rawAI = (rawAI ?? "") + "\n\n/* parsed actions: \(reply.actions.count) */"
                    }
                    let pack = DefierActionParser.parse(from: reply.content)
                    // Also use already-parsed reply.actions if content was cleaned
                    let actions = !(reply.actions.isEmpty) ? reply.actions : (pack.payload?.actions ?? [])
                    // 展示优先：parser 剥净的 prose → payload.summary → 全文再剥一遍
                    let candidates = [
                        pack.displayText,
                        pack.payload?.summary ?? "",
                        reply.content
                    ]
                    let cleaned = candidates
                        .map { DefierActionParser.userVisibleProse($0) }
                        .first { $0.count >= 4 && !$0.contains("{") }
                        ?? DefierActionParser.userVisibleProse(pack.displayText)

                    if !cleaned.isEmpty {
                        var plain = cleaned
                        let aiTag = L10n.t("diag.ai_tag")
                        if !plain.hasPrefix(aiTag) {
                            plain = aiTag + plain
                        }
                        report.aiNarrative = plain
                    }

                    if !actions.isEmpty {
                        let pathSet = Set(apps.map(\.path))
                        let safe = DefierActionGuard.sanitizeAll(actions, knownAppPaths: pathSet)
                        chatActions = safe
                        let aiFindings = safe.compactMap { Self.finding(from: $0) }
                        // AI 行动卡置顶，其后保留规则 findings（去重 id 宽松）
                        var merged = aiFindings
                        let aiTitles = Set(aiFindings.map(\.title))
                        for f in report.findings where !aiTitles.contains(f.title) {
                            merged.append(f)
                        }
                        report.findings = merged
                        // D01 三态保留；附加 AI/规则计数，不盖掉「正常/偏卡/空间紧」
                        let high = report.findings.filter { $0.severity == .high }.count
                        let warn = report.findings.filter { $0.severity == .warn }.count
                        let base = DiagnosticScanEngine.statusSummaryLine(
                            findings: report.findings, high: high, warn: warn
                        )
                        let ruleCount = report.findings.count - aiFindings.count
                        report.summaryLine = L10n.t(
                            "diag.summary.ai_rules",
                            base,
                            aiFindings.count,
                            max(0, ruleCount)
                        )
                    } else if useAI {
                        // 模型只回了字、没出 actions — 规则结果仍可用，summaryLine 由引擎生成即可
                    }
                    lastAICompletedAt = Date()
                } catch {
                    // 失败零感：规则结果已可用，不挡用户
                    lastError = nil
                }
            }
        }

        if gen != scanGeneration {
            return DiagnosticChatResult(
                summary: Self.chatSummary(for: report),
                actions: chatActions.isEmpty
                    ? report.findings.compactMap { Self.defierAction(from: $0) }
                    : chatActions,
                report: report,
                errorHint: nil,
                wasBusy: false
            )
        }

        // AI can take long enough for its original observations to change. Publish current rules.
        let refreshed = DiagnosticScanEngine.refreshReport(report, snapshot: monitor.snapshot, apps: apps)
        if (refreshed.aiNarrative == nil && report.aiNarrative != nil)
            || (report.findings.contains { $0.id.hasPrefix("ai-") }
                && !refreshed.findings.contains { $0.id.hasPrefix("ai-") }) {
            chatActions = []
            lastAICompletedAt = nil
        }
        report = refreshed

        // Chat needs DefierAction cards even when AI skipped or only rules ran.
        if chatActions.isEmpty {
            chatActions = report.findings.compactMap { Self.defierAction(from: $0) }
        }
        // 保证聊天至少有一个可点下一步（关 AI / 模型失败时也成立）
        if chatActions.isEmpty {
            chatActions = Self.defaultNavigationActions(junkBytes: junkBytes)
        }
        // Cap cards for chat readability
        if chatActions.count > 6 {
            chatActions = Array(chatActions.prefix(6))
        }

        self.report = report
        self.lastScanApps = apps
        self.reportLanguageRaw = AppLanguage.current.rawValue
        DiagnosticScanStore.save(
            report: report,
            useAI: useAI,
            lastError: lastError,
            rawAIReply: rawAI
        )
        phaseHint = ""
        isScanning = false

        let summary = Self.chatSummary(for: report)
        return DiagnosticChatResult(
            summary: summary,
            actions: chatActions,
            report: report,
            errorHint: lastError,
            wasBusy: false
        )
    }

    /// Bounded warm-up only. A failed pressure/swap probe remains unknown and must not extend the wait.
    private static func waitForCoreSamples(monitor: MonitorService) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !Task.isCancelled, clock.now < deadline {
            if monitor.snapshot.cpuIsFresh(), monitor.snapshot.ramIsFresh(), monitor.snapshot.systemDiskIsFresh() { return }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
    }

    /// 规则/AI 都没卡出问题时：仍给「正常」卡片 + 可点入口，避免空白页。
    private static func ensureUserFacingFindings(
        _ report: DiagnosticReport,
        junkBytes: UInt64,
        trashBytes: UInt64
    ) -> DiagnosticReport {
        var r = report
        if r.findings.isEmpty {
            var cards: [DiagnosticFinding] = [
                DiagnosticFinding(
                    id: "ok-all-clear",
                    kind: .ok,
                    severity: .info,
                    title: L10n.t("diag.ok_card"),
                    detail: L10n.t("diag.ok_card_detail"),
                    metric: nil,
                    action: .openMonitor,
                    actionTitle: L10n.t("diag.act.open_monitor"),
                    secondaryAction: .openCleanupAndScan,
                    secondaryActionTitle: L10n.t("diag.ok_sec_cleanup")
                )
            ]
            if junkBytes > 1_073_741_824 {
                let sz = ByteCountFormatter.string(fromByteCount: Int64(junkBytes), countStyle: .file)
                cards.append(
                    DiagnosticFinding(
                        id: "ok-junk-hint",
                        kind: .cleanup,
                        severity: .info,
                        title: L10n.t("diag.junk_preview"),
                        detail: L10n.t("diag.junk_preview_detail", sz),
                        metric: sz,
                        action: .openCleanupAndScan,
                        actionTitle: L10n.t("act.open_cleanup")
                    )
                )
            }
            if trashBytes > 200 * 1_024 * 1_024 {
                let sz = ByteCountFormatter.string(fromByteCount: Int64(trashBytes), countStyle: .file)
                cards.append(
                    DiagnosticFinding(
                        id: "ok-trash-hint",
                        kind: .cleanup,
                        severity: .info,
                        title: L10n.t("diag.trash_left"),
                        detail: L10n.t("diag.trash_left_detail", sz),
                        metric: sz,
                        action: .openCleanupAndScan,
                        actionTitle: L10n.t("diag.go_cleanup_page")
                    )
                )
            }
            r.findings = cards
            r.summaryLine = DiagnosticScanEngine.statusSummaryLine(
                findings: cards,
                high: 0,
                warn: 0
            )
            // Keep this as a rule-only result. An AI tag is added only after
            // an actual enrichment response, never to make an empty state
            // look AI-generated.
        } else {
            let high = r.findings.filter { $0.severity == .high }.count
            let warn = r.findings.filter { $0.severity == .warn }.count
            r.summaryLine = DiagnosticScanEngine.statusSummaryLine(
                findings: r.findings,
                high: high,
                warn: warn
            )
        }
        return r
    }

    private static func defaultNavigationActions(junkBytes: UInt64) -> [DefierAction] {
        var list: [DefierAction] = [
            DefierAction(kind: .openMonitor, title: L10n.t("act.open_monitor"), detail: L10n.t("diag.ok_card_detail")),
            DefierAction(kind: .cleanup, title: L10n.t("act.open_cleanup"), detail: L10n.t("cleanup.scanning_hint"))
        ]
        if junkBytes > 0 {
            list[1].detail = L10n.t("diag.junk_preview")
        }
        return list
    }

    private static func chatSummary(for report: DiagnosticReport) -> String {
        if !report.monitorEvidenceIsComplete { return L10n.t("diag.find.metrics_unknown_detail") }
        if report.cleanupIsPartial { return L10n.t("diag.find.cleanup_partial_detail") }
        if let n = report.aiNarrative?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            let oneLine = n
                .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if oneLine.count > 220 {
                return String(oneLine.prefix(200)) + "…"
            }
            return oneLine
        }
        let high = report.highCount
        let warn = report.warnCount
        if high == 0, warn == 0 {
            if report.findings.contains(where: { $0.kind == .ok }) {
                return L10n.t("diag.chat_ok")
            }
            return L10n.t("diag.chat_mild")
        }
        var parts: [String] = []
        if high > 0 { parts.append(L10n.t("diag.chat_high", high)) }
        if warn > 0 { parts.append(L10n.t("diag.chat_warn", warn)) }
        let sep = AppLanguage.current.isEnglish ? ", " : "、"
        let head = parts.joined(separator: sep)
        return L10n.t("diag.chat_issues", head)
    }

    /// Map rule/AI findings back to navigation actions for chat cards.
    private static func defierAction(from finding: DiagnosticFinding) -> DefierAction? {
        let kind: DefierAction.Kind
        switch finding.action {
        case .openCleanupAndScan:
            kind = .cleanup
        case .openSoftware:
            kind = (finding.appPath != nil || finding.appBundleID != nil) ? .uninstall : .openSoftware
        case .openMonitor:
            kind = .openMonitor
        case .quitProcess:
            kind = .quitProcess
        case .openMister:
            kind = .openDiagnostic
        case .none:
            return nil
        }
        let title = finding.actionTitle.isEmpty ? finding.title : finding.actionTitle
        return DefierAction(
            id: finding.id,
            kind: kind,
            title: title,
            detail: finding.detail,
            appName: finding.processName,
            bundleID: finding.appBundleID,
            appPath: finding.appPath,
            processPID: finding.processPID,
            processName: finding.processName,
            metric: finding.metric
        )
    }

    private static func finding(from action: DefierAction) -> DiagnosticFinding? {
        let fa: FindingAction
        let kind: FindingKind
        switch action.kind {
        case .cleanup:
            fa = .openCleanupAndScan
            kind = .cleanup
        case .uninstall, .openSoftware:
            fa = .openSoftware
            kind = .software
        case .openMonitor:
            fa = .openMonitor
            kind = .monitor
        case .quitProcess:
            fa = .quitProcess
            kind = .monitor
        case .openDiagnostic, .openSettings, .none:
            // open settings not in FindingAction — map to openMister for settings-like, or skip
            if action.kind == .openSettings {
                fa = .openMister
                kind = .ok
            } else if action.kind == .openDiagnostic {
                return nil
            } else {
                return nil
            }
        }
        let sev: FindingSeverity = action.kind == .uninstall || action.kind == .cleanup ? .warn : .info
        return DiagnosticFinding(
            id: "ai-\(action.id)",
            kind: kind,
            severity: sev,
            title: action.buttonLabel,
            detail: action.detail.isEmpty
                ? L10n.t("diag.ai_action_fallback")
                : action.detail,
            metric: action.metric,
            action: fa,
            actionTitle: cta(for: action.kind),
            processPID: action.processPID,
            processName: action.processName ?? action.appName,
            appPath: action.appPath,
            appBundleID: action.bundleID
        )
    }

    private static func cta(for kind: DefierAction.Kind) -> String {
        switch kind {
        case .cleanup: return L10n.t("act.open_cleanup")
        case .uninstall: return L10n.t("act.see_detail")
        case .openSoftware: return L10n.t("act.open_software")
        case .openMonitor: return L10n.t("act.open_monitor")
        case .quitProcess: return L10n.t("act.quit_process")
        case .openSettings: return L10n.t("act.open_settings")
        case .openDiagnostic: return L10n.t("act.open_diagnostic")
        case .none: return L10n.t("act.go_look")
        }
    }
}
