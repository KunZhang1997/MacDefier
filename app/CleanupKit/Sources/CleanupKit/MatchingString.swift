// MatchingString — normalize helpers adapted from PureMac StringNormalization (MIT).

import Foundation

extension String {
    func mdNormalizedForMatching() -> String {
        lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    func mdStrippingTrailingVersion() -> String {
        replacingOccurrences(
            of: #"\s+\d+(\.\d+)*\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    var mdLettersOnly: String {
        filter(\.isLetter).lowercased()
    }

    var mdBundleLastTwoComponents: String {
        let components = components(separatedBy: ".")
            .compactMap { $0 != "-" ? $0.lowercased() : nil }
        return components.suffix(2).joined()
    }

    var mdBaseBundleIdentifier: String? {
        let components = components(separatedBy: ".")
        let suffixes: Set<String> = [
            "helper", "agent", "daemon", "service", "xpc",
            "launcher", "updater", "installer", "uninstaller",
            "login", "extension", "plugin"
        ]
        guard components.count >= 4,
              let last = components.last?.lowercased(),
              suffixes.contains(last)
        else { return nil }
        return components.dropLast().joined(separator: ".")
    }
}

/// 名称类 token 的「分段精确」匹配：候选名按非字母数字切词，token 完整命中某词段才算。
/// 修复实证案例：卸载 1Password 误命中 com.apple.Passwords（lettersOnly=password 被 contains 命中）、
/// 卸载 Craft 误命中 Minecraft（"minecraft".contains("craft")）。
enum MatchingSegments {
    static func of(_ raw: String) -> Set<String> {
        Set(raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// 过于通用的词不做名称 token（单拎出来必误关联）
    static let stopwords: Set<String> = [
        "password", "passwords", "craft", "app", "apps", "soft", "software",
        "data", "manager", "helper", "agent", "client", "desktop",
        "mac", "macos", "osx", "pro", "lite", "free", "tool", "tools", "utils", "system", "service"
    ]
}
