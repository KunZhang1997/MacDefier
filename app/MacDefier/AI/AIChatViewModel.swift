import Foundation
import Combine
import MonitorKit
import CleanupKit

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var settings: AISettings = AISettingsStore.load()
    @Published var messages: [AIMessage] = []
    @Published var input: String = ""
    @Published var isSending = false
    @Published var status: String = ""
    @Published var includeMonitorContext = true
    @Published var intensity: AIIntensity = .standard
    @Published var rollingSummary: String = ""
    @Published var lastCompressed = false
    @Published var expandedThinkingIDs: Set<UUID> = []
    @Published var restoredHint: String?

    private var inFlight: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    /// 代次令牌：stop() 时 +1，模块扫描不可取消，迟到的结果按代次不符丢弃
    private var sendGeneration = 0

    init() {
        restoreConversation()
    }

    func reloadSettings() {
        settings = AISettingsStore.load()
        // keep intensity from conversation unless never set
        if messages.isEmpty {
            intensity = settings.defaultIntensity
        }
        updateStatusIdle()
    }

    /// 监控等旁路注入一句助手提示（同文案不重复；不打断 isSending）。
    func appendNotice(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let last = messages.last, last.role == .assistant, last.content == t { return }
        messages.append(AIMessage(role: .assistant, content: t))
        schedulePersist()
    }

    /// AI 总开关关闭（闲聊不可用，规则诊断/清理仍可用）。
    var isAIDisabled: Bool {
        !settings.enabled || settings.mode == .off
    }

    /// 已开 AI 但还没配可用 Endpoint / API Key。
    var needsAPISetup: Bool {
        !isAIDisabled && AIClient.resolveEndpoint(settings) == nil
    }

    /// 空态/闲聊需要引导去设置（关 AI 或未填 Key）。
    var needsAISetupGuide: Bool {
        isAIDisabled || needsAPISetup
    }

    func updateStatusIdle() {
        if isAIDisabled {
            status = L10n.t("chat.ai_off")
            return
        }
        if AIClient.resolveEndpoint(settings) == nil {
            status = L10n.t("chat.need_api")
            return
        }
        if let ep = AIClient.resolveEndpoint(settings) {
            let where_ = ep.useLocal ? L10n.t("chat.local") : L10n.t("chat.cloud")
            status = "\(where_) · \(ep.model) · \(intensity.title)"
        }
    }

    private func restoreConversation() {
        guard let snap = AIConversationStore.load() else { return }
        messages = AIConversationStore.toMessages(snap)
        rollingSummary = snap.rollingSummary
        if let i = AIIntensity(rawValue: snap.intensity) {
            intensity = i
        }
        includeMonitorContext = snap.includeMonitorContext
        lastCompressed = !snap.rollingSummary.isEmpty
        if !messages.isEmpty {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            restoredHint = L10n.t("chat.restored", f.string(from: snap.updatedAt), messages.count)
        }
    }

    /// Debounced persist so we don't thrash disk every keystroke of related state.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            AIConversationStore.save(
                messages: messages,
                rollingSummary: rollingSummary,
                intensity: intensity,
                includeMonitorContext: includeMonitorContext
            )
        }
    }

    private func persistNow() {
        AIConversationStore.save(
            messages: messages,
            rollingSummary: rollingSummary,
            intensity: intensity,
            includeMonitorContext: includeMonitorContext
        )
    }

    func send(monitor: MonitorService) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        settings = AISettingsStore.load()

        let intent = ChatIntentRouter.resolve(text)

        restoredHint = nil
        let userMsg = AIMessage(role: .user, content: text)
        messages.append(userMsg)
        input = ""
        persistNow()

        // 诊断 / 清理 / 软件：规则本机就能跑，不依赖 AI。
        // 自由闲聊才需要 AI；关掉或未配置时给人话引导 + 可点「去设置填 Key」。
        if intent == .freeChat {
            if isAIDisabled {
                messages.append(AIMessage(
                    role: .assistant,
                    content: L10n.t("chat.ai_off_body"),
                    actions: Self.setupGuideActions
                ))
                status = L10n.t("chat.ai_off")
                updateStatusIdle()
                persistNow()
                return
            }
            if AIClient.resolveEndpoint(settings) == nil {
                messages.append(AIMessage(
                    role: .assistant,
                    content: L10n.t("chat.no_api_body"),
                    actions: Self.setupGuideActions
                ))
                status = L10n.t("chat.need_api")
                updateStatusIdle()
                persistNow()
                return
            }
        }

        isSending = true
        sendGeneration += 1

        switch intent {
        case .diagnostic:
            runDiagnosticModule(monitor: monitor)
        case .cleanup:
            runCleanupModule()
        case .software:
            runSoftwareModule(monitor: monitor, userText: text)
        case .freeChat:
            runFreeChat(monitor: monitor)
        }
    }

    /// AI 关 / 未配 Key：设置优先，旁路仍给诊断/清理/软件。
    private static var setupGuideActions: [DefierAction] {
        [
            DefierAction(
                kind: .openSettings,
                title: L10n.t("chat.setup_api"),
                detail: L10n.t("chat.setup_api_detail")
            ),
            DefierAction(kind: .openDiagnostic, title: L10n.t("chat.guide.diagnostic"), detail: L10n.t("chat.guide.diagnostic_d")),
            DefierAction(kind: .cleanup, title: L10n.t("chat.guide.cleanup"), detail: L10n.t("chat.guide.cleanup_d")),
            DefierAction(kind: .openSoftware, title: L10n.t("chat.guide.software"), detail: L10n.t("chat.guide.software_d"))
        ]
    }

    private static var guideActions: [DefierAction] {
        [
            DefierAction(kind: .openDiagnostic, title: L10n.t("chat.guide.diagnostic"), detail: L10n.t("chat.guide.diagnostic_d")),
            DefierAction(kind: .cleanup, title: L10n.t("chat.guide.cleanup"), detail: L10n.t("chat.guide.cleanup_d")),
            DefierAction(kind: .openSoftware, title: L10n.t("chat.guide.software"), detail: L10n.t("chat.guide.software_d"))
        ]
    }

    private var moduleUseAI: Bool {
        settings.enabled
            && settings.mode != .off
            && AIClient.resolveEndpoint(settings) != nil
    }

    /// Execute home diagnostic pipeline (module prompt only — no chat business prompt).
    private func runDiagnosticModule(monitor: MonitorService) {
        status = ScanProgressL10n.withStop(L10n.t("chat.status.diag"))
        let useAI = moduleUseAI

        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            let generation = self.sendGeneration
            let hintTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let h = DiagnosticScanService.shared.phaseHint
                    if !h.isEmpty {
                        self?.status = ScanProgressL10n.withStop(h)
                    }
                    try? await Task.sleep(nanoseconds: 280_000_000)
                }
            }
            defer { hintTask.cancel() }

            do {
                try Task.checkCancellation()
                // 10 分钟内复用首页诊断结果，避免聊天再触发一轮扫盘 + API
                let result = await DiagnosticScanService.shared.scan(
                    monitor: monitor,
                    useAI: useAI,
                    force: false
                )
                try Task.checkCancellation()
                self.appendModuleResult(
                    result.asModuleResult,
                    emptyHint: L10n.t("chat.empty_hint.diag"),
                    generation: generation
                )
            } catch is CancellationError {
                self.finishCancelled(generation: generation)
            } catch {
                if Task.isCancelled {
                    self.finishCancelled(generation: generation)
                    return
                }
                self.finishFailed(prefix: L10n.t("chat.fail_prefix"), error: error, generation: generation)
            }
        }
    }

    /// Cleanup page pipeline (CleanupAIScan prompt only).
    private func runCleanupModule() {
        status = ScanProgressL10n.withStop(L10n.t("chat.status.cleanup"))
        let useAI = moduleUseAI

        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            let generation = self.sendGeneration
            let hintTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let svc = CleanupService.shared
                    if svc.isAIEnriching {
                        let h = svc.scanHint.isEmpty ? L10n.t("cleanup.ai_clarify") : ScanProgressL10n.localize(svc.scanHint)
                        self?.status = ScanProgressL10n.withStop(h)
                    } else if case .scanning(_, let hint) = svc.phase {
                        let base = hint.isEmpty ? L10n.t("chat.status.cleanup") : ScanProgressL10n.localize(hint)
                        self?.status = ScanProgressL10n.withStop(base)
                    }
                    try? await Task.sleep(nanoseconds: 280_000_000)
                }
            }
            defer { hintTask.cancel() }

            do {
                try Task.checkCancellation()
                let result = await CleanupAIScan.runForChat(useAI: useAI)
                try Task.checkCancellation()
                self.appendModuleResult(
                    result,
                    emptyHint: L10n.t("chat.empty_hint.cleanup"),
                    generation: generation
                )
            } catch is CancellationError {
                self.finishCancelled(generation: generation)
            } catch {
                if Task.isCancelled {
                    self.finishCancelled(generation: generation)
                    return
                }
                self.finishFailed(prefix: L10n.t("chat.fail_prefix"), error: error, generation: generation)
            }
        }
    }

    /// Software page pipeline. Targeted uninstall uses full-list AppQueryMatcher first (not Top12).
    private func runSoftwareModule(monitor: MonitorService, userText: String) {
        status = ScanProgressL10n.withStop(L10n.t("chat.status.software"))
        let useAI = moduleUseAI

        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            let generation = self.sendGeneration
            let hintTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let svc = SoftwareService.shared
                    if svc.isAIEnriching {
                        self?.status = ScanProgressL10n.withStop(L10n.t("cleanup.ai_clarify"))
                    } else if svc.isLoading {
                        self?.status = ScanProgressL10n.withStop(L10n.t("chat.status.software"))
                    }
                    try? await Task.sleep(nanoseconds: 280_000_000)
                }
            }
            defer { hintTask.cancel() }

            do {
                try Task.checkCancellation()
                // Ensure inventory loaded (full list)
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    SoftwareService.shared.refresh(force: false) {
                        cont.resume()
                    }
                }
                try Task.checkCancellation()

                if AppQueryMatcher.looksLikeTargetedUninstall(userText),
                   let query = AppQueryMatcher.extractQuery(from: userText) {
                    let apps = SoftwareService.shared.apps
                    // M05-3: exact unique name/base first — never contains-first auto sheet target.
                    switch AppOwnership.resolveDeepLink(path: nil, bundleID: nil, name: query, in: apps) {
                    case .exact(let app):
                        let size = app.formattedSize
                        let body = AppLanguage.current.isEnglish
                            ? "Found \(app.name) (\(size)). Open uninstall preview — nothing is deleted until you confirm."
                            : "找到 \(app.name)（\(size)）。打开卸载预览，确认前不会删除。"
                        self.appendModuleResult(
                            ModuleChatResult(
                                summary: body,
                                actions: [
                                    DefierAction(
                                        kind: .uninstall,
                                        title: L10n.t("software.preview_uninstall"),
                                        detail: app.name,
                                        appName: app.name,
                                        bundleID: app.bundleIdentifier,
                                        appPath: app.path
                                    )
                                ],
                                errorHint: nil,
                                wasBusy: false
                            ),
                            emptyHint: "",
                            generation: generation
                        )
                        return
                    case .ambiguous(let exactHits):
                        let lines = exactHits.prefix(6).map { "· \($0.name) · \($0.formattedSize)" }.joined(separator: "\n")
                        let body = AppLanguage.current.isEnglish
                            ? "Several apps match “\(query)”. Pick one:\n\(lines)"
                            : "有多个应用匹配「\(query)」，请点选：\n\(lines)"
                        let actions = exactHits.prefix(6).map {
                            DefierAction(
                                kind: .uninstall,
                                title: $0.name,
                                detail: $0.formattedSize,
                                appName: $0.name,
                                bundleID: $0.bundleIdentifier,
                                appPath: $0.path
                            )
                        }
                        self.appendModuleResult(
                            ModuleChatResult(summary: body, actions: Array(actions), errorHint: nil, wasBusy: false),
                            emptyHint: "",
                            generation: generation
                        )
                        return
                    case .none:
                        break
                    }
                    // Alias / fuzzy: only list choices (path+bid each). Never auto-pick first.
                    let hits = AppQueryMatcher.findMatches(query: query, in: apps)
                    if hits.isEmpty {
                        let body = AppLanguage.current.isEnglish
                            ? "No installed app matched “\(query)”. This search used your full app list (not a short top-size sample)."
                            : "在全部已装应用里没有找到「\(query)」。这次是全表匹配，不是只看体积前几名。"
                        self.appendModuleResult(
                            ModuleChatResult(
                                summary: body,
                                actions: [
                                    DefierAction(kind: .openSoftware, title: L10n.t("chat.guide.software"), detail: "")
                                ],
                                errorHint: nil,
                                wasBusy: false
                            ),
                            emptyHint: "",
                            generation: generation
                        )
                        return
                    }
                    let lines = hits.prefix(6).map { "· \($0.name) · \($0.formattedSize)" }.joined(separator: "\n")
                    let body: String
                    if hits.count == 1 {
                        body = AppLanguage.current.isEnglish
                            ? "Closest match for “\(query)” (not an exact name). Confirm before uninstall preview:\n\(lines)"
                            : "「\(query)」不是精确应用名，最接近的是：\n\(lines)\n请点选确认后再打开卸载预览。"
                    } else {
                        body = AppLanguage.current.isEnglish
                            ? "Several apps match “\(query)”. Pick one:\n\(lines)"
                            : "有多个应用匹配「\(query)」，请点选：\n\(lines)"
                    }
                    let actions = hits.prefix(6).map {
                        DefierAction(
                            kind: .uninstall,
                            title: $0.name,
                            detail: $0.formattedSize,
                            appName: $0.name,
                            bundleID: $0.bundleIdentifier,
                            appPath: $0.path
                        )
                    }
                    self.appendModuleResult(
                        ModuleChatResult(summary: body, actions: Array(actions), errorHint: nil, wasBusy: false),
                        emptyHint: "",
                        generation: generation
                    )
                    return
                }

                let result = await SoftwareAIScan.runForChat(monitor: monitor, useAI: useAI)
                try Task.checkCancellation()
                self.appendModuleResult(
                    result,
                    emptyHint: L10n.t("chat.empty_hint.software"),
                    generation: generation
                )
            } catch is CancellationError {
                self.finishCancelled(generation: generation)
            } catch {
                if Task.isCancelled {
                    self.finishCancelled(generation: generation)
                    return
                }
                self.finishFailed(prefix: L10n.t("chat.fail_prefix"), error: error, generation: generation)
            }
        }
    }

    private func appendModuleResult(_ result: ModuleChatResult, emptyHint: String, generation: Int) {
        guard generation == sendGeneration else { return } // 已停止，丢弃迟到结果
        // 不要用「（错误）」单独当一条假回复；有 summary 再附一句说明，否则并入正文
        var body = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if body == "（）" || body == "()" { body = "" }
        if let err = result.errorHint?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
            if body.isEmpty {
                body = err
            } else if !body.contains(err) {
                body += "\n\n" + err
            }
        }
        if body.isEmpty, result.actions.isEmpty, !result.wasBusy {
            body = emptyHint
        } else if body.isEmpty, !result.actions.isEmpty {
            body = L10n.t("chat.actions_ready")
        } else if result.actions.isEmpty, !result.wasBusy, !body.contains(emptyHint) {
            body += "\n\n" + emptyHint
        }
        let paths = Set(SoftwareService.shared.apps.map(\.path))
        let safeActions = DefierActionGuard.sanitizeAll(result.actions, knownAppPaths: paths)
        messages.append(AIMessage(role: .assistant, content: body, actions: safeActions))
        isSending = false
        inFlight = nil
        persistNow()
        updateStatusIdle()
    }

    private func finishFailed(prefix: String, error: Error, generation: Int) {
        guard generation == sendGeneration else { return }
        messages.append(AIMessage(role: .assistant, content: "\(prefix)：\(error.localizedDescription)"))
        isSending = false
        inFlight = nil
        persistNow()
        status = L10n.t("chat.status.failed")
    }

    /// Legacy free-form chat (generic system prompt). Not used for scan/diagnose intents.
    private func runFreeChat(monitor: MonitorService) {
        status = intensity == .deep
            ? L10n.t("chat.status.think_deep")
            : L10n.t("chat.status.think")

        let history = messages
        let settingsCopy = settings
        let intensityCopy = intensity
        let summaryCopy = rollingSummary.isEmpty ? nil : rollingSummary
        let includeCtx = includeMonitorContext
        let monitorSnap = monitor.snapshot

        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            let generation = self.sendGeneration
            do {
                try Task.checkCancellation()

                var extra: String? = nil
                if includeCtx {
                    extra = await Self.buildActionContext(snapshot: monitorSnap)
                }

                let packed = AIClient.packHistory(
                    messages: history,
                    keepRecentTurns: settingsCopy.keepRecentTurns,
                    charBudget: settingsCopy.historyCharBudget,
                    existingSummary: summaryCopy
                )
                if packed.didCompress, let s = packed.summary {
                    self.rollingSummary = s
                    self.lastCompressed = true
                }

                try Task.checkCancellation()
                let reply = try await AIClient.chat(
                    messages: history,
                    settings: settingsCopy,
                    intensity: intensityCopy,
                    systemExtra: extra,
                    rollingSummary: summaryCopy
                )
                try Task.checkCancellation()
                var safe = reply
                if !safe.actions.isEmpty {
                    let paths = Set(SoftwareService.shared.apps.map(\.path))
                    safe.actions = DefierActionGuard.sanitizeAll(safe.actions, knownAppPaths: paths)
                }
                guard generation == self.sendGeneration else { return } // 已停止，丢弃迟到结果
                self.messages.append(safe)
                self.isSending = false
                self.inFlight = nil
                self.persistNow()
                self.updateStatusIdle()
            } catch is CancellationError {
                self.finishCancelled(generation: generation)
            } catch {
                if Task.isCancelled {
                    self.finishCancelled(generation: generation)
                    return
                }
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                    self.finishCancelled(generation: generation)
                    return
                }
                guard generation == self.sendGeneration else { return }
                self.messages.append(AIMessage(role: .assistant, content: L10n.t("chat.fail_connect", error.localizedDescription)))
                self.isSending = false
                self.inFlight = nil
                self.persistNow()
                self.status = L10n.t("chat.status.failed")
            }
        }
    }

    private func finishCancelled(generation: Int) {
        guard generation == sendGeneration else { return }
        isSending = false
        inFlight = nil
        messages.append(AIMessage(role: .assistant, content: L10n.t("chat.stopped")))
        persistNow()
        updateStatusIdle()
    }

    func stop() {
        guard isSending else { return }
        // 代次 +1：模块扫描不可取消，立即复位发送通道，迟到的结果按代次丢弃
        sendGeneration += 1
        inFlight?.cancel()
        isSending = false
        inFlight = nil
        messages.append(AIMessage(role: .assistant, content: L10n.t("chat.stopped")))
        persistNow()
        updateStatusIdle()
    }

    func clear() {
        stop()
        messages = []
        rollingSummary = ""
        lastCompressed = false
        expandedThinkingIDs = []
        restoredHint = nil
        AIConversationStore.clear()
        updateStatusIdle()
    }

    /// 设置页「清空聊天记录」：不依赖当前是否打开聊天面板。
    static func clearPersistedConversation() {
        AIConversationStore.clear()
        NotificationCenter.default.post(name: .macDefierConversationDidClear, object: nil)
    }

    /// Lightweight app identity cache. Free chat never recursively computes
    /// bundle/data sizes; detailed sizes belong to SoftwareService's explicit scan.
    private static var appsCache: (apps: [InstalledApp], at: Date)?
    private static let appsCacheTTL: TimeInterval = 300

    private static func cachedInstalledApps() async -> [InstalledApp] {
        if let c = appsCache, Date().timeIntervalSince(c.at) < appsCacheTTL { return c.apps }
        let apps = await Task.detached(priority: .utility) {
            AppInventory.fetchInstalledApps(
                includeSystemApps: false,
                computeSize: false,
                isCancelled: { Task.isCancelled }
            )
        }.value
        guard !Task.isCancelled else { return [] }
        appsCache = (apps, Date())
        return apps
    }

    /// Snapshot for action-oriented chat: monitor + top apps + light junk hint.
    private static func buildActionContext(snapshot: MonitorSnapshot) async -> String {
        var lines: [String] = []
        lines.append(AIClient.monitorSnapshotTextSync(snapshot))

        let apps = await cachedInstalledApps()
        if !apps.isEmpty {
            // Identity only: no full path and no fake zero-byte size labels.
            lines.append("已装应用样本（未计算体积；点名卸载须在软件页全表匹配）：")
            for a in apps.prefix(12) {
                lines.append("- \(a.name) | \(a.bundleIdentifier)")
            }
        }
        if !snapshot.topCPU.isEmpty {
            lines.append("高 CPU 进程（quit_process 须用真实 pid）：")
            for p in snapshot.topCPU.prefix(6) {
                lines.append("- \(p.name) pid=\(p.pid) cpu=\(String(format: "%.0f", p.usage))%")
            }
        }
        lines.append("提醒：cleanup 只打开清理页并预览；uninstall 只打开软件卸载弹窗，均不直接删除。")
        return lines.joined(separator: "\n")
    }

    func toggleThinking(_ id: UUID) {
        if expandedThinkingIDs.contains(id) {
            expandedThinkingIDs.remove(id)
        } else {
            expandedThinkingIDs.insert(id)
        }
    }

    /// Call when intensity / monitor toggle changes
    func noteSettingsChanged() {
        schedulePersist()
        updateStatusIdle()
    }
}

extension Notification.Name {
    static let macDefierConversationDidClear = Notification.Name("macDefier.conversationDidClear")
    static let macDefierAISettingsDidChange = Notification.Name("macDefier.aiSettingsDidChange")
}
