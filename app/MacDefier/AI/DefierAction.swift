// Structured actions from Mr. Defier — buttons that navigate to real work.
// AI never deletes/uninstalls; only opens preview / sheet for the user.

import AppKit
import Foundation

/// One tappable card under an assistant message (or diagnostic finding).
public struct DefierAction: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case cleanup
        case uninstall
        case openSoftware
        case openMonitor
        case openDiagnostic
        case quitProcess
        case openSettings
        case none
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    /// For uninstall / open software
    public var appName: String?
    public var bundleID: String?
    public var appPath: String?
    /// For quit process
    public var processPID: Int?
    public var processName: String?
    /// Optional size hint from model or rules (display only)
    public var metric: String?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        title: String,
        detail: String = "",
        appName: String? = nil,
        bundleID: String? = nil,
        appPath: String? = nil,
        processPID: Int? = nil,
        processName: String? = nil,
        metric: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.appName = appName
        self.bundleID = bundleID
        self.appPath = appPath
        self.processPID = processPID
        self.processName = processName
        self.metric = metric
    }

    public var buttonLabel: String {
        if !title.isEmpty { return title }
        switch kind {
        case .cleanup: return L10n.t("act.cleanup")
        case .uninstall: return L10n.t("act.uninstall")
        case .openSoftware: return L10n.t("act.software")
        case .openMonitor: return L10n.t("act.monitor")
        case .openDiagnostic: return L10n.t("act.diagnostic")
        case .quitProcess: return L10n.t("act.quit")
        case .openSettings: return L10n.t("act.settings")
        case .none: return title
        }
    }
}

/// Payload the model should return (plus short human summary).
struct DefierActionPayload: Equatable, Sendable, Codable {
    var summary: String
    var actions: [DefierAction]

    static let empty = DefierActionPayload(summary: "", actions: [])
}

/// 行动白名单闸门：AI/规则按钮进 UI 前洗一遍，防幻觉 path、乱杀进程。
enum DefierActionGuard {
    /// 已知安装 path 集合（可选）；nil 时只做文件系统存在性校验。
    static func sanitize(_ action: DefierAction, knownAppPaths: Set<String>? = nil) -> DefierAction {
        var a = action
        switch a.kind {
        case .uninstall, .openSoftware:
            if let p = a.appPath?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                let okExt = p.hasSuffix(".app")
                let exists = FileManager.default.fileExists(atPath: p)
                let inList = knownAppPaths.map { $0.contains(p) } ?? true
                if !okExt || !exists || !inList {
                    a.appPath = nil // 交给 bundle/name 查找；不跳幽灵路径
                }
            } else {
                a.appPath = nil
            }
            if a.appName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                a.appName = nil
            }
            if a.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                a.bundleID = nil
            }
            // uninstall 至少要有一个定位线索，否则降级 openSoftware
            if a.kind == .uninstall, a.appPath == nil, a.bundleID == nil, a.appName == nil {
                a.kind = .openSoftware
                if a.title.isEmpty { a.title = "打开软件" }
            }
        case .quitProcess:
            if let pid = a.processPID, !isSafeToQuit(pid: pid) {
                a.kind = .openMonitor
                a.title = a.title.isEmpty ? "打开监控" : a.title
                a.detail = "已拦下结束进程（系统或无效 PID）"
                a.processPID = nil
            }
        default:
            break
        }
        return a
    }

    static func sanitizeAll(_ actions: [DefierAction], knownAppPaths: Set<String>? = nil) -> [DefierAction] {
        actions.map { sanitize($0, knownAppPaths: knownAppPaths) }
    }

    static func isSafeToQuit(pid: Int) -> Bool {
        guard pid > 1 else { return false }
        // AI-hallucinated / out-of-range PID must not trap on pid_t truncation
        guard let pid32 = pid_t(exactly: pid) else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid32) else { return false }
        if app == NSRunningApplication.current { return false }
        // 不杀标记为系统关键的进程
        if app.activationPolicy == .prohibited { return false }
        let bid = (app.bundleIdentifier ?? "").lowercased()
        if bid.hasPrefix("com.apple.") { return false }
        if bid == "com.macdefier.app" { return false }
        return true
    }
}

enum DefierActionParser {
    /// 给人看的正文：去掉 fence / 裸 JSON 块 / 过重 markdown，避免气泡只剩残片。
    static func userVisibleProse(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }

