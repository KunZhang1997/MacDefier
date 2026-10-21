// Match user-named apps in chat ("卸载腾讯视频") against installed inventory.

import Foundation

public enum AppQueryMatcher {
    /// Common aliases: user words → substrings to match name/bundle/path.
    private static let aliases: [String: [String]] = [
        "腾讯视频": ["腾讯视频", "tenvideo", "qqlive", "tencentvideo", "tencent video"],
        "微信": ["微信", "wechat", "weixin"],
        "企业微信": ["企业微信", "wxwork", "wework"],
        "qq": ["qq", "qq.app", "qqnt"],
        "钉钉": ["钉钉", "dingtalk"],
        "飞书": ["飞书", "lark", "feishu"],
        "chrome": ["chrome", "google chrome"],
        "edge": ["edge", "microsoft edge"],
        "word": ["word", "microsoft word"],
        "excel": ["excel", "microsoft excel"],
        "powerpoint": ["powerpoint", "microsoft powerpoint", "keynote"],
        "wps": ["wps"],
        "网易云音乐": ["网易云", "neteasemusic", "neteasemusic"],
        "qq音乐": ["qq音乐", "qqmusic"],
        "spotify": ["spotify"],
        "steam": ["steam"],
        "docker": ["docker"],
        "vscode": ["visual studio code", "code", "vscode"],
        "xcode": ["xcode"],
        "notion": ["notion"],
        "obsidian": ["obsidian"],
        "腾讯会议": ["腾讯会议", "tencentmeeting", "wemeet"],
        "zoom": ["zoom"],
        "迅雷": ["迅雷", "thunder", "xunlei"],
        "百度网盘": ["百度网盘", "baidunetdisk", "baidu netdisk"],
        "爱奇艺": ["爱奇艺", "iqiyi"],
        "优酷": ["优酷", "youku"],
        "b站": ["哔哩哔哩", "bilibili", "b站"],
        "哔哩哔哩": ["哔哩哔哩", "bilibili"]
    ]

    /// Strip uninstall/delete verbs; leftover is likely the app name.
    public static func extractQuery(from userText: String) -> String? {
        var t = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        let patterns = [
            #"(?i)帮我|请|麻烦|帮忙"#,
            #"(?i)把|将|把这个|把那个"#,
            #"(?i)删除掉|删掉|删除|卸掉|卸载掉|卸载|卸了|移除掉|移除|去掉|清掉"#,
            #"(?i)uninstall|remove|delete"#,
            #"(?i)这个软件|那个软件|这个应用|那个应用|软件|应用|app"#,
            #"[\"'「」『』《》\[\]【】]"#,
            #"吧|呀|啊|呢|嘛|哦|喔|一下|一下吧"#
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop pure action leftovers
        if t.isEmpty { return nil }
        if ["电脑", "mac", "系统", "空间", "垃圾", "缓存"].contains(t.lowercased()) { return nil }
        // Too generic inventory questions
        if t.count <= 1 { return nil }
        return t
    }

    /// Whether utterance looks like "I want this app gone" (even without classic 卸载 keyword alone).
    public static func looksLikeTargetedUninstall(_ text: String) -> Bool {
        let t = text.lowercased()
        let hasAction = matches(t, [
            "卸载", "卸掉", "卸了", "删除", "删掉", "删除掉", "移除", "去掉",
            "uninstall", "remove", "delete"
        ])
        guard hasAction else { return false }
        // Has leftover name after stripping verbs
        if let q = extractQuery(from: text), q.count >= 2 { return true }
        return false
    }

    public static func findMatches(query: String, in apps: [InstalledApp], limit: Int = 8) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let tokens = matchTokens(for: q)
        var scored: [(InstalledApp, Int)] = []

        for app in apps {
            let name = app.name.lowercased()
            let bid = app.bundleIdentifier.lowercased()
            let base = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.lowercased()
            var score = 0

            for tok in tokens {
                let t = tok.lowercased()
                if name == t || base == t { score += 100 }
                else if name.contains(t) { score += 60 }
                else if base.contains(t) { score += 50 }
                else if bid.contains(t) { score += 40 }
                // compact: 腾讯视频 vs tencentvideo
                let compactName = name.replacingOccurrences(of: " ", with: "")
                let compactTok = t.replacingOccurrences(of: " ", with: "")
                if compactName.contains(compactTok) { score += 45 }
            }

            // Original query as whole
            let ql = q.lowercased()
            if name.contains(ql) { score += 70 }
            if bid.contains(ql.replacingOccurrences(of: " ", with: "")) { score += 30 }

            if score > 0 {
                scored.append((app, score))
            }
        }

        return scored
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.totalBytes > $1.0.totalBytes
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func matchTokens(for query: String) -> [String] {
        var tokens: [String] = [query]
        let lower = query.lowercased()
        for (key, values) in aliases {
            if lower.contains(key.lowercased()) || key.lowercased().contains(lower) {
                tokens.append(contentsOf: values)
            }
            for v in values where lower.contains(v.lowercased()) || v.lowercased().contains(lower) {
                tokens.append(key)
                tokens.append(contentsOf: values)
            }
        }
        // Unique
        var seen = Set<String>()
        return tokens.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func matches(_ text: String, _ keys: [String]) -> Bool {
        keys.contains { text.contains($0.lowercased()) }
    }
}
