// AIClient — OpenAI-compatible chat; intensity + think-strip + history compression.

import Foundation
import MonitorKit

public struct AIMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: Role
    public var content: String
    /// Hidden reasoning extracted from model (think blocks); not shown by default.
    public var thinking: String?
    public let date: Date
    public var isSummary: Bool
    /// Structured next-steps (cleanup / uninstall / monitor…). Empty for pure text.
    public var actions: [DefierAction]

    public enum Role: String, Sendable {
        case system, user, assistant
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        thinking: String? = nil,
        date: Date = Date(),
        isSummary: Bool = false,
        actions: [DefierAction] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.date = date
        self.isSummary = isSummary
        self.actions = actions
    }

    /// Content suitable for API (assistant: final answer only, no action JSON).
    public var apiContent: String {
        if role == .assistant {
            let parsed = DefierActionParser.parse(from: content)
            if !parsed.displayText.isEmpty { return parsed.displayText }
            return AIReplyParser.displayText(from: content).answer
        }
        return content
    }
}

public enum AIClientError: LocalizedError {
    case disabled
    case notConfigured
    case badURL
    case redirectBlocked(Int)
    case http(Int, String)
    case emptyResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .disabled: return "AI 已关闭（设置里开启）"
        case .notConfigured: return "未配置 API Key 或本地 Endpoint"
        case .badURL: return "Base URL / Endpoint 无效"
        case .redirectBlocked(let code):
            return AppLanguage.current.isEnglish
                ? "AI endpoint redirected (HTTP \(code)). The request was stopped to protect your data. Set the final endpoint URL and retry."
                : "AI 端点返回重定向（HTTP \(code)），已停止转发以保护数据。请配置最终端点地址后重试。"
        case .http(let code, let body): return "HTTP \(code)：\(body)"
        case .emptyResponse: return L10n.t("chat.empty_model")
        case .network(let m): return m
        }
    }
}

/// Parse MiniMax / Qwen style think tags and markdown fences.
public enum AIReplyParser {
    public struct Parsed: Sendable {
        public let answer: String
        public let thinking: String?
    }

