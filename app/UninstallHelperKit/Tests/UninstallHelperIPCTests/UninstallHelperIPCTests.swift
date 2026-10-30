import Darwin
import Foundation
import Security
import XCTest
@testable import UninstallHelperIPC

final class UninstallHelperIPCTests: XCTestCase {
    private let team = "AB12345678"
    private var endpoint: UninstallHelperEndpoint {
        UninstallHelperEndpoint(clientIdentifier: "com.macdefier.app", teamIdentifier: team)
    }

    func testExactPeerRequirementIsAcceptedBySecurityParser() throws {
        let value = try UninstallHelperTrust.requirement(teamIdentifier: team, identifier: endpoint.helperIdentifier)
        XCTAssertTrue(value.contains("anchor apple generic"))
        XCTAssertTrue(value.contains("identifier \"com.macdefier.app.uninstall-helper\""))
        XCTAssertTrue(value.contains("certificate leaf[subject.OU] = \"AB12345678\""))
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(value as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
    }

    func testRequirementRejectsTeamOrIdentifierInjection() {
        for value in ["", "AB123", "ab12345678", "AB1234567\" or true", "AB1234567\n"] {
            XCTAssertThrowsError(try UninstallHelperTrust.requirement(teamIdentifier: value, identifier: endpoint.helperIdentifier))
        }
        for identifier in ["com.macdefier.other", "com.macdefier.app\" or true", "com.macdefier.app.uninstall-helper.extra"] {
            XCTAssertThrowsError(try UninstallHelperTrust.requirement(teamIdentifier: team, identifier: identifier))
        }
    }

    func testDevelopmentAndReleaseEndpointsAndRightsAreSeparate() {
        let development = UninstallHelperEndpoint(clientIdentifier: "com.macdefier.app.dev", teamIdentifier: team)
        XCTAssertEqual(endpoint.serviceName, "com.macdefier.app.uninstall-helper")
        XCTAssertEqual(development.serviceName, "com.macdefier.app.dev.uninstall-helper")
        XCTAssertEqual(endpoint.authorizationRightName, "com.macdefier.app.uninstall.trash.v2")
        XCTAssertEqual(development.authorizationRightName, "com.macdefier.app.dev.uninstall.trash.v2")
        XCTAssertNotEqual(endpoint.helloIdentity, development.helloIdentity)
    }

    func testVersionTwoHandshakeAndRightsAreIsolatedFromLegacyAuthorization() {
        for identifier in ["com.macdefier.app", "com.macdefier.app.dev"] {
            let value = UninstallHelperEndpoint(clientIdentifier: identifier, teamIdentifier: team)
            XCTAssertEqual(value.helloIdentity, value.serviceName + ":v2")
            XCTAssertNotEqual(value.helloIdentity, value.serviceName + ":v1")
            XCTAssertEqual(value.authorizationRightName, identifier + ".uninstall.trash.v2")
            XCTAssertNotEqual(value.authorizationRightName, identifier + ".uninstall.trash")
        }
    }

    func testTestRunnerCannotClaimProductionOrDevelopmentIdentity() {
        XCTAssertThrowsError(try UninstallHelperTrust.current(role: .client))
        XCTAssertThrowsError(try UninstallHelperTrust.current(role: .helper))
    }

    func testChallengeIsBoundedAndRejectsControlCharacters() {
        XCTAssertTrue(UninstallHelperLimits.isValidChallenge(UUID().uuidString))
        XCTAssertTrue(UninstallHelperLimits.isValidChallenge(String(repeating: "A", count: 128)))
        for value in ["", "short", String(repeating: "A", count: 129), "0123456789abcdef\n", "0123456789abcde/", "0123456789abcde中"] {
            XCTAssertFalse(UninstallHelperLimits.isValidChallenge(value))
        }
    }

    func testMalformedAuthorizationLengthFailsBeforeSecurityServerAccess() {
        for count in [0, UninstallHelperAuthorization.externalFormLength - 1,
                      UninstallHelperAuthorization.externalFormLength + 1, 16_384] {
            XCTAssertThrowsError(try UninstallHelperAuthorization.verifyExternalForm(Data(repeating: 0, count: count), endpoint: endpoint)) { error in
                XCTAssertEqual((error as? UninstallHelperFailure)?.code, "uninstall_helper_authorization_invalid")
            }
        }
    }

    func testOnlyFixedNonsharedAdministratorDelegationIsAccepted() {
        XCTAssertTrue(UninstallHelperAuthorization.isExpectedDefinition(["class": "rule", "rule": ["authenticate-admin-nonshared"]]))
        XCTAssertTrue(UninstallHelperAuthorization.isExpectedDefinition(["class": "rule", "rule": "authenticate-admin-nonshared", "k-of-n": 1]))
        let rejected: [[String: Any]] = [
            ["class": "allow"],
            ["class": "rule", "rule": ["allow"]],
            ["class": "rule", "rule": ["authenticate-admin"]],
            ["class": "rule", "rule": "authenticate-admin"],
            ["class": "rule", "rule": ["authenticate-admin-nonshared", "allow"]],
            ["class": "rule", "rule": ["authenticate-admin-nonshared", "authenticate-admin"]],
            ["class": "rule", "rule": ["authenticate-admin-nonshared"], "k-of-n": 0],
            ["class": "rule", "rule": ["authenticate-admin-nonshared"], "mechanisms": ["allow"]],
            ["class": "user", "rule": ["authenticate-admin-nonshared"]]
        ]
        for definition in rejected { XCTAssertFalse(UninstallHelperAuthorization.isExpectedDefinition(definition)) }
    }

    private var administratorRule: [String: Any] {
        ["class": "user", "group": "admin", "timeout": 30,
         "shared": false, "allow-root": false, "authenticate-user": true,
         "session-owner": false, "tries": 3]
    }

    func testFixedAdministratorRuleAcceptsOnlyPolicyFieldsAndMetadata() {
        XCTAssertTrue(UninstallHelperAuthorization.isExpectedAdministratorRule(administratorRule))
        var definition = administratorRule
        definition.merge([
            "comment": "Fixture policy", "created": 123.0, "modified": 124.0,
            "version": 1, "identifier": "fixture.rule", "requirement": "fixture requirement",
            "default-prompt": ["en": "Authenticate"], "tries": 3
        ]) { _, new in new }
        XCTAssertTrue(UninstallHelperAuthorization.isExpectedAdministratorRule(definition))
    }

    func testInstalledAdministratorRuleReadOnlyMatchesExpectedPolicy() throws {
        guard ProcessInfo.processInfo.environment["MACDEFIER_VERIFY_SYSTEM_AUTHORIZATION_RULE"] == "1" else {
            throw XCTSkip("Host policy check is opt-in; set MACDEFIER_VERIFY_SYSTEM_AUTHORIZATION_RULE=1 outside the sandbox.")
        }
        // AuthorizationRightGet only reads the definition. This test neither
        // creates an authorization reference nor requests or changes rights.
        var value: CFDictionary?
        let status = "authenticate-admin-nonshared".withCString { AuthorizationRightGet($0, &value) }
        XCTAssertEqual(status, errSecSuccess)
        let definition = try XCTUnwrap(value as? [String: Any])
        XCTAssertTrue(UninstallHelperAuthorization.isExpectedAdministratorRule(definition),
                      "Installed administrator policy differs: \(definition)")
    }

    func testAdministratorRuleRejectsMissingRequiredPolicyFields() {
        for key in administratorRule.keys {
            var definition = administratorRule
            definition.removeValue(forKey: key)
            XCTAssertFalse(UninstallHelperAuthorization.isExpectedAdministratorRule(definition), "Accepted missing \(key)")
        }
    }

    func testAdministratorRuleRejectsSharedRootOrSessionOwnerCredentials() {
        let invalid: [(String, Any)] = [
            ("class", "allow"), ("class", "rule"), ("group", "everyone"), ("group", "staff"),
            ("shared", true), ("allow-root", true), ("session-owner", true),
            ("authenticate-user", false)
        ]
        for (key, value) in invalid {
            var definition = administratorRule
            definition[key] = value
            XCTAssertFalse(UninstallHelperAuthorization.isExpectedAdministratorRule(definition), "Accepted invalid \(key)")
        }
    }

    func testAdministratorRuleRejectsZeroOrExcessiveCredentialTimeout() {
        for timeout in [0, -1, 31, 300, "30", true] as [Any] {
            var definition = administratorRule
            definition["timeout"] = timeout
            XCTAssertFalse(UninstallHelperAuthorization.isExpectedAdministratorRule(definition), "Accepted timeout \(timeout)")
        }
    }

    func testAdministratorRuleRejectsDelegationMechanismsAndUnknownEffects() {
        let invalid: [(String, Any)] = [
            ("rule", ["allow"]), ("mechanisms", ["builtin:authenticate"]),
            ("k-of-n", 0), ("entitled", true), ("entitled-group", true),
            ("allow-any", true), ("future-policy-effect", false)
        ]
        for (key, value) in invalid {
            var definition = administratorRule
            definition[key] = value
            XCTAssertFalse(UninstallHelperAuthorization.isExpectedAdministratorRule(definition), "Accepted extra policy field \(key)")
        }
    }

    func testAdministratorRuleRequiresPositiveIntegerTries() {
        for tries in [1, 3, 10] {
            var definition = administratorRule
            definition["tries"] = tries
            XCTAssertTrue(UninstallHelperAuthorization.isExpectedAdministratorRule(definition))
        }
        for tries in [0, -1, 1.5, "3", false, true] as [Any] {
            var definition = administratorRule
            definition["tries"] = tries
            XCTAssertFalse(UninstallHelperAuthorization.isExpectedAdministratorRule(definition), "Accepted tries \(tries)")
        }
    }

    func testAuthorizationFlagsAcquireRealRightsAndHelperCannotInteract() {
        let client = UninstallHelperAuthorization.clientAuthorizationFlags
        let helper = UninstallHelperAuthorization.helperAuthorizationFlags
        XCTAssertEqual(client, [.interactionAllowed, .extendRights])
        XCTAssertEqual(helper, [.extendRights])
        XCTAssertFalse(client.contains(.preAuthorize))
        XCTAssertFalse(helper.contains(.preAuthorize))
        XCTAssertFalse(helper.contains(.interactionAllowed))
        XCTAssertFalse(client.contains(.partialRights))
        XCTAssertFalse(helper.contains(.partialRights))
    }

    func testRootAndMissingAccountCannotBecomeInteractiveCaller() {
        XCTAssertThrowsError(try UninstallHelperCaller.resolve(userUID: 0))
        XCTAssertThrowsError(try UninstallHelperCaller.resolve(userUID: uid_t.max))
    }

    func testHomeMustBeLocalOwnedDirectoryNotSymlinkOrWorldWritable() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("UninstallHelperIPC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        // Foundation may abbreviate /private/tmp to /tmp even after resolving
        // symlinks. The positive control needs an actual physical directory path.
        let physical = try XCTUnwrap(realpath(home.path, nil))
        let homePath = String(cString: physical)
        free(physical)
        XCTAssertNoThrow(try UninstallHelperCaller.validateHome(homePath, userUID: geteuid()))
        XCTAssertThrowsError(try UninstallHelperCaller.validateHome(homePath + "/.", userUID: geteuid()))
        XCTAssertThrowsError(try UninstallHelperCaller.validateHome(homePath, userUID: geteuid() + 1))
        let linkPath = (homePath as NSString).deletingLastPathComponent + "/linked-home"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: homePath)
        XCTAssertThrowsError(try UninstallHelperCaller.validateHome(linkPath, userUID: geteuid()))
        try FileManager.default.setAttributes([.posixPermissions: 0o707], ofItemAtPath: home.path)
        XCTAssertThrowsError(try UninstallHelperCaller.validateHome(homePath, userUID: geteuid()))
        XCTAssertThrowsError(try UninstallHelperCaller.validateHome("/", userUID: geteuid()))
    }
}
