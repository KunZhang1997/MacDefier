// Strict low-risk policy for bulk-select.
// Nothing auto-selected on scan. User may tap「勾选低风险」only for carefully allowlisted junk.

import Foundation

public enum CleanupRiskPolicy {
    /// Still-used tools / sensitive tokens — never low-risk bulk.
    /// Prefer tokens length ≥ 4; matching is path-segment aware for short ones.
    private static let activeOrSensitiveTokens: [String] = [
        "colima", "lima", "orbstack", "podman", "rancher",
        "docker", "buildx", "containerd",
        "swiftpm", "org.swift.swiftpm", "cocoapods", "carthage",
        "geoservices", "mapkit", "cloudkit",
        "vortex", "speakdd", "speechmodel", "speaksend",
        "openai", "anthropic", "ollama", "lmstudio",
        "yuanbao", "wechat", "tencent", "com.tencent",
        "keychain", "password", "credential",
        "photoslibrary", "android", "gradle",
        "familycircle", "knowledge-agent",
        "crashreporter", "diagnosticreports",
        "com.microsoft.vscode", "jetbrains",
        "zoom.us", "discord", "telegram"
    ]

    /// Folder / cache names that must never appear as「孤儿」（多半仍在用或是系统组件）
    public static func shouldNeverListAsOrphan(name: String, path: String) -> Bool {
        let n = name.lowercased()
        let p = path.lowercased()
        if n.hasPrefix("com.apple.") { return true }
        if n.hasPrefix(".") { return true }
        if matchesActiveToken(name: n, path: p) { return true }
        // 额外孤儿硬跳（名称精确或前缀）
        let hardSkipExact: Set<String> = [
            "cloudkit", "familycircle", "passkit", "askpermission",
            "callhistorytransactions", "callhistorydb",
            "com.crashlytics", "io.fabric", "homebrew", "pip", "yarn", "pnpm", "npm",
            "spotify", "steam", "slack", "discord"
        ]
        if hardSkipExact.contains(n) { return true }
        let hardSkipPrefix = ["com.apple", "org.swift", "com.docker", "io.colima", "com.linguee", "com.macdefier"]
        if hardSkipPrefix.contains(where: { n.hasPrefix($0) }) { return true }
        return false
    }

    /// Refine risk after ItemExplainer.
    public static func refine(
        name: String,
        path: String,
        category: CleanupCategory,
        base: CleanupRisk
    ) -> CleanupRisk {
        if base == .skip { return .skip }

        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()

        switch category {
        case .orphans:
            return .caution
        case .trash, .installerPackages, .largeAppData:
            return .caution
        case .temp:
            // /tmp product dumps: user must opt in
            if lowerName.hasPrefix("com.apple.") || lowerPath.contains("coresimulator") {
                return .rebuild
            }
            return .caution
        case .xcode:
            if lowerName == "archives" || lowerPath.hasSuffix("/archives") {
                return .caution
            }
            if matchesActiveToken(name: lowerName, path: lowerPath) {
                return .caution
            }
        case .docker, .aiApps:
            return .caution
        case .browsers:
            if lowerName.contains("password") || lowerPath.contains("login data") {
                return .skip
            }
            if lowerName.contains("cookie") || lowerName.contains("history") || lowerName.contains("site") {
                return .caution
            }
            if lowerName.contains("cache") || lowerName.contains("缓存") {
                return .rebuild
            }
            return .caution
        case .userCache:
            if lowerName.hasPrefix("com.apple.") || lowerName == "geoservices" {
                return .caution
            }
            if matchesActiveToken(name: lowerName, path: lowerPath) {
                return .caution
            }
        default:
            if matchesActiveToken(name: lowerName, path: lowerPath) {
                // brew/node category paths are intentional package caches
                if category == .brew || category == .node { return .rebuild }
                return .caution
            }
        }

        return base
    }

    /// Eligible for「勾选低风险」— aligned with `.safe` / `.rebuild` badges, excluding manual-confirm categories.
    public static func isLowRiskBulkEligible(_ item: CleanableItem) -> Bool {
        guard item.risk == .safe || item.risk == .rebuild else { return false }

        switch item.category {
        case .orphans, .trash, .installerPackages, .largeAppData:
            return false
        case .userCache, .userLogs, .systemLogs, .browsers, .xcode, .brew, .node, .wallpaper, .temp, .docker, .aiApps:
            return true
        }
    }

    private static func matchesActiveToken(name: String, path: String) -> Bool {
        for t in activeOrSensitiveTokens {
            if name == t || name.hasPrefix(t + ".") || name.hasPrefix(t + "-") {
                return true
            }
            // 短 token 只认路径段，避免 "git" 误伤 "digital"
            if t.count <= 4 {
                if path.contains("/\(t)/") || path.hasSuffix("/\(t)") { return true }
                continue
            }
            if name.contains(t) || path.contains("/\(t)") || path.contains("/\(t)/") {
                return true
            }
        }
        return false
    }
}
