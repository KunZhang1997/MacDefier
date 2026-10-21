// Software AI 盘点 — 规则列表先出；AI 只解读 + 可选「预览卸载」深链（须真实 path）。

import Foundation
import CleanupKit
import MonitorKit

enum SoftwareAIScan {
    @MainActor
    static var isConfigured: Bool {
        let s = AISettingsStore.load()
        return s.enabled && s.mode != .off && AIClient.resolveEndpoint(s) != nil
    }

    @MainActor
    static func runInventory(service: SoftwareService, monitor: MonitorService, force: Bool = true) {
        let useAI = isConfigured
        service.refresh(force: force) {
            Task { @MainActor in
                await enrichIfNeeded(service: service, monitor: monitor, useAI: useAI)
            }
        }
    }

    /// Full software inventory for chat: same refresh + module prompt as the Software page.
    /// Never uninstalls; only preview navigation actions.
    @MainActor
    static func runForChat(
        service: SoftwareService? = nil,
        monitor: MonitorService,
        useAI: Bool
    ) async -> ModuleChatResult {
        // 默认值表达式在调用方上下文求值，.shared 的 MainActor 隔离会触发 Swift 6 警告 → 挪进函数体
        let service = service ?? SoftwareService.shared
        // No busy reject — wait until inventory is ready (queues if already loading).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            service.refresh(force: !service.hasFreshInventory) {
                cont.resume()
            }
        }

        let wantAI = useAI && isConfigured
        await enrichIfNeeded(service: service, monitor: monitor, useAI: wantAI)

        var actions: [DefierAction] = []
        // AI preview uninstall cards (path already validated in enrich)
        for a in service.aiPreviewActions.prefix(4) {
            let appName = service.apps.first(where: { $0.path == a.path })?.name
            actions.append(DefierAction(
                kind: .uninstall,
                title: a.title.isEmpty ? L10n.t("software.chat.preview_title") : a.title,
                detail: a.reason.isEmpty
                    ? L10n.t("software.chat.preview_detail")
                    : a.reason,
                appName: appName,
                bundleID: a.bundleID,
                appPath: a.path
            ))
        }
        actions.append(DefierAction(
            kind: .openSoftware,
            title: L10n.t("software.chat.open_title"),
            detail: L10n.t("software.chat.open_detail")
        ))

        let summary = chatSummary(service: service)
        return ModuleChatResult(
            summary: summary,
            actions: actions,
            errorHint: nil,
            wasBusy: false
        )
    }

    @MainActor
    private static func chatSummary(service: SoftwareService) -> String {
        if let n = service.aiNarrative?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            let footer = "\n\n" + L10n.t("software.chat.footer")
            // Already has disclaimer markers (zh or en) — do not double-append
            let markers = [
                "没卸", "不会删", "打开软件",
                "nothing was uninstalled", "not uninstalled", "Open Apps", "didn't uninstall"
            ]
            if markers.contains(where: { n.localizedCaseInsensitiveContains($0) }) {
                return n
            }
            return n + footer
        }
        if service.apps.isEmpty {
            return L10n.t("software.chat.empty")
        }
        return L10n.t("software.chat.summary", service.apps.count)
    }

    @MainActor
    static func enrichIfNeeded(
        service: SoftwareService,
        monitor: MonitorService,
        useAI: Bool
    ) async {
        guard useAI, isConfigured else { return }
        let hasNarrative = !(service.aiNarrative ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasNarrative, service.hasFreshInventory { return }
        service.beginAIEnrichment()

        let disks = monitor.snapshot.disks.physical.isEmpty
            ? monitor.snapshot.disks
            : monitor.snapshot.disks.physical
        // 仅系统盘紧张才允许卸载 CTA（M09-2）；外置小盘不算
        let diskTight = DiagnosticScore.isSystemDiskTight(disks)
        let sizesMeasured = service.apps.contains { $0.totalBytes > 0 || $0.bytes > 0 }
        let freeLabel: String = {
            guard let d = disks.primary ?? disks.first else { return "—" }
            return ByteCountFormatter.string(fromByteCount: Int64(d.free), countStyle: .file)
        }()

        let ctx = service.contextTextForAI(diskTight: diskTight, freeDiskLabel: freeLabel)
        let settings = AISettingsStore.load()

        let lang = AppLanguage.current
        let systemExtra = """
        You are MacDefier Apps-page assistant.
        Rules already did: inventory, size tiers, sorting — do not restate as discoveries.
        You only interpret: rough use, shared-data caveats, careful uninstall, optional tips if disk is tight.
        Never delete/uninstall or claim done. Large ≠ broken; if disk is fine, do not push uninstalling games.
        \(lang.aiLanguageRule)
        Short multi-line lines; no think-only; no wall of text; friendly tone.
        """

        let bodyFmt = lang.isEnglish
            ? """
            【Body format — one line each, English labels, ≤ 80 chars】
            Overview: app count + whether disk is tight + large apps are installed software not malware
            Uses: 1–2 names each for games/dev/daily/other if confident
            Watch: shared data / related size pitfalls (or “none obvious”)
            Tip: disk fine → no need to force uninstall; tight → optional free-space directions
            Careful: system + browsers/chat still in use (one line)
            """
            : """
            【正文格式 — 强制，每行一条，中文冒号；每行 ≤ 80 字】
            概况：一句话（应用数 + 磁盘是否偏紧 + 大体积是已装软件不是中毒）
            用途：粗分游戏/开发/日常/其他里各举 1～2 个有把握的名字
            注意：共享数据、关联体积、容易误卸的坑
            建议：磁盘不紧 → 不必强行卸载；偏紧 → 可选腾空间方向
            慎卸：系统与还在用的浏览器/聊天等（一行）
            """

        let prompt = """
        List + size tiers are already shown in UI. Only do AI interpretation (not another size ranking).

        \(bodyFmt)

        \(lang.aiLanguageRule)
        Disk tight = \(lang.yesNo(diskTight)).

        Optional: only if disk tight, attach defier-json preview uninstall; else actions=[].
        Uninstall actions MUST use bundleID from the list above (ctx has name|bundle|bytes — no install paths were sent).
        Do NOT invent paths. Local app resolves path from bundleID.
        ```defier-json
        {
          "summary": "one line",
          "actions": [
            {
              "type": "uninstall",
              "title": "Preview uninstall App",
              "detail": "Optional free space, not required",
              "appName": "Display name",
              "bundleID": "com.example.app"
            }
          ]
        }
        ```

        【本机应用列表（只读）】
        \(ctx)
        """

        do {
            let reply = try await AIClient.chat(
                messages: [AIMessage(role: .user, content: prompt)],
                settings: settings,
                intensity: .standard,
                systemExtra: systemExtra
            )
            let pack = DefierActionParser.parse(from: reply.content)
            var text = DefierActionParser.userVisibleProse(pack.displayText)
            if text.isEmpty {
                text = DefierActionParser.userVisibleProse(DiagnosticScanEngine.plainText(reply.content))
            }
            if text.isEmpty, let s = pack.payload?.summary, !s.isEmpty {
                text = s
            }
            text = sanitize(text)

            // AIClient may place chat.empty_model when the model returns think/JSON-only — treat as empty.
            if isUseless(text) {
                text = ""
            }

            var actions: [SoftwareAIPreviewAction] = []
            // 系统盘不紧或未测体积：丢弃卸载 CTA（大 App 只作信息）
            let allowUninstallCTA = diskTight && sizesMeasured
            // Uninstall preview cards: only exact path / unique bid / exact unique name.
            let rawActions = reply.actions.isEmpty ? (pack.payload?.actions ?? []) : reply.actions
            if allowUninstallCTA {
                for a in rawActions where a.kind == .uninstall {
                    let nameHint: String? = {
                        if let n = a.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                            return n
                        }
                        let t = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }()
                    switch AppOwnership.resolveDeepLink(
                        path: a.appPath,
                        bundleID: a.bundleID,
                        name: nameHint,
                        in: service.apps
                    ) {
                    case .exact(let app):
                        actions.append(SoftwareAIPreviewAction(
                            title: a.title.isEmpty ? L10n.t("software.preview_uninstall") : a.title,
                            path: app.path,
                            bundleID: app.bundleIdentifier,
                            reason: a.detail
                        ))
                    case .ambiguous, .none:
                        NSLog(
                            "[SoftwareAIScan] drop uninstall action: no unique resolve path=%@ bid=%@ name=%@",
                            a.appPath ?? "nil",
                            a.bundleID ?? "nil",
                            nameHint ?? "nil"
                        )
                        continue
                    }
                }
            }

            if text.isEmpty {
                service.finishAIEnrichment(
                    narrative: ruleFallback(service: service, diskTight: diskTight),
                    error: nil,
                    previewActions: actions
                )
            } else {
                service.finishAIEnrichment(narrative: text, error: nil, previewActions: actions)
            }
        } catch {
            service.finishAIEnrichment(
                narrative: ruleFallback(service: service, diskTight: diskTight),
                error: nil,
                previewActions: []
            )
            NSLog("[SoftwareAIScan] AI failed, used rule fallback: %@", error.localizedDescription)
        }
    }

    /// 规则兜底：不复述体积分档（列表已展示）；面向软件页，不用聊天「换个问法」话术
    @MainActor
    private static func ruleFallback(service: SoftwareService, diskTight: Bool) -> String {
        let n = service.apps.count
        let sep = AppLanguage.current == .chinese ? "、" : ", "
        let top = service.apps.prefix(3).map(\.name).joined(separator: sep)
        let topLine = top.isEmpty ? "" : L10n.t("software.chat.top_line", top)
        let suggest = diskTight
            ? L10n.t("software.chat.suggest_tight")
            : L10n.t("software.chat.suggest_loose")
        return L10n.t("software.chat.rule_fallback", n, topLine, suggest)
    }

    private static func sanitize(_ raw: String) -> String {
        var t = raw
            .replacingOccurrences(of: "defier-json", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["已思考完毕，见下方可展开的过程", "（已思考完毕，见下方可展开的过程）", "已思考完毕"] {
            t = t.replacingOccurrences(of: p, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUseless(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.count < 16 { return true }
        if t.contains("已思考完毕") || t.contains("见下方可展开") { return true }
        // AIClient placeholder when model returned no prose (chat-oriented; wrong on Software page)
        if t.contains("没读到有效正文") || t.localizedCaseInsensitiveContains("No usable reply") {
            return true
        }
        if t == L10n.t("chat.empty_model") { return true }
        if t.contains("换个问法或点强度") { return true }
        return false
    }
}