        // 1) Complete fenced blocks ```…```
        if let re = try? NSRegularExpression(pattern: #"(?is)```[\s\S]*?```"#) {
            let range = NSRange(t.startIndex..<t.endIndex, in: t)
            t = re.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2) Unclosed fence from first ``` / ''' to end (model often stops mid-json)
        if let re = try? NSRegularExpression(pattern: #"(?is)```[\s\S]*$"#) {
            let range = NSRange(t.startIndex..<t.endIndex, in: t)
            t = re.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3) Lone fence / language tag lines: ```defier-json / `defier-json` / defier-json
        let lineJunk = [
            #"(?m)^\s*`{1,3}\s*(?:defier-json|json)?\s*`{0,3}\s*$"#,
            #"(?im)^\s*defier-json\s*$"#,
            #"(?i)`+defier-json`+"#,
            #"(?i)defier-json"#
        ]
        for pat in lineJunk {
            if let re = try? NSRegularExpression(pattern: pat) {
                let range = NSRange(t.startIndex..<t.endIndex, in: t)
                t = re.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
            }
        }
        t = t.replacingOccurrences(of: "```", with: "")
        t = t.replacingOccurrences(of: "``", with: "")

        // 4) Drop a trailing / whole-message JSON object that looks like action payload
        if t.contains("\"actions\"") || t.contains("\"summary\"") {
            if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end {
                let before = String(t[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
                let after = t[t.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
                let joined = [before, String(after)].filter { !$0.isEmpty }.joined(separator: "\n")
                if !joined.isEmpty {
                    t = joined
                } else if t.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                    t = ""
                }
            }
        }

        // 5) Light markdown
        t = t.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: "__", with: "")
        while t.contains("\n\n\n") {
            t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract ```defier-json … ``` or bare JSON object with "actions".
    static func parse(from raw: String) -> (displayText: String, payload: DefierActionPayload?) {
        let strippedThink = AIReplyParser.displayText(from: raw)
        var text = strippedThink.answer
        var payload: DefierActionPayload?

        // Fenced block (complete)
        if let re = try? NSRegularExpression(
            pattern: #"(?is)```(?:defier-json|json)?\s*(\{[\s\S]*?\})\s*```"#
        ) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = re.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: text) {
                let jsonStr = String(text[r])
                if let p = decodePayload(jsonStr) {
                    payload = p
                }
            }
        }

        // Unclosed fence: ```defier-json { ... }  (maybe no closing ```)
        if payload == nil,
           let re = try? NSRegularExpression(pattern: #"(?is)```(?:defier-json|json)?\s*(\{[\s\S]*)"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = re.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: text) {
                var jsonStr = String(text[r])
                // trim trailing fence if any
                if let cut = jsonStr.range(of: "```") {
                    jsonStr = String(jsonStr[..<cut.lowerBound])
                }
                // try decode from first { to last }
                if let s = jsonStr.firstIndex(of: "{"), let e = jsonStr.lastIndex(of: "}"), s < e {
                    if let p = decodePayload(String(jsonStr[s...e])) {
                        payload = p
                    }
                }
            }
        }

        // Whole message is JSON
        if payload == nil {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let p = decodePayload(trimmed) {
                payload = p
            }
        }

        // Heuristic: first { ... "actions" ... }
        if payload == nil,
           let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end {
            let jsonStr = String(text[start...end])
            if jsonStr.contains("\"actions\""), let p = decodePayload(jsonStr) {
                payload = p
            }
        }

        // Display = prose only (never show fence tags)
        var display = userVisibleProse(text)
        if display.isEmpty, let s = payload?.summary, !s.isEmpty {
            display = s
        }
        // Prefer short summary when prose is just noise / repeats cards
        if let s = payload?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if display.isEmpty || display.count > 420 || display.localizedCaseInsensitiveContains("defier") {
                display = s
            }
        }
        return (display, payload)
    }

    private static func decodePayload(_ jsonStr: String) -> DefierActionPayload? {
        guard let data = jsonStr.data(using: .utf8) else { return nil }
        // Flexible decode: allow type alias field
        struct LooseAction: Codable {
            var id: String?
            var type: String?
            var kind: String?
            var title: String?
            var detail: String?
            var appName: String?
            var name: String?
            var bundleID: String?
            var bundleId: String?
            var path: String?
            var appPath: String?
            var pid: Int?
            var processPID: Int?
            var processName: String?
            var metric: String?
        }
        struct LoosePayload: Codable {
            var summary: String?
            var message: String?
            var actions: [LooseAction]?
        }
        guard let loose = try? JSONDecoder().decode(LoosePayload.self, from: data) else {
            return nil
        }
        let actions = (loose.actions ?? []).compactMap { a -> DefierAction? in
            let typeRaw = (a.type ?? a.kind ?? "none").lowercased()
            let kind: DefierAction.Kind
            switch typeRaw {
            case "cleanup", "clean", "junk": kind = .cleanup
            case "uninstall", "remove_app", "removeapp": kind = .uninstall
            case "open_software", "software", "apps": kind = .openSoftware
            case "open_monitor", "monitor": kind = .openMonitor
            case "open_diagnostic", "diagnostic", "home": kind = .openDiagnostic
            case "quit_process", "quit", "kill": kind = .quitProcess
            case "open_settings", "settings": kind = .openSettings
            default: kind = .none
            }
            guard kind != .none else { return nil }
            let title = (a.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (a.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let appName = a.appName ?? a.name
            let bundleID = a.bundleID ?? a.bundleId
            let path = a.appPath ?? a.path
            let pid = a.processPID ?? a.pid
            let resolvedTitle: String = {
                if !title.isEmpty { return title }
                switch kind {
                case .cleanup: return "去清理（预览）"
                case .uninstall: return appName.map { "卸载 \($0)" } ?? "去卸载"
                case .openSoftware: return "打开软件列表"
                case .openMonitor: return "打开监控"
                case .openDiagnostic: return "打开诊断"
                case .quitProcess: return a.processName.map { "结束 \($0)" } ?? "结束进程"
                case .openSettings: return "打开设置"
                case .none: return "操作"
                }
            }()
            return DefierAction(
                id: a.id ?? UUID().uuidString,
                kind: kind,
                title: resolvedTitle,
                detail: detail,
                appName: appName,
                bundleID: bundleID,
                appPath: path,
                processPID: pid,
                processName: a.processName,
                metric: a.metric
            )
        }
        let summary = (loose.summary ?? loose.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if actions.isEmpty && summary.isEmpty { return nil }
        return DefierActionPayload(summary: summary, actions: actions)
    }
}
