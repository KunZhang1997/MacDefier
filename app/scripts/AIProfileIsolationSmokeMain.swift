// Exercises the shipped settings loader without real Keychain or preference writes.
import Foundation

enum L10n {
    static func t(_ key: String, _ args: CVarArg...) -> String { key }
}

@main
enum AIProfileIsolationSmoke {
    enum Failure: Error { case assertion(String) }

    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    static func load(profiles: [AICloudProfile]?, active: String?, keys: [String: String]) throws -> AISettings {
        let suite = UserDefaults(suiteName: "MacDefier.ProfileIsolation.\(UUID().uuidString)")!
        var values: [String: Any] = [
            "ai.cloudPrivacyAcknowledged": true,
            "ai.baseURL": "https://legacy.invalid/v1"
        ]
        if let profiles { values["ai.cloudProfiles"] = try JSONEncoder().encode(profiles) }
        if let active { values["ai.activeCloudProfileId"] = active }
        suite.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        return AISettingsStore.load(from: suite, loadAPIKeys: { _ in keys })
    }

    static func main() throws {
        let a = AICloudProfile(id: "A", name: "A", baseURL: "https://a.invalid/v1", apiKey: "synthetic-A")
        let b = AICloudProfile(id: "B", name: "B", baseURL: "https://b.invalid/v1")
        var settings = AISettings.default
        settings.cloudProfiles = [a, b]
        settings.apiKey = a.apiKey
        settings.activeCloudProfileId = b.id
        settings.applyActiveCloudProfile()
        try expect(settings.apiKey.isEmpty && settings.baseURL == b.baseURL, "switching profile must clear the previous endpoint key")

        let legacyFallback = try load(profiles: [a, b], active: b.id, keys: ["A": a.apiKey, "_legacy": a.apiKey])
        try expect(legacyFallback.apiKey.isEmpty && !legacyFallback.isConfiguredForCloud, "empty active profile must not inherit legacy key")

        let firstFallback = try load(profiles: [a, b], active: b.id, keys: ["A": a.apiKey])
        try expect(firstFallback.apiKey.isEmpty, "empty active profile must not inherit first profile key")

        let ownKey = try load(profiles: [a, b], active: b.id, keys: ["A": a.apiKey, "B": "synthetic-B", "_legacy": a.apiKey])
        try expect(ownKey.apiKey == "synthetic-B" && ownKey.baseURL == b.baseURL, "active profile keeps its own key")

        let migration = try load(profiles: nil, active: nil, keys: ["_legacy": "synthetic-legacy"])
        try expect(migration.apiKey == "synthetic-legacy" && migration.baseURL == "https://legacy.invalid/v1", "single-profile migration preserves original endpoint and key")

        let missingActive = try load(profiles: [a, b], active: "deleted", keys: ["A": a.apiKey, "_legacy": "wrong"])
        try expect(missingActive.activeCloudProfileId == a.id && missingActive.apiKey == a.apiKey, "missing active ID selects one whole profile")

        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        try expect(!json.contains(a.apiKey), "profile JSON must not contain credentials")
        print("AIProfileIsolationSmoke: PASS (7 cases; no real Keychain, network or preference writes)")
    }
}
