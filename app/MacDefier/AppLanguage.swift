// App language — single source for Mr. Defier banter (and future UI i18n).
// Banter follows **Settings → 语言 only**, never the OS preferredLanguages list.

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// UserDefaults / AppStorage key (Settings + banter).
    static let storageKey = "app.language"

    var settingsTitle: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    /// Language for banter strings (zh/en pairs).
    var banterLanguage: PetBanterLanguage {
        switch self {
        case .chinese: return .chinese
        case .english: return .english
        }
    }

    private static let cacheLock = NSLock()
    private static var cachedCurrent: AppLanguage?
    private static let observerSetup: Void = {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            invalidateCache()
        }
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            invalidateCache()
        }
    }()

    static func invalidateCache() {
        cacheLock.lock()
        cachedCurrent = nil
        cacheLock.unlock()
    }

    /// Current choice from app settings.
    /// Unset / legacy `"system"` → follow **system preferred language** (en* → English, else 中文).
    static var current: AppLanguage {
        _ = observerSetup
        cacheLock.lock()
        if let cached = cachedCurrent {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let resolved: AppLanguage
        let raw = UserDefaults.standard.string(forKey: storageKey)
        if let raw, raw != "system", let lang = AppLanguage(rawValue: raw) {
            resolved = lang
        } else {
            resolved = systemPreferred
        }

        cacheLock.lock()
        cachedCurrent = resolved
        cacheLock.unlock()
        return resolved
    }

    /// macOS preferred language → app language (used when user has not chosen yet).
    static var systemPreferred: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        if preferred.hasPrefix("en") { return .english }
        return .chinese
    }

    var isEnglish: Bool { self == .english }

    /// Injected into every AI system/user prompt so model output matches Settings language.
    var aiLanguageRule: String {
        switch self {
        case .chinese:
            return "【语言 · 强制】所有用户可见文案必须用简体中文（正文、summary、title、detail）。禁止英文整段回复。"
        case .english:
            return """
            【Language · REQUIRED — override any Chinese in this prompt】
            All user-visible text MUST be natural English only \
            (body, summary, title, detail, button labels, status lines). \
            Do NOT reply in Chinese. Do NOT mix Chinese characters into the body. \
            Keep JSON keys (type, summary, actions, title, detail, …) as specified; values in English.
            """
        }
    }

    /// Short yes/no for prompts that embed 是/否.
    func yesNo(_ yes: Bool) -> String {
        switch self {
        case .chinese: return yes ? "是" : "否"
        case .english: return yes ? "yes" : "no"
        }
    }
}

extension PetBanterLanguage {
    /// **Only** app Settings language — ignore system locale.
    static func resolve() -> PetBanterLanguage {
        AppLanguage.current.banterLanguage
    }
}
