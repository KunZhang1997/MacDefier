// Cleanup AI enrich — rules scan first; AI only critiques the list (no delete, no path rewrite).

import Foundation
import CleanupKit

enum CleanupAIScan {
    @MainActor
    static var isConfigured: Bool {
        let s = AISettingsStore.load()
        return s.enabled && s.mode != .off && AIClient.resolveEndpoint(s) != nil
    }

    /// Full cleanup pipeline for chat: same rules scan + module prompt as the Cleanup page.
    /// Never deletes; returns navigation actions only (open Cleanup page for user to confirm).
    @MainActor
    static func runForChat(
        service: CleanupService? = nil,
        useAI: Bool
    ) async -> ModuleChatResult {
        // 默认值表达式在调用方上下文求值，.shared 的 MainActor 隔离会触发 Swift 6 警告 → 挪进函数体
        let service = service ?? CleanupService.shared
        // cleaning 中不打断破坏性操作、不改路径快照；prepare 内仍会拦截
        // M09-1：复用预览也必须清勾选（建议态 ≠ 带着上次勾选可直接 trash）
        let ready = await service.preparePreviewForChat()
        if !ready {
            return ModuleChatResult(
                summary: L10n.t("cleanup.chat.busy_cleaning"),
                actions: [openCleanupPageAction(metric: nil)],
                errorHint: nil,
                wasBusy: true
            )
        }

        let wantAI = useAI && isConfigured
        await enrichIfNeeded(service: service, useAI: wantAI)

        // If AI failed / skipped, still give a readable rule summary for chat + page.
        if (service.aiNarrative ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            service.aiNarrative = ruleBasedNarrative(service: service)
            service.lastAIError = nil
        }

        let summary = chatSummary(service: service)
        let metric = service.totalBytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(service.totalBytes), countStyle: .file)
            : nil
        // Do not surface internal AI errors in chat — scan already succeeded; user needs the page CTA.
        return ModuleChatResult(
            summary: summary,
            actions: [openCleanupPageAction(metric: metric)],
            errorHint: nil,
            wasBusy: false
        )
    }

    @MainActor
    private static func openCleanupPageAction(metric: String?) -> DefierAction {
        DefierAction(
            kind: .cleanup,
            title: L10n.t("cleanup.chat.open_title"),
            detail: L10n.t("cleanup.chat.open_detail"),
            metric: metric
        )
    }

    /// Model 失败时的**纯统计**兜底（不做「哪类可删」硬编码结论）。
    @MainActor
    static func ruleBasedNarrative(service: CleanupService) -> String {
        let total = service.totalBytes
        let count = service.allItems.count
        if count == 0 {
            return L10n.t("cleanup.chat.none")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        let top = service.groups
            .filter { $0.totalBytes > 0 }
            .sorted { $0.totalBytes > $1.totalBytes }
            .prefix(4)
            .map { g in
                let s = ByteCountFormatter.string(fromByteCount: Int64(g.totalBytes), countStyle: .file)
                return L10n.t("cleanup.chat.top_line", g.category.localizedTitle, s)
            }
            .joined(separator: "\n")

        var lines: [String] = []
        lines.append(L10n.t("cleanup.chat.looked"))
        lines.append(L10n.t("cleanup.chat.count_size", count, size))
        if !top.isEmpty {
            lines.append(L10n.t("cleanup.chat.top_header"))
            lines.append(top)
        }
        // 统计 only：引导打开清理页对照路径，不替用户判定可删
        lines.append(L10n.t("cleanup.chat.cta"))
        return lines.joined(separator: "\n")
    }

    @MainActor
    private static func chatSummary(service: CleanupService) -> String {
        if let n = service.aiNarrative?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            // Drop dead AI placeholders; fall back to rules
            if isUselessAIText(n) {
                return ruleBasedNarrative(service: service)
            }
            let footer = "\n\n" + L10n.t("cleanup.chat.footer")
            // Already has disclaimer markers (either language)
            let markers = ["没删", "没有删", "打开清理", "什么都还没动", "nothing deleted", "not deleted", "Open Cleanup", "haven't deleted"]
            if markers.contains(where: { n.localizedCaseInsensitiveContains($0) }) {
                return n
            }
            return n + footer
        }
        return ruleBasedNarrative(service: service)
    }

    /// 规则扫出表后，把表交给模型自判「先勾/先别勾」。执行删除仍只在用户侧。
    @MainActor
    static func enrichIfNeeded(service: CleanupService, useAI: Bool) async {
        guard useAI, isConfigured else { return }
        // 仅新鲜 preview 可挂 AI；cleaning / 过期 / 扫描中一律跳过
        guard case .preview = service.phase,
              !service.isDestructiveBusy,
              service.hasFreshPreview
        else { return }
        // 已有解读且预览仍新鲜：不重复消耗 API
        let hasNarrative = !(service.aiNarrative ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasNarrative { return }

        let settings = AISettingsStore.load()
        let ep = AIClient.resolveEndpoint(settings)
        let whereHint: String = {
            guard let ep else { return L10n.t("cleanup.ai_clarify") }
            if ep.useLocal {
                return "\(L10n.t("chat.local")) · \(ep.model)"
            }
            return "\(L10n.t("chat.cloud")) · \(ep.model)"
        }()
        let token = service.beginAIEnrichment(hint: whereHint)
        // begin 在 non-preview / busy 返回死 token（不设 isAIEnriching）；勿打 API
        guard service.isAIEnriching else { return }

        let ctx = service.contextTextForAI()
        let lang = AppLanguage.current
        // 本机模型：略短，仍自判，不另写硬编码分类器
        let local = ep?.useLocal == true

        let systemExtra = """
        You are MacDefier Cleanup advisor (not an auto-cleaner).
        The app already scanned; you only analyze the table and advise what the user may tick.
        Rules: speak only from the table; use path= fields to distinguish same titles; never invent paths/sizes;
        never delete/move; never claim cleanup is done; never tick for the user.
        If unsure whether an item is personal media/project vs regenerable cache, say so and tell user to open Finder via the path.
        \(lang.aiLanguageRule)
        Tone: short, plain; no scareware.
        """

        let structure = lang.isEnglish
            ? """
            Structure (you decide content from the table only):
            Overview: one line.
            Safe to tick first: items you judge regenerable/low personal risk — cite path= when possible.
            Leave alone: personal files, projects, ambiguous same-name folders — cite path=.
            Don't: don't select for user; don't invent rows not in the table.
            \(local ? "Keep under ~100 words." : "About 80–160 words.") Bullets with "·" ok.
            """
            : """
            结构（内容由表自判，勿套固定应用名单）：
            【总览】一句。
            【可以先勾】你判断可再生/低个人风险的项——尽量写出 path=。
            【先别勾】个人文件、项目、同名难辨项——写出 path=；不确定就写需用户看 Finder。
            【别做】不替用户勾选；不编表外路径。
            \(local ? "全文约 80～120 字。" : "全文约 120～220 字。") 分条用「·」。
            """

        let prompt = """
        Scan list ready (nothing selected, nothing deleted). Advise only.

        \(structure)

        \(lang.aiLanguageRule)

        【只能依据这张表】
        \(ctx)
        """

        do {
            let reply = try await AIClient.chat(
                messages: [AIMessage(role: .user, content: prompt)],
                settings: settings,
                intensity: local ? .light : .standard,
                systemExtra: systemExtra
            )
            var text = DiagnosticScanEngine.plainText(reply.content)
            text = sanitizeAIDisplay(text)
            if isUselessAIText(text) {
                let retry = try await AIClient.chat(
                    messages: [
                        AIMessage(role: .user, content: """
                        \(AppLanguage.current.aiLanguageRule)
                        From this cleanup table only, write 3–5 short bullets (no think tags):
                        which paths look OK to tick first vs leave alone. Cite path= values. Do not invent rows.
                        Data:
                        \(ctx.prefix(local ? 4500 : 8000))
                        """)
                    ],
                    settings: settings,
                    intensity: .light,
                    systemExtra: systemExtra
                )
                text = sanitizeAIDisplay(DiagnosticScanEngine.plainText(retry.content))
            }
            if isUselessAIText(text) {
                service.finishAIEnrichment(
                    token: token,
                    narrative: ruleBasedNarrative(service: service),
                    error: nil
                )
            } else {
                service.finishAIEnrichment(token: token, narrative: text, error: nil)
            }
        } catch {
            service.finishAIEnrichment(
                token: token,
                narrative: ruleBasedNarrative(service: service),
                error: nil
            )
        }
    }

    private static func sanitizeAIDisplay(_ raw: String) -> String {
        var text = DefierActionParser.userVisibleProse(raw)
        let junkPhrases = [
            "已思考完毕，见下方可展开的过程",
            "（已思考完毕，见下方可展开的过程）",
            "已思考完毕",
            "见下方可展开的过程"
        ]
        for p in junkPhrases {
            text = text.replacingOccurrences(of: p, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUselessAIText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.count < 12 { return true }
        if t.contains("已思考完毕") { return true }
        if t.contains("见下方可展开") { return true }
        // Known empty-model / placeholder strings (en + zh)
        let empties = [
            "No usable reply text",
            "没有可用",
            L10n.t("chat.empty_model")
        ]
        if empties.contains(where: { t.localizedCaseInsensitiveContains($0) }) { return true }
        return false
    }
}