    public static func displayText(from raw: String) -> Parsed {
        var text = raw
        var thinkingParts: [String] = []

        // <think>...</think> or <thinking>...</thinking>
        let patterns = [
            #"(?is)<think>(.*?)</think>"#,
            #"(?is)<thinking>(.*?)</thinking>"#,
            #"(?is)<reasoning>(.*?)</reasoning>"#
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                    guard let match, match.numberOfRanges > 1,
                          let r = Range(match.range(at: 1), in: text) else { return }
                    thinkingParts.append(String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                text = re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            }
        }

        // 未闭合 <think>（推理模型被 max_tokens 截断）：其后整段按思考处理，不泄进气泡
        if let openRange = text.range(of: #"<think>|<thinking>|<reasoning>"#, options: .regularExpression) {
            let tail = String(text[openRange.lowerBound...])
            let hasClose = tail.range(of: #"</think>|</thinking>|</reasoning>"#, options: .regularExpression) != nil
            if !hasClose {
                let part = String(text[openRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { thinkingParts.append(part) }
                text = String(text[..<openRange.lowerBound])
            }
        }

        text = text
            .replacingOccurrences(of: #"(?m)^\s*```(?:thinking|reason|reasoning)?\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // collapse excess blank lines
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        // strip leaked fence language tags
        text = text
            .replacingOccurrences(of: #"(?m)^\s*defier-json\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let thinking = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n\n")
        // 正文空时：不要塞「（已思考完毕…）」占位——会像单独回复一个括号句。
        // 有 thinking 则 answer 留空，UI 用可展开思考；无 thinking 再退回 raw 剥净。
        let answer: String
        if !text.isEmpty {
            answer = text
        } else if thinking != nil {
            answer = ""
        } else {
            answer = DefierActionParser.userVisibleProse(raw)
        }
        return Parsed(answer: answer, thinking: thinking)
    }
}

public enum AIClient {
    /// 解析可用端点。新用户无 Key → nil（不发网）。
    /// 本机 loopback 可无远程摘要；LAN/公网须已 acknowledged 且通过 endpoint policy。
    public static func resolveEndpoint(_ settings: AISettings) -> (base: String, model: String, apiKey: String?, useLocal: Bool)? {
        guard settings.enabled, settings.mode != .off else { return nil }
        switch settings.mode {
        case .cloud:
            return resolveCloud(settings)
        case .localOnly:
            return resolveLocal(settings, allowCloudFallback: false)
        case .localFirst:
            if let local = resolveLocal(settings, allowCloudFallback: false) {
                return local
            }
            return resolveCloud(settings)
        case .off:
            return nil
        }
    }

    private static func resolveCloud(_ settings: AISettings) -> (base: String, model: String, apiKey: String?, useLocal: Bool)? {
        // 新用户无 Key：不请求
        guard settings.isConfiguredForCloud else { return nil }
        let cls = AIEndpointPolicy.classify(settings.baseURL)
        guard cls.isRequestAllowed else { return nil }
        // 非 loopback 云端须已确认隐私摘要
        if cls.requiresRemotePrivacyAck, !settings.cloudPrivacyAcknowledged {
            return nil
        }
        return (settings.baseURL, settings.cloudModel, settings.apiKey, false)
    }

    private static func resolveLocal(
        _ settings: AISettings,
        allowCloudFallback: Bool
    ) -> (base: String, model: String, apiKey: String?, useLocal: Bool)? {
        guard settings.isConfiguredForLocal else {
            return allowCloudFallback ? resolveCloud(settings) : nil
        }
        let cls = AIEndpointPolicy.classify(settings.localEndpoint)
        // M08-1: local 模式仅 loopback / 私网·link-local；公网禁止挂「本地」标签
        guard AIEndpointPolicy.mayRequestAsLocalMode(
            settings.localEndpoint,
            privacyAcknowledged: settings.cloudPrivacyAcknowledged
        ) else {
            return allowCloudFallback ? resolveCloud(settings) : nil
        }
        switch cls.kind {
        case .loopback:
            // 真本机：无需远程摘要
            return (settings.localEndpoint, settings.localModel, nil, true)
        case .privateLAN:
            // useLocal=false：UI 勿当「纯本机」；仍用配置的 localEndpoint 传输
            return (settings.localEndpoint, settings.localModel, nil, false)
        case .remote, .invalid:
            return allowCloudFallback ? resolveCloud(settings) : nil
        }
    }

    public static func chatURL(from baseRaw: String) throws -> URL {
        var base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.contains("/chat/completions") {
            guard let u = URL(string: base) else { throw AIClientError.badURL }
            return u
        }
        if base.hasSuffix("/v1") {
            guard let u = URL(string: base + "/chat/completions") else { throw AIClientError.badURL }
            return u
        }
        // OpenAI-style root without /v1
        guard let u = URL(string: base + "/v1/chat/completions") else { throw AIClientError.badURL }
        return u
    }

    public static func chat(
        messages: [AIMessage],
        settings: AISettings,
        intensity: AIIntensity,
        systemExtra: String? = nil,
        rollingSummary: String? = nil
    ) async throws -> AIMessage {
        guard settings.enabled, settings.mode != .off else { throw AIClientError.disabled }
        guard let ep = resolveEndpoint(settings) else { throw AIClientError.notConfigured }
        // 请求边界重复执行 endpoint policy
        let cls = AIEndpointPolicy.classify(ep.base)
        guard cls.isRequestAllowed else { throw AIClientError.badURL }
        if cls.requiresRemotePrivacyAck, !settings.cloudPrivacyAcknowledged {
            throw AIClientError.notConfigured
        }
        let chatURL = try chatURL(from: ep.base)

        let packed = packHistory(
            messages: messages,
            keepRecentTurns: settings.keepRecentTurns,
            charBudget: settings.historyCharBudget,
            existingSummary: rollingSummary
        )

        var apiMessages: [[String: String]] = []
        apiMessages.append([
            "role": "system",
            "content": systemPrompt(intensity: intensity, extra: systemExtra, summary: packed.summary)
        ])
        for m in packed.recent {
            apiMessages.append(["role": m.role.rawValue, "content": m.apiContent])
        }

        let knobs = knobs(for: intensity)
        var body: [String: Any] = [
            "model": ep.model,
            "messages": apiMessages,
            "temperature": knobs.temperature
        ]
        body["max_tokens"] = knobs.maxTokens

        // OpenAI o-series / some gateways: reasoning_effort
        if let effort = knobs.reasoningEffort {
            body["reasoning_effort"] = effort
        }
        // Ollama's OpenAI-compatible API uses "none" to disable thinking.
        // enable_thinking=false is ignored there; small local models can spend
        // the entire normal reply budget reasoning without producing an answer.
        if ep.apiKey == nil, intensity != .deep {
            body["reasoning_effort"] = "none"
        }
        // Some Chinese gateways accept enable_thinking / thinking
        if intensity == .deep {
            body["enable_thinking"] = true
        } else if intensity == .light {
            body["enable_thinking"] = false
        }

        var req = URLRequest(url: chatURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ep.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = intensity == .deep ? 120 : 60

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await AIRequestTransport.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AIClientError.network(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(code) { throw AIClientError.redirectBlocked(code) }
        if code < 200 || code >= 300 {
            let text = String(data: data, encoding: .utf8) ?? ""
            // Retry without optional fields if 400 (gateway doesn't know reasoning_effort)
            if code == 400, body["reasoning_effort"] != nil || body["enable_thinking"] != nil {
                body.removeValue(forKey: "reasoning_effort")
                body.removeValue(forKey: "enable_thinking")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (d2, r2) = try await AIRequestTransport.data(for: req)
                let c2 = (r2 as? HTTPURLResponse)?.statusCode ?? 0
                if (300..<400).contains(c2) { throw AIClientError.redirectBlocked(c2) }
                if c2 >= 200 && c2 < 300 {
                    return try parseAssistant(data: d2)
                }
                // 重试失败抛第二次的状态与响应体（此前抛第一次的 400 body，误导排查）
                let text2 = String(data: d2, encoding: .utf8) ?? ""
                let short2 = text2.count > 280 ? String(text2.prefix(280)) + "…" : text2
                throw AIClientError.http(c2, short2.isEmpty ? "无响应体" : short2)
            }
            let short = text.count > 280 ? String(text.prefix(280)) + "…" : text
            throw AIClientError.http(code, short.isEmpty ? "无响应体" : short)
        }
        return try parseAssistant(data: data)
    }

    private static func parseAssistant(data: Data) throws -> AIMessage {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                let parsed = AIReplyParser.displayText(from: content)
                let extraThink = (message["reasoning_content"] as? String)
                    ?? (message["reasoning"] as? String)
                let thinking = [parsed.thinking, extraThink].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                let actionPack = DefierActionParser.parse(from: content)
                let actions = actionPack.payload?.actions ?? []
                let finalDisplay = Self.composeDisplay(
                    primary: actionPack.displayText,
                    secondary: parsed.answer,
                    payloadSummary: actionPack.payload?.summary,
                    hasActions: !actions.isEmpty
                )
                return AIMessage(
                    role: .assistant,
                    content: finalDisplay,
                    thinking: thinking.isEmpty ? parsed.thinking : thinking,
                    actions: actions
                )
            }
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                let parsed = AIReplyParser.displayText(from: content)
                let actionPack = DefierActionParser.parse(from: content)
                let actions = actionPack.payload?.actions ?? []
                let finalDisplay = Self.composeDisplay(
                    primary: actionPack.displayText,
                    secondary: parsed.answer,
                    payloadSummary: actionPack.payload?.summary,
                    hasActions: !actions.isEmpty
                )
                return AIMessage(
                    role: .assistant,
                    content: finalDisplay,
                    thinking: parsed.thinking,
                    actions: actions
                )
            }
        }
        throw AIClientError.emptyResponse
    }

    /// Prefer real prose; never leave a lone "（…）" bubble when we have actions or summary.
    private static func composeDisplay(
        primary: String,
        secondary: String,
        payloadSummary: String?,
        hasActions: Bool
    ) -> String {
        let candidates = [primary, secondary, payloadSummary ?? ""]
            .map { DefierActionParser.userVisibleProse($0) }
            .map { stripParenOnlyPlaceholder($0) }
            .filter { !$0.isEmpty }
            .filter { !$0.localizedCaseInsensitiveContains("defier-json") }
            .filter { !$0.contains("```") }

        if let best = candidates.first {
            return best
        }
        // JSON-only / think-only replies: one short human line, not decorative parentheses.
        if hasActions {
            return L10n.t("chat.actions_ready")
        }
        return L10n.t("chat.empty_model")
    }

    /// Drop strings that are only fullwidth/halfwidth parens, or old internal placeholders.
    private static func stripParenOnlyPlaceholder(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("（") && t.hasSuffix("）") && t.count <= 40 {
            // keep if it's a real sentence inside; drop pure junk markers
            let inner = String(t.dropFirst().dropLast())
            if inner.contains("已思考完毕") || inner.contains("模型未返回") || inner.isEmpty {
                return ""
            }
        }
        if t == "()" || t == "（）" || t == "[]" || t == "{}" { return "" }
        return t
    }

    private struct Knobs {
        let temperature: Double
        let maxTokens: Int
        let reasoningEffort: String?
    }

    private static func knobs(for intensity: AIIntensity) -> Knobs {
        switch intensity {
        case .light:
            return Knobs(temperature: 0.2, maxTokens: 400, reasoningEffort: "low")
        case .standard:
            return Knobs(temperature: 0.4, maxTokens: 900, reasoningEffort: "medium")
        case .deep:
            return Knobs(temperature: 0.5, maxTokens: 1800, reasoningEffort: "high")
        }
    }

    // MARK: - History compression

    public struct PackedHistory: Sendable {
        public let summary: String?
        public let recent: [AIMessage]
        public let didCompress: Bool
    }

    /// Keep last `keepRecentTurns` non-system messages; put older into summary blob.
    public static func packHistory(
        messages: [AIMessage],
        keepRecentTurns: Int,
        charBudget: Int,
        existingSummary: String?
    ) -> PackedHistory {
        let dialog = messages.filter { $0.role == .user || $0.role == .assistant }
        let keep = max(4, keepRecentTurns)
        if dialog.count <= keep {
            // still enforce char budget by trimming oldest
            return trimToBudget(dialog, budget: charBudget, existingSummary: existingSummary)
        }
        let older = Array(dialog.dropLast(keep))
        let recent = Array(dialog.suffix(keep))
        var summaryLines: [String] = []
        if let existingSummary, !existingSummary.isEmpty {
            summaryLines.append(existingSummary)
        }
        for m in older {
            let role = m.role == .user ? "用户" : "助手"
            let snippet = String(m.apiContent.prefix(220))
            summaryLines.append("\(role)：\(snippet)")
        }
        // hard cap summary length
        var summary = summaryLines.joined(separator: "\n")
        if summary.count > 3500 {
            summary = "…" + String(summary.suffix(3500))
        }
        return trimToBudget(recent, budget: charBudget, existingSummary: summary)
    }

    private static func trimToBudget(_ recent: [AIMessage], budget: Int, existingSummary: String?) -> PackedHistory {
        var r = recent
        var sum = existingSummary
        var total = r.reduce(0) { $0 + $1.apiContent.count } + (sum?.count ?? 0)
        var compressed = sum != nil && !(sum?.isEmpty ?? true)
        while total > budget && r.count > 4 {
            let dropped = r.removeFirst()
            let role = dropped.role == .user ? "用户" : "助手"
            let line = "\(role)：\(String(dropped.apiContent.prefix(160)))"
            sum = ((sum ?? "") + "\n" + line)
            if let s = sum, s.count > 3500 {
                sum = "…" + String(s.suffix(3500))
            }
            total = r.reduce(0) { $0 + $1.apiContent.count } + (sum?.count ?? 0)
            compressed = true
        }
        return PackedHistory(summary: sum, recent: r, didCompress: compressed)
    }

    public static func testConnection(settings: AISettings) async -> String {
        do {
            let probe = AppLanguage.current.isEnglish ? "Reply with only: ok" : "请只回复：ok"
            let sys = AppLanguage.current.isEnglish
                ? "Connectivity test. Reply with one word: ok."
                : "你是连通性测试。只回复一个词 ok。"
            let reply = try await chat(
                messages: [AIMessage(role: .user, content: probe)],
                settings: settings,
                intensity: .light,
                systemExtra: sys
            )
            guard !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reply.content != L10n.t("chat.empty_model") else {
                throw AIClientError.emptyResponse
            }
            return L10n.t("settings.test_ok", String(reply.content.prefix(80)))
        } catch {
            return L10n.t("settings.test_fail", error.localizedDescription)
        }
    }

    public static func systemPrompt(intensity: AIIntensity, extra: String?, summary: String?) -> String {
        var s = """
        你是 MacDefier 的 Mr. Defier（本机 Mac 管理助手）。

        【权限红线 — 系统级强制，不可违反】
        - 你只允许：读摘要、分析、给建议、输出可点按钮（跳转界面）。
        - 你绝对不允许：删除/移动/改写任何文件或文件夹；清空废纸篓；执行 rm、卸载命令、shell、脚本。
        - 你绝对不允许：声称「已删除」「已清理完成」「已卸载成功」——你做不到，只有用户在 App 里点确认后才会进废纸篓。
        - cleanup / uninstall 类按钮的含义仅是「打开预览页让用户自己勾选」，不是授权你删东西。
        - 禁止恐吓式安全话术；禁止假装已杀毒/已加速/已清理。

        【语气 · 一读性（强制）】
        - 像靠谱朋友顺口说一句，不要公文腔、播报腔、诊断报告腔。
        - 不用「偏紧/负载/占用较高/建议立即/务必/存在风险」这类生硬或吓人词；改成「有点满」「在忙」「可以先看看」。
        - 事实照说，语气放软；能肯定就肯定，别端着。
        - 仍禁止恐吓式安全话术；大软件≠故障。

        【回答形态】
        - \(AppLanguage.current.aiLanguageRule)
        - Body: **1–2 short sentences only**. Friendly. No report tone. No bullet walls.
        - Do **not** repeat action card titles in the body (cards already show them).
        - No <think>, no markdown headings, no bullet lists of apps (use actions for that).
        - Numbers/paths only from the live Mac summary. Large app ≠ malware/broken.
        - Games can be huge — say so calmly; don't push uninstall unless user wants free space.

        【输出格式 — 强制 · 必须两段】
        A) Human line(s): 1–2 sentences the user reads in the bubble. **Never** write the words defier-json, ```, or raw JSON here.
        B) Then a **complete** fenced block (open AND close with ```). Language tag: defier-json

        Example shape (structure only):
        Wuthering Waves is the big install (~155 GB); that's normal for a game. For free space, chat caches and Xcode leftovers are more realistic.
        ```defier-json
        {"summary":"one-line echo","actions":[{"type":"open_software","title":"Open Apps","detail":"Browse sizes"}]}
        ```

        Rules for the JSON block:
        - Must be valid JSON inside a **closed** ```defier-json ... ``` fence.
        - Never leave an unclosed fence or a bare "defier-json" line in the human part.
        - type only: cleanup | uninstall | open_software | open_monitor | open_diagnostic | quit_process | open_settings
        - uninstall: path/bundleID must come from the live summary.
        - Prefer ≤ 4 actions. summary language = UI language.
        - If no actions, actions=[] and put the reason in the human lines.
        """
        switch intensity {
        case .light:
            s += AppLanguage.current.isEnglish
                ? "\nIntensity=Light: at most 3 actions; body max 2 short sentences."
                : "\n强度=轻：最多 3 个 actions，正文最多两句。"
        case .standard:
            s += AppLanguage.current.isEnglish
                ? "\nIntensity=Standard: at most 4 actions; body max 2 sentences."
                : "\n强度=标准：最多 4 个 actions，正文两句内。"
        case .deep:
            s += AppLanguage.current.isEnglish
                ? "\nIntensity=Deep: at most 5 actions; body still short (not an essay)."
                : "\n强度=深：最多 5 个 actions，正文仍要短，不要长文。"
        }
        // Always restate language LAST so the model does not ignore it
        s += "\n\n" + AppLanguage.current.aiLanguageRule
        s += AppLanguage.current.isEnglish
            ? "\n\nFinal check: human bubble must NOT contain defier-json, triple-backticks, or JSON braces."
            : "\n\n最终检查：用户气泡里禁止出现 defier-json、``` 或 JSON 大括号。"
        if let summary, !summary.isEmpty {
            s += AppLanguage.current.isEnglish
                ? "\n\n[Earlier conversation summary — for continuity; do not recite verbatim]\n" + summary
                : "\n\n【更早对话摘要，供连贯，勿原样复读】\n" + summary
        }
        if let extra, !extra.isEmpty {
            s += AppLanguage.current.isEnglish
                ? "\n\n[Live Mac summary — use only these paths/bundleIDs/pids]\n" + extra
                : "\n\n【当前本机摘要 — 只能据此给 path/bundleID/pid】\n" + extra
        }
        return s
    }

    @MainActor
    public static func monitorSnapshotText(_ monitor: MonitorService) -> String {
        let s = monitor.snapshot
        var lines: [String] = []
        if let c = s.cpu {
            lines.append(String(format: "CPU 占用约 %.0f%%（系统 %.0f%% / 用户 %.0f%%）", c.totalUsage * 100, c.systemLoad * 100, c.userLoad * 100))
        }
        if let r = s.ram {
            lines.append(String(format: "内存使用约 %.0f%%，压力 \(r.pressure.value.rawValue)", r.usage * 100))
        }
        for d in s.disks.prefix(8) {
            lines.append(String(
                format: "磁盘 · %@（%@）已用约 %.0f%%，可用 %@",
                d.name,
                d.kindLabel,
                d.usage * 100,
                ByteCountFormatter.string(fromByteCount: Int64(d.free), countStyle: .file)
            ))
        }
        if !s.topCPU.isEmpty {
            let top = s.topCPU.prefix(5).map { "\($0.name) \(String(format: "%.1f", $0.usage))%" }.joined(separator: "；")
            lines.append("Top CPU：\(top)")
        }
        return lines.isEmpty ? "（监控数据尚未就绪）" : lines.joined(separator: "\n")
    }
}
