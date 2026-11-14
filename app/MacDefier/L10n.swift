// L10n — Settings-driven UI language (zh-Hans / en). Does NOT follow system locale.

import Foundation

enum L10n {
    private static let cacheLock = NSLock()
    private static var bundleCache: [String: Bundle] = [:]
    private static var missingBundles: Set<String> = []
    private static var localeCache: [String: Locale] = [:]

    /// Lookup key in `AppLanguage.current` lproj bundle.
    static func t(_ key: String) -> String {
        string(key)
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = string(key)
        return String(format: format, locale: locale, arguments: args)
    }

    static var locale: Locale {
        let lang = AppLanguage.current.rawValue
        cacheLock.lock()
        if let cached = localeCache[lang] {
            cacheLock.unlock()
            return cached
        }
        let created = Locale(identifier: lang)
        localeCache[lang] = created
        cacheLock.unlock()
        return created
    }

    private static func cachedBundle(for lang: String) -> Bundle? {
        cacheLock.lock()
        if let cached = bundleCache[lang] {
            cacheLock.unlock()
            return cached
        }
        if missingBundles.contains(lang) {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        let loaded = Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:))

        cacheLock.lock()
        if let loaded {
            bundleCache[lang] = loaded
        } else {
            missingBundles.insert(lang)
        }
        cacheLock.unlock()
        return loaded
    }

    private static func string(_ key: String) -> String {
        let lang = AppLanguage.current.rawValue
        if let bundle = cachedBundle(for: lang) {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            if value != key { return value }
        }
        // Fallback: **do not** drop English users into Chinese.
        // EN miss → try en (no-op if already en) is skipped; only other direction is
        // zh miss → en. Never: en miss → zh-Hans (was leaking Chinese in English mode).
        if lang != "en", let enBundle = cachedBundle(for: "en") {
            let value = enBundle.localizedString(forKey: key, value: nil, table: "Localizable")
            if value != key { return value }
        }
        return key
    }
}
