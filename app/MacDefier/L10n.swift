// L10n — Settings-driven UI language (zh-Hans / en). Does NOT follow system locale.

import Foundation

enum L10n {
    /// Lookup key in `AppLanguage.current` lproj bundle.
    static func t(_ key: String) -> String {
        string(key)
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = string(key)
        return String(format: format, locale: locale, arguments: args)
    }

    static var locale: Locale {
        Locale(identifier: AppLanguage.current.rawValue)
    }

    private static func string(_ key: String) -> String {
        let lang = AppLanguage.current.rawValue
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            if value != key { return value }
        }
        // Fallback: **do not** drop English users into Chinese.
        // EN miss → try en (no-op if already en) is skipped; only other direction is
        // zh miss → en. Never: en miss → zh-Hans (was leaking Chinese in English mode).
        if lang != "en" {
            if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
               let bundle = Bundle(path: path) {
                let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                if value != key { return value }
            }
        }
        return key
    }
}
