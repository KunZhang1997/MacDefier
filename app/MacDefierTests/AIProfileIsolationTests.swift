import XCTest
@testable import MacDefier

final class AIProfileIsolationTests: XCTestCase {
    private func load(
        rawProfilesValue: Any?,
        includeProfilesKey: Bool,
        active: String?,
        baseURL: String = "https://legacy.invalid/v1",
        keys: [String: String]
    ) -> AISettings {
        let suiteName = "MacDefier.ProfileIsolationTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        var values: [String: Any] = [
            "ai.cloudPrivacyAcknowledged": true,
            "ai.baseURL": baseURL
        ]
        if includeProfilesKey, let rawProfilesValue {
            values["ai.cloudProfiles"] = rawProfilesValue
        }
        if let active {
            values["ai.activeCloudProfileId"] = active
        }
        suite.setPersistentDomain(values, forName: suiteName)
        return AISettingsStore.load(from: suite, loadAPIKeys: { _ in keys })
    }

    private func load(profiles: [AICloudProfile]?, active: String?, keys: [String: String]) throws -> AISettings {
        let encoded = try profiles.map { try JSONEncoder().encode($0) }
        return load(
            rawProfilesValue: encoded,
            includeProfilesKey: profiles != nil,
            active: active,
            keys: keys
        )
    }

    func testProfileCredentialIsolationAndLegacyMigration() throws {
        let a = AICloudProfile(id: "A", name: "A", baseURL: "https://a.invalid/v1", apiKey: "synthetic-A")
        let b = AICloudProfile(id: "B", name: "B", baseURL: "https://b.invalid/v1")

        var settings = AISettings.default
        settings.cloudProfiles = [a, b]
        settings.apiKey = a.apiKey
        settings.activeCloudProfileId = b.id
        settings.applyActiveCloudProfile()
        XCTAssertTrue(settings.apiKey.isEmpty)
        XCTAssertEqual(settings.baseURL, b.baseURL)

        let legacyFallback = try load(profiles: [a, b], active: b.id, keys: ["A": a.apiKey, "_legacy": a.apiKey])
        XCTAssertTrue(legacyFallback.apiKey.isEmpty)
        XCTAssertFalse(legacyFallback.isConfiguredForCloud)

        let firstFallback = try load(profiles: [a, b], active: b.id, keys: ["A": a.apiKey])
        XCTAssertTrue(firstFallback.apiKey.isEmpty)

        let ownKey = try load(profiles: [a, b], active: b.id, keys: ["A": a.apiKey, "B": "synthetic-B", "_legacy": a.apiKey])
        XCTAssertEqual(ownKey.apiKey, "synthetic-B")
        XCTAssertEqual(ownKey.baseURL, b.baseURL)

        let migration = try load(profiles: nil, active: nil, keys: ["_legacy": "synthetic-legacy"])
        XCTAssertEqual(migration.apiKey, "synthetic-legacy")
        XCTAssertEqual(migration.baseURL, "https://legacy.invalid/v1")

        let missingActive = try load(profiles: [a, b], active: "deleted", keys: ["A": a.apiKey, "_legacy": "wrong"])
        XCTAssertEqual(missingActive.activeCloudProfileId, a.id)
        XCTAssertEqual(missingActive.apiKey, a.apiKey)

        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertFalse(json.contains(a.apiKey), "profile JSON must not contain credentials")
    }

    func testF2CorruptedOrEmptyProfilesNeverAttachLegacyCredential() throws {
        let keys = ["_legacy": "secret-from-endpoint-A", "A": "secret-A"]

        // 1) Corrupted JSON Data in ai.cloudProfiles while ai.baseURL points to endpoint B
        let corrupted = load(
            rawProfilesValue: Data("{not-valid-json".utf8),
            includeProfilesKey: true,
            active: "B",
            baseURL: "https://endpoint-b.invalid/v1",
            keys: keys
        )
        XCTAssertTrue(corrupted.apiKey.isEmpty, "Corrupted ai.cloudProfiles must NOT attach _legacy credential")
        XCTAssertFalse(corrupted.isConfiguredForCloud)
        XCTAssertEqual(corrupted.cloudProfiles.count, 1)
        XCTAssertTrue(corrupted.cloudProfiles[0].apiKey.isEmpty)

        // 2) Empty JSON array [] in ai.cloudProfiles
        let emptyArrayData = try JSONEncoder().encode([AICloudProfile]())
        let emptyProfiles = load(
            rawProfilesValue: emptyArrayData,
            includeProfilesKey: true,
            active: "B",
            baseURL: "https://endpoint-b.invalid/v1",
            keys: keys
        )
        XCTAssertTrue(emptyProfiles.apiKey.isEmpty, "Empty ai.cloudProfiles array must NOT attach _legacy credential")
        XCTAssertFalse(emptyProfiles.isConfiguredForCloud)

        // 3) Unexpected non-Data plist type (e.g. String / Dictionary) in ai.cloudProfiles
        let wrongType = load(
            rawProfilesValue: ["unexpected": "structure"],
            includeProfilesKey: true,
            active: nil,
            baseURL: "https://endpoint-b.invalid/v1",
            keys: keys
        )
        XCTAssertTrue(wrongType.apiKey.isEmpty, "Malformed plist value in ai.cloudProfiles must NOT attach _legacy credential")
        XCTAssertFalse(wrongType.isConfiguredForCloud)
    }
}
