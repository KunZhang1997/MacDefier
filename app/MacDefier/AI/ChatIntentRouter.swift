// Routes chat utterances to feature modules. Chat does not own business prompts —
// it only picks which module's existing AI/rules pipeline to run.

import Foundation

enum ChatModuleIntent: String, Sendable {
    /// Home diagnostic: rules + DiagnosticScanService module prompt.
    case diagnostic
    /// CleanupAIScan module prompt.
    case cleanup
    /// SoftwareAIScan module prompt.
    case software
    /// Fallback free-form chat (generic assistant prompt only).
    case freeChat
}

/// Shared chat payload from any feature module (display + navigate only).
struct ModuleChatResult: Sendable {
    var summary: String
    var actions: [DefierAction]
    var errorHint: String?
    var wasBusy: Bool

    static func busy(_ message: String, open: DefierAction? = nil) -> ModuleChatResult {
        ModuleChatResult(
            summary: message,
            actions: open.map { [$0] } ?? [],
            errorHint: nil,
            wasBusy: true
        )
    }
}

enum ChatIntentRouter {
    /// Empty-state phrase chips (labels + send text follow UI language).
    static var examplePhrases: [(label: String, text: String)] {
        [
            (L10n.t("chat.chip.slow"), L10n.t("chat.chip.slow.text")),
            (L10n.t("chat.chip.space"), L10n.t("chat.chip.space.text")),
            (L10n.t("chat.chip.apps"), L10n.t("chat.chip.apps.text")),
            (L10n.t("chat.chip.check"), L10n.t("chat.chip.check.text"))
        ]
    }

    /// Lightweight keyword routing. Prefer the most specific module first.
    static func resolve(_ text: String) -> ChatModuleIntent {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .freeChat }
        let lower = t.lowercased()

        // Cleanup first (junk / trash / cache).（去掉裸 "clean"/"缓存"：会误路由 "clean architecture"、"DNS 缓存" 类技术问答）
        if matches(lower, anyOf: [
            "清理", "清垃圾", "扫垃圾", "清一下", "腾空间", "腾点空间", "腾出空间",
            "废纸篓", "清空废纸篓", "清缓存", "清理缓存", "垃圾", "太满了", "磁盘满", "空间不够",
            "junk", "cleanup", "clean up", "free.?up space", "out of space"
        ]) {
            return .cleanup
        }

        // Software inventory / uninstall preview.（含裸「删除/删掉」+ App 名点名）
        if matches(lower, anyOf: [
            "卸载", "卸掉", "卸了", "删掉应用", "删软件", "移除应用",
            "删除", "删掉", "删了",
            "大软件", "大应用", "软件太大", "应用太大", "哪个.*占",
            "占空间", "占地方", "占内存", "装了什么", "已装软件", "软件列表", "应用列表",
            "uninstall", "remove app", "delete app", "software", "big app"
        ]) {
            return .software
        }

        if matches(lower, anyOf: [
            "检查", "诊断", "体检", "扫一下", "扫一扫", "扫描",
            "帮我看", "看看电脑", "有什么问题", "哪里有问题",
            "卡不卡", "卡顿", "好卡", "卡了", "好慢", "太慢", "很卡", "发烫", "风扇", "为什么卡",
            "健康", "状况", "怎么样了", "出了什么", "电脑怎么了",
            "check", "diagnos", "scan", "health", "slow", "lag", "what.?wrong", "look over"
        ]) {
            return .diagnostic
        }

        // Short imperative “帮我查一下 / 查一下吧”
        if t.count <= 24, matches(lower, anyOf: ["查一下", "看一下", "测一下", "帮我查", "帮我看", "帮我扫", "查查"]) {
            return .diagnostic
        }

        return .freeChat
    }

    private static func matches(_ text: String, anyOf keys: [String]) -> Bool {
        for k in keys {
            if k.contains("?") || k.contains(".") {
                if text.range(of: k, options: .regularExpression) != nil { return true }
            } else if text.contains(k) {
                return true
            }
        }
        return false
    }
}
