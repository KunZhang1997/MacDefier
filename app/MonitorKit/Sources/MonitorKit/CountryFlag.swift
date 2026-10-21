// ISO 3166-1 alpha-2 → regional-indicator flag emoji (no asset pack).

import Foundation

public enum CountryFlag {
    /// 🇯🇵 from "JP" / "jp"
    public static func emoji(forCode raw: String?) -> String? {
        guard let code = normalizedCode(raw) else { return nil }
        let base: UInt32 = 0x1F1E6 // REGIONAL INDICATOR SYMBOL LETTER A
        var scalars = String.UnicodeScalarView()
        for u in code.unicodeScalars {
            let offset = u.value &- 65 // 'A'
            guard let s = UnicodeScalar(base &+ offset) else { return nil }
            scalars.append(s)
        }
        return String(scalars)
    }

    /// "JP" from common English/geo API country names (legacy cache without code).
    public static func code(fromCountryName name: String?) -> String? {
        guard let n = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !n.isEmpty
        else { return nil }
        if let direct = normalizedCode(n), direct.count == 2 { return direct }
        return nameToCode[n]
    }

    public static func normalizedCode(_ raw: String?) -> String? {
        guard var c = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        if c.count > 2, c.contains("-") {
            c = String(c.split(separator: "-").first ?? Substring(c))
        }
        c = c.uppercased()
        guard c.count == 2,
              c.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) })
        else { return nil }
        return c
    }

    /// "🇯🇵 Hyōgo · Japan" — flag first when code known
    public static func placeLabel(city: String?, country: String?, countryCode: String?) -> String? {
        let cityT = clean(city)
        let countryT = clean(country)
        let code = normalizedCode(countryCode) ?? code(fromCountryName: countryT)
        let flag = emoji(forCode: code)
        var body: [String] = []
        if let cityT { body.append(cityT) }
        if let countryT { body.append(countryT) }
        let place = body.isEmpty ? nil : body.joined(separator: " · ")
        switch (flag, place) {
        case let (f?, p?): return "\(f) \(p)"
        case let (f?, nil): return f
        case let (nil, p?): return p
        default: return nil
        }
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // Minimal map for backfill; primary path is API country_code.
    private static let nameToCode: [String: String] = [
        "japan": "JP", "日本": "JP",
        "united states": "US", "united states of america": "US", "usa": "US", "us": "US", "美国": "US",
        "china": "CN", "中国": "CN", "people's republic of china": "CN",
        "hong kong": "HK", "香港": "HK",
        "taiwan": "TW", "台灣": "TW", "台湾": "TW",
        "south korea": "KR", "korea": "KR", "korea, republic of": "KR", "韩国": "KR", "韓國": "KR",
        "singapore": "SG", "新加坡": "SG",
        "united kingdom": "GB", "great britain": "GB", "uk": "GB", "england": "GB", "英国": "GB",
        "germany": "DE", "德国": "DE", "deutschland": "DE",
        "france": "FR", "法国": "FR",
        "canada": "CA", "加拿大": "CA",
        "australia": "AU", "澳大利亚": "AU",
        "india": "IN", "印度": "IN",
        "russia": "RU", "russian federation": "RU", "俄罗斯": "RU",
        "brazil": "BR", "巴西": "BR",
        "netherlands": "NL", "荷兰": "NL",
        "switzerland": "CH", "瑞士": "CH",
        "sweden": "SE", "瑞典": "SE",
        "norway": "NO", "挪威": "NO",
        "finland": "FI", "芬兰": "FI",
        "italy": "IT", "意大利": "IT",
        "spain": "ES", "西班牙": "ES",
        "portugal": "PT", "葡萄牙": "PT",
        "ireland": "IE", "爱尔兰": "IE",
        "poland": "PL", "波兰": "PL",
        "turkey": "TR", "türkiye": "TR", "土耳其": "TR",
        "thailand": "TH", "泰国": "TH",
        "vietnam": "VN", "viet nam": "VN", "越南": "VN",
        "indonesia": "ID", "印度尼西亚": "ID",
        "malaysia": "MY", "马来西亚": "MY",
        "philippines": "PH", "菲律宾": "PH",
        "mexico": "MX", "墨西哥": "MX",
        "argentina": "AR", "阿根廷": "AR",
        "new zealand": "NZ", "新西兰": "NZ",
        "united arab emirates": "AE", "uae": "AE", "阿联酋": "AE",
        "israel": "IL", "以色列": "IL",
        "south africa": "ZA", "南非": "ZA",
        "macao": "MO", "macau": "MO", "澳门": "MO", "澳門": "MO"
    ]
}
